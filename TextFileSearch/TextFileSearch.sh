#!/bin/zsh
#
# KeySearch
#
# by: Scott Kendall
#
# Written: 12/15/2023
# Last updated: 07/30/2026
#
# Script Purpose: Method for searching through user script files for specific text or keys
#
# 1.0 - Initial
# 1.1 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - truncated the log_body to 2000 characters to avoid SD crashing on large results
#       Included .mobileconfig and .bash files in the search filetypes
#       Added a check to ensure that the destination path is inside the logged-in user's home directory
#       Defined local variables
#       Verifed logged in user and home directory before proceeding
#       Added a check to ensure that the source path is not a sensitive system path
#       Added a check to ensure that the destination path is not a symlink
#       Added a check to ensure that the source path is not a symlink
#       Verified that defaults file variables are not empty before using them
#       Verified that search criteria is not empty before proceeding
#       Added timestamp to output file name
#       Defaulted output file to users desktop
#       Sanitized with MS Copilot

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="TextFileSearch"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
if [[ -z "$LOGGED_IN_USER" ]]; then
    echo "ERROR: No logged-in user detected."
    exit 1
fi
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
if [[ -z "$USER_DIR" || ! -d "$USER_DIR" ]]; then
    echo "ERROR: Unable to determine home directory for $LOGGED_IN_USER."
    exit 1
fi

FREE_DISK_SPACE=$(( $(/bin/df -g / | /usr/bin/awk 'NR==2 {print $4}') ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

TMP_FILE_STORAGE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
TMP_PREVIEW_STORAGE=$(mktemp "/var/tmp/${SCRIPT_NAME}_preview.XXXXX")
chmod 600 "$TMP_PREVIEW_STORAGE"
chmod 600 "$TMP_FILE_STORAGE"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_PLIST="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_PLIST" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_PLIST" SupportFiles 2>/dev/null)
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_PLIST" BannerImage 2>/dev/null)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_PLIST" BannerPadding 2>/dev/null)
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_PLIST" BannerSubtitle 2>/dev/null)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_PLIST" TitleFontColor 2>/dev/null)
fi
[[ -z "$SUPPORT_DIR" ]] && SUPPORT_DIR="/Library/Application Support/GiantEagle"
[[ -z "$SD_BANNER_IMAGE" ]] && SD_BANNER_IMAGE="GE_SD_BannerImage.png"
[[ -z "$BANNER_TEXT_PADDING" ]] && BANNER_TEXT_PADDING=10
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Text File Search"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="${ICON_FILES}ClippingText.icns"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"    

