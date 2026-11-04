#!/bin/zsh
#
# SpeedTest
#
# by: Scott Kendall
#
# Written: 02/27/2025
# Last updated: 11/04/2026
#
# Script Purpose: Use the networkquality command to test the speed of the network
#
# 1.0 - Initial 
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.2 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
# 1.3 - Had to increase window height for Tahoe & SD v3.0
# 1.4 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Production hardening and reliability improvements
#       Added secure SwiftDialog temporary-file creation and cleanup
#       Added command-file locking and improved dialog process management
#       Added root, logged-in user, and UID validation
#       Improved SwiftDialog installation, version, and command error handling
#       Added jq and support-file dependency validation and installation handling
#       Changed SwiftDialog JSON generation to use jq
#       Improved Jamf policy execution validation
#       Hardened networkQuality execution, parsing, and result validation
#       Added support for decimal latency results
#       Improved logging and user-facing failure handling
#       Added graceful cleanup for normal, failed, and interrupted execution



######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="SpeedTest"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

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

# Remove any trailing slash from the configured support directory
SUPPORT_DIR="${SUPPORT_DIR%/}"

if [[ "${SD_BANNER_IMAGE#/SupportFiles/}" != "$SD_BANNER_IMAGE" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE#/}"
elif [[ "${SD_BANNER_IMAGE:0:1}" != "/" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
fi


# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)
SD_WINDOW_TITLE="Internet Speed Test"
SD_WINDOW_ICON="${ICON_FILES}/GenericNetworkIcon.icns"
OVERLAY_ICON="computer"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"
 
##################################################
#
# Passed in variables
# 
#################################################               

JAMF_PARAMETER_USER="${3:-}"    #If run from JAMF, this will be the logged in user. If run from terminal, this will be empty (and will use the logged in user)

####################################################################################################
#
# Functions
#
####################################################################################################

function admin_user ()
{
    (( UID == 0 ))
}

function check_for_sudo ()
{
    if ! admin_user; then
        print -u2 -r -- "ERROR: This script must be run as root."
        return 1
    fi

    return 0
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
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | /usr/bin/tee -a "${LOG_FILE}" >&2
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

    if ! SD_VERSION=$("$SW_DIALOG" --version 2>/dev/null); then
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
    local JAMF_exit=0

    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install SwiftDialog."
        return 1
    fi

    /usr/local/bin/jamf policy -event "$DIALOG_INSTALL_POLICY"
    JAMF_exit=$?

    if (( JAMF_exit != 0 )); then
        logMe "ERROR: Jamf policy failed while installing SwiftDialog. Exit code: ${JAMF_exit}"
        return 1
    fi

    if [[ ! -x "$SW_DIALOG" ]]; then
        logMe "ERROR: SwiftDialog remains unavailable after the installation attempt."
        return 1
    fi

    return 0
}

function check_support_files ()
{
    if [[ -f "$SD_BANNER_IMAGE" ]]; then
        logMe "Banner image found: ${SD_BANNER_IMAGE}"
    else
        logMe "Banner image not found: ${SD_BANNER_IMAGE}"

        if [[ -x /usr/local/bin/jamf ]]; then
            logMe "Running support-file installation policy."

            if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"; then
                logMe "WARNING: Support-file installation policy failed."
            fi
        else
            logMe "WARNING: The local Jamf binary is unavailable. The support-file installation policy cannot be run."
        fi

        if [[ -f "$SD_BANNER_IMAGE" ]]; then
            logMe "Banner image successfully installed: ${SD_BANNER_IMAGE}"
        else
            logMe "WARNING: Banner image remains unavailable: ${SD_BANNER_IMAGE}"
        fi
    fi

     if ! JQ_BIN=$(command -v jq); then
        logMe "jq is not installed."

        if [[ ! -x /usr/local/bin/jamf ]]; then
            logMe "ERROR: The local Jamf binary is unavailable, so jq cannot be installed."
            return 1
        fi

        logMe "Running jq installation policy."

        if ! /usr/local/bin/jamf policy -event "$JQ_FILE_INSTALL_POLICY"; then
            logMe "ERROR: jq installation policy failed."
            return 1
        fi

        if ! JQ_BIN=$(command -v jq); then
            logMe "ERROR: jq remains unavailable after installation."
            return 1
        fi
    fi
    logMe "jq is available at ${JQ_BIN}."
    return 0
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM

    if (( exit_code != 0 )) &&
        [[ -n "${DIALOG_PROCESS:-}" ]] &&
        /bin/kill -0 "$DIALOG_PROCESS" 2>/dev/null
    then
        /bin/kill "$DIALOG_PROCESS" 2>/dev/null
        wait "$DIALOG_PROCESS" 2>/dev/null
    fi

    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] &&
        /bin/rmdir "${DIALOG_COMMAND_FILE}.lock" 2>/dev/null

    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] &&
        /bin/rm -f -- "$DIALOG_COMMAND_FILE"

    [[ -n "${JSON_DIALOG_BLOB:-}" ]] &&
        /bin/rm -f -- "$JSON_DIALOG_BLOB"

    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

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

    JAMF_LOGGED_IN_USER="${JAMF_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"
    return 0
}

function write_dialog_command ()
{
    local dialog_command="${1:-}"
    local lock_directory="${DIALOG_COMMAND_FILE}.lock"
    local -i lock_attempts=0
    local -i write_status=0

    [[ -n "$dialog_command" ]] || return 0

    while ! /bin/mkdir "$lock_directory" 2>/dev/null; do
        /bin/sleep 0.02
        (( lock_attempts++ ))

        if (( lock_attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for the SwiftDialog command-file lock."
            return 1
        fi
    done

    print -r -- "$dialog_command" >> "$DIALOG_COMMAND_FILE"
    write_status=$?

    /bin/rmdir "$lock_directory" 2>/dev/null

    return "$write_status"
}

function update_display_list ()
{
    # PURPOSE:
    #   Start, update, or close the SwiftDialog progress display.
    #
    # PARAMETERS:
    #   $1 = Action: create, show, update, change, progress,
    #        buttonenable, or destroy
    #   $2 = Zero-based list-item index for update/change
    #   $3 = List-item status text for update/change
    #   $4 = List-item status for update/change, or progress text
    #        for the progress action
    #   $5 = Progress value for the progress action
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local action="${1:l}"
    local list_index="${2:-}"
    local status_text="${3:-}"
    local status_value="${4:-}"
    local progress_value="${5:-}"
    local dialog_command=""
    case "${action:l}" in

        "create" )
            "$SW_DIALOG" --progress --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" &
            DIALOG_PROCESS=$!

            /bin/sleep 0.2

            if ! /bin/kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
                logMe "ERROR: SwiftDialog failed to start."
                return 1
            fi

            logMe "SwiftDialog started and initialized with PID ${DIALOG_PROCESS}."
            ;;

        "show" )

            write_dialog_command "activate:"  || return 1
            ;;
     
        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            write_dialog_command "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" || return 1
            ;;

        "buttonaction" )

            # Change button 1 action
            write_dialog_command 'button1action: "'${2}'"' || return 1
            ;;
  
        "buttonchange" )

            # change text of button 1
            write_dialog_command "button1text: ${2}" || return 1
            ;;

        "buttondisable" )

            # disable button 1
            write_dialog_command "button1: disable" || return 1
            ;;

        "buttonenable" )

            # Enable button 1
            write_dialog_command "button1: enable" || return 1
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            case "$status_value" in
                wait|success|fail|error|pending|progress)
                    ;;
                *)
                    logMe "ERROR: Invalid SwiftDialog status: ${status_value:-empty}"
                    return 1
                ;;
            esac
            if [[ -z "$list_index" || "$list_index" != <-> ]]; then
                logMe "ERROR: Invalid SwiftDialog list index: ${list_index:-empty}"
                return 1
            fi

            status_text="${status_text//$'\r'/}"
            status_text="${status_text//$'\n'/<br>}"

            dialog_command="listitem: index: ${list_index}, status: ${status_value}, statustext: ${status_text}"

            #logMe "SwiftDialog command: ${dialog_command}"

            if ! write_dialog_command "$dialog_command"; then
                logMe "ERROR: Unable to write SwiftDialog update for index ${list_index}."
                return 1
            fi
            ;;

  
        "clear" )
  
            # Clear the list and show an optional message  
            write_dialog_command "list: clear" || return 1
            write_dialog_command "message: ${2}" || return 1
            ;;
  
        "delete" )
  
            # Delete item from list  
            write_dialog_command "listitem: delete, title: ${2}" || return 1
            ;;
 
        "destroy" )
     
            # Kill the progress bar and clean up
            write_dialog_command "quit:" || return 1
            ;;
 
        "done" )
          
            # Complete the progress bar and clean up  
            write_dialog_command "progress: 100" || return 1
            ;;
          
        "icon" )
            if [[ -z "${2:-}" ]]; then
                write_dialog_command "icon: none" || return 1
            else
                write_dialog_command "icon: ${2}" || return 1
            fi
            ;;
  
  
        "image" )
            # Display an image and optional progress text
            write_dialog_command "image: ${2}" || return 1

            if [[ -n "${3:-}" ]]; then
                write_dialog_command "progresstext: ${3}" || return 1
            fi
            ;;
  
        "infobox" )
  
            # Show text message  
            write_dialog_command "infobox: ${2}" || return 1
            ;;

        "infotext" )
  
            # Show text message  
            write_dialog_command "infotext: ${2}" || return 1
            ;;
  
  
        "title" )
            if [[ -z "${2:-}" ]]; then
                write_dialog_command "title: none" || return 1
            else
                write_dialog_command "title: ${2}" || return 1
            fi
            ;;

  
        "progress" )
  
            # Set the progress bar to the value supplied in $5
            # Display optional progress text supplied in $4

            if [[ -n "$progress_value" ]]; then
                write_dialog_command "progress: ${progress_value}" || return 1
            fi

            if [[ -n "$status_value" ]]; then
                write_dialog_command "progresstext: ${status_value}" || return 1
            fi
            ;;
        * )
            logMe "ERROR: Unknown SwiftDialog action: ${action:-empty}"
            return 1
            ;;
    esac

    return 0
}

