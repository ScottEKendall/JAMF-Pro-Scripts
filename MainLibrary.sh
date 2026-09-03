#!/bin/zsh
#
# Main Library
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 09/03/2026
#
# Script Purpose: Main Library containing all of my commonly used functions.
#
# 1.0 - Initial
# 1.1 - Code optimization
# 1.1 - Changed the get_nic_info logic
# 1.2 - renamed all JAMF functions to start with JAMF_.....
# 1.3 - Changed JAMF function names to be more descriptive
# 1.4 - Added listitem, textbox, checkbox and dropdown functions
# 1.5 - Reworked top section for better idea of what can be modified
#       New create_log_directory check routine that parses the path and checks the directory structure
# 1.6 - Add several new MS Graph API routines
# 1.7 - Add more JAMF API Libraries for Static Group modifications & Checking to see which version of SS/SS+ is being used
# 1.8 - Added option to move some of the "defaults" to a plist file / Also used the variable SCRIPT_for temp files creation & log file cname
# 1.9 - Add more JAMF functions
#       Add Check for focus mode
# 1.10 -Added static group functions
# 1.11 -Removed dependencies of using systemprofiler command and use sysctl instead
#       Add RunAsUser & check_logged_in_user command
#       Changed create_infobox_message to use new OS & version variables
# 1.12 -Added function "admin_user" to detect if user is admin or not. 
#       Changed logging functions to only record if a user is admin
# 1.13 -Added more JAMF API calls
# 1.14 -Optimized Common section
#       Added functions for check_display_sleep and logged_in_user
#       Added JAMF DDM libraries
# 1.15 - Add functions to detect touchID, enable TouchID & enable pluginkit extensions
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Updates based on MS Copilot review

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME=""
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
MAIN_PID=$$

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"


###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
echo "Setting Default values"
SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles 2>/dev/null) || SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage 2>/dev/null) || SD_BANNER_IMAGE="GE_SD_BannerImage.png"
BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding 2>/dev/null) || BANNER_TEXT_PADDING=10
BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle 2>/dev/null) || BANNER_SUBTITLE=""
BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor 2>/dev/null) || BANNER_TEXT_COLOR="white"

[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE=""
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="/System/Applications/App Store.app"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_INSTALL_POLICY="install_jq"

APP_EXTENSIONS=("com.microsoft.CompanyPortalMac.ssoextension"
                "com.microsoft.CompanyPortalMac.Mac-Autofill-Extension")

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"
CLIENT_ID=${4}                               # user name for JAMF Pro
CLIENT_SECRET=${5}
[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF credentials we are using 

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
    local LOG_DIR="${LOG_FILE%/*}"

    admin_user || return 0

    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {print -u2 "ERROR: Unable to create log directory: ${LOG_DIR}"; return 1; }
    fi
    chmod 755 "$LOG_DIR" || {print -u2 "ERROR: Unable to set permissions on: ${LOG_DIR}"; return 1; }
    # If the log file does not exist - create it and set the permissions
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE" || {print -u2 "ERROR: Unable to create log file: ${LOG_FILE}"; return 1;}
    fi

    chmod 640 "$LOG_FILE" || {print -u2 "ERROR: Unable to secure log file: ${LOG_FILE}"; return 1;}
    return 0
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
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | /usr/bin/tee -a "${LOG_FILE}"
    else
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"
    fi
}

function check_swift_dialog_install ()
{
    local SD_VERSION

    logMe "Ensuring that SwiftDialog is installed..."

    if [[ ! -x "$SW_DIALOG" ]]; then
        logMe "SwiftDialog is missing. Attempting installation."

        if ! install_swift_dialog || [[ ! -x "$SW_DIALOG" ]]; then
            logMe "ERROR: SwiftDialog installation failed." >&2
            return 1
        fi
    fi

    if ! SD_VERSION=$("$SW_DIALOG" --version ); then #2>/dev/null); then
        logMe "ERROR: Unable to determine SwiftDialog version." >&2
        return 1
    fi

    if [[ -z "$SD_VERSION" ]]; then
        logMe "ERROR: SwiftDialog returned an empty version." >&2
        return 1
    fi

    if ! is-at-least "$MIN_SD_REQUIRED_VERSION" "$SD_VERSION"; then
        logMe "SwiftDialog ${SD_VERSION} is outdated. Attempting update."

        if ! install_swift_dialog; then
            logMe "ERROR: SwiftDialog update failed." >&2
            return 1
        fi

        if ! SD_VERSION=$("$SW_DIALOG" --version 2>/dev/null); then
            logMe "ERROR: Unable to read SwiftDialog version after update." >&2
            return 1
        fi

        if ! is-at-least "$MIN_SD_REQUIRED_VERSION" "$SD_VERSION"; then
            logMe "ERROR: SwiftDialog remains below the required version." >&2
            return 1
        fi
    fi

    logMe "SwiftDialog version ${SD_VERSION} is available."
    return 0
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
    if [[ ! -e "$SD_BANNER_IMAGE" ]] && [[ "$SD_BANNER_IMAGE" =~ \.(jpg|png|heic)$ ]]; then
        if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"
        then
            logMe "WARNING: Support-file installation failed." >&2
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        if ! /usr/local/bin/jamf policy -event "$JQ_INSTALL_POLICY"; then
            logMe "ERROR: jq installation policy failed." >&2
            return 1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        logMe "ERROR: jq remains unavailable after installation." >&2
        return 1
    fi

    return 0
}

function initialize_user_context ()
{
    LOGGED_IN_USER=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ {print $3}')

    if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "loginwindow" ]]; then
        printf '%s\n' "INFO: No interactive user is logged in."
        return 1
    fi

    if ! USER_UID=$(id -u "$LOGGED_IN_USER"); then
        printf '%s\n' "ERROR: Unable to resolve UID for ${LOGGED_IN_USER}." >&2
        return 1
    fi

    if ! USER_DIR=$(dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory | awk '{ print $2 }'); then
        printf '%s\n' "ERROR: Unable to resolve home directory for ${LOGGED_IN_USER}." >&2
        return 1
    fi

    if [[ -z "$USER_DIR" || ! -d "$USER_DIR" ]]; then
        printf '%s\n' "ERROR: Invalid home directory for ${LOGGED_IN_USER}: ${USER_DIR}" >&2
        return 1
    fi

    Jamf_LOGGED_IN_USER="${Jamf_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${Jamf_LOGGED_IN_USER%%.*}}"

    CSV_PATH="${USER_DIR}/Desktop/DDM Data Dump for "
    DDM_CROSS_REF_FILE="${USER_DIR}/Documents/DDMCrossRef.csv"

    return 0
}

function create_infobox_message ()
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

function check_display_sleep ()
{
    # PURPOSE: Determine if the mac is asleep or awake.
    # RETURN: will return 0 if awake, otherwise will return 1
    # EXPECTED: None
    local sleepval=$(pmset -g systemstate | tail -1 | awk '{print $4}')
    local retval=0
    logMe "INFO: Checking sleep status"
    [[ "$sleepval" == "4" ]] && logMe "INFO: System appears to be awake" || { logMe "INFO: System appears to be asleep, will pause notifications"; retval=1; }
    return $retval
}

