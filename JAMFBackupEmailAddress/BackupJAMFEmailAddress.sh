#!/bin/zsh
#
# JAMFEmailBackup
#
# by: Scott Kendall
#
# Written: 05/28/2025
# Last updated: 10/29/2026
#
# Script Purpose:
#   Export Jamf Pro user information as VCF contact files.
#   Users can be selected from all Jamf users, users with managed systems,
#   or members of a static computer group. Successfully exported users can
#   optionally be added as recipients to a new email message.

# 1.0 - Initial
# 1.1 - Created a few new functions to reduce complexity / document function details / renamed all JAMF functions to start with JAMF......
# 1.2 - Verified working against JAMF API 11.20
#       Added option to detect which SS/SS+ we are using a grab the appropriate icon
#       Now works with JAMF Client/Secret or Username/password authentication
#       Change variable declare section around for better readability
#       Changed to using JSON blobs vs XML Blobs
#       Bumped Swift Dialog to v2.5.0
# 1.3   Add function to check for passed JAMF credentials
# 2.0 - Added better error handling and display of error messages to the user.
#       Had to increase window height for Tahoe & SD v3.0
#       Changed JAMF 'policy -trigger' to JAMF 'policy -event'
#       Optimized "Common" section for better performance
#       Added option to read in the defaults file
#       Fixed function to check which SS/SS+ is being used (again)
#       Fully multitasking enabled for faster processing of large user counts
# 2.1 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.2 - Added selectable export scopes for all Jamf users, managed-system users, and static computer groups
#       Added static computer group selection and assigned-user matching using User and Location inventory
#       Added optional email creation for successfully exported users
#       Added parallel-safe email recipient collection, validation, and case-insensitive duplicate removal
#       Added support for overriding the Jamf Pro server URL using a passed script parameter
#       Added expanded SwiftDialog help describing export scopes, user requirements, and email functionality
#       Updated welcome, progress, summary, and logging messages for the expanded workflow

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="JAMFBackupEmail"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

FREE_DISK_SPACE=$(/bin/df -g / | awk 'NR == 2 { print $4 }')
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)

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

SUPPORT_DIR="${SUPPORT_DIR%/}"

if [[ "${SD_BANNER_IMAGE#/SupportFiles/}" != "$SD_BANNER_IMAGE" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE#/}"
elif [[ "${SD_BANNER_IMAGE:0:1}" != "/" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
fi

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="JAMF Retrieve Email"
OVERLAY_ICON=""
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

BACKGROUND_TASKS=20                 # Number of background tasks to run in parallel
EMAIL_APP='com.microsoft.outlook'   # Use the bundle identifier of your email app. you can find it by this command "osascript -e 'id of app "<appname>"' "

##################################################
#
# Passed in variables
# 
#################################################               

JAMF_PARAMETER_USER="${3:-}"    #If run from JAMF, this will be the logged in user. If run from terminal, this will be empty (and will use the logged in user)
CLIENT_ID="${4:-}"              #Client ID for JAMF API authentication (if using Client ID/Secret)
CLIENT_SECRET="${5:-}"          #Client Secret for JAMF API authentication (if using Client ID/Secret)
JAMF_SERVER="${6:-}"            #Override the JAMF server URL if needed (if not passed, will use the defaults file or the local JAMF binary to determine the server URL)

# Determine which Jamf API authentication method is being used.
CLIENT_ID_REGEX='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
[[ "$CLIENT_ID" =~ ${CLIENT_ID_REGEX} ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" 

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

    if ! command -v jq >/dev/null 2>&1; then
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
    fi

    if ! command -v jq >/dev/null 2>&1; then
        logMe "ERROR: jq remains unavailable after installation."
        return 1
    fi

    return 0
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
	SD_INFO_BOX_MSG+="{osname} {osversion}<br>"
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM

    if [[ -n "${api_token:-}" ]]; then
        if ! JAMF_invalidate_token; then
            logMe "WARNING: Unable to invalidate the Jamf Pro API token."
        fi
    fi

    [[ -n "${JSON_DIALOG_BLOB:-}" ]] && /bin/rm -f -- "$JSON_DIALOG_BLOB"
    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && /bin/rm -f -- "$DIALOG_COMMAND_FILE"
    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && /bin/rm -rf -- "${DIALOG_COMMAND_FILE}.lock"
    [[ -n "${EMAIL_RECIPIENT_DIR:-}" ]] && /bin/rm -rf -- "$EMAIL_RECIPIENT_DIR"

    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

function make_temp_files ()
{
    JSON_DIALOG_BLOB=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog JSON file."
        return 1
    }

    DIALOG_COMMAND_FILE=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog command file."
        /bin/rm -f -- "$JSON_DIALOG_BLOB"
        JSON_DIALOG_BLOB=""
        return 1
    }

    EMAIL_RECIPIENT_DIR=$(
        /usr/bin/mktemp -d "/var/tmp/${SCRIPT_NAME}_recipients.XXXXX"
    ) || {
        logMe "ERROR: Unable to create temporary email-recipient directory."
        return 1
    }

    if ! /usr/sbin/chown "$USER_UID" "$EMAIL_RECIPIENT_DIR"; then
        logMe "ERROR: Unable to set ownership on the email-recipient directory."
        return 1
    fi

    if ! /bin/chmod 700 "$EMAIL_RECIPIENT_DIR"; then
        logMe "ERROR: Unable to secure the email-recipient directory."
        return 1
    fi
    if ! /usr/sbin/chown "$USER_UID" \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"; then

        logMe "ERROR: Unable to set temporary dialog-file ownership."
        return 1
    fi

    if ! /bin/chmod 600 \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"; then

        logMe "ERROR: Unable to secure temporary dialog files."
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

    JAMF_LOGGED_IN_USER="${JAMF_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"
    return 0
}

function update_display_list ()
{
    # PURPOSE:
    #   Start, update, or close the SwiftDialog progress display.
    #
    # PARAMETERS:
    # $1 = Action: add, create, show, update, change, progress,
    #      buttonenable, buttonchange, or destroy
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
    case "$action" in

        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            write_dialog_command "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" 
            ;;

        "create" | "show" )
            "$SW_DIALOG" --progress --infotext "${jamfpro_url}" --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" & 
            DIALOG_PROCESS=$!

            if ! wait_for_dialog_ready; then
                return 1
            fi

            logMe "SwiftDialog started and initialized with PID ${DIALOG_PROCESS}."
            ;;

        "buttonenable" )

            # Enable button 1
            write_dialog_command "button1: enable"
            ;;

        "destroy" )
     
            # Kill the progress bar and clean up
            write_dialog_command "quit:"
            ;;
 
       "buttonchange" )

            # change text of button 1
            write_dialog_command "button1text: ${2}"
            ;;

        "update" | "change" )
            #
            # Update the specified SwiftDialog list item.
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
        "progress" )
            #
            # Update the progress value and progress text.
            # $4 = Progress text
            # $5 = Progress value
            #
            [[ -n "$progress_value" ]] && write_dialog_command "progress: ${progress_value}"
            [[ -n "$status_value" ]] && write_dialog_command "progresstext: ${status_value}"
            ;;

        *)
            logMe "ERROR: Invalid SwiftDialog action: ${action:-empty}"
            return 1
            ;;
        
	esac
    return 0
}