####################################################################################################
#
# Global Functions
#
####################################################################################################

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
    if running_as_root; then
        LOG_DIR=${LOG_FILE%/*}
        [[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
        /bin/chmod 755 "${LOG_DIR}"

        # If the log file does not exist - create it and set the permissions
        [[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
        /bin/chmod 644 "${LOG_FILE}"
    fi
}

function logMe () 
{
    # Basic two pronged logging function that will log like this:
    #
    # 20231204 12:00:00: Some message here
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    # if the user is an admin, it will write to the logfile, otherwise it will just echo to the screen
    #
    # RETURN: None
    if running_as_root; then
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | /usr/bin/tee -a "${LOG_FILE}"
    else
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"
    fi
}

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None

    logMe "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$("${SW_DIALOG}" --version)      
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else    
        logMe "Swift Dialog is currently running: ${SD_VERSION}"
    fi
}

function install_swift_dialog ()
{
    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install Swift Dialog."
        cleanup_and_exit 1
    fi

    /usr/local/bin/jamf policy -event "${DIALOG_INSTALL_POLICY}"
    local jamf_exit="$?"

    if [[ "$jamf_exit" -ne 0 ]]; then
        logMe "ERROR: Jamf policy failed while installing Swift Dialog. Exit code: $jamf_exit"
        cleanup_and_exit 1
    fi

    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "ERROR: Swift Dialog still missing after install attempt."
        cleanup_and_exit 1
    fi
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && [[ "${SD_BANNER_IMAGE}" =~ \.(jpg|png|heic)$ ]] && /usr/local/bin/jamf policy -event "${SUPPORT_FILE_INSTALL_POLICY}"
}

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="{serialnumber}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Free Space<br>"
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
}

function cleanup_and_exit ()
{
    [[ -n "$JSON_OPTIONS" && -f "$JSON_OPTIONS" ]] && /bin/rm -f -- "$JSON_OPTIONS"
    [[ -n "$TMP_FILE_STORAGE" && -f "$TMP_FILE_STORAGE" ]] && /bin/rm -f -- "$TMP_FILE_STORAGE"
    [[ -n "$DIALOG_COMMAND_FILE" && -f "$DIALOG_COMMAND_FILE" ]] && /bin/rm -f -- "$DIALOG_COMMAND_FILE"
    [[ -n "$TMP_PREVIEW_STORAGE" && -f "$TMP_PREVIEW_STORAGE" ]] && /bin/rm -f -- "$TMP_PREVIEW_STORAGE"
    exit $1
}

function running_as_root ()
{
    [[ $UID -eq 0 ]] && return 0 || return 1
}

####################################################################################################
#
# App Specific Functions
#
####################################################################################################

function welcomemsg ()
{
    local windowHeight
    local message
    local temp
    local returnCode
    local criteria
    local start
    windowHeight=$((420 + $SEARCH_CRITERIA * 20))
    message="This script will scan through the selected folder and search for lines containing your search string. Enter up to $SEARCH_CRITERIA search criteria below:<br><br>"
	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 920
        --height $windowHeight
        --moveable
        --ignorednd
        --quitkey 0
    )
    start=1
    for ((i = start; i <= $SEARCH_CRITERIA; i++)); do
        if [[ -n "${SEARCH_FOR_KEYS[i]}" ]]; then
            MainDialogBody+=(--textfield "Search Criteria $i",value="${SEARCH_FOR_KEYS[i]}")
        else
            MainDialogBody+=(--textfield "Search Criteria $i")
        fi
    done
    
    MainDialogBody+=(
        --textfield "Starting Directory",fileselect,filetype=folder,required,name=SourceFiles
        --button1text "OK"
        --button2text "Cancel"
    )

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ "$returnCode" == "2" ]] && {logMe "Cancel..."; cleanup_and_exit 0; }

    sourceFiles=$(printf '%s\n' "$temp" | /usr/bin/awk -F ': ' '/SourceFiles/ {print $2; exit}')

    # Build the search array from search keys
    
    SEARCH_FOR_KEYS=()
    start=1
    for ((i = start; i <= $SEARCH_CRITERIA; i++)); do
        criteria=$(printf '%s\n' "$temp" | awk -F ': ' "/Criteria $i/ {print \$2; exit}")
        if [[ -n "$criteria" ]] && SEARCH_FOR_KEYS+=("$criteria")
    done
    if [[ "${#SEARCH_FOR_KEYS[@]}" -eq 0 ]]; then
        logMe "ERROR: No search criteria entered."
        cleanup_and_exit 1
    fi
}

function scan_files ()
{
    local start
    local i
    local item
    local filename
    local line_number
    local line_content
    local remainder

    printf '"File","Line","Match"\n' > "$TMP_FILE_STORAGE"

    start=1

    for ((i = start; i <= SEARCH_CRITERIA; i++)); do
        item="${SEARCH_FOR_KEYS[i]}"

        [[ -z "$item" ]] && continue

        logMe "Searching for '$item' in '$sourceFiles'"

        /usr/bin/grep -R -I -F -i -n \
            --include="*.txt" \
            --include="*.sh" \
            --include="*.zsh" \
            --include="*.mobileconfig" \
            --include="*.bash" \
            --exclude-dir=".git" \
            --exclude-dir="node_modules" \
            --exclude-dir=".venv" \
            -- "$item" "$sourceFiles" 2>/dev/null | while IFS= read -r result; do

            filename="${result%%:*}"

            remainder="${result#*:}"
            line_number="${remainder%%:*}"
            line_content="${remainder#*:}"

            process_result "$filename" "$line_number" "$line_content"
        done
    done
}

function csv_escape()
{
    local value="$1"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

function process_result ()
{
    local full_path="$1"
    local line_number="$2"
    local line_content="$3"
    local filename

    filename="${full_path#$sourceFiles/}"

    {
        csv_escape "$filename"
        printf ','
        csv_escape "$line_number"
        printf ','
        csv_escape "$line_content"
        printf '\n'
    } >> "$TMP_FILE_STORAGE"
    printf '%s | %s | %s\n' "$filename" "$line_number" "$line_content" >> "$TMP_PREVIEW_STORAGE"
}

function import_results ()
{
    log_body=""
    logMe "Reading in and formatting results"

    while IFS= read -r item; do
        log_body+="${item}<br>"
    done < "${TMP_PREVIEW_STORAGE}"
}

function display_results ()
{
    log_length=2000
    log_body="${log_body:0:$log_length}"
	MainDialogBody=(
        --message "### Results Preview ###\n\n$log_body"
        --messagefont "size=14"
		--ontop
		--icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
		--width 900
        --height 600
        --resizeable
        --moveable
		--quitkey 0
        --selecttitle "Save As:",radio --selectvalues "CSV, Text"
        --textfield "Directory to store results",fileselect,filetype=folder,required,name=DestOutput,value="${USER_DIR}/Desktop"
        --vieworder "radiobutton, textfield, checkbox"
		--button1text "Save"
		--button2text "Cancel"
    )
	# Show the dialog screen and allow the user to choose
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null) 
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit 0

    destPath=$(echo $temp | grep "DestOutput" | awk -F ":" '{print $2}' | xargs)
    outputType=$(echo $temp | grep "SelectedOption" | awk -F ":" '{print $2}' | xargs )
    save_results
}	

function validate_source_path ()
{
    if [[ -z "$sourceFiles" || ! -d "$sourceFiles" ]]; then
        logMe "ERROR: Source path is invalid: $sourceFiles"
        cleanup_and_exit 1
    fi

    case "$sourceFiles" in
        /etc|/etc/*|/private/etc|/private/etc/*|/var/db|/var/db/*|/Library/Keychains|/Library/Keychains/*|/Users/*/Library/Keychains|/Users/*/Library/Keychains/*)
            logMe "ERROR: Refusing to search sensitive path: $sourceFiles"
            cleanup_and_exit 1
            ;;
    esac
}

function validate_output_path ()
{
    if [[ -z "$destPath" || ! -d "$destPath" ]]; then
        logMe "ERROR: Destination path is invalid: $destPath"
        cleanup_and_exit 1
    fi

    # Optional but recommended: only allow saving inside the logged-in user's home directory.
    case "$destPath" in
        "$USER_DIR"/*|"$USER_DIR")
            ;;
        *)
            logMe "ERROR: Destination must be inside $USER_DIR"
            cleanup_and_exit 1
            ;;
    esac
}

function save_results ()
{
    local outputFilename=""
    local exit_code=0
    local timestamp=$(/bin/date '+%Y%m%d_%H%M%S')

    case "${outputType:l}" in
        "csv" )
            outputFilename="${destPath}/${OUTPUT_NAME}_${timestamp}.csv"
            if [[ -L "$outputFilename" ]]; then
                logMe "ERROR: Refusing to write to symlink: $outputFilename"
                cleanup_and_exit 1
            fi

            /bin/cp "$TMP_FILE_STORAGE" "$outputFilename"
            exit_code=$?
            ;;
        "text" )
            outputFilename="${destPath}/${OUTPUT_NAME}_${timestamp}.txt"
            if [[ -L "$outputFilename" ]]; then
                logMe "ERROR: Refusing to write to symlink: $outputFilename"
                cleanup_and_exit 1
            fi

            /bin/cp "$TMP_PREVIEW_STORAGE" "$outputFilename"
            exit_code=$?
            ;;
        * )
            logMe "ERROR: Unknown output type: $outputType"
            exit_code=1
            ;;
    esac
    
    if [[ "$exit_code" -eq 0 ]]; then
        /usr/sbin/chown "$LOGGED_IN_USER":staff "$outputFilename" 2>/dev/null
        /bin/chmod 600 "$outputFilename" 2>/dev/null
        logMe "Saving file: $outputFilename"
        /usr/bin/open "$destPath"
    else
        logMe "ERROR: Failed to save file: $outputFilename"
    fi

    cleanup_and_exit "$exit_code"
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare sourceFiles
declare destPath
declare destFile
declare log_body
declare outputType
declare OUTPUT_NAME

# number of search criteria to allow
SEARCH_CRITERIA=5
# pre-programmed search criteria
SEARCH_FOR_KEYS=(JSSResource/ /api/)
# Results Filename
OUTPUT_NAME="Search_Results"

create_log_directory

if running_as_root; then 
    logMe "INFO: Running with root privileges"
fi

check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg
validate_source_path
scan_files

if [[ ! -s "$TMP_PREVIEW_STORAGE" ]]; then
    logMe "No results found."
    log_body="No results found."
else
    import_results
fi

display_results