function construct_dialog_header_settings()
{
    local message="${1:-}"

    "$JQ_BIN" -n \
        --arg icon "$SD_WINDOW_ICON" \
        --arg overlayicon "$OVERLAY_ICON" \
        --arg message "$message" \
        --arg bannerimage "$SD_BANNER_IMAGE" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg bannertitle "$SD_WINDOW_TITLE" \
        --arg titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}" \
        --arg commandfile "$DIALOG_COMMAND_FILE" \
        '{
            icon: $icon,
            overlayicon: $overlayicon,
            message: $message,
            bannerimage: $bannerimage,
            subtitle: $subtitle,
            bannertitle: $bannertitle,
            titlefont: $titlefont,
            commandfile: $commandfile,
            button1text: "OK",
            height: 375,
            width: 720,
            moveable: true,
            progress: 0,
            messageposition: "top"
        }'
}

function display_welcome_message ()
{
    local welcome_message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  Please wait while we test the speed of your internet connection"

    if ! construct_dialog_header_settings "$welcome_message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct SwiftDialog configuration."
        return 1
    fi

    if ! update_display_list "create"; then
        logMe "ERROR: Unable to launch SwiftDialog."
        return 1
    fi

    update_display_list "buttondisable" || return 1
    update_display_list "progress" "" "" "" 0 || return 1

    return 0
}