function dialog_cmd ()
{
    # Serialize SwiftDialog command-file writes from background workers.
    local command="$1"
    local attempts=0

    while ! mkdir "$DIALOG_LOCK_DIR" 2>/dev/null; do
        sleep 0.02
        (( attempts++ ))

        if (( attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for dialog command lock" >&2
            return 1
        fi
    done

    {
        if ! printf '%s\n' "$command" >> "$DIALOG_COMMAND_FILE"; then
            logMe "ERROR: Unable to write SwiftDialog command: $command" >&2
            return 1
        fi
    } always {
        rmdir "$DIALOG_LOCK_DIR" 2>/dev/null
    }

    return 0
}

function cleanup_files ()
{
    # Perform a clean-up on all of the temp files that were created at run-time
    (( ZSH_SUBSHELL == 0 )) || return 0
    [[ "$$" == "$MAIN_PID" ]] || return 0
    local file

    for file in \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE" \
        "$TMP_FILE_STORAGE"
    do
        [[ -n "$file" && -e "$file" ]] && rm -f -- "$file"
    done

    [[ -n "$RESULTS_DIR" && -d "$RESULTS_DIR" ]] && rm -rf -- "$RESULTS_DIR"
    [[ -n "$CSV_LOCK_DIR" && -d "$CSV_LOCK_DIR" ]] && rmdir "$CSV_LOCK_DIR" 2>/dev/null
    [[ -n "$DIALOG_LOCK_DIR" && -d "$DIALOG_LOCK_DIR" ]] && rmdir "$DIALOG_LOCK_DIR" 2>/dev/null
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - EXIT
    cleanup_files
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM
trap 'cleanup_files' EXIT

function check_for_sudo ()
{
	# Ensures that script is run as ROOT
    if ! admin_user; then
    	MainDialogBody=(
        --message "In order for this script to function properly, it must be run as an admin user!"
		--ontop
		--icon computer
		--overlayicon "$STOP_ICON"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
		--button1text "OK"
    )
    	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
		cleanup_and_exit 1
	fi
}

function make_temp_files ()
{
    
    JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog JSON file" >&2
        return 1
    }

    DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog command file" >&2
        return 1
    }

    TMP_FILE_STORAGE=$(mktemp "/var/tmp/${SCRIPT_NAME}_storage.XXXXX") || {
        logMe "ERROR: Unable to create temporary storage file" >&2
        return 1
    }

    RESULTS_DIR=$(mktemp -d "/var/tmp/${SCRIPT_NAME}_results.XXXXX") || {
        logMe "ERROR: Unable to create results counter directory" >&2
        return 1
    }

    chmod 700 "$RESULTS_DIR" || {
    logMe "ERROR: Unable to secure results counter directory" >&2
    return 1
    }

    CSV_LOCK_DIR="/var/tmp/${SCRIPT_NAME}.${MAIN_PID}.csv.lock"
    DIALOG_LOCK_DIR="/var/tmp/${SCRIPT_NAME}.${MAIN_PID}.dialog.lock"

    if ! /usr/sbin/chown "$USER_UID" \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"
    then
        logMe "ERROR: Unable to set temporary dialog-file ownership" >&2
        return 1
    fi

    if ! chmod 600 \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"
    then
        logMe "ERROR: Unable to secure temporary dialog files" >&2
        return 1
    fi

    if ! /usr/sbin/chown root:wheel "$TMP_FILE_STORAGE"; then
        logMe "ERROR: Unable to set temporary storage ownership" >&2
        return 1
    fi

    if ! chmod 600 "$TMP_FILE_STORAGE"; then
        logMe "ERROR: Unable to secure temporary storage file" >&2
        return 1
    fi

    return 0
}

function welcomemsg ()
{
    message=""

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
        --ignorednd
        --quitkey 0
        --button1text "OK"
        --button2text "Create Ticket"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ "$returnCode" == "2" ]] && {logMe "Cancel..."; break; }

    # Examples of how to extra data from returned string
    search_type=$(echo $temp | plutil -extract "SelectedOption" 'raw' -)
    computer_id=$(echo $temp | plutil -extract "Device" 'raw' -)
    reason=$(echo $temp | plutil -extract "Reason" 'raw' -)
}

function check_focus_status ()
{
    # PURPOSE: Check to see if the user is in focus mode
    # RETURN: in focus mode (Off/On)
    # EXPECTED: FOCUS_FILE is the location of FocusMode settings
    # PARAMETERS: None

    local results="off"
    if [[ -f "$FOCUS_FILE" ]] && grep -q '"storeAssertionRecords"' "$FOCUS_FILE" 2>/dev/null; then
        results="on"
    fi
    echo $results
}

function touch_id_status ()
{
    local hw="Absent"
    retval="$hw"
    local enrolled="false"
    local bioCount="0"
    # --- Detect Touch ID–capable hardware (internal or external) ---
    bioOutput=$(ioreg -l 2>/dev/null)

    # Check for the device entry indicating hardware presence
    if [[ $bioOutput == *"+-o AppleBiometricSensor"* ]]; then
        hw="Present"
    else
        # Fallback: Parse IOKitDiagnostics for class instance count
        if [[ $bioOutput =~ '"AppleBiometricSensor"=([0-9]+)' && ${match[1]} -gt 0 ]]; then
            hw="Present"
        # Fallback: Magic Keyboard with Touch ID
        elif system_profiler SPUSBDataType 2>/dev/null | grep -q "Magic Keyboard.*Touch ID"; then
            hw="Present"
        fi
    fi

    if [[ "${hw}" == "Present" ]]; then
        # Enrollment check

        bioCount=$(runAsUser bioutil -c 2>/dev/null | awk '/biometric template/{print $3}' | grep -Eo '^[0-9]+$' || echo "0")
        [[ "${bioCount}" -gt 0 ]] && enrolled="true"

        [[ "${enrolled}" == "true" ]] && retval="Enabled" || retval="Not enabled"
    fi
    echo "$retval"
}

function force_touch_id ()
{
    # PURPOSE: Forces touchID registration
    # RETURN: 0 if successful, 1 if aborted
    # EXPECTED: TOUCH_ID_STATUS = Status of TouchID sensor
    # PARAMETERS: None
    while true; do
        open "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension"
        "${SW_DIALOG}" \
        --title "Touch ID Required" \
        --message "Touch ID needs to be enabled on your system.  Please add at least one fingerprint.  Close this window when you are done adding your fingerprint." \
        --icon "SF=touchid,colour=auto" \
        --style mini \
        --position "topright" \
        --button1text "Close" \
        --button2text "Abort" \
        --quitkey 0 \
        --ontop \

        buttonpress=$?
        TOUCH_ID_STATUS=$(touch_id_status)
        [[ $TOUCH_ID_STATUS == "Enabled" || $buttonpress == 2 ]] && break
    done
    killall "System Settings" >/dev/null 2>&1
    # Set the status code
    [[ $buttonpress == 2 ]] && return 1 || return 0
}