function write_dialog_command ()
{
    local dialog_command="${1:-}"
    local lock_directory="${DIALOG_COMMAND_FILE}.lock"
    local -i lock_attempts=0
    local -i write_status=0

    [[ -n "$dialog_command" ]] || return 0

    while ! mkdir "$lock_directory" 2>/dev/null; do
        sleep 0.02
        (( lock_attempts++ ))

        if (( lock_attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for the SwiftDialog command-file lock."
            return 1
        fi
    done

    print -r -- "$dialog_command" >> "$DIALOG_COMMAND_FILE"
    write_status=$?

    rmdir "$lock_directory" 2>/dev/null

    return "$write_status"
}

function wait_for_dialog_ready ()
{
    local -i attempts=0
    local -i maximum_attempts=20

    while (( attempts < maximum_attempts )); do
        if [[ -n "${DIALOG_PROCESS:-}" ]] &&
           kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
            break
        fi

        sleep 0.1
        (( attempts++ ))
    done

    if (( attempts >= maximum_attempts )); then
        logMe "ERROR: SwiftDialog failed to start."
        return 1
    fi

    # The process may exist before the large list has finished loading.
    sleep 2

    if ! kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
        logMe "ERROR: SwiftDialog exited during list initialization."
        return 1
    fi

    if ! write_dialog_command "progresstext: Preparing Jamf user list..."; then
        logMe "ERROR: Unable to initialize the SwiftDialog command file."
        return 1
    fi

    sleep 0.25
    return 0
}

###########################
#
# JAMF functions
#
###########################

function JAMF_build_curl_args ()
{
    # PURPOSE:
    #   Build the shared curl arguments for authenticated Jamf API requests.
    #
    # PARAMETERS:
    #   $1 = Optional response-file path
    #
    # RETURN:
    #   CURL_ARGS global array

    local response_file="${1:-}"

    CURL_ARGS=(
        --silent
        --show-error
        --location
        --connect-timeout 15
        --max-time 60
    )

    [[ -n "$response_file" ]] && CURL_ARGS+=(--output "$response_file")
    return 0
}

function JAMF_get_server ()
{
    if [[ -z "$JAMF_SERVER" ]]; then
        if ! JAMF_SERVER=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null); then
            logMe "ERROR: Unable to read the Jamf Pro URL."
            return 1
        fi

        logMe "No server passed in, defaulting to: ${JAMF_SERVER}"
    fi

    JAMF_SERVER="${JAMF_SERVER#"${JAMF_SERVER%%[![:space:]]*}"}"
    JAMF_SERVER="${JAMF_SERVER%"${JAMF_SERVER##*[![:space:]]}"}"

    if [[ -z "$JAMF_SERVER" ]]; then
        logMe "ERROR: The Jamf Pro server URL is empty."
        return 1
    fi

    case "${JAMF_SERVER%%:*}" in
        http|https)
            ;;
        *)
            logMe "ERROR: The Jamf Pro server URL is invalid: ${JAMF_SERVER}"
            return 1
            ;;
    esac

    jamfpro_url="${JAMF_SERVER%/}"
    logMe "Jamf Pro server is: ${jamfpro_url}"
    return 0
}

function JAMF_check_credentials ()
{
    # PURPOSE: Check to make sure the Client ID & Secret are passed correctly
    # RETURN: None
    # EXPECTED: None

    if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
        logMe "ERROR: Jamf API credentials were not provided."
        return 1
    fi
    logMe "Jamf API credentials were provided."
    return 0
}

function JAMF_check_connection ()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None
    local http_code=""
    local curlExitCode=0
    local -a curlArgs


    JAMF_build_curl_args
    curlArgs=("${CURL_ARGS[@]}")
    curlArgs+=(
        --write-out "%{http_code}"
        --output /dev/null
    )

    http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/healthCheck.html")
    curlExitCode=$?

    if (( curlExitCode != 0 )); then
        logMe "ERROR: Unable to connect to ${jamfpro_url}. curl exit code: ${curlExitCode}" >&2
        return 1
    fi

    if [[ "$http_code" != "200" ]]; then
        logMe "ERROR: Jamf Pro connection check returned HTTP ${http_code} for ${jamfpro_url}." >&2
        return 1
    fi

    logMe "Jamf Pro connection active: ${jamfpro_url}"
    return 0
}

function JAMF_which_self_service ()
{
    local app_path=""
    app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)

    [[ -z "$app_path" ]] &&app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
    [[ -z "$app_path" || ! -e "$app_path" ]] && app_path="SF=wrench.and.screwdriver.fill"
    print -r -- "$app_path"
}