function perform_speedtest ()
{
    local results
    local uplink_raw
    local downlink_raw
    local latency_raw
    local numeric_pattern='^[0-9]+([.][0-9]+)?$'

    logMe "Starting network quality test."

    if ! results=$(/usr/bin/networkQuality -c 2>/dev/null); then
        logMe "ERROR: networkQuality failed."
        return 1
    fi

    if [[ -z "$results" ]]; then
        logMe "ERROR: networkQuality returned no results."
        return 1
    fi

    if ! uplink_raw=$(print -r -- "$results" | /usr/bin/plutil -extract ul_throughput raw -o - - 2>/dev/null); then
        logMe "ERROR: Unable to retrieve upload throughput."
        return 1
    fi

    if ! downlink_raw=$(print -r -- "$results" | /usr/bin/plutil -extract dl_throughput raw -o - - 2>/dev/null); then
        logMe "ERROR: Unable to retrieve download throughput."
        return 1
    fi

    if ! latency_raw=$(print -r -- "$results" | /usr/bin/plutil -extract base_rtt raw -o - - 2>/dev/null); then
        logMe "ERROR: Unable to retrieve network latency."
        return 1
    fi

    if [[ ! "$uplink_raw" =~ $numeric_pattern ]]; then
        logMe "ERROR: Invalid upload throughput returned: ${uplink_raw}"
        return 1
    fi

    if [[ ! "$downlink_raw" =~ $numeric_pattern ]]; then
        logMe "ERROR: Invalid download throughput returned: ${downlink_raw}"
        return 1
    fi

    if [[ ! "$latency_raw" =~ $numeric_pattern ]]; then
        logMe "ERROR: Invalid network latency returned: ${latency_raw}"
        return 1
    fi

    SpeedTest_Uplink=$(( uplink_raw / 1024 / 1024 ))
    SpeedTest_DownLink=$(( downlink_raw / 1024 / 1024 ))
    SpeedTest_Latency=$(printf "%.2f" "$latency_raw")

    logMe "Network quality test completed successfully."
    logMe "Upload: ${SpeedTest_Uplink} Mbps"
    logMe "Download: ${SpeedTest_DownLink} Mbps"
    logMe "Latency: ${SpeedTest_Latency} ms"

    return 0
}