function enable_app_extension ()
{
    # PURPOSE: Enable the auto fill extension for TouchID
    #          check each extension listed in the array to see if it is enabled in PlugKit
    # RETURN: None
    # EXPECTED: APP_EXTENSIONS array of extensions to check / enable
    # PARAMETERS: None
    # 

    for extension in "${APP_EXTENSIONS[@]}"; do
        logMe "Checking for extension: $extension"
        results=$(runAsUser pluginkit -m | grep "${extension}")
        # Check if extension exists
        if [[ -z $results ]]; then
            logMe "Error: Extension not found: ${extension}"
            logMe "Skipping..."
            continue
        fi
        logMe "Extension found: $extension"
        # Check if the extension is enabled
        if [[ $(echo $results | awk '{print $1}') == "+" ]]; then
            logMe "INFO: $extension is already enabled"
        else
            logMe "WARNING: $extension is not enabled. Enabling now..."
            runAsUser pluginkit -e use -i "${extension}"
            logMe "INFO: $extension has been enabled"
        fi
    done
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "**Problems retrieving Jamf Info**<br><br>Error Message: $1"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_for_sudo

if ! initialize_user_context; then
    cleanup_and_exit 0
fi

if ! create_log_directory; then
    cleanup_and_exit 1
fi

if ! check_swift_dialog_install; then
    cleanup_and_exit 1
fi

if ! check_support_files; then
    cleanup_and_exit 1
fi

if ! make_temp_files; then
    cleanup_and_exit 1
fi

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with Jamf credentials we are using
create_infobox_message

if ! Jamf_check_connection; then
    cleanup_and_exit 1
fi

if ! Jamf_check_credentials; then
    cleanup_and_exit 1
fi

if ! Jamf_get_server; then
    cleanup_and_exit 1
fi
OVERLAY_ICON=$(Jamf_which_self_service)

welcomemsg
exit 0

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
    # the GLOB :l converts any incoming parameter into lowercase

    
    case "${1:l}" in
 
        "create" )
            # Remove commands from any previous progress dialog.
            if ! : > "$DIALOG_COMMAND_FILE"; then
                logMe "ERROR: Unable to reset SwiftDialog command file" >&2
                return 1
            fi

            DIALOG_PROCESS=""
            if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
                logMe "ERROR: Constructed SwiftDialog JSON is invalid" >&2
                return 1
            fi
            "$SW_DIALOG" --progress --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" &

            DIALOG_PROCESS=$!

            if [[ -z "$DIALOG_PROCESS" ]]; then
                logMe "ERROR: Unable to capture the SwiftDialog process ID" >&2
                return 1
            fi

            return 0
            ;;
     
        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            dialog_cmd "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" 
            ;;

        "buttonaction" )

            # Change button 1 action
            dialog_cmd 'button1action: "'${2}'"'
            ;;
  
        "buttonchange" )

            # change text of button 1
            dialog_cmd "button1text: ${2}"
            ;;

        "buttondisable" )

            # disable button 1
            dialog_cmd "button1: disable"
            ;;

        "buttonenable" )

            # Enable button 1
            dialog_cmd "button1: enable"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar

            dialog_cmd "listitem: title: ${3}, status: ${5}, statustext: ${4}"
            [[ -n "$6" ]] && dialog_cmd "progress: ${6}"
            ;;

  
        "clear" )
  
            # Clear the list and show an optional message  
            dialog_cmd "list: clear"
            dialog_cmd "message: ${2}"
            ;;
  
        "delete" )
  
            # Delete item from list  
            dialog_cmd "listitem: delete, title: ${2}"
            ;;
 
        "destroy" )
     
            # Kill the progress bar and clean up
            dialog_cmd "quit:"
            ;;
 
        "done" )
          
            # Complete the progress bar and clean up  
            dialog_cmd "progress: complete"
            dialog_cmd "progresstext: $5"
            ;;
          
        "icon" )
  
            # set / clear the icon, pass <nil> if you want to clear the icon  
            [[ -z ${2} ]] && dialog_cmd "icon: none" || dialog_cmd "icon: ${2}"
            ;;
  
  
        "image" )
  
            # Display an image and show an optional message  
            dialog_cmd "image: ${2}"
            [[ -n ${3} ]] && dialog_cmd "progresstext: $5"
            ;;
  
        "infobox" )
  
            # Show text message  
            dialog_cmd "infobox: ${2}"
            ;;

        "infotext" )
  
            # Show text message  
            dialog_cmd "infotext: ${2}"
            ;;
  
        "show" )
  
            # Activate the dialog box
            dialog_cmd "activate:"
            ;;
  
        "title" )
  
            # Set / Clear the title, pass <nil> to clear the title
            [[ -z ${2} ]] && dialog_cmd "title: none:" || dialog_cmd "title: ${2}"
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            dialog_cmd "progress: ${6}"
            dialog_cmd "progresstext: ${5}"
            ;;
  
    esac
}

function unload_and_delete_daemon ()
{
    # Unloads the launch daemon from launchctl
    #
    # RETURNS: None
    /bin/launchctl unload -wF "${LAUNCH_DAEMON_PATH:r}"
    /bin/rm -f "${LAUNCH_DAEMON_PATH}"
}

function runAsUser () 
{  
    launchctl asuser "$USER_UID" sudo -iu "$LOGGED_IN_USER" open "$@"
}

function array_contains ()
{
    # Purpose: Scan for item inside an arry
    # Paramters: #1 - Pass entire array
    #            #2 - Item to look for in array
    # Returns: Return 0 if element exists in array
    local match="$1"
    shift

    local item
    for item in "$@"; do
        [[ "$item" == "$match" ]] && return 0
    done

    return 1
}

function read_lockfile_pid ()
{
    # Reads a file which contains a PID.
    #
    # RETURNS: A string representation of a PID or nothing if 
    #          the file is empty or doesnt exist

    [[ ! -e ${LOCKFILE_PATH} ]] && return

    pid=$(cat "${LOCKFILE_PATH}")
    echo $pid
}

function clear_lock_file ()
{
    # Remove the lock file - we use this if we exit for a deferral and d
    # not want to clean up other files
    #
    # RETURNS: None
    /bin/rm -f "${LOCKFILE_PATH}"
}

function set_lock_file_with_pid ()
{
    printf $$ > "${LOCKFILE_PATH}"
}

function get_nic_info ()
{

    declare sname
    declare sdev
    declare sip

    adapter=""
    currentIPAddress=""
    wifiName=""

    # Get all active intefaces, its name & ip address

    while read -r line; do
        sname=$(echo "$line" | awk -F  "(, )|(: )|[)]" '{print $2}' | awk '{print $1}')
        sdev=$(echo "$line" | awk -F  "(, )|(: )|[)]" '{print $4}')
        sip=$(ipconfig getifaddr $sdev)

        [[ -z $sip ]] && continue
        currentIPAddress+="$(ipconfig getifaddr "$sdev") | "
        adapter+="$sname | " 
    done <<< "$(networksetup -listnetworkserviceorder | grep 'Hardware Port')"

    adapter=${adapter::-3}
    currentIPAddress=${currentIPAddress::-3}
    wifiName=$(sudo wdutil info | grep "SSID" | head -1 | awk -F ":" '{print $2}' | xargs)

}

function extract_xml_data ()
{
    declare -a retval
    # PURPOSE: extract an XML string from the passed string
    # RETURN: parsed XML string
    # PARAMETERS: $1 - XML "blob"
    #             $2 - String to extract
    # EXPECTED: None
    retval=$(echo "$1" | xmllint --xpath "//$2/text()" - 2>/dev/null)
    printf '%s\n' "$retval"
}

function convert_to_hex ()
{
    local input="$1"
    local length="${#input}"
    local result=""

    for (( i = 0; i <= length; i++ )); do
        local char="${input[i]}"
        if [[ "$char" =~ [^a-zA-Z0-9] ]]; then
            hex=$(printf '%x' "'$char")
            result+="%$hex"
        else
            result+="$char"
        fi
    done

    echo "$result"
}