function format_JAMF_date ()
{
    local raw_date="${1:-}"
    local output_format="${2:-%m/%d/%Y}"

    [[ "$output_format" == +* ]] || output_format="+${output_format}"
    local normalized_date=""
    local parsed_date=""

    [[ -n "$raw_date" && "$raw_date" != "null" ]] || return 1

    normalized_date="$raw_date"

    # Convert a trailing UTC designator to a numeric offset.
    if [[ "$normalized_date" == *Z ]]; then
        normalized_date="${normalized_date%Z}+0000"
    fi

    # Convert timezone offsets such as -04:00 to -0400.
    if [[ "$normalized_date" =~ '([+-][0-9]{2}):([0-9]{2})$' ]]; then
        normalized_date="${normalized_date[1,-4]}${normalized_date[-2,-1]}"
    fi

    # Remove fractional seconds while preserving any timezone offset.
    normalized_date=$(print -r -- "$normalized_date" | /usr/bin/sed -E 's/\.([0-9]+)([+-][0-9]{4})$/\2/; s/\.([0-9]+)$//')
    normalized_date="${normalized_date#"${normalized_date%%[![:space:]]*}"}"
    normalized_date="${normalized_date%"${normalized_date##*[![:space:]]}"}"

    if parsed_date=$(/bin/date -j -f "%Y-%m-%dT%H:%M:%S%z" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(/bin/date -j -f "%Y-%m-%dT%H:%M:%S" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S%z" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(/bin/date -j -f "%Y-%m-%d" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    return 1
}

function JAMF_get_classic_api_token ()
{
    local response_file=""
    local http_status=""
    local curl_status=0
    local token=""
    local expires=""
    local expiration_epoch=""
    local error_message=""
    local -a curlArgs

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.classic-token.XXXXX") || {
        logMe "ERROR: Unable to create Classic API token response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure Classic API token response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    JAMF_build_curl_args "$response_file"
    curlArgs=("${CURL_ARGS[@]}")
    curlArgs+=(
        --write-out "%{http_code}"
        --request POST
        --user "${CLIENT_ID}:${CLIENT_SECRET}"
        --header "Accept: application/json"
    )

    {
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/$JAMF_API_MDM_KEY")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Classic API token request failed. curl exit code: ${curl_status}"
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Classic API token request returned HTTP ${http_status}."

            if [[ -s "$response_file" ]]; then
                error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // .error // empty' "$response_file" 2>/dev/null)

                if [[ -n "$error_message" ]]; then
                    logMe "Jamf error: ${error_message}"
                else
                    logMe "ERROR: Classic API response begins with:"
                    /usr/bin/head -c 500 "$response_file" >&2
                    /usr/bin/printf '\n' >&2
                fi
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Classic API token response was empty."
            return 1
        fi

        if ! jq -e 'type == "object"' "$response_file" >/dev/null 2>&1
        then
            logMe "ERROR: Classic API token response was not valid JSON."
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic API response did not contain a bearer token."
            return 1
        fi

        if ! expires=$(jq -er '.expires | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic API response did not contain a token expiration date."
            return 1
        fi

        if ! expiration_epoch=$(format_JAMF_date "$expires" "+%s"); then
            logMe "ERROR: Unable to parse Classic API token expiration: ${expires}"
            return 1
        fi

        if [[ "$expiration_epoch" != <-> ]]; then
            logMe "ERROR: Classic API token expiration is not a valid epoch value: ${expiration_epoch}"
            return 1
        fi

        if (( expiration_epoch <= EPOCHSECONDS )); then
            logMe "ERROR: Classic API returned an already-expired token. Expiration: ${expires}"
            return 1
        fi

        api_token="$token"
        api_token_expires_epoch="$expiration_epoch"

        logMe "Classic API bearer token successfully obtained."
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_ensure_valid_token ()
{
    local -i renewal_buffer=60

    if [[ -n "$api_token" ]] &&
       (( api_token_expires_epoch > 0 )) &&
       (( EPOCHSECONDS + renewal_buffer < api_token_expires_epoch )); then
        return 0
    fi

    logMe "Jamf API token is missing or nearing expiration. Requesting a new token."

    api_token=""
    api_token_expires_epoch=0

    case "$JAMF_TOKEN" in
        new)
            if ! JAMF_get_access_token; then
                logMe "ERROR: Unable to obtain a new OAuth access token." >&2
                return 1
            fi
            ;;

        classic)
            if ! JAMF_get_classic_api_token; then
                logMe "ERROR: Unable to obtain a new Classic API bearer token." >&2
                return 1
            fi
            ;;

        *)
            logMe "ERROR: Unknown authentication type: ${JAMF_TOKEN}" >&2
            return 1
            ;;
    esac

    if [[ -z "$api_token" ]]; then
        logMe "ERROR: Token request completed without returning an API token." >&2
        api_token_expires_epoch=0
        return 1
    fi

    if (( api_token_expires_epoch <= EPOCHSECONDS )); then
        logMe "ERROR: Token request returned an invalid expiration epoch: ${api_token_expires_epoch}" >&2
        api_token=""
        api_token_expires_epoch=0
        return 1
    fi

    return 0
}

function JAMF_get_access_token ()
{
    local response_file
    local http_status
    local curl_status
    local token
    local expires_in 
    local -a curlArgs

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create OAuth response file" >&2
        return 1
    }
    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure OAuth token response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    JAMF_build_curl_args "$response_file"
    curlArgs=("${CURL_ARGS[@]}")
    curlArgs+=(
        --write-out "%{http_code}"
        --request POST 
        --header "Content-Type: application/x-www-form-urlencoded"
        --data-urlencode "client_id=${CLIENT_ID}" 
        --data-urlencode "grant_type=client_credentials" 
        --data-urlencode "client_secret=${CLIENT_SECRET}"
    )

    {
        http_status=$(curl  "${curlArgs[@]}" "${jamfpro_url}/api/oauth/token")
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


        if ! expires_in=$(jq -er '.expires_in | numbers | floor | select(. > 0)' "$response_file"); then
            logMe "ERROR: OAuth response did not contain a valid expires_in value." >&2
            return 1
        fi

        api_token="$token"
        api_token_expires_epoch=$(( EPOCHSECONDS + expires_in ))
        logMe "OAuth access token successfully obtained."
        return 0
    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_invalidate_token ()
{
    local response_file=""
    local http_status=""
    local curl_status=0
    local error_message=""
    local token_to_invalidate=""
    local -a curlArgs

    if [[ -z "$api_token" ]]; then
        logMe "INFO: No Jamf token is available to invalidate."
        return 0
    fi

    if [[ "$JAMF_TOKEN" == "new" ]]; then
        api_token=""
        api_token_expires_epoch=0
        logMe "OAuth access token cleared from script memory."
        return 0
    fi

    token_to_invalidate="$api_token"

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.invalidate.XXXXX") || {
        logMe "ERROR: Unable to create token-invalidation response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure token-invalidation response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    JAMF_build_curl_args "$response_file"
    curlArgs=("${CURL_ARGS[@]}")

    curlArgs+=(
        --write-out "%{http_code}"
        --request POST
        --header "Authorization: Bearer ${token_to_invalidate}"
        --header "Accept: application/json"
    )

    {
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v1/auth/invalidate-token")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Token invalidation failed. curl exit code: ${curl_status}"
            return 1
        fi

        case "$http_status" in
            204)
                logMe "Jamf Pro user-account token successfully invalidated."
                return 0
                ;;

            401)
                logMe "Jamf Pro user-account token was already invalid."
                return 0
                ;;

            *)
                logMe "WARNING: Unexpected token invalidation response: HTTP ${http_status}"

                if [[ -s "$response_file" ]]; then
                    error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // .error // empty' "$response_file" 2>/dev/null)
                    [[ -n "$error_message" ]] && logMe "Jamf error: ${error_message}"
                fi
                return 1
                ;;
        esac

    } always {
        api_token=""
        api_token_expires_epoch=0
        token_to_invalidate=""
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_retrieve_json_data ()
{
    # PURPOSE:
    #   Retrieve JSON data from a Jamf Pro API endpoint.
    #
    # PARAMETERS:
    #   $1 = Jamf Pro API endpoint, relative to jamfpro_url
    #
    # RETURN:
    #   JSON response written to stdout
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local api_endpoint="${1:-}"
    local response_file=""
    local response_body=""
    local http_code=""
    local curl_exit_code=0
    local error_message=""
    local -a curlArgs

    if [[ -z "$api_endpoint" ]]; then
        logMe "ERROR: JAMF_retrieve_json_data called without an API endpoint."
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    # Normalize the API endpoint so the caller may provide it
    # with or without a leading slash.
    api_endpoint="${api_endpoint#/}"

    response_file=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.json.XXXXX"
    ) || {
        logMe "ERROR: Unable to create temporary Jamf API response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure temporary Jamf API response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        JAMF_build_curl_args "$response_file"
        curlArgs=("${CURL_ARGS[@]}")

        curlArgs+=(
            --write-out "%{http_code}"
            --request GET
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/json"
        )

        http_code=$(
            /usr/bin/curl \
                "${curlArgs[@]}" \
                "${jamfpro_url}/${api_endpoint}"
        )
        curl_exit_code=$?

        if (( curl_exit_code != 0 )); then
            logMe "ERROR: Jamf API request failed. curl exit code: ${curl_exit_code}"
            logMe "ERROR: Endpoint: ${api_endpoint}"
            return 1
        fi

        case "$http_code" in
            200)
                ;;

            400)
                logMe "ERROR: Invalid Jamf API request for '${api_endpoint}' (HTTP 400)."
                ;;

            401)
                logMe "ERROR: Unauthorized Jamf API request for '${api_endpoint}' (HTTP 401)."
                ;;

            403)
                logMe "ERROR: Insufficient privileges for '${api_endpoint}' (HTTP 403)."
                ;;

            404)
                logMe "ERROR: Jamf API endpoint was not found: '${api_endpoint}' (HTTP 404)."
                ;;

            429)
                logMe "ERROR: Jamf API rate limit reached for '${api_endpoint}' (HTTP 429)."
                ;;

            5??)
                logMe "ERROR: Jamf Pro server error while retrieving '${api_endpoint}' (HTTP ${http_code})."
                ;;

            *)
                logMe "ERROR: Unexpected HTTP ${http_code} while retrieving '${api_endpoint}'."
                ;;
        esac

        if [[ "$http_code" != "200" ]]; then

            if [[ -s "$response_file" ]]; then

                error_message=$(
                    /usr/bin/jq -r '
                        .errors[0].description //
                        .errors[0].message //
                        .message //
                        .error_description //
                        .error //
                        empty
                    ' "$response_file" 2>/dev/null
                )

                if [[ -n "$error_message" ]]; then
                    logMe "Jamf error: ${error_message}"
                else
                    logMe "ERROR: Jamf API response begins with:"
                    /usr/bin/head -c 1000 "$response_file" >&2
                    /usr/bin/printf '\n' >&2
                fi
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Jamf Pro returned an empty response for '${api_endpoint}'."
            return 1
        fi

        if ! /usr/bin/jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Jamf Pro returned invalid JSON for '${api_endpoint}'."
            return 1
        fi

        response_body="$(<"$response_file")"

        /usr/bin/printf '%s' "$response_body"

        return 0

    } always {
        [[ -n "$response_file" && -f "$response_file" ]] &&
            /bin/rm -f -- "$response_file"
    }
}

