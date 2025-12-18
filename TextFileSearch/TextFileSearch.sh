#!/bin/zsh
#
# KeySearch
#
# by: Scott Kendall
#
# Written: 12/15/2023
# Last updated: 12/17/2025
#
# Script Purpose: Method for search thru all users scripts for specific text (or keys)
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="TextFileSearch"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$( /usr/bin/sw_vers -productName )
MACOS_VERSION=$( /usr/bin/sw_vers -productVersion )
MAC_RAM=$( /usr/sbin/sysctl -n hw.memsize 2>/dev/null | /usr/bin/awk '{printf "%.0f GB", $1/1024/1024/1024}' )
MAC_CPU=$( /usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null )
# Fallback to uname if sysctl fails
#[[ -z "$MAC_CPU" ]] && [[ "$(/usr/bin/uname -m)" == "arm64" ]] && MAC_CPU="Apple Silicon" || MAC_CPU="Intel"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

TMP_FILE_STORAGE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
chmod 666 $TMP_FILE_STORAGE

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
    SD_BANNER_IMAGE=$SUPPORT_DIR$(defaults read $DEFAULTS_DIR "BannerImage")
    spacing=$(defaults read $DEFAULTS_DIR "BannerPadding")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Text File Search"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="${ICON_FILES}ClippingText.icns"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"    

####################################################################################################
#
# Functions
#
####################################################################################################

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
	LOG_DIR=${LOG_FILE%/*}
	[[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
	/bin/chmod 755 "${LOG_DIR}"

	# If the log file does not exist - create it and set the permissions
	[[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
	/bin/chmod 644 "${LOG_FILE}"
}

function logMe () 
{
    # Basic two pronged logging function that will log like this:
    #
    # 20231204 12:00:00: Some message here
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    #
    # RETURN: None
    if admin_user; then
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
        echo "admin user" 1>&2
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
        SD_VERSION=$( ${SW_DIALOG} --version)        
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
    # Install Swift dialog From JAMF
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
    #
    # RETURN: None

	/usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
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
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function admin_user ()
{
    [[ $UID -eq 0 ]] && return 0 || return 1
}

function welcomemsg ()
{
    windowHeight=$((420 + $SEARCH_CRITERIA * 20))
    message="This script will scan thru all of your chosen folder(s) and search for any lines that might contain yor search string.  Enter up to $SEARCH_CRITERIA search criteria below:<br><br>"
	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 920
        --height $windowHeight
        --ignorednd
        --quitkey 0
    )
    start=1
    for ((i = start; i <= $SEARCH_CRITERIA; i++)); do
        if [[ ! -z $SEARCH_FOR_KEYS[i] ]]; then
            MainDialogBody+=(--textfield "Search Criteria $i",value=$SEARCH_FOR_KEYS[i])
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

    sourceFiles=$(echo $temp | grep "SourceFiles" | awk -F ":" '{print $2}' | xargs)

    # Build the search array from search keys
    
    SEARCH_FOR_KEYS=()
    start=1
    for ((i = start; i <= $SEARCH_CRITERIA; i++)); do
        criteria=$(echo $temp | grep "Criteria $i" | awk -F ":" '{print $2}' | xargs)
        if [[ ! -z $criteria ]] && SEARCH_FOR_KEYS+=($criteria)
    done
}

function scan_files ()
{
    start=1
    for ((i = start; i <= $SEARCH_CRITERIA; i++)); do
        item=${SEARCH_FOR_KEYS[i]}
        if [[ -z $item ]]; then
            continue
        fi
        logMe "Searching for $item in $sourceFiles"
        # Search with grep and process each result
        # If you need to add more search criteria, add '--include "*.<ext>' to the below line
        grep -r -i -n "$item" "$sourceFiles" --include="*.txt" --include="*.sh" --include "*.zsh" --include "*.bash" | while IFS=: read -r filename line_number line_content; do
            process_result "$filename" "$line_number" "$line_content"
        done
    done
}

function process_result ()
{
    # Purpose: export the grep results into a file
    # PARMS $1 - filename
    #       $2 - Line # from grep results
    #       $3 - script line of found results
    # RETURN: None   
    local line_number="$2"
    local line_content="$3"
    filename=$(echo "${1//$sourceFiles/}")
    echo "$filename, $line_number, $line_content" >> "$TMP_FILE_STORAGE"
}

function import_results ()
{
    log_body=""
    logMe "Reading in and formatting results"
    while IFS= read -r item; do
        # If you want to format your results different, change the AWK fields here
        item=$(echo $item | awk -F',' '{print $1 " | " $2 " | " $3}')
        log_body+="$item<br>"
    done < "${TMP_FILE_STORAGE}"
}

function display_results ()
{
	MainDialogBody=(
        --message "### Results Preview ###\n\n$log_body"
       --messagefont "size=14"
		--ontop
		--icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --titlefont shadow=1
		--width 900
        --height 600
        --moveable
		--quitkey 0
        --selecttitle "Save As:",radio --selectvalues "CSV, Text"
        --textfield "Directory to store results",fileselect,filetype=folder,required,name=DestOutput,value=$sourceFiles
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

function save_results ()
{
    # If you want to save in other formats:
    # 1.  Add the format option in Line #312 above
    # 2.  Add the appropriate case statement to process format
    # 3.  Add in programming code to process the the format

    local outputFilename=""
    exit_code=0
    case "${outputType:l}" in
        "csv" )
            outputFilename="${destPath}/${OUTPUT_NAME}.csv"
            cp $TMP_FILE_STORAGE $outputFilename
            ;;
        "text" )
            outputFilename="${destPath}/${OUTPUT_NAME}.txt"
            cat $TMP_FILE_STORAGE | awk -F ',' '{print $1 " | " $2 " | " $3}' > $outputFilename
            ;;
        * )
            logMe "An error has occurred while processing file"
            exit_code=1
        ;;
    esac
    [[ $exit_code == 0 ]] && logMe "Saving file: $outputFilename"

    # Open the finder window to show the results
    open $destPath
    cleanup_and_exit $exit_code
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

check_root_privileges
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg
scan_files
import_results
display_results