function execute_in_parallel ()
{
    # PURPOSE: Execute items in parallel for faster processing
    local process_type="$1"
    shift

    local -a ids=("$@")
    local -a worker_pids=()
    local ID
    local pid
    local completed_pid
    local numberOfComputers=${#ids[@]}
    local completed_count=0
    local progress=0
    local worker_failures=0

    (( numberOfComputers == 0 )) && return 0

    for ID in "${ids[@]}"; do
        if [[ "$process_type" == "blueprint" ]]; then
            process_blueprint_computer "$ID" &
        else
            process_group_computer "$ID" &
        fi

        worker_pids+=("$!")
        # Record the worker PIDs so we know when everything is done
        if (( ${#worker_pids[@]} >= BACKGROUND_TASKS )); then
            completed_pid="${worker_pids[1]}"

            if ! wait "$completed_pid"; then
                (( worker_failures++ ))
            fi

            worker_pids[1]=()

            (( completed_count++ ))
            progress=$(( completed_count * 100 / numberOfComputers ))

            update_display_list "progress" "" "" "" "Processed ${completed_count} of ${numberOfComputers}" "$progress"
        fi
    done

    # Wait for all of the work PIDs to finish
    for pid in "${worker_pids[@]}"; do
        if ! wait "$pid"; then
            (( worker_failures++ ))
        fi

        (( completed_count++ ))
        progress=$(( completed_count * 100 / numberOfComputers ))

        update_display_list "progress" "" "" "" "Processed ${completed_count} of ${numberOfComputers}" "$progress"
    done

    # If something failed, then record it
    if (( worker_failures > 0 )); then
        logMe "WARNING: ${worker_failures} background worker(s) failed" >&2
        return 1
    fi

    return 0
}
###########################
#
# CSV Functions
#
###########################

function initialize_csv_file ()
{
    local file="$1"

    if ! : > "$file"; then
        logMe "ERROR: Unable to create CSV file: ${file}" >&2
        return 1
    fi

    if ! /usr/sbin/chown root:wheel "$file"; then
        logMe "ERROR: Unable to set temporary CSV ownership: ${file}" >&2
        return 1
    fi

    if ! chmod 600 "$file"; then
        logMe "ERROR: Unable to secure CSV file: ${file}" >&2
        return 1
    fi

    if ! printf '%s\n' "$CSV_HEADER" > "$file"; then
        logMe "ERROR: Unable to write CSV header: ${file}" >&2
        return 1
    fi

    return 0
}

function csv_escape ()
{
    local value="$1"

    value=${value//$'\r'/ }
    value=${value//$'\n'/\\n}
    value=${value//\"/\"\"}

    printf '"%s"' "$value"
}

function append_csv_row ()
{
    # PURPOSE:
    #   Construct, escape, lock, and append one CSV record.
    #
    # PARAMETERS:
    #   $1  - System name
    #   $2  - Management ID
    #   $3  - Current OS
    #   $4  - Last update
    #   $5  - Status
    #   $6  - Failed Blueprint IDs
    #   $7  - Inactive Blueprint IDs
    #   $8 - Mixed Blueprint IDs
    #   $9 - Inactive reason
    #   $10 - Invalid Blueprint IDs
    #   $11 - Invalid reason
    #   $12 - Software update failures
    #
    # RETURN:
    #   0 - Record written
    #   1 - Lock or write failure

    local attempts=0
    local csv_line

    if (( $# != 12 )); then
        logMe "ERROR: append_csv_row expected 12 fields but received $#" >&2
        return 1
    fi

    csv_line="$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
        "$(csv_escape "$1")" \
        "$(csv_escape "$2")" \
        "$(csv_escape "$3")" \
        "$(csv_escape "$4")" \
        "$(csv_escape "$5")" \
        "$(csv_escape "$6")" \
        "$(csv_escape "$7")" \
        "$(csv_escape "$8")" \
        "$(csv_escape "$9")" \
        "$(csv_escape "${10}")" \
        "$(csv_escape "${11}")" \
        "$(csv_escape "${12}")")"

    while ! mkdir "$CSV_LOCK_DIR" 2>/dev/null; do
        sleep 0.02
        (( attempts++ ))

        if (( attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for CSV lock" >&2
            return 1
        fi
    done

    {
        if ! printf '%s\n' "$csv_line" >> "$CSV_OUTPUT"; then
            logMe "ERROR: Unable to append CSV record for: $1" >&2
            return 1
        fi
    } always {
        rmdir "$CSV_LOCK_DIR" 2>/dev/null
    }

    return 0
}

function sanitize_filenames ()
{
    local value="$1"

    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\//-}"
    value="${value//:/-}"
    value="${value//../.}"
    value="${value##[[:space:]]#}"
    value="${value%%[[:space:]]#}"

    [[ -n "$value" ]] || value="Unnamed"

    printf '%s' "${value[1,150]}"
}

###########################
#
# MS-GRAPH API functions
#
###########################

function msgraph_getdomain ()
{
    # PURPOSE: construct the domain from the jamf.plist file
    # PARAMETERS: None
    # RETURN: None
    # EXPECTED: MS_DOMAIN

    local url
    url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)

    # Extract the desired part using Zsh parameter expansion
    tmp=${url#*://}  # Remove the protocol part
    MS_DOMAIN=${tmp%%.*}".com"  # Remove everything after the first dot and add '.com' to the end
}

function msgraph_get_access_token ()
{
    local response_file
    local http_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.graph-token.XXXXX") ||
        return 1

    {
        http_status=$(/usr/bin/curl -sS -o "$response_file" -w '%{http_code}' -X POST -H "Content-Type: application/x-www-form-urlencoded" \
                --data-urlencode "grant_type=client_credentials" --data-urlencode "client_id=${GRAPH_CLIENT_ID}" --data-urlencode "client_secret=${GRAPH_CLIENT_SECRET}" --data-urlencode "scope=https://graph.microsoft.com/.default" \
                "https://login.microsoftonline.com/${GRAPH_TENANT_ID}/oauth2/v2.0/token") || return 1

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Graph token request returned HTTP ${http_status}" >&2
            return 1
        fi

        token=$(jq -er '.access_token | strings | select(length > 0)' "$response_file") || return 1

        GRAPH_ACCESS_TOKEN="$token"
    } always {
        rm -f -- "$response_file"
    }
}

function msgraph_upn_sanity_check ()
{
    # PURPOSE: format the user name to make sure it is in the format <first.last>@domain.com
    # RETURN: None
    # PARAMETERS: $1 = User name
    # EXPECTED: LOGGED_IN_USER, MS_DOMAIN, MS_USER_NAME

    # if the local name already contains “@”, then it should be good
    if [[ "$LOGGED_IN_USER" == *"@"* ]]; then
        echo "$LOGGED_IN_USER"
        return 0
    fi
    # If the user name doesn't have a "." in it, then it must be formatted correctly so that MS Graph API can find them
    
    # if it isn't ormatted correctly, grab it from the users com.microsoft.CompanyPortalMac.usercontext.info
    if [[ "$CLEAN_USER" != *"."* ]]; then
        CLEAN_USER=$(/usr/bin/more $SUPPORT_DIR/com.microsoft.CompanyPortalMac.usercontext.info | xmllint --xpath 'string(//dict/key[.="aadUserId"]/following-sibling::string[1])' -)
    fi
    
    # if it still isn't formatted correctly, try the email from the system JSS file
    
    if [[ "$CLEAN_USER" != *"."* ]]; then
        CLEAN_USER=$(/usr/libexec/plistbuddy -c "print 'User Name'" $SYSTEM_JSS_FILE 2>&1)
    fi

    # if it ends with the domain without the “@” → we add the @ sign
    if [[ "$LOGGED_IN_USER" == *"$MS_DOMAIN" ]]; then
        CLEAN_USER=${LOGGED_IN_USER%$MS_DOMAIN}
        MS_USER_NAME="${CLEAN_USER}@${MS_DOMAIN}"
    else
        # 3) normal short name → user@domain
        MS_USER_NAME="${LOGGED_IN_USER}@${MS_DOMAIN}"
    fi
}

function msgraph_get_password_data ()
{
    # PURPOSE: Retrieve the user's Graph API Record
    # RETURN: last_password_change
    # EXPECTED: MS_USER_NAME, MS_ACCESS_TOKEN

    user_response=$(curl -s -X GET "https://graph.microsoft.com/v1.0/users/$MS_USER_NAME?\$select=lastPasswordChangeDateTime" -H "Authorization: Bearer $MS_ACCESS_TOKEN")
    last_password_change=$(echo "$user_response" | jq -r '.lastPasswordChangeDateTime')
    echo $last_password_change

}

function msgraph_get_group_data ()
{
    # PURPOSE: Retrieve the user's Graph API group membership
    # PARAMETERS: None
    # RETURN: None
    # EXPECTED: MS_USER_NAME, MS_ACCESS_TOKEN, MSGRAPH_GROUP

    response=$(curl -s -X GET "https://graph.microsoft.com/v1.0/users/$MS_USER_NAME/memberOf" -H "Authorization: Bearer $MS_ACCESS_TOKEN" | jq -r '.value[].displayName')

    # Use a while loop to read and handle the line break delimiter - store the final list into an array
    MSGRAPH_GROUPS=()
    while IFS= read -r line; do
        MSGRAPH_GROUPS+=("$line")
    done <<< "$response"   
}

function msgraph_get_user_photo_etag ()
{
    # PURPOSE: Retrieve the user's Graph API Record
    # RETURN: last_password_change
    # EXPECTED: MS_USER_NAME, MS_ACCESS_TOKEN

    user_response=$(curl -s -X GET "https://graph.microsoft.com/v1.0/users/${MS_USER_NAME}/photo" -H "Authorization: Bearer $MS_ACCESS_TOKEN")
    echo "$user_response" | jq -r '."@odata.mediaEtag"'
}

function msgraph_get_user_photo_jpeg ()
{
    # PURPOSE: Retrieve the user's Graph API JPEG photo
    # PARAMETERS: $1 - Photo file to store download file
    # RETURN: None
    # EXPECTED: MS_USER_NAME, MS_ACCESS_TOKEN

    curl -s -L -H "Authorization: Bearer ${MS_ACCESS_TOKEN}" "https://graph.microsoft.com/v1.0/users/${MS_USER_NAME}/photo/\$value" --output "$1"
    [[ ! -s "$1" ]] && { echo "ERROR: Downloaded file empty"; cleanup_and_exit 1; }
}

function create_photo_dir ()
{
    # Store retrieved file to perm location  
    PERM_PHOTO_FILE="${PERM_PHOTO_DIR}/${LOGGED_IN_USER}.jpg"
    /bin/mkdir -p "$PERM_PHOTO_DIR"
    /bin/cp "$PHOTO_FILE" "$PERM_PHOTO_FILE"
    /bin/chmod 644 "$PERM_PHOTO_FILE"
}

###########################
#
# JAMF functions
#
###########################


function jamf_check_credentials ()
{
    if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
        logMe "ERROR: Jamf client ID or client secret is missing." >&2
        return 1
    fi

    logMe "Valid credentials passed."
    return 0
}

function Jamf_check_connection ()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None

    if ! /usr/local/bin/jamf -checkjssconnection -retry 5; then
        logMe "Error: JSS connection not active."
        exit 1
    fi
    logMe "JSS connection active!"
}

function Jamf_get_server ()
{
    jamfpro_url=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url) || {
        logMe "ERROR: Unable to read Jamf Pro URL" >&2
        return 1
    }
    jamfpro_url="${jamfpro_url%/}"
    logMe "Jamf Pro server is: $jamfpro_url"
}

function Jamf_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* || -z $retval ]] && retval=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    printf '%s\n' "$retval"
}

###########################
#
# JAMF functions (Token Info)
#
###########################

function Jamf_validate_token () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

    local http_status
    http_status=$(curl -sS --write-out '%{http_code}' --output /dev/null --request GET --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth") || return 1
    [[ "$http_status" == "200" ]]
}

function Jamf_get_classic_api_token ()
{
    local response_file
    local http_status
    local curl_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create Classic token response file" >&2
        return 1
    }

    {
        http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' -X POST -u "${CLIENT_ID}:${CLIENT_SECRET}" -H "Accept: application/json" "${jamfpro_url}/api/v1/auth/token")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Classic token request failed, curl exit ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Classic token request returned HTTP ${http_status}" >&2
            return 1
        fi

        if ! jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Classic token response was not valid JSON" >&2
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic response did not contain a bearer token" >&2
            return 1
        fi

        api_token="$token"
        logMe "Classic bearer token successfully obtained."
        return 0

    } always {
        rm -f -- "$response_file"
    }
}

function Jamf_get_access_token ()
{
    local response_file
    local http_status
    local curl_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create OAuth response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -X POST -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "client_id=${CLIENT_ID}" --data-urlencode "grant_type=client_credentials" --data-urlencode "client_secret=${CLIENT_SECRET}" "${jamfpro_url}/api/oauth/token")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: OAuth token request failed, curl exit ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: OAuth token request returned HTTP ${http_status}" >&2
            return 1
        fi

        if ! jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: OAuth token response was not valid JSON" >&2
            return 1
        fi

        if ! token=$(jq -er '.access_token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: OAuth response did not contain an access token" >&2
            return 1
        fi

        api_token="$token"
        logMe "OAuth access token successfully obtained."
        return 0
    } always {
        rm -f -- "$response_file"
    }
}

function JAMF_check_and_renew_api_token ()
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     JAMF_validate_token

     # If the api_authentication_check has a value of 200, that means that the current
     # bearer token is valid and can be used to authenticate an API call.

     if [[ ${api_authentication_check} == 200 ]]; then

     # If the current bearer token is valid, it is used to connect to the keep-alive endpoint. This will
     # trigger the issuing of a new bearer token and the invalidation of the previous one.

          api_token=$(/usr/bin/curl "${jamfpro_url}/api/v1/auth/keep-alive" --silent --request POST -H "Authorization: Bearer ${api_token}" | plutil -extract token raw -)

     else

          # If the current bearer token is not valid, this will trigger the issuing of a new bearer token
          # using Basic Authentication.

          JAMF_get_classic_api_token
     fi
}

function Jamf_invalidate_token ()
{
    local returnval
    local curl_status

    if [[ -z "$api_token" ]]; then
        logMe "INFO: No Jamf token is available to invalidate."
        return 0
    fi
    returnval=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${api_token}" -X POST "${jamfpro_url}/api/v1/auth/invalidate-token")
    curl_status=$?

    if (( curl_status != 0 )); then
        logMe "ERROR: Token invalidation failed, curl exit ${curl_status}" >&2
        api_token=""
        return 1
    fi

    case "$returnval" in
        204)
            logMe "Token successfully invalidated"
            ;;

        401)
            logMe "Token already invalid"
            ;;

        *)
            logMe "ERROR: Unexpected token invalidation response: HTTP ${returnval}" >&2
            api_token=""
            return 1
            ;;
    esac

    api_token=""
    return 0
}

