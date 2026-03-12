#!/bin/zsh
#
# ArchitectureScan
#
# by: Scott Kendall
#
# Written: 03/05/2026
# Last updated: 03/11/2026
#
# Script Purpose: Scan a finder directory (and sub-folders) to make sure all files are windows "safe"
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="WindowsFileNameFix"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX")
DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")
TMP_FILE_STORAGE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")

chmod 666 $JSON_DIALOG_BLOB
chmod 666 $DIALOG_COMMAND_FILE
chmod 666 $TMP_FILE_STORAGE

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles)
    SD_BANNER_IMAGE="${SUPPORT_DIR}$(defaults read "$DEFAULTS_DIR" BannerImage)"
    SPACING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    SPACING=5 #5 spaces to accommodate for icon offset
fi
BANNER_TEXT_PADDING="${(j::)${(l:$SPACING:: :)}}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Windows FileName Fix"
SD_ICON_FILE="https://files.softicons.com/download/business-icons/ecommerce-and-business-icons-by-designcontest.com/ico/bar-code.ico"
SD_OVERLAY_ICON="https://files.softicons.com/download/system-icons/colobrush-icons-by-eponas-deeway/ico/icone_windows.ico"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"
TARGET_PATH=${4:-"$USER_DIR/Library/CloudStorage/OneDrive-GiantEagle,Inc"}


####################################################################################################
#
# Functions
#
####################################################################################################

function admin_user ()
{
    [[ $UID -eq 0 ]] && return 0 || return 1
}

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
    if admin_user; then
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
    if admin_user; then
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
    else
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"
    fi
}

function check_for_sudo ()
{
	# Ensures that script is run as ROOT
    if ! admin_user; then
    	MainDialogBody=(
        --message "**Admin access required!**<br><br>In order for this script to function properly, it must be run as an admin user!"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --width 700
        --titlefont shadow=1
        --button1text "OK"
    )
    	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
		cleanup_and_exit 1
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
    fi
    SD_VERSION=$( ${SW_DIALOG} --version) 
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

	/usr/local/bin/jamf policy -event ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -event ${SUPPORT_FILE_INSTALL_POLICY}
    [[ $(which jq) == *"not found"* ]] && /usr/local/bin/jamf policy -event ${JQ_INSTALL_POLICY}
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
    SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
    SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
}

function check_logged_in_user ()
{    
    # PURPOSE: Make sure there is a logged in user
    # RETURN: None
    # EXPECTED: $LOGGED_IN_USER
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in, exiting"
        cleanup_and_exit 0
    else
        logMe "INFO: User $LOGGED_IN_USER is logged in"
    fi
}