function JAMF_get_inventory_record ()
{
    # PURPOSE:
    #   Retrieve the General inventory section for one Jamf computer.
    #
    # PARAMETERS:
    #   $1 = Jamf computer ID
    #
    # RETURN:
    #   Validated inventory JSON written to stdout
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local computer_id="${1:-}"
    local inventory_json=""

    if [[ -z "$computer_id" ]]; then
        logMe "ERROR: JAMF_get_inventory_record called without a computer ID."
        return 1
    fi

    if [[ "$computer_id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf computer ID: ${computer_id}"
        return 1
    fi

    if ! inventory_json=$(
        JAMF_retrieve_json_data \
            "api/v1/computers-inventory-detail/${computer_id}?section=GENERAL"
    ); then
        logMe "ERROR: Unable to retrieve inventory for computer ID ${computer_id}."
        return 1
    fi

    if ! print -r -- "$inventory_json" |
        /usr/bin/jq -e '
            type == "object" and
            (.general | type == "object")
        ' >/dev/null 2>&1; then

        logMe "ERROR: Computer ID ${computer_id} returned an invalid General inventory record."
        return 1
    fi

    /usr/bin/printf '%s' "$inventory_json"

    return 0
}

function JAMF_get_user_location_record ()
{
    # PURPOSE:
    #   Retrieve the User and Location inventory section for one
    #   Jamf computer.
    #
    # PARAMETERS:
    #   $1 = Jamf computer ID
    #
    # RETURN:
    #   Validated User and Location JSON written to stdout
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local computer_id="${1:-}"
    local inventory_json=""

    if [[ -z "$computer_id" ]]; then
        logMe "ERROR: JAMF_get_user_location_record called without a computer ID."
        return 1
    fi

    if [[ "$computer_id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf computer ID: ${computer_id}"
        return 1
    fi

    if ! inventory_json=$(
        JAMF_retrieve_json_data \
            "api/v1/computers-inventory-detail/${computer_id}?section=USER_AND_LOCATION"
    ); then
        logMe "ERROR: Unable to retrieve User and Location inventory for computer ID ${computer_id}."
        return 1
    fi

    if ! print -r -- "$inventory_json" |
        /usr/bin/jq -e '
            type == "object" and
            (.userAndLocation | type == "object")
        ' >/dev/null 2>&1
    then
        logMe "ERROR: Computer ID ${computer_id} returned an invalid User and Location record."
        return 1
    fi

    /usr/bin/printf '%s' "$inventory_json"

    return 0
}

function JAMF_retrieve_static_computer_groups ()
{
    # PURPOSE:
    #   Retrieve the list of static computer groups from Jamf Pro.
    #
    # RETURN:
    #   JSON containing static computer groups written to stdout
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local group_json=""

    if ! group_json=$(JAMF_retrieve_json_data "JSSResource/computergroups"); then
        logMe "ERROR: Unable to retrieve Jamf computer groups."
        return 1
    fi

    if ! print -r -- "$group_json" | /usr/bin/jq -e '.computer_groups | type == "array"' >/dev/null 2>&1; then
        logMe "ERROR: Jamf returned an invalid computer-group response."
        return 1
    fi

    print -r -- "$group_json" | /usr/bin/jq -c '{computer_groups: [.computer_groups[]| select(.is_smart == false)]}'
    return $?
}

function JAMF_retrieve_static_computer_group ()
{
    # PURPOSE:
    #   Retrieve a single static computer group and its members.
    #
    # PARAMETERS:
    #   $1 = Jamf computer group ID
    #
    # RETURN:
    #   Computer-group JSON written to stdout
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local group_id="${1:-}"
    local group_json=""

    if [[ -z "$group_id" ]]; then
        logMe "ERROR: JAMF_retrieve_static_computer_group called without a group ID."
        return 1
    fi

    if [[ "$group_id" != <-> ]]; then
        logMe "ERROR: Invalid static computer group ID: ${group_id}"
        return 1
    fi

    if ! group_json=$(
        JAMF_retrieve_json_data "JSSResource/computergroups/id/${group_id}"); then
        logMe "ERROR: Unable to retrieve static computer group ID ${group_id}."
        return 1
    fi

    if ! print -r -- "$group_json" | /usr/bin/jq -e '.computer_group | type == "object"' >/dev/null 2>&1; then
        logMe "ERROR: Static computer group ID ${group_id} returned an invalid record."
        return 1
    fi

    /usr/bin/printf '%s' "$group_json"

    return 0
}

###############################################
#
# Application Specific functions
#
###############################################

function welcomemsg ()
{
    local message=""
    local temp=""
    local -i returnCode=0
    local -a MainDialogBody

    message="This utility exports Jamf Pro user information as VCF contact files. <br><br>You can export all Jamf users, users with managed systems, or users associated with computers in a selected static computer group. <br><br>Choose a destination folder and optionally create a new email addressed to the exported users."

    HELP_MESSAGE="## Jamf Email Export<br><br>This utility retrieves user information from Jamf Pro and exports each user as a VCF contact file.<br><br>### Export Scope<br><br>"
    HELP_MESSAGE+="**All Jamf Users**<br><br>Exports users returned by Jamf Pro that contain the required contact information.<br><br>"
    HELP_MESSAGE+="**Users with Managed Systems**<br><br>Exports only users that have at least one assigned computer that is currently managed by Jamf Pro.<br><br>"
    HELP_MESSAGE+="**Static Computer Group**<br><br>Allows you to select a static computer group and exports the Jamf users associated with computers in that group<br><br>"
    HELP_MESSAGE+="### Destination Folder ###<br><br>Select the folder where the exported VCF contact files will be saved. One VCF file is created for each successfully exported user.<br><br>"
    HELP_MESSAGE+="### Create an Email<br><br>Enable **Create an email to exported members** to open a new email after processing is complete.<br>"
    HELP_MESSAGE+="The To field will be populated with the unique email addresses of users that were successfully exported. The message is opened for review and is not automatically sent.<br>"
    HELP_MESSAGE+="### User Requirements ###<br><br>A Jamf user must have a username, full name, and email address to be successfully exported.<br>"
    HELP_MESSAGE+="Users that do not meet the selected export criteria or are missing required information will be skipped or reported as failed during processing.<br><br>"
    HELP_MESSAGE+="### Processing Results<br><br>The progress window displays the status of each user while the export is running.<br>When processing is complete, a summary shows the number of users exported, skipped, or failed."

    MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --infotext "${jamfpro_url}"
        --vieworder "textfield,checkbox,select"
        --helpmessage "$HELP_MESSAGE"
        --width 840
        --height 580
        --ignorednd
        --json
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
        --textfield "Select a storage location",fileselect,filetype=folder,required,name=StorageLocation
        --checkbox "Create email to exported users",name=EmailMembers
        --selecttitle "Export Scope" --selectvalues "All Jamf Users,Users with Managed Systems,Static Computer Group" --selectdefault "Users with Managed Systems"
    )
 #        --checkbox "Export only users with managed systems",checked,name=OnlyManagedUsers

    temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    case "$returnCode" in
        0)
            ;;
        2)
            cleanup_and_exit 0
            ;;
        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}."
            return 1
            ;;
    esac

    if ! print -r -- "$temp" | /usr/bin/jq -e . >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog returned invalid JSON."
        return 1
    fi

    if ! ssStoragePath=$(print -r -- "$temp" | /usr/bin/jq -er '.StorageLocation | strings | select(length > 0)'); then
        logMe "ERROR: No destination folder was selected."
        return 1
    fi

    if ! EXPORT_SCOPE=$(print -r -- "$temp" | /usr/bin/jq -er '."Export Scope".selectedValue | strings | select(length > 0)'); then
        logMe "ERROR: No export scope was selected."
        return 1
    fi

    case "$EXPORT_SCOPE" in
        "All Jamf Users")
            ssOnlyManagedUsers="false"
            ;;
        "Users with Managed Systems")
            ssOnlyManagedUsers="true"
            ;;
        "Static Computer Group")
            ssOnlyManagedUsers="false"
            ;;
        *)
            logMe "ERROR: Invalid export scope: ${EXPORT_SCOPE}"
            return 1
            ;;
    esac

    EMAIL_MEMBERS=$(print -r -- "$temp" | /usr/bin/jq -r '.EmailMembers // false')
    case "$EMAIL_MEMBERS" in
        true|false)
            ;;
        *)
            logMe "WARNING: Invalid email-members selection. Defaulting to false."
            EMAIL_MEMBERS="false"
            ;;
    esac

    logMe "Create email to exported members: ${EMAIL_MEMBERS}"
    
        if [[ ! -d "$ssStoragePath" ]]; then
        logMe "ERROR: Destination folder does not exist: ${ssStoragePath}"
        return 1
    fi

    if [[ ! -w "$ssStoragePath" ]]; then
        logMe "ERROR: Destination folder is not writable: ${ssStoragePath}"
        return 1
    fi

    return 0
}

function select_static_computer_group ()
{
    local group_json="${1:-}"
    local dialog_result=""
    local return_code=0
    local group_names=""

    if [[ -z "$group_json" ]]; then
        logMe "ERROR: select_static_computer_group called without group JSON."
        return 1
    fi

    group_names=$(
        print -r -- "$group_json" |
            /usr/bin/jq -r '
                .computer_groups
                | sort_by(.name | ascii_downcase)
                | map(.name)
                | join(",")
            '
    )

    if [[ -z "$group_names" ]]; then
        logMe "INFO: No static computer groups were found."
        return 1
    fi

    dialog_result=$(
        "$SW_DIALOG" \
            --title "$SD_WINDOW_TITLE" \
            --message "Select the static computer group whose assigned users should be exported." \
            --icon "$SD_ICON_FILE" \
            --overlayicon "$OVERLAY_ICON" \
            --bannerimage "$SD_BANNER_IMAGE" \
            --subtitle "$BANNER_SUBTITLE" \
            --bannertitle "$SD_WINDOW_TITLE" \
            --selecttitle "Static Computer Group" \
            --selectvalues "$group_names" \
            --button1text "Continue" \
            --button2text "Cancel" \
            --json
    )

    return_code=$?

    case "$return_code" in
        0)
            ;;
        2)
            cleanup_and_exit 0
            ;;
        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${return_code}."
            return 1
            ;;
    esac

    if ! SELECTED_STATIC_GROUP_NAME=$(print -r -- "$dialog_result" | /usr/bin/jq -er '."Static Computer Group".selectedValue | strings| select(length > 0)'); then
        logMe "ERROR: No static computer group was selected."
        return 1
    fi
    if ! SELECTED_STATIC_GROUP_ID=$(
        print -r -- "$group_json" |
            /usr/bin/jq -er --arg name "$SELECTED_STATIC_GROUP_NAME" '.computer_groups[]| select(.name == $name)| .id'); then
        logMe "ERROR: Unable to determine the ID for static group: ${SELECTED_STATIC_GROUP_NAME}"
        return 1
    fi

    logMe "Selected static computer group: ${SELECTED_STATIC_GROUP_NAME} (${SELECTED_STATIC_GROUP_ID})"

    return 0
}