function jamf_retrieve_data_summary ()
{
    local endpoint="$1"
    local format="${2:-xml}"

    /usr/bin/curl -sS --fail-with-body --header "Authorization: Bearer ${api_token}" --header "Accept: application/${format}" "${jamfpro_url%/}/${endpoint#/}"
}

function Jamf_retrieve_data_details ()
{    
    # PURPOSE: Extract the summary of the JAMF conmand results
    # RETURN: XML contents of command
    # PARAMTERS: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server
    declare format=$2
    [[ -z "${format}" ]] && format="xml"
    xmlBlob=$(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}")
}

function Jamf_get_inventory_record ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS:  $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $2 - Filter condition to use for search

    local response_file
    local http_status
    local curl_status
    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || return 1
    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
            --data-urlencode "section=$1" --data-urlencode "filter=$2" --get "${jamfpro_url}/api/v4/computers-inventory")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving computer inventory, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                cat "$response_file"
                ;;
            401)
                logMe "ERROR: Jamf authentication failed retrieving DDM data, HTTP 401" >&2
                cat "$response_file" >&2
                return 1
                ;;
            403)
                logMe "ERROR: Insufficient privilege to retrieve DDM data, HTTP 403" >&2
                cat "$response_file" >&2
                return 1
                ;;
            404)
                printf 'Client %s not found. Is DDM enabled on that Mac?\n' "$1"
                return 1
                ;;
            *)
                logMe "ERROR: Unexpected Jamf response, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
            } always {
           rm -f "$response_file"
        }
}

function Jamf_get_inventory_record_byID ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - The JAMF ID of the device to retrieve
    #        $2 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $3 - Filter to use for search

    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}/api/v2/computers-inventory/$1?section=$2" 2>/dev/null)
    echo $retval | tr -d '\n'
}