function display_results ()
{
    local result_message

    result_message="The speed test is complete. Here are the results:<br><br>"
    result_message+="**Upload:** ${SpeedTest_Uplink} Mbps<br>"
    result_message+="**Download:** ${SpeedTest_DownLink} Mbps<br>"
    result_message+="**Latency:** ${SpeedTest_Latency} ms"

    update_display_list "buttonenable" || return 1
    update_display_list "done" || return 1
    update_display_list "clear" "$result_message" || return 1

    return 0
}

function wait_for_dialog ()
{
    if [[ -n "${DIALOG_PROCESS:-}" ]] &&
        /bin/kill -0 "$DIALOG_PROCESS" 2>/dev/null
    then
        wait "$DIALOG_PROCESS"
    fi
}

##############################
#
# Main Program
#
##############################

declare SpeedTest_Uplink
declare SpeedTest_DownLink
declare SpeedTest_Latency

autoload -Uz is-at-least

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
make_temp_files || cleanup_and_exit 1
display_welcome_message || cleanup_and_exit 1

if ! perform_speedtest; then
    logMe "ERROR: Internet speed test failed."

    update_display_list "buttonenable" || {
        logMe "ERROR: Unable to enable the SwiftDialog button."
        cleanup_and_exit 1
    }

    update_display_list "clear" "The internet speed test could not be completed. Please verify your network connection and try again." || {
            logMe "ERROR: Unable to display the speed-test failure message."
            cleanup_and_exit 1
        }

    wait_for_dialog
    cleanup_and_exit 1
fi

display_results || cleanup_and_exit 1
wait_for_dialog
cleanup_and_exit 0