function cleanup_and_exit ()
{
  [[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
  [[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
  [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
  exit $1
}

function construct_dialog_header_settings ()
{
    # Construct the basic Swift Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "message" : "'$1'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${SD_OVERLAY_ICON}'",
        "ontop" : "true",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1",
        "button1text" : "Wait",
        "button2text" : "OK",
        "moveable" : "true",
        "height" : "80%",
        "width" : "900",
        "json" : "true", 
        "ignorednd" : "true",
        "quitkey" : "0",'
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - type of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    # EXPECTED: None


    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "" "first"

    for item in "${APP_LIST[@]}"; do
        name=${item:t}
        create_listitem_message_body "$name" "" "" "Pending..." "pending" ""
    done
    create_listitem_message_body "" "" "" "" "" "last"
    update_display_list "Create"
}

function create_listitem_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},
    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title 
    #        $2 - icon
    #        $3 - status text (for display)
    #        $4 - status
    #        $5 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    [[ "$6:l" == "first" ]] && line+='"button1disabled" : "true", "listitem" : ['
    [[ ! -z $1 ]] && [[ ! -z $2 ]] && line+='{"title" : "'$1'", "subtitle" : "'$2'", "icon" : "'$3'", "status" : "'$5'", "statustext" : "'$4'"},'
    [[ ! -z $1 ]] && [[ -z $2 ]] && line+='{"title" : "'$1'", "icon" : "'$3'", "status" : "'$5'", "statustext" : "'$4'"},'
    [[ "$6:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function update_display_list ()
{
    # setopt -s nocasematch
    # This function updates the Swift Dialog list display with easy to implement parameter passing...
    # The Swift Dialog native structure is very strict with the command structure...this routine makes
    # it easier to implement
    #
    # Param list
    #
    # $1 - Action to be done ("Create", "Add", "Change", "Clear", "Info", "Show", "Done", "Update")
    # ${2} - Affected item (2nd field in JSON Blob listitem entry)
    # ${3} - Icon status "wait, success, fail, error, pending or progress"
    # ${4} - Status Text
    # $5 - Progress Text (shown below progress bar)
    # $6 - Progress amount
            # increment - increments the progress by one
            # reset - resets the progress bar to 0
            # complete - maxes out the progress bar
            # If an integer value is sent, this will move the progress bar to that value of steps
    # the GLOB :l converts any inconing parameter into lowercase
    
    case "${1:l}" in
 
        "create" | "show" )
 
            # Display the Dialog prompt
            $SW_DIALOG --progress --jsonfile "${JSON_DIALOG_BLOB}" --commandfile "${DIALOG_COMMAND_FILE}" & sleep .2
            DIALOG_PROCESS=$! #Grab the process ID of the background process
            ;;

        "buttondisable" )

            # disable button 1
            /bin/echo "button1: disable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonenable" )

            # Enable button 1
            /bin/echo "button1: enable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonchange" )

            # change text of button 1
            /bin/echo "button1text: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar
            /bin/echo "listitem: title: ${3}, status: ${5}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"

            /bin/sleep .5
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: ${5}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "createlist" )

            # Construct a list with the names of the files that were discovered
            echo "list: " >> "${DIALOG_COMMAND_FILE}"
            echo "listitem: delete, index: 0" >> ${DIALOG_COMMAND_FILE}
            ;;
    esac
}

####################################################################################################
#
# Script Specific Functions
#
####################################################################################################

function welcomemsg ()
{
    message="$SD_DIALOG_GREETING $SD_FIRST_NAME.  "
    message+="When you save files to the cloud (like **OneDrive**), Windows has specific rules for how they can be named. To make sure your files sync correctly and don't get lost, some corrections need to be made."
    message+="<br><br>Starting scan at: **$TARGET_PATH**<br> "
    preload_apps
    APP_LIST=("${reply[@]}")

    construct_dialog_header_settings $message > "${JSON_DIALOG_BLOB}"
    echo "}" >> "${JSON_DIALOG_BLOB}"
    update_display_list "Create"
    update_display_list "buttondisable"

    # show the applications in a list
    populate_list

    # 2nd pass which actually changes the names
    scan_apps
    update_display_list "progress" "" "" "" "" 100
    [[ $writeLog == "yes" ]] && update_display_list "buttonchange" "Export" || update_display_list "buttonchange" "Done"
    update_display_list "buttonenable"
    wait

    buttonpress=$?
    if [[ $writeLog == "yes" ]] && [[ $buttonpress == 0 ]]; then
        export_failed_items
    fi
}

function preload_apps () 
{
    find "$TARGET_PATH" -depth -not -path '*/.*' | while read -r app; do
        [[ -n "$EXCLUSION_LIST" && "${app}" =~ "$EXCLUSION_LIST" ]] && continue
        reply+=("$app")
    done
    APPLIST_COUNT=$#reply
}

function scan_apps ()
{
    local writeLog="no"
    local dir_name base_name new_name check_res appStatus final_path path_length relative_path scanned
    echo "Old File","New File","Reason" >> "${TMP_FILE_STORAGE}"
    find "$TARGET_PATH" -depth -not -path '*/.*' -print0 | while read -r -d '' old_path; do

        # Set some default values
        appStatus="Passed"
        statusIcon="success"
        dir_name=$(dirname "$old_path")
        base_name=$(basename "$old_path")
        display_name="${old_path:h:t}/${old_path:t}"
    
        [[ -n "$EXCLUSION_LIST" && "${old_path}" =~ "$EXCLUSION_LIST" ]] && continue
        ((scanned++))
        
        # 1. Replace Illegal Characters (< > : " / \ | ? *)
        new_name=$(echo "$base_name" | sed 's/[<>:"\\|?*]/_/g')
        
        # 2. Scrub Trailing Periods and Spaces (Windows ignores these and breaks)
        new_name=$(echo "$new_name" | sed 's/[. ]*$//')
        
        # 3. Check Reserved Names
        check_res="${new_name%.*}"
        for res in "${reserved_names[@]}"; do
            if [[ "${check_res:u}" == "$res" ]]; then
                new_name="_${new_name}"
                appStatus="Reserved name"
                statusIcon="error"
                break
            fi
        done

        if [[ "$base_name" != "$new_name" && "$appStatus" != ("success"|"Reserved name") ]]; then
            appStatus="Illegal characters"
            statusIcon="error"
        fi

        # --- PATH STABILITY LOGIC ---
        final_path="$dir_name/$new_name"
        
        # 4. Check for max length

        # Strip the starting directory from the front of the path
        # The '#' operator removes the smallest matching prefix
        relative_path="${old_path#$TARGET_PATH}"
        
        # Remove leading slash if it remains after stripping
        relative_path="${relative_path#/}"
        
        # Calculate length of the remaining path
        path_length=${#relative_path}
        if [[ $path_length -ge 255 ]]; then
            appStatus="Path to Long"
            statusIcon="error"
        fi

        if [[ "$appStatus" != "Passed" ]]; then
            # Collision Check: Does the target name already exist?
            # On Mac, "File.txt" and "file.txt" can coexist; on Windows, they CANNOT.
            if [[ -e "$final_path" ]]; then
                extension="${new_name##*.}"
                filename="${new_name%.*}"
                # Append a timestamp to make it unique
                new_name="${filename}_$(date +%s).${extension}"
                final_path="$dir_name/$new_name"
            fi
            writeLog="yes"
            # Write to CSV log
            echo $old_path,$final_path,$appStatus >> "${TMP_FILE_STORAGE}"
            mv "${old_path}" "${final_path}"
            logMe "Changed name to: ${final_path}"
        fi
        echo "listitem: title: $display_name, subtitle: $new_name, status: $statusIcon, statustext: $appStatus" >> "${DIALOG_COMMAND_FILE}"
        update_display_list "progress" "" "" "" "" $((100*scanned/APPLIST_COUNT))
    done
}

function populate_list ()
{   
    update_display_list "createlist"
    for item in ${APP_LIST[@]}; do
        fileName="${item:h:t}/${item:t}"
        echo "listitem: add, title: ${fileName}, subtitle: ${item:t}, status: pending", statustext: pending >> "${DIALOG_COMMAND_FILE}"
    done
}

function export_failed_items ()
{
    logMe "Changed files list stored in $EXPORTED_LIST"
    mv "${TMP_FILE_STORAGE}" $EXPORTED_LIST
} 

####################################################################################################
#
# Main Script
#
####################################################################################################
local APPLIST_COUNT=$(find "$TARGET_PATH" -not -path '*/.*' | wc -l | xargs)
local -a APP_LIST
local reserved_names=(CON PRN AUX NUL COM0 COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9 LPT0 LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9)
local EXCLUSION_LIST="sparsebundle|Icon"
local EXPORTED_LIST="$USER_DIR/Desktop/ChangedFiles.csv"

autoload 'is-at-least'

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg
cleanup_and_exit 0