function Jamf_get_bulk_inventory_record ()
{
    # PURPOSE: Uses the Jamf modern API to retrieve inventory info
    # NOTE: You can change the JAMF_INVENTORY_PAGE_SIZE to control how many results are return in a single API call.
    #       This can be adjusted to suit your environment / performance results
    # RETURN: JSON blob of inventory records
    # PARMS:  None
    # EXPECTED: jamfpro_url, api_token

    local results
    local results_count
    local line
    local response_file
    local http_status
    local curl_status
    local JAMF_API_KEY="api/v3/computers-inventory"
    local page=0
    local first_item=true

    "$SW_DIALOG" --notification --style banner --identifier "inventory" --title "Retrieving Jamf Inventory Records" --message "Please be patient" --button1text "Dismiss" >/dev/null 2>&1

    printf '[\n' > "$TMP_FILE_STORAGE" || {
        logMe "ERROR: Unable to initialize inventory storage file" >&2
        return 1
    }

    while :; do
        response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.inventory.XXXXX") || {
            logMe "ERROR: Unable to create inventory response file" >&2
            return 1
        }

        {
            http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
            "${jamfpro_url}/${JAMF_API_KEY}?page=${page}&page-size=${JAMF_INVENTORY_PAGE_SIZE}")
            curl_status=$?

            if (( curl_status != 0 )); then
                logMe "ERROR: Inventory page ${page} failed, curl exit ${curl_status}" >&2
                return 1
            fi

            if [[ "$http_status" != "200" ]]; then
                logMe "ERROR: Inventory page ${page} returned HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
            fi

            if ! jq -e '.results | arrays' "$response_file" >/dev/null 2>&1; then
                logMe "ERROR: Invalid inventory response on page ${page}" >&2
                return 1
            fi

            results=$(<"$response_file")
        } always {
            rm -f -- "$response_file"
        }

        results_count=$(jq -r '.results | length' <<< "$results") || {
            logMe "ERROR: Unable to count inventory page ${page}" >&2
            return 1
        }

        (( results_count == 0 )) && break

        while IFS= read -r line; do
            if [[ "$first_item" == true ]]; then
                printf '  %s\n' "$line" >> "$TMP_FILE_STORAGE"
                first_item=false
            else
                printf '  ,%s\n' "$line" >> "$TMP_FILE_STORAGE"
            fi
        done < <(jq -c '.results[] | {id: .id, name: .general.name, managementId: .general.managementId}' <<< "$results")

        (( page++ ))
    done

    printf ']\n' >> "$TMP_FILE_STORAGE"

    if ! jq -e 'arrays' "$TMP_FILE_STORAGE" >/dev/null 2>&1; then
        logMe "ERROR: Constructed inventory data is not valid JSON" >&2
        return 1
    fi

    cat "$TMP_FILE_STORAGE"
}

function Jamf_get_policy_list ()
{
    # PURPOSE: Get the list of policies from JAMF Pro
    # RETURN: XML contents of command
    # EXPECTED: api_token, jamfpro_url
    # PARMS: None

    echo $(curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/xml" "${jamfpro_url}/JSSResource/policies")

}

function Jamf_clear_failed_mdm_commands()
{
    # PURPOSE: clear failed MDM commands for the computer in Jamf Pro
    # RETURN: None
    # Expected jamfpro_url, api_token, ID
    
    response=$(curl -s -X DELETE "${jamfpro_url}JSSResource/commandflush/computers/id/$1/status/Failed" -H "Authorization: Bearer $api_token")
    logMe "Clear MDM Commands Response: $response"
}

function Jamf_fileVault_recovery_key_valid_check () 
{
     # Verify that a FileVault recovery key is available by running an API command
     # which checks if there is a FileVault recovery key present.
     #
     # The API call will only return the HTTP status code.

     filevault_recovery_key_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/computers-inventory/$ID/filevault" --request GET -H "Authorization: Bearer ${api_token}")
}

function Jamf_fileVault_recovery_key_retrieval () 
{
     # Retrieves a FileVault recovery key from the computer inventory record.
     filevault_recovery_key_retrieved=$(/usr/bin/curl --silent --fail -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}/api/v1/computers-inventory/$ID/filevault" | plutil -extract personalRecoveryKey raw -)   
}

function Jamf_send_recovery_lock_command()
{
    # PURPOSE: send the command to clear or remove the Recovery Lock 
    # RETURN: None
    # PARMS: $1 = Lock code to set (pass blank to clear)
    # Expected jamfpro_url, ap_token, ID
    echo "New Recovery Lock: "$2
    httpString='{"clientData": [
        {"managementId": "'$1'",
        "clientType": "COMPUTER"}],
    "commandData": {
        "commandType": "SET_RECOVERY_LOCK",'
    [[ -z $2 ]] && httpString+='"newPassword": ""}}' || httpString+='"newPassword": "'$2'"}}'


    # payload=$(jq -cn --arg management_id "$1" --arg password "$2" \
    #     '{
    #         clientData: [{
    #             managementId: $management_id,
    #             clientType: "COMPUTER"
    #         }],
    #         commandData: {
    #             commandType: "SET_RECOVERY_LOCK",
    #             newPassword: $password
    #         }
    #     }') || return 1

    #echo $httpString 1>&2

    returnval=$(curl -X POST -s "$jamfpro_url/api/v2/mdm/commands" -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/json" --data-raw "$httpString")

    logMe "Recovery Lock ${lockMode} for ${computer_id}"
    echo $returnval
}

function Jamf_view_recovery_lock ()
{
    retval=$(/usr/bin/curl -s -X 'GET' \
        "${jamfpro_url}/api/v2/computers-inventory/$ID/view-recovery-lock-password" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer ${api_token}")
    retval=$(extract_string $retval '.recoveryLockPassword')
    echo $retval
}

function Jamf_retrieve_static_group_id ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID # of static group
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static group name
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computer-groups/static-groups?page=0&page-size=100&sort=id%3Aasc&filter=name%3D%3D%22"${1}%22)
    echo $tmp | jq -r '.results[].id'
}

function Jamf_retrieve_static_group_members ()
{
    # PURPOSE: Retrieve the members of a static group
    # RETURN: array of members
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static group ID
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}/JSSResource/computergroups/id/${1}")
    echo $tmp #| jq -r '.computer_group.computers[].name'
}

function Jamf_retrieve_data_blob ()
{
    local endpoint="$1"
    local format="${2:-xml}"
    local jq_filter="${3:-}"
    local response_file
    local http_status
    local curl_status

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/${format}" "${jamfpro_url%/}/${endpoint}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving ${endpoint}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if [[ "$format" == "json" ]]; then
                    if ! jq -e . "$response_file" >/dev/null 2>&1; then
                        logMe "ERROR: Invalid JSON returned by ${endpoint}" >&2
                        cat "$response_file" >&2
                        return 1
                    fi

                    if [[ -n "$jq_filter" ]]; then
                        if ! jq "$jq_filter" "$response_file"; then
                            logMe "ERROR: Unable to apply jq filter to ${endpoint}: ${jq_filter}" >&2
                            return 1
                        fi
                    else
                        cat "$response_file"
                    fi
                else
                    cat "$response_file"
                fi
                ;;

            401)
                logMe "ERROR: Authentication failed retrieving ${endpoint}, HTTP 401" >&2
                cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege retrieving ${endpoint}, HTTP 403" >&2
                cat "$response_file" >&2
                return 1
                ;;

            404)
                logMe "ERROR: Resource not found: ${endpoint}, HTTP 404" >&2
                cat "$response_file" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response for ${endpoint}, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
    } always {
        rm -f -- "$response_file"
        }
}

function Jamf_get_deviceID ()
{
    local search_type="$1"
    local search_value="$2"
    local jq_filter="$3"
    local type
    local response_file
    local http_status
    local curl_status
    local total
    local id

    case "$search_type" in
        "Hostname")         type="general.name" ;;
        "Serial Number")    type="hardware.serialNumber" ;;
        *)
            display_failure_message "Unsupported search type: ${search_type}"
            logMe "ERROR: Unsupported device search type: ${search_type}" >&2
            return 1
            ;;
    esac

    if [[ -z "$search_value" ]]; then
        display_failure_message "A device name or serial number was not provided."
        return 1
    fi

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.device.XXXXX") || {
        logMe "ERROR: Unable to create device lookup response file" >&2
        return 1
        }

    {
        local escaped_search_value

        escaped_search_value="${search_value//\\/\\\\}"
        escaped_search_value="${escaped_search_value//\'/\\\'}"

        http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' --get -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
            --data-urlencode "section=GENERAL" --data-urlencode "filter=${type}=='${escaped_search_value}'" "${jamfpro_url%/}/api/v3/computers-inventory")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Device lookup failed, curl exit ${curl_status}" >&2
            display_failure_message "Failed to contact Jamf Pro."
            return 1
        fi

        case "$http_status" in
            200)
                ;;

            400)
                logMe "ERROR: Jamf rejected the device lookup filter, HTTP 400" >&2
                cat "$response_file" >&2
                display_failure_message "Jamf rejected the device search criteria."
                return 1
                ;;

            401)
                logMe "ERROR: Device lookup authentication failed, HTTP 401" >&2
                display_failure_message "Jamf authentication failed."
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege for device lookup, HTTP 403" >&2
                display_failure_message "The API client cannot read computer inventory."
                return 1
                ;;

            *)
                logMe "ERROR: Device lookup returned HTTP ${http_status}" >&2
                cat "$response_file" >&2
                display_failure_message "Jamf returned HTTP ${http_status}."
                return 1
                ;;
        esac

        if ! jq -e '(.totalCount | numbers) and (.results | arrays)' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Invalid device lookup JSON structure" >&2
            display_failure_message "Jamf returned an invalid inventory response."
            return 1
        fi

        if ! total=$(jq -er '.totalCount' "$response_file"); then
            logMe "ERROR: Unable to read totalCount from device lookup" >&2
            display_failure_message "Unable to parse the Jamf inventory response."
            return 1
        fi

        if (( total == 0 )); then
            logMe "INFO: No inventory record found for ${search_value}"
            display_failure_message "Inventory record '${search_value}' was not found."
            return 1
        fi

        if (( total > 1 )); then
            logMe "ERROR: Multiple inventory records matched ${search_value}" >&2
            display_failure_message "More than one inventory record matched '${search_value}'."
            return 1
        fi

        if ! id=$(jq -er "$jq_filter // empty" "$response_file"); then
            logMe "ERROR: Matching device did not contain a management ID" >&2
            display_failure_message "The matching inventory record did not contain a management ID."
            return 1
        fi

        if [[ -z "$id" || "$id" == "null" ]]; then
            logMe "ERROR: Empty management ID returned for ${search_value}" >&2
            display_failure_message "The matching inventory record did not contain a management ID."
            return 1
        fi

        printf '%s\n' "$id"
        return 0

    } always {rm -f -- "$response_file"
    }
}