function build_user_list_from_static_group ()
{
    # PURPOSE:
    #   Build a Jamf-compatible user list containing users assigned
    #   to computers in the selected static computer group.
    #
    # PARAMETERS:
    #   $1 = Static computer-group JSON
    #   $2 = Complete Jamf user-list JSON
    #
    # RETURN:
    #   Jamf-compatible user-list JSON written to stdout
    #
    # RETURNS:
    #   0 = User list constructed successfully
    #   1 = Failure

    local group_json="${1:-}"
    local all_users_json="${2:-}"
    local computer_id=""
    local inventory_json=""
    local assigned_username=""
    local usernames_json="[]"
    local matched_user_list=""

    local -a computer_ids=()
    local -a assigned_usernames=()

    local -i computer_count=0
    local -i retrieved_count=0
    local -i no_username_count=0
    local -i failed_count=0
    local -i unique_username_count=0
    local -i matched_user_count=0

    if [[ -z "$group_json" || -z "$all_users_json" ]]; then
        logMe "ERROR: build_user_list_from_static_group called without required JSON."
        return 1
    fi

    if ! print -r -- "$group_json" |
        /usr/bin/jq -e '
            .computer_group.computers
            | type == "array"
        ' >/dev/null 2>&1
    then
        logMe "ERROR: Static computer group does not contain a valid computer list."
        return 1
    fi

    if ! print -r -- "$all_users_json" |
        /usr/bin/jq -e '
            .users
            | type == "array"
        ' >/dev/null 2>&1
    then
        logMe "ERROR: Invalid Jamf user-list JSON."
        return 1
    fi

    computer_ids=("${(@f)$(
        print -r -- "$group_json" |
            /usr/bin/jq -r '
                .computer_group.computers[]?.id
                // empty
            '
    )}")

    computer_ids=("${(@)computer_ids:#}")
    computer_count=${#computer_ids[@]}

    if (( computer_count == 0 )); then
        logMe "INFO: Static group '${SELECTED_STATIC_GROUP_NAME}' contains no computers."
        /usr/bin/printf '%s' '{"users":[]}'
        return 0
    fi

    logMe "Static group '${SELECTED_STATIC_GROUP_NAME}' contains ${computer_count} computers."
    logMe "Retrieving User and Location records for static-group computers."

    for computer_id in "${computer_ids[@]}"; do

        if [[ "$computer_id" != <-> ]]; then
            logMe "WARNING: Ignoring invalid computer ID: ${computer_id}"
            (( failed_count++ ))
            continue
        fi

        if ! inventory_json=$(
            JAMF_get_user_location_record "$computer_id"
        ); then
            logMe "WARNING: Unable to retrieve User and Location for computer ID ${computer_id}."
            (( failed_count++ ))
            continue
        fi

        (( retrieved_count++ ))

        assigned_username=$(
            print -r -- "$inventory_json" |
                /usr/bin/jq -r '
                    .userAndLocation.username
                    // empty
                '
        )

        if [[ -z "$assigned_username" ]]; then
            logMe "INFO: Computer ID ${computer_id} does not have an assigned username."
            (( no_username_count++ ))
            continue
        fi

        assigned_usernames+=("$assigned_username")
    done

    if (( ${#assigned_usernames[@]} == 0 )); then
        logMe "INFO: No assigned usernames were found in the static-group computer records."
        logMe "User and Location records retrieved: ${retrieved_count}"
        logMe "Computers without assigned usernames: ${no_username_count}"
        logMe "Computer retrieval failures: ${failed_count}"

        /usr/bin/printf '%s' '{"users":[]}'
        return 0
    fi

    if ! usernames_json=$(
        /usr/bin/printf '%s\n' "${assigned_usernames[@]}" |
            /usr/bin/jq -Rsc '
                split("\n")
                | map(
                    select(length > 0)
                    | ascii_downcase
                )
                | unique
            '
    ); then
        logMe "ERROR: Unable to construct the assigned-username array."
        return 1
    fi

    unique_username_count=$(
        print -r -- "$usernames_json" |
            /usr/bin/jq -r 'length'
    )

    if ! matched_user_list=$(
        print -r -- "$all_users_json" |
            /usr/bin/jq -c \
                --argjson usernames "$usernames_json" '
                    {
                        users: [
                            .users[]
                            | select(
                                (.name // "" | ascii_downcase) as $name
                                | $usernames
                                | index($name)
                            )
                        ]
                    }
                '
    ); then
        logMe "ERROR: Unable to match assigned usernames against Jamf users."
        return 1
    fi

    matched_user_count=$(
        print -r -- "$matched_user_list" |
            /usr/bin/jq -r '.users | length'
    )

    logMe "User and Location records retrieved: ${retrieved_count}"
    logMe "Computers without assigned usernames: ${no_username_count}"
    logMe "Computer retrieval failures: ${failed_count}"
    logMe "Unique assigned usernames found: ${unique_username_count}"
    logMe "Matched Jamf users: ${matched_user_count}"

    /usr/bin/printf '%s' "$matched_user_list"

    return 0
}

function construct_dialog_header_settings ()
{
    # PURPOSE:
    #   Create the complete base SwiftDialog JSON object.
    #
    # PARAMETERS:
    #   $1 = Dialog message
    #
    # RETURN:
    #   Complete JSON object written to stdout

    local dialogMessage="${1:-}"
    local titleFont="shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"

    jq -n \
        --arg icon "$SD_ICON_FILE" \
        --arg overlayIcon "$OVERLAY_ICON" \
        --arg message "$dialogMessage" \
        --arg bannerImage "$SD_BANNER_IMAGE" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg bannerTitle "$SD_WINDOW_TITLE" \
        --arg infoBox "$SD_INFO_BOX_MSG" \
        --arg titleFont "$titleFont" \
        --arg helpMessage "$HELP_MESSAGE" \
        --arg button1Text "OK" \
        --arg infotext "$jamfpro_url" \
        '{
            icon: $icon,
            overlayicon: $overlayIcon,
            message: $message,
            bannerimage: $bannerImage,
            subtitle: $subtitle,
            bannertitle: $bannerTitle,
            infobox: $infoBox,
            titlefont: $titleFont,
            helpmessage: $helpMessage,
            infotext: $infotext,
            moveable: true,
            quitkey: "0",
            ontop: true,
            vieworder: "textfield, dropdown, listitem, selectitems",
            width: 940,
            height: 660,
            messageposition: "top",
            button1text: $button1Text
        }'
}

function create_listitem_list ()
{
    # PURPOSE:
    #   Create the complete SwiftDialog JSON document containing
    #   the base dialog settings and configuration-profile list.
    #
    # PARAMETERS:
    #   $1 = Dialog message
    #   $2 = Data format; currently JSON only
    #   $3 = jq expression used to select list-item names
    #   $4 = JSON source data
    #   $5 = SwiftDialog icon specification
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local dialogMessage="${1:-}"
    local dataFormat="${2:-json}"
    local jqExpression="${3:-}"
    local sourceData="${4:-}"
    local itemIcon="${5:-}"
    local baseJSON=""
    local listItems=""

    if [[ -z "$dialogMessage" ]]; then
        logMe "ERROR: No SwiftDialog message was provided."
        return 1
    fi

    if [[ "${dataFormat:l}" != "json" ]]; then
        logMe "ERROR: Unsupported list-item data format: ${dataFormat}"
        return 1
    fi

    if [[ -z "$jqExpression" ]]; then
        logMe "ERROR: No jq list-item expression was provided."
        return 1
    fi

    if ! print -r -- "$sourceData" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: Invalid JSON was provided for the SwiftDialog list."
        return 1
    fi

    if ! baseJSON=$(construct_dialog_header_settings "$dialogMessage"); then
        logMe "ERROR: Unable to construct the base SwiftDialog JSON."
        return 1
    fi

    if ! listItems=$(
        print -r -- "$sourceData" |
            jq -c \
                --arg icon "$itemIcon" \
                "[
                    ${jqExpression}
                    | select(type == \"string\" and length > 0)
                    | {
                        title: .,
                        icon: \$icon,
                        status: \"pending\",
                        statustext: \"Pending...\"
                    }
                ]"
    ); then
        logMe "ERROR: Unable to construct the SwiftDialog list items."
        return 1
    fi

    if ! print -r -- "$baseJSON" | jq --argjson listItems "$listItems" '.button1disabled = true | .listitem = $listItems' > "$JSON_DIALOG_BLOB"
    then
        logMe "ERROR: Unable to write the SwiftDialog JSON file."
        return 1
    fi

    if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
        logMe "ERROR: The generated SwiftDialog JSON is invalid."
        return 1
    fi

    if ! update_display_list "create"; then
        logMe "ERROR: Unable to start the SwiftDialog progress display."
        return 1
    fi

    return 0
}

function make_apfs_safe ()
{
    # PURPOSE:
    #   Replace characters that are unsafe or problematic in a filename.
    #
    # PARAMETERS:
    #   $1 = Original filename
    #
    # RETURN:
    #   Sanitized filename written to stdout

    local file_name="${1:-}"

    [[ -n "$file_name" ]] || return 1

    print -r -- "$file_name" | /usr/bin/sed -e 's/:/_/g' -e 's#/#-#g' -e 's/|/-/g'
    return 0
}

function extract_user_details ()
{
    # PURPOSE:
    #   Retrieve a Jamf user record, optionally verify assigned managed
    #   computers, export the user as a VCF file, and update SwiftDialog.
    #
    # PARAMETERS:
    #   $1 = Jamf user ID
    #   $2 = Zero-based SwiftDialog list-item index
    #
    # RETURNS:
    #   0 = User exported successfully
    #   1 = User could not be exported
    #   2 = User skipped because assigned computers exist but none are managed
    #   3 = User skipped because no computer records are assigned

    local user_id="${1:-}"
    local list_index="${2:-}"

    local user_json=""
    local user_short_name=""
    local user_full_name=""
    local user_email=""
    local user_position=""
    local safe_file_name=""
    local managed_status="managed"
    local progress_value=0

    if [[ -z "$user_id" ]]; then
        logMe "ERROR: extract_user_details called without a Jamf user ID."
        return 1
    fi

    if [[ -z "$list_index" || "$list_index" != <-> ]]; then
        logMe "ERROR: Invalid SwiftDialog list index: ${list_index:-empty}"
        return 1
    fi

    if ! user_json=$(JAMF_retrieve_json_data "JSSResource/users/id/${user_id}"); then
        logMe "ERROR: Unable to retrieve Jamf user ID ${user_id}."
        update_display_list "update" "$list_index" "Retrieval failed" "fail"
        return 1
    fi

    if ! print -r -- "$user_json" | /usr/bin/jq -e '.user | type == "object"' >/dev/null 2>&1; then
        logMe "ERROR: Jamf user ID ${user_id} returned an invalid user record."
        update_display_list "update" "$list_index" "Invalid user record" "fail"
        return 1
    fi

    user_short_name=$(print -r -- "$user_json" | /usr/bin/jq -r '.user.name // empty')
    user_full_name=$(print -r -- "$user_json" | /usr/bin/jq -r '.user.full_name // empty')
    user_email=$(print -r -- "$user_json" | /usr/bin/jq -r '.user.email_address //.user.email //empty')
    user_position=$(print -r -- "$user_json" | /usr/bin/jq -r '.user.position // empty')
    progress_value=$(((list_index + 1) * 100 / userCount))

    if [[ -z "$user_short_name" ]]; then
        logMe "ERROR: Jamf user ID ${user_id} does not have a username."
        update_display_list "update" "$list_index" "Username is missing" "fail"
        update_display_list "progress" "" "" "Unable to export Jamf user ID ${user_id}" "$progress_value"
        return 1
    fi

    if [[ -z "$user_full_name" ]]; then
        logMe "WARNING: ${user_short_name} does not have a full name."
        update_display_list "update" "$list_index" "Full name is missing" "fail"
        update_display_list "progress" "" "" "Unable to export ${user_short_name}" "$progress_value"
        return 1
    fi

    if [[ -z "$user_email" ]]; then
        logMe "WARNING: ${user_short_name} does not have an email address."
        update_display_list "update" "$list_index" "Email address is missing" "fail"
        update_display_list "progress" "" "" "Unable to export ${user_short_name}" "$progress_value"
        return 1
    fi

    update_display_list "update" "$list_index" "Working..." "wait"

    if [[ "$ssOnlyManagedUsers" == "true" ]]; then

        if ! managed_status=$(extract_assigned_systems "$user_json"); then
            logMe "ERROR: Unable to check managed systems for ${user_short_name}."

            update_display_list "update" "$list_index" "Managed-system check failed" "fail"
            update_display_list "progress" "" "" "Unable to export ${user_short_name}" "$progress_value"
            return 1
        fi

        case "$managed_status" in

            managed)
                ;;

            unmanaged)
                logMe "INFO: ${user_short_name} has computer records, but none are managed."
                update_display_list "update" "$list_index" "No managed systems" "pending"
                update_display_list "progress" "" "" "Skipped ${user_short_name}" "$progress_value"
                return 2
                ;;

            none)
                logMe "INFO: ${user_short_name} has no computer records."
                update_display_list "update" "$list_index" "No computers assigned" "pending"
                update_display_list "progress" "" "" "Skipped ${user_short_name}" "$progress_value"
                return 3
                ;;

            *)
                logMe "ERROR: Unexpected managed-system status for ${user_short_name}: ${managed_status}"
                update_display_list "update" "$list_index" "Unknown system status" "fail"
                return 1
                ;;
        esac
    fi
    if ! safe_file_name=$(make_apfs_safe "$user_short_name"); then
        logMe "ERROR: Unable to create a safe filename for ${user_short_name}."
        update_display_list "update" "$list_index" "Invalid filename" "fail"
        return 1
    fi

    if [[ -z "$safe_file_name" ]]; then
        logMe "ERROR: Safe filename is empty for ${user_short_name}."
        update_display_list "update" "$list_index" "Invalid filename" "fail"
        return 1
    fi

    if ! export_vcf_file "$user_full_name" "$user_email" "$user_position" > "${ssStoragePath}/${safe_file_name}.vcf"; then
        logMe "ERROR: Unable to export VCF for ${user_short_name}."
        /bin/rm -f -- "${ssStoragePath}/${safe_file_name}.vcf"
        update_display_list "update" "$list_index" "Export failed" "fail"
        update_display_list "progress" "" "" "Unable to export ${user_short_name}" "$progress_value"
        return 1
    fi

    if [[ "$EMAIL_MEMBERS" == "true" ]]; then

        if ! save_email_recipient "$user_id" "$user_email"; then
            logMe "ERROR: Unable to save the email recipient for ${user_short_name}."
            /bin/rm -f -- "${ssStoragePath}/${safe_file_name}.vcf"
            update_display_list "update" "$list_index" "Recipient capture failed" "fail"
            update_display_list "progress" "" "" "Unable to process ${user_short_name}" "$progress_value"
            return 1
        fi

    fi

    logMe "Exported VCF for ${user_short_name}."
    update_display_list "update" "$list_index" "Finished" "success"
    update_display_list "progress" "" "" "Exported ${user_short_name}" "$progress_value"
    return 0
}