function Jamf_static_group_action_by_serial ()
{
    # PURPOSE: Write out the changes to the static group
    # RETURN: None
    # Expected jamfprourl, api_token, JAMFjson_BLOB
    # PARAMETERS: $1 = JAMF Static group id
    #            $2 - Serial # of device
    #            $3 = Acton to take "Add/Remove"
    declare apiData
    declare tmp


    if [[ ${3:l} == "remove" ]]; then
        apiData="<computer_group><computer_deletions><computer><name>${2}</name></computer></computer_deletions></computer_group>"
    else
        apiData="<computer_group><computer_additions><computer><name>${2}</name></computer></computer_additions></computer_group>"
    fi

    ## curl call to the API to add the computer to the provided group ID
    tmp=$(/usr/bin/curl -s -f -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/xml" "${jamfpro_url}/JSSResource/computergroups/id/${1}" -X PUT -d "${apiData}")
    #Evaluate the responses
    if [[ "$tmp" = *"<id>${1}</id>"* ]]; then

        retval="Successful $3 of $2 on group"
        logMe "$retval" 1>&2
    elif [[ $tmp == *"409"* ]]; then
        retval="$2 Not a member of group"
        logMe "$retval" 1>&2
    else
        retval="API Error #$? has occurred while try to $3 $2 to group"
        logMe "$retval" 1>&2
    fi
    echo $retval
}

###########################
#
# JAMF functions (DDM Info)
#
###########################

function Jamf_get_DDM_info ()
{
    # PURPOSE: Retrieve DDM status items using the management ID.
    # RETURN:
    #   0 and JSON on stdout when successful
    #   1 on API, HTTP, or transport failure
    # PARMS:
    #   $1 - Management ID

    local management_id="$1"
    local response_file
    local http_status
    local curl_status

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary DDM response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url%/}/api/v1/ddm/${management_id}/status-items")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving DDM data for management ID ${management_id}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if ! jq -e . "$response_file" >/dev/null 2>&1; then
                    logMe "ERROR: Jamf returned invalid JSON for management ID ${management_id}" >&2
                    cat "$response_file" >&2
                    return 1
                fi

                cat "$response_file"
                return 0
                ;;

            401)
                logMe "ERROR: Jamf authentication failed retrieving DDM data, HTTP 401" >&2
                cat "$response_file" >&2
                return 41
                ;;

            403)
                logMe "ERROR: Insufficient privilege to retrieve DDM data, HTTP 403" >&2
                cat "$response_file" >&2
                return 43
                ;;

            404)
                printf 'INFO: DDM %s not found. Is DDM enabled on that Mac?\n' "$management_id" >&2
                return 44
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
        } always {
           rm -f "$response_file"
        }
}

function Jamf_force_ddm_sync ()
{
    # PURPOSE: Request a DDM status sync for a management ID.
    # RETURN:
    #   0 for HTTP 204
    #   1 for transport or HTTP failure
    # PARMS:
    #   $1 - Management ID

    local management_id="$1"
    local response_file
    local http_status
    local curl_status

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary DDM sync response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -X 'POST' -H "Authorization: Bearer ${api_token}" -H "accept: */*" "${jamfpro_url%/}/api/v1/ddm/${management_id}/sync" -d '')
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed sending DDM sync for management ID ${management_id}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            204)
                logMe "DDM sync successfully requested for management ID ${management_id}"
                return 0
                ;;

            400)
                logMe "ERROR: Jamf rejected the DDM sync request, HTTP 400" >&2
                cat "$response_file" >&2
                return 1
                ;;

            401)
                logMe "ERROR: Jamf authentication failed sending DDM sync, HTTP 401" >&2
                cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege to send DDM sync, HTTP 403" >&2
                cat "$response_file" >&2
                return 1
                ;;

            404)
                logMe "ERROR: DDM client ${management_id} was not found, HTTP 404" >&2
                return 1
                ;;

            500)
                logMe "ERROR: Jamf server error sending DDM sync, HTTP 500" >&2
                cat "$response_file" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf DDM sync response, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
    } always {
        rm -f "$response_file"
    }
}

function Jamf_retrieve_ddm_blueprint_statuses ()
{
    # PURPOSE:
    #   Retrieve and classify Blueprint UUIDs found in the
    #   management.declarations.configurations status value.
    #
    # NOTES:
    #   Jamf appends values such as:
    #     _s1_c1_sys_cfg1
    #     _s2_c1_sys_cfg8
    #     _s2_c1_sys_act9
    #
    #   Only the embedded UUID is retained.
    #
    # RETURN:
    #   0 - Parsing completed
    #   1 - Unable to extract the configuration value
    local json="$1"
    local value_str
    local blueprintID
    local record

    DDMBlueprintSuccess=()
    DDMBlueprintInactive=()
    DDMBlueprintInvalid=()
    DDMBlueprintFailed=()

    if ! value_str=$(printf '%s' "$json" | jq -r '.value // empty'); then
        logMe "WARNING: Unable to extract blueprint configuration value" >&2
        return 1
    fi

    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        blueprintID=$(printf '%s\n' "$record" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)

        [[ -z "$blueprintID" ]] && continue
        blueprintID="${blueprintID:l}"

        # These are intentionally independent tests.
        # One blueprint can have multiple state indicators.

        if [[ "$record" == *"status=failed"* ]]; then
            DDMBlueprintFailed+=("$blueprintID")
        fi

        if [[ "$record" == *"valid=invalid"* ]]; then
            DDMBlueprintInvalid+=("$blueprintID")
        fi

        if [[ "$record" == *"active=true"* ]]; then
            DDMBlueprintSuccess+=("$blueprintID")
        fi

        if [[ "$record" == *"active=false"* ]] ||
            [[ "$record" == *"valid=unknown"* ]]
        then
            DDMBlueprintInactive+=("$blueprintID")
        fi

    done < <(printf '%s' "$value_str" | tr '{}' '\n' )
    return 0
}