function save_email_recipient ()
{
    # PURPOSE:
    #   Save one validated email address to a worker-specific file.
    #   Each parallel worker writes to a different file, avoiding
    #   concurrent array or shared-file modification.
    #
    # PARAMETERS:
    #   $1 = Jamf user ID
    #   $2 = Email address
    #
    # RETURNS:
    #   0 = Address saved
    #   1 = Invalid arguments or write failure

    local user_id="${1:-}"
    local email_address="${2:-}"
    local recipient_file=""

    if [[ -z "$user_id" || "$user_id" != <-> ]]; then
        logMe "ERROR: Invalid user ID supplied to save_email_recipient."
        return 1
    fi

    if [[ -z "$email_address" ]]; then
        logMe "ERROR: No email address supplied for Jamf user ID ${user_id}."
        return 1
    fi

    if [[ -z "${EMAIL_RECIPIENT_DIR:-}" ||
          ! -d "$EMAIL_RECIPIENT_DIR" ]]; then
        logMe "ERROR: Email-recipient directory is unavailable."
        return 1
    fi

    #
    # Basic format validation. This is intentionally practical rather
    # than attempting full RFC email-address validation.
    #
    if [[ "$email_address" != *@*.* ]]; then
        logMe "WARNING: Invalid email address for Jamf user ID ${user_id}: ${email_address}"
        return 1
    fi

    recipient_file="${EMAIL_RECIPIENT_DIR}/${user_id}.email"

    if ! /usr/bin/printf '%s\n' "$email_address" > "$recipient_file"; then
        logMe "ERROR: Unable to save email address for Jamf user ID ${user_id}."
        return 1
    fi

    return 0
}

function export_vcf_file ()
{
    # PURPOSE:
    #   Write a version 3.0 vCard to stdout.
    #
    # PARAMETERS:
    #   $1 = Full name
    #   $2 = Email address
    #   $3 = Position or title
    #
    # RETURNS:
    #   0 = Success
    #   1 = Required data missing

    local full_name="${1:-}"
    local email_address="${2:-}"
    local position="${3:-}"

    if [[ -z "$full_name" || -z "$email_address" ]]; then
        return 1
    fi

    /usr/bin/printf 'BEGIN:VCARD\r\n'
    /usr/bin/printf 'VERSION:3.0\r\n'
    /usr/bin/printf 'FN:%s\r\n' "$full_name"
    /usr/bin/printf 'EMAIL:%s\r\n' "$email_address"

    [[ -n "$position" ]] && /usr/bin/printf 'TITLE:%s\r\n' "$position"
 
    /usr/bin/printf 'END:VCARD\r\n'

    return 0
}

function extract_assigned_systems ()
{
    # PURPOSE:
    #   Determine whether a Jamf user has assigned computer records
    #   and whether at least one assigned computer is currently managed.
    #
    # PARAMETERS:
    #   $1 = Complete Jamf user JSON record
    #
    # RETURN:
    #   managed   = At least one assigned computer is managed
    #   unmanaged = Computer records exist, but none are managed
    #   none      = No computer records are assigned to the user
    #
    # RETURNS:
    #   0 = Check completed successfully
    #   1 = User JSON or inventory retrieval failed

    local user_json="${1:-}"
    local computer_id=""
    local inventory_json=""
    local managed_status=""
    local -i checked_computers=0
    local -a computer_ids

    if [[ -z "$user_json" ]]; then
        logMe "ERROR: extract_assigned_systems called without user JSON."
        return 1
    fi

    if ! print -r -- "$user_json" |
        /usr/bin/jq -e '.user | type == "object"' >/dev/null 2>&1; then

        logMe "ERROR: Invalid user JSON supplied to extract_assigned_systems."
        return 1
    fi

    computer_ids=("${(@f)$(print -r -- "$user_json" | /usr/bin/jq -r '.user.links.computers[]?.id // empty' )}")
    computer_ids=("${(@)computer_ids:#}")

    #
    # No computer records assigned.
    #
    if (( ${#computer_ids[@]} == 0 )); then
        print -r -- "none"
        return 0
    fi

    #
    # Inspect assigned computers.
    #
    for computer_id in "${computer_ids[@]}"; do

        if [[ "$computer_id" != <-> ]]; then
            logMe "WARNING: Ignoring invalid computer ID associated with the user: ${computer_id}"
            continue
        fi

        if ! inventory_json=$(JAMF_get_inventory_record "$computer_id"); then
            logMe "ERROR: Unable to determine management status for computer ID ${computer_id}."
            return 1
        fi

        (( checked_computers++ ))

        managed_status=$(print -r -- "$inventory_json" | /usr/bin/jq -r '.general.remoteManagement.managed // false')
        if [[ "$managed_status" == "true" ]]; then
            print -r -- "managed"
            return 0
        fi
    done

    #
    # Computer records were referenced, but none could
    # actually be evaluated.
    #
    if (( checked_computers == 0 )); then
        logMe "ERROR: No valid computer records could be evaluated."
        return 1
    fi

    #
    # At least one computer was successfully evaluated,
    # but none were managed.
    #
    print -r -- "unmanaged"

    return 0
}

function execute_in_parallel ()
{
    # PURPOSE:
    #   Export Jamf users in parallel while limiting the number
    #   of concurrent background processes.
    #
    # PARAMETERS:
    #   $1 = Maximum number of concurrent jobs
    #   $2... = Jamf user IDs
    #
    # WORKER RETURN CODES:
    #   0 = Exported successfully
    #   1 = Export failed
    #   2 = Skipped - no managed systems
    #   3 = Skipped - no computer records
    #
    # RETURNS:
    #   0 = Processing completed without worker failures
    #   1 = Invalid arguments or one or more workers failed

    local -i max_jobs="${1:-0}"
    local -i list_index=0
    local user_id=""
    local pid=""
    local worker_status=0
    local -a pids=()

    shift

    #
    # Reset summary counters.
    #
    EXPORT_COUNT=0
    SKIP_UNMANAGED_COUNT=0
    SKIP_NO_COMPUTERS_COUNT=0
    FAILED_COUNT=0

    if (( max_jobs <= 0 )); then
        logMe "ERROR: Invalid maximum background job count: ${max_jobs}"
        return 1
    fi

    if (( $# == 0 )); then
        logMe "INFO: No users were provided for parallel processing."
        return 0
    fi

    for user_id in "$@"; do

        extract_user_details "$user_id" "$list_index" &

        pids+=("$!")
        (( list_index++ ))

        #
        # Wait once the maximum number of concurrent
        # workers has been reached.
        #
        if (( ${#pids[@]} >= max_jobs )); then

            for pid in "${pids[@]}"; do
                wait "$pid"
                worker_status=$?

                process_worker_status "$worker_status"
            done

            pids=()
        fi
    done

    #
    # Process the final partial batch.
    #
    for pid in "${pids[@]}"; do
        wait "$pid"
        worker_status=$?

        process_worker_status "$worker_status"
    done

    #
    # Log final statistics.
    #
    logMe "Export summary:"
    logMe "  Exported: ${EXPORT_COUNT}"
    logMe "  Skipped - no managed systems: ${SKIP_UNMANAGED_COUNT}"
    logMe "  Skipped - no computers assigned: ${SKIP_NO_COMPUTERS_COUNT}"
    logMe "  Failed: ${FAILED_COUNT}"

    if (( FAILED_COUNT > 0 )); then
        return 1
    fi

    return 0
}

function process_worker_status ()
{
    #
    # Process the return code from a completed worker.
    #
        local -i statusCode="${1:-1}"

        case "$statusCode" in
            0)
                (( EXPORT_COUNT++ ))
                ;;

            2)
                (( SKIP_UNMANAGED_COUNT++ ))
                ;;

            3)
                (( SKIP_NO_COMPUTERS_COUNT++ ))
                ;;

            *)
                (( FAILED_COUNT++ ))
                ;;
        esac
}

function open_email_message ()
{
    # PURPOSE:
    #   Open the configured email application in the logged-in user's
    #   GUI session with recipients populated in the To field.
    #
    # PARAMETERS:
    #   $@ = Email addresses
    #
    # RETURNS:
    #   0 = Email application opened successfully
    #   1 = No email addresses supplied
    #   2 = Invalid user context
    #   3 = Mailto URI is too large
    #   4 = Unable to open the email application

    local -a email_addresses=("$@")
    local recipient_list=""
    local mailto_uri=""
    local -i mailto_length=0
    local -i recommended_max_length=7000

    email_addresses=("${(@)email_addresses:#}")

    if (( ${#email_addresses[@]} == 0 )); then
        logMe "ERROR: No email addresses were provided."
        return 1
    fi

    if [[ -z "${USER_UID:-}" || "$USER_UID" != <-> ]]; then
        logMe "ERROR: A valid logged-in user UID is unavailable."
        return 2
    fi

    if [[ -z "${EMAIL_APP:-}" ]]; then
        logMe "ERROR: No email application bundle identifier was configured."
        return 2
    fi

    recipient_list="${(j:,:)email_addresses}"
    mailto_uri="mailto:${recipient_list}"
    mailto_length=${#mailto_uri}

    #
    # A mailto URI can become unreliable when hundreds of recipients
    # produce a very large launch-services argument.
    #
    if (( mailto_length > recommended_max_length )); then
        logMe "ERROR: The mailto recipient list is too large (${mailto_length} characters)."
        logMe "ERROR: Refusing to open an incomplete Outlook recipient list."
        return 3
    fi

    logMe "Opening ${EMAIL_APP} with ${#email_addresses[@]} recipients."

    if ! /bin/launchctl asuser "$USER_UID" /usr/bin/open -b "$EMAIL_APP" "$mailto_uri"; then
        logMe "ERROR: Unable to open the configured email application."
        return 4
    fi

    logMe "Email message opened successfully."
    return 0
}

function collect_email_recipients ()
{
    # PURPOSE:
    #   Read the email files created by parallel workers, normalize the
    #   values, remove duplicates, and populate EMAIL_ADDRESSES.
    #
    # GLOBALS SET:
    #   EMAIL_ADDRESSES
    #
    # RETURNS:
    #   0 = One or more recipients collected
    #   1 = No valid recipients found

    local recipient_file=""
    local email_address=""
    local normalized_address=""
    local recipient_json=""

    local -a raw_addresses=()

    EMAIL_ADDRESSES=()

    if [[ -z "${EMAIL_RECIPIENT_DIR:-}" ||
          ! -d "$EMAIL_RECIPIENT_DIR" ]]; then
        logMe "ERROR: Email-recipient directory is unavailable."
        return 1
    fi

    for recipient_file in "$EMAIL_RECIPIENT_DIR"/*.email(N); do

        if [[ ! -s "$recipient_file" ]]; then
            continue
        fi

        email_address=$(
            /usr/bin/head -n 1 "$recipient_file" |
                /usr/bin/tr -d '\r\n'
        )

        #
        # Trim surrounding whitespace.
        #
        email_address="${email_address#"${email_address%%[![:space:]]*}"}"
        email_address="${email_address%"${email_address##*[![:space:]]}"}"

        if [[ -z "$email_address" ]]; then
            continue
        fi

        if [[ "$email_address" != *@*.* ]]; then
            logMe "WARNING: Ignoring invalid recipient address: ${email_address}"
            continue
        fi

        raw_addresses+=("$email_address")
    done

    if (( ${#raw_addresses[@]} == 0 )); then
        logMe "INFO: No valid email recipients were collected."
        return 1
    fi

    #
    # Let jq deduplicate case-insensitively while preserving one
    # usable copy of each address.
    #
    if ! recipient_json=$(
        /usr/bin/printf '%s\n' "${raw_addresses[@]}" | /usr/bin/jq -Rsc 'split("\n") 
                | map(select(length > 0))
                | sort_by(ascii_downcase)
                | group_by(ascii_downcase)
                | map(.[0])
            '
    ); then
        logMe "ERROR: Unable to normalize the email-recipient list."
        return 1
    fi

    EMAIL_ADDRESSES=("${(@f)$(print -r -- "$recipient_json" | /usr/bin/jq -r '.[]')}") 
    EMAIL_ADDRESSES=("${(@)EMAIL_ADDRESSES:#}")
    if (( ${#EMAIL_ADDRESSES[@]} == 0 )); then
        logMe "INFO: No valid email recipients remained after validation."
        return 1
    fi

    logMe "Collected ${#EMAIL_ADDRESSES[@]} unique email recipients."

    return 0
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload -Uz is-at-least
zmodload zsh/datetime

typeset -g api_token=""
typeset -gi api_token_expires_epoch=0

typeset -gi EXPORT_COUNT=0
typeset -gi SKIP_UNMANAGED_COUNT=0
typeset -gi SKIP_NO_COMPUTERS_COUNT=0
typeset -gi FAILED_COUNT=0

typeset -i processed_count=0
typeset -i SKIPPED_COUNT=0
typeset -g FINAL_SUMMARY=""

typeset -g EXPORT_SCOPE=""
typeset -g EXPORT_DESCRIPTION=""
typeset -g EMAIL_MEMBERS="false"

typeset -g SELECTED_STATIC_GROUP_ID=""
typeset -g SELECTED_STATIC_GROUP_NAME=""

typeset -g StaticGroupList=""
typeset -g StaticGroupJSON=""
typeset -gi matched_static_group_users=0

typeset -g EMAIL_RECIPIENT_DIR=""
typeset -a EMAIL_ADDRESSES=()

declare jamfpro_url
declare ssStoragePath
declare ssOnlyManagedUsers
declare UserList
declare userCount
typeset -a UserIDs


check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
JAMF_get_server || cleanup_and_exit 1
JAMF_check_connection || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1
make_temp_files || cleanup_and_exit 1
create_infobox_message

OVERLAY_ICON=$(JAMF_which_self_service)

welcomemsg || cleanup_and_exit 1
JAMF_ensure_valid_token || cleanup_and_exit 1

if ! UserList=$(JAMF_retrieve_json_data "JSSResource/users"); then
    logMe "ERROR: Unable to retrieve the Jamf Pro user list."
    cleanup_and_exit 1
fi

case "$EXPORT_SCOPE" in

    "All Jamf Users")
        logMe "Export scope: All Jamf users"
        ;;

    "Users with Managed Systems")
        logMe "Export scope: Users with managed systems"
        ;;

    "Static Computer Group")
        logMe "Export scope: Static computer group"

        if ! StaticGroupList=$(JAMF_retrieve_static_computer_groups); then
            logMe "ERROR: Unable to retrieve static computer groups."
            cleanup_and_exit 1
        fi

        if ! select_static_computer_group "$StaticGroupList"; then
            logMe "ERROR: Unable to select a static computer group."
            cleanup_and_exit 1
        fi

        if ! StaticGroupJSON=$(
            JAMF_retrieve_static_computer_group "$SELECTED_STATIC_GROUP_ID"
        ); then
            logMe "ERROR: Unable to retrieve selected static computer group."
            cleanup_and_exit 1
        fi

        if ! UserList=$(build_user_list_from_static_group "$StaticGroupJSON" "$UserList"); then
            logMe "ERROR: Unable to build the user list from static group."
            cleanup_and_exit 1
        fi
        matched_static_group_users=$(print -r -- "$UserList" | /usr/bin/jq -r '.users | length')

        logMe "Matched Jamf users from static group: ${matched_static_group_users}"
        ;;

    *)
        logMe "ERROR: Unknown export scope: ${EXPORT_SCOPE}"
        cleanup_and_exit 1
        ;;
esac

UserIDs=("${(@f)$(print -r -- "$UserList" | jq -r '.users[]?.id // empty')}")
UserIDs=("${(@)UserIDs:#}")
userCount=${#UserIDs[@]}

if (( userCount == 0 )); then

    if [[ "$EXPORT_SCOPE" == "Static Computer Group" ]]; then
        logMe "INFO: No Jamf users were associated with computers in static group '${SELECTED_STATIC_GROUP_NAME}'."
    else
        logMe "INFO: No Jamf users were returned."
    fi

    cleanup_and_exit 0
fi

case "$EXPORT_SCOPE" in

    "All Jamf Users")
        EXPORT_DESCRIPTION="all Jamf users"
        ;;

    "Users with Managed Systems")
        EXPORT_DESCRIPTION="Jamf users with managed systems"
        ;;

    "Static Computer Group")
        EXPORT_DESCRIPTION="users from static group '${SELECTED_STATIC_GROUP_NAME}'"
        ;;

esac

if ! create_listitem_list "Creating VCF cards for ${EXPORT_DESCRIPTION}" "json" '.users[].name' "$UserList" ""; then
    logMe "ERROR: Unable to create the SwiftDialog user list."
    cleanup_and_exit 1
fi

logMe "Exporting ${userCount} users from ${EXPORT_DESCRIPTION}"

if ! execute_in_parallel "$BACKGROUND_TASKS" "${UserIDs[@]}"; then
    logMe "WARNING: One or more user exports did not complete successfully."
fi

SKIPPED_COUNT=$(( SKIP_UNMANAGED_COUNT + SKIP_NO_COMPUTERS_COUNT ))
(( processed_count = EXPORT_COUNT + SKIP_UNMANAGED_COUNT + SKIP_NO_COMPUTERS_COUNT + FAILED_COUNT ))
if [[ "$EXPORT_SCOPE" == "Static Computer Group" ]]; then
    FINAL_SUMMARY="Group: ${SELECTED_STATIC_GROUP_NAME} | Exported: ${EXPORT_COUNT} | Failed: ${FAILED_COUNT}"
else
    FINAL_SUMMARY="Exported: ${EXPORT_COUNT} | Skipped: ${SKIPPED_COUNT} | Failed: ${FAILED_COUNT}"
fi


if (( processed_count != userCount )); then
    logMe "WARNING: Processed count (${processed_count}) does not match expected user count (${userCount})."
fi

logMe "========================================"
logMe "Export Summary"
logMe "========================================"
logMe "Exported:                       ${EXPORT_COUNT}"
logMe "Skipped - no managed systems:   ${SKIP_UNMANAGED_COUNT}"
logMe "Skipped - no computers:         ${SKIP_NO_COMPUTERS_COUNT}"
logMe "Skipped - total:                ${SKIPPED_COUNT}"
logMe "Failed:                         ${FAILED_COUNT}"
logMe "Total processed:                ${processed_count}"
logMe "Total expected:                 ${userCount}"
logMe "========================================"


update_display_list "progress" "" "" "$FINAL_SUMMARY" "100"
update_display_list "buttonenable"
wait
if [[ "$EMAIL_MEMBERS" == "true" ]]; then

    if collect_email_recipients; then
        if ! open_email_message "${EMAIL_ADDRESSES[@]}"; then
            logMe "WARNING: VCF export completed, but the email message could not be opened."
        fi
    else
        logMe "WARNING: Email creation was requested, but no valid recipients were available."
    fi
else
    logMe "Email creation was not requested."
fi
if (( FAILED_COUNT > 0 )); then
    cleanup_and_exit 1
else
    cleanup_and_exit 0
fi