function Jamf_retrieve_ddm_softwareupdate_info () 
{
    # PURPOSE: extract the DDM Software update info from the computer record
    # RETURN: array of the DDM software update information
    # PARMS: $1 - DDM JSON blob of the computer
    local results
    results=$(jq -r '[.statusItems[]? | select(.key | startswith("softwareupdate.pending-version.")) | select(.value != null) | (.key | ltrimstr("softwareupdate.pending-version.")) + ":" + (.value | tostring)] +
        [.statusItems[]? | select(.key | startswith("softwareupdate.install-")) | .value] | join("\n")' <<< "$1")
    DDMSoftwareUpdateActive=("${(f)results}")
}

function Jamf_retrieve_ddm_softwareupdate_failures ()
{
    # PURPOSE: Extract the Software Updates failures from the system
    local input_json="$1"
    local results

    DDMSoftwareUpdateFailures=()

    if ! jq -e . >/dev/null 2>&1 <<< "$input_json"; then
        logMe "WARNING: Invalid DDM JSON while parsing software update failures" >&2
        return 1
    fi

    results=$(jq -r '.statusItems[]? | select((.key | type == "string") and (.key | startswith("softwareupdate.failure-reason.")) and (.value != null))
            | "\(.key | ltrimstr("softwareupdate.failure-reason.")):\(.value)" ' <<< "$input_json") || return 1

    [[ -n "$results" ]] && DDMSoftwareUpdateFailures=("${(@f)results}")
    return 0
}

function Jamf_retrieve_ddm_blueprint_active ()
{
    # 1. jq extracts the inner 'value' string.
    # 2. perl searches for blocks containing active=false.
    # 3. The regex captures the ID, optionally skipping the 'Blueprint_' prefix.
    DDMBlueprintSuccess=(${(f)"$(printf "%s" "$1" | jq -r '.value' | perl -nle 'while(/active=true, identifier=(Blueprint_)?([^,}_]+)(?:_s1_sys_act1)?/g) { print $2 }')"})
}

function Jamf_retrieve_ddm_blueprint_errors ()
{
    # 1. jq extracts the inner 'value' string.
    # 2. perl searches for blocks containing active=false.
    # 3. The regex captures the ID, optionally skipping the 'Blueprint_' prefix.
    DDMBlueprintErrors=(${(f)"$(printf "%s" "$1" | jq -r '.value' | perl -nle 'while(/active=false, identifier=(Blueprint_)?([^,}_]+)(?:_s1_sys_act1)?/g) { print $2 }')"})
}

function Jamf_retrieve_ddm_blueprint_invalid_reason ()
{
    local json="$1"
    local value_str
    local results

    DDMBlueprintInvalidReason=()

    if ! value_str=$(printf '%s' "$json" | jq -er '.value // empty'); then
        return 0
    fi

    results=$(printf '%s\n' "$value_str" | tr '{}' '\n' | sed -nE 's/.*Error=([^}]+).*/\1/p')
    [[ -n "$results" ]] && DDMBlueprintInvalidReason=("${(@f)results}")
    return 0
}

function Jamf_retrieve_ddm_keys ()
{
    local input_json="$1"
    local requested_key="$2"

    printf '%s' "$input_json" | jq -r --arg requested_key "$requested_key" '.statusItems[]? | select(.key == $requested_key)'
}

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function construct_dialog_header_settings ()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "message" : "'$1'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : "true",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1",
        "button1text" : "OK",
        "moveable" : "true",
        "json" : "true", 
        "quitkey" : "0",
        "messageposition" : "top",'
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined

    local xml_blob
    local line

    if ! construct_dialog_header_settings "$1" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to initialize SwiftDialog JSON" >&2
        return 1
    fi

    if ! create_listitem_message_body "" "" "" "" "first"; then
        return 1
    fi

    if [[ "${2:l}" == "json" ]]; then
        # Parse the JSON data using jq and extract the relevant information
        if ! xml_blob=$(printf '%s' "$4" | jq -r "$3"); then
            logMe "ERROR: Unable to parse list-item JSON" >&2
            return 1
        fi
    else
        # Parse the XML data using xmllint and extract the relevant information
        if ! xml_blob=$(printf '%s' "$4" | xmllint --xpath "//$3" - 2>/dev/null); then
            logMe "ERROR: Unable to parse list-item XML" >&2
            return 1
        fi
    fi

    while IFS= read -r line; do
        line="${${line#*<name>}%</name>*}"
        line="${line%%[[:space:]]#}"

        if ! create_listitem_message_body "$line" "$5" "pending" "Pending..."; then
            return 1
        fi
    done <<< "$xml_blob"

    if ! create_listitem_message_body "" "" "" "" "last"; then
        return 1
    fi

    if ! update_display_list "Create"; then
        return 1
    fi

    return 0
}

function create_listitem_message_body ()
{
    if [[ "${5:l}" == "first" ]]; then
        printf '%s\n' '"button1disabled":true,"listitem":[' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ "${5:l}" == "last" ]]; then
        sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']}' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    [[ -z "$1" ]] && return 0

    if ! jq -cn --arg title "$1" --arg icon "$2" --arg status "$3" --arg statustext "$4" \
        '{
            title: $title,
            icon: $icon,
            status: $status,
            statustext: $statustext
        }' |
        sed '$s/$/,/' >> "$JSON_DIALOG_BLOB"
    then
        logMe "ERROR: Unable to append list item for ${1}" >&2
        return 1
    fi
}

function create_textfield_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - item name (interal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem heders / footers

    declare line && line=""
    declare today && today=$(date +"%m/%d/%y")

    [[ "$3:l" == "first" ]] && line+='"textfield" : ['
    [[ ! -z $1 ]] && line+='{"name" : "'$1'", "title" : "'$2'", "isdate" : "true", "required" : "true", "value" : "'$today'" },'
    [[ "$3:l" == "last" ]] && line+=']'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_dropdown_list ()
{
    # PURPOSE: Create the dropdown list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - tyoe of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    # EXPECTED: None
    declare -a array

    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_dropdown_message_body "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is XML, then parse the XML data
        xml_blob=$(echo $4 | jq -r '.results[]'$3)
    else
        # If the second parameter is JSON, then parse the JSON data
        xml_blob=$(echo $4 | xmllint --xpath '//'$3 - 2) #>/dev/null)
    fi
    
    echo $xml_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo $line | sed 's/[[:space:]]*$//')
        array+='"'$line'",'
    done
    # Remove the trailing comma from the array
    array="${array%,}"
    create_dropdown_message_body "Select Groups:" "$array" "last"

    #create_dropdown_message_body "" "" "last"
    update_display_list "Create"
}

function create_dropdown_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - values (comma separated list)
    #        $3 - default option
    #        $4 - first or last - construct appropriate listitem headers / footers

    local line && line=""

    [[ "$4:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2'], "default" : "'$3'"},'
    if [[ "${4:l}" == "last" ]]; then
        sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']' >> "$JSON_DIALOG_BLOB"
        return 0
    fi
    printf '%s\n' "$line" >> "$JSON_DIALOG_BLOB"
}

function construct_dropdown_list_items ()
{
    local input_json="$1"
    local jq_path="$2"
    local line
    local -a values=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        values+=("$(jq -Rn --arg value "$line" '$value')")
    done < <(printf '%s' "$input_json" | jq -r "${jq_path} | \"\\(.id) - \\(.name)\"")

    printf '%s' "${(j:,:)values}"
}

function create_checkbox_message_body ()
{
    # PURPOSE: Construct a checkbox style body of the dialog box
    #"checkbox" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - name (internal reference)
    #        $3 - icon
    #        $4 - Default Checked (true/false)
    #        $5 - disabled (true/false)
    #        $6 - first or last - construct appropriate listitem headers / footers
    local line=""

    if [[ "${6:l}" == "first" ]]; then
        printf '%s\n' '"checkbox" : [' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ -n "$1" ]]; then
        printf '%s\n' '{"name":"'"$2"'","label":"'"$1"'","icon":"'"$3"'","checked":'"${4:-false}"',"disabled":'"${5:-false}"'},' >> "$JSON_DIALOG_BLOB"
    fi

    if [[ "${6:l}" == "last" ]]; then
        sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']' >> "$JSON_DIALOG_BLOB"
    fi
}

#######################################################################################################
# 
# Functions for system & user level TCCC Database
#
#######################################################################################################

function configure_system_tccdb ()
{
    local values=$1
    local dbPath="/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sudo sqlite3 "$dbPath" "$sqlQuery"
}

function configure_user_tccdb () 
{
    local values=$1
    local dbPath="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sqlite3 "$dbPath" "$sqlQuery"
}