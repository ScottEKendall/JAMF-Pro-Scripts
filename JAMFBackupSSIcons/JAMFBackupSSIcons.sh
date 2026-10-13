#!/bin/zsh
#
# BackupSSIcons
#
# by: Scott Kendall
#
# Written: 05/21/2025
# Last updated: 10/13/2026
#
# Script Purpose: Backup JAMF Self service icons to a local folder
#
# 1.0 - Initial
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.2 - Created a few new functions to reduce complexity / document function details / renamed all JAMF functions to start with JAMF......
# 1.3 - Verified working agains JAMF API 11.20
#       Added option to detect which SS/SS+ we are using and grab the appropriate icon
#       Now works with JAMF Client/Secret or Username/password authentication
#       Change variable typeset section around for better readability
#       Bumped Swift Dialog to v2.5.0
# 1.4   Add function to check JAMF credentials were passed
#       Fixed logic to determine which SS/SS+ is being used
# 2.0 - Fixed display issues with Swift Dialog 3.0
#       Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Added section to use the defaults file if found to set the banner image and spacing
# 2.1 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.2 - Improved SwiftDialog status update reliability
#       Added dialog startup readiness validation
#       Implemented serialized command-file writes for concurrent workers
#       Fixed policy-list/display index alignment issues
#       Added Self Service icon URI validation
#       Improved API token renewal handling for long-running exports
#       Improved temporary file and lock cleanup
#       Enhanced large-environment stability and performance

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="BackupSSIcons"
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

SD_WINDOW_TITLE="Backup Self Service Icons"
SD_ICON_FILE="${ICON_FILES}ToolbarCustomizeIcon.icns"
OVERLAY_ICON=""

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

##################################################
#
# Passed in variables
# 
#################################################               

JAMF_PARAMETER_USER="${3:-}"
CLIENT_ID="${4:-}"
CLIENT_SECRET="${5:-}"
JAMF_SERVER="${6:-}"

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
    local jamf_exit=0

    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install SwiftDialog."
        return 1
    fi

    /usr/local/bin/jamf policy -event "$DIALOG_INSTALL_POLICY"
    jamf_exit=$?

    if (( jamf_exit != 0 )); then
        logMe "ERROR: Jamf policy failed while installing SwiftDialog. Exit code: ${jamf_exit}"
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

    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

function make_temp_files ()
{
    JSON_DIALOG_BLOB=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX"
    ) || {
        logMe "ERROR: Unable to create SwiftDialog JSON file."
        return 1
    }

    DIALOG_COMMAND_FILE=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX"
    ) || {
        logMe "ERROR: Unable to create SwiftDialog command file."
        /bin/rm -f -- "$JSON_DIALOG_BLOB"
        JSON_DIALOG_BLOB=""
        return 1
    }

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

    Jamf_LOGGED_IN_USER="${Jamf_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${Jamf_LOGGED_IN_USER%%.*}}"
    return 0
}

function create_display_list ()
{
    local dialog_message=""
    local -i dialog_item_count=0
    local -i policy_id_count=0

    dialog_message="The following Self Service Policy icons will be backed up to:<br>${ssStoragePath}"

    if ! /usr/bin/jq -n \
        --arg icon "$SD_ICON_FILE" \
        --arg message "$dialog_message" \
        --arg bannerimage "$SD_BANNER_IMAGE" \
        --arg bannertitle "$SD_WINDOW_TITLE" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}" \
        --argjson policies "$PolicyList" \
        '
        {
            icon: $icon,
            message: $message,
            bannerimage: $bannerimage,
            bannertitle: $bannertitle,
            subtitle: $subtitle,
            titlefont: $titlefont,
            button1text: "OK",
            moveable: true,
            height: 800,
            quitkey: "0",
            messageposition: "top",
            button1disabled: true,
            listitem: (
                $policies.policies
                | map(
                    select(.id | type == "number")
                    | {
                        title: (
                            (.name // ("Policy " + (.id | tostring)))
                            + " [ID: "
                            + (.id | tostring)
                            + "]"
                        ),
                        icon: "",
                        status: "pending",
                        statustext: "Pending..."
                    }
                )
            )
        }
        ' > "$JSON_DIALOG_BLOB"
    then
        logMe "ERROR: Unable to construct SwiftDialog JSON."
        return 1
    fi

    if ! /usr/bin/jq -e '
        type == "object" and
        (.listitem | type == "array") and
        (.listitem | length > 0)
    ' "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
        logMe "ERROR: Generated SwiftDialog configuration is invalid or contains no list items."
        return 1
    fi

    if ! dialog_item_count=$(
        /usr/bin/jq -er '.listitem | length' "$JSON_DIALOG_BLOB"
    ); then
        logMe "ERROR: Unable to determine the SwiftDialog list-item count."
        return 1
    fi

    if ! policy_id_count=$(
        /usr/bin/jq -er '
            [
                .policies[]
                | select(.id | type == "number")
            ]
            | length
        ' <<< "$PolicyList"
    ); then
        logMe "ERROR: Unable to determine the valid policy count."
        return 1
    fi

    if (( dialog_item_count != policy_id_count )); then
        logMe "ERROR: SwiftDialog item count ${dialog_item_count} does not match policy count ${policy_id_count}."
        return 1
    fi

    logMe "Created ${dialog_item_count} SwiftDialog policy list items."

    if ! update_display_list "Create"; then
        logMe "ERROR: Unable to initialize the SwiftDialog display."
        return 1
    fi

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

function wait_for_dialog_ready ()
{
    local -i attempts=0
    local -i maximum_attempts=20

    while (( attempts < maximum_attempts )); do
        if [[ -n "${DIALOG_PROCESS:-}" ]] &&
           /bin/kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
            break
        fi

        /bin/sleep 0.1
        (( attempts++ ))
    done

    if (( attempts >= maximum_attempts )); then
        logMe "ERROR: SwiftDialog failed to start."
        return 1
    fi

    # The process may exist before the large list has finished loading.
    /bin/sleep 2

    if ! /bin/kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
        logMe "ERROR: SwiftDialog exited during list initialization."
        return 1
    fi

    if ! write_dialog_command "progresstext: Preparing policy list..."; then
        logMe "ERROR: Unable to initialize the SwiftDialog command file."
        return 1
    fi

    /bin/sleep 0.25
    return 0
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

    case "$action" in

        create|show)
            "$SW_DIALOG" --progress --infotext "${jamfpro_url}" --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" &
            DIALOG_PROCESS=$!

            if ! wait_for_dialog_ready; then
                return 1
            fi

            logMe "SwiftDialog started and initialized with PID ${DIALOG_PROCESS}."
            ;;

        buttonenable)
            write_dialog_command "button1: enable"
            ;;

        destroy)
            write_dialog_command "quit:"
            ;;

        update|change)
            case "$status_value" in
                wait|success|fail|error|pending|progress)
                    ;;
                *)
                    logMe "ERROR: Invalid SwiftDialog status: ${status_value:-empty}"
                    return 1
                *;;
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

        progress)
            [[ -n "$progress_value" ]] && write_dialog_command "progress: ${progress_value}"
            
            [[ -n "$status_value" ]] && write_dialog_command "progresstext: ${status_value}"
            ;;

        *)
            logMe "ERROR: Unknown SwiftDialog display action: ${1:-empty}"
            return 1
            ;;
    esac

    return 0
}

###########################
#
# JAMF functions
#
###########################

function JAMF_which_self_service ()
{
    local app_path=""

    app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)

    if [[ -z "$app_path" ]]; then
        app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
    fi

    if [[ -z "$app_path" || ! -e "$app_path" ]]; then
        app_path="SF=wrench.and.screwdriver.fill"
    fi

    print -r -- "$app_path"
}

function JAMF_check_connection ()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None
    local http_status=""
    local curl_status=0

    http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 30 --output /dev/null --write-out '%{http_code}' "${jamfpro_url}/healthCheck.html")
    curl_status=$?

    if (( curl_status != 0 )); then
        logMe "ERROR: Unable to connect to ${jamfpro_url}. curl exit code: ${curl_status}" >&2
        return 1
    fi

    if [[ "$http_status" != "200" ]]; then
        logMe "ERROR: Jamf Pro connection check returned HTTP ${http_status} for ${jamfpro_url}." >&2
        return 1
    fi

    logMe "Jamf Pro connection active: ${jamfpro_url}"
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

function JAMF_get_server ()
{
    if [[ -z "$JAMF_SERVER" ]]; then
        JAMF_SERVER=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url) || {
            logMe "ERROR: Unable to read Jamf Pro URL" >&2
            return 1
        }
        logMe "No server passed in, defaulting to: $JAMF_SERVER"
        
    fi
    jamfpro_url="${JAMF_SERVER%/}"
    logMe "Jamf Pro server is: $jamfpro_url"
}

function JAMF_get_classic_api_token ()
{
    local response_file=""
    local http_status=""
    local curl_status=0
    local token=""
    local expires=""
    local expiration_epoch=""

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.classic-token.XXXXX") || {
        logMe "ERROR: Unable to create Classic API token response file." >&2
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure Classic API token response file." >&2
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
            --request POST --user "${CLIENT_ID}:${CLIENT_SECRET}" --header "Accept: application/json" "${jamfpro_url}/api/v1/auth/token")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Classic API token request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Classic API token request returned HTTP ${http_status}." >&2

            if [[ -s "$response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 500 "$response_file" >&2
                /usr/bin/printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Classic API token response was empty." >&2
            return 1
        fi

        if ! /usr/bin/jq -e 'type == "object"' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Classic API token response was not valid JSON." >&2
            return 1
        fi

        if ! token=$(/usr/bin/jq -er '.token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic API response did not contain a bearer token." >&2
            return 1
        fi

        if ! expires=$(/usr/bin/jq -er '.expires | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic API response did not contain a token expiration date." >&2
            return 1
        fi

        if ! expiration_epoch=$(format_jamf_date "$expires" "+%s"); then
            logMe "ERROR: Unable to parse Classic API token expiration: ${expires}" >&2
            return 1
        fi

        if [[ "$expiration_epoch" != <-> ]]; then
            logMe "ERROR: Classic API token expiration did not convert to a valid epoch value: ${expiration_epoch}" >&2
            return 1
        fi

        if (( expiration_epoch <= EPOCHSECONDS )); then
            logMe "ERROR: Classic API returned a token that is already expired. Expiration: ${expires}" >&2
            return 1
        fi

        api_token="$token"
        api_token_expires_epoch="$expiration_epoch"

        logMe "Classic API bearer token successfully obtained."
        #logMe "Classic API bearer token expires at ${expires}."

        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_get_access_token ()
{
    local response_file=""
    local http_status=""
    local curl_status=0
    local token=""
    local expires_in=0
    
    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create OAuth response file" >&2
        return 1
    }
    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure OAuth token response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl -s -S -L -o "$response_file" -w '%{http_code}' -X POST -H "Content-Type: application/x-www-form-urlencoded" --connect-timeout 15 --max-time 60 \
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

function JAMF_ensure_valid_token ()
{
    local -i renewal_buffer=300

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

function JAMF_invalidate_token ()
{
    local response_file=""
    local http_status=""
    local curl_status=0

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

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.invalidate.XXXXX") || {
        logMe "ERROR: Unable to create token-invalidation response file."
        api_token=""
        api_token_expires_epoch=0
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure token-invalidation response file."
        api_token=""
        api_token_expires_epoch=0
        /bin/rm -f -- "$response_file"
        return 1
    fi
    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --request POST --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth/invalidate-token")
        curl_status=$?

        api_token=""
        api_token_expires_epoch=0

        if (( curl_status != 0 )); then
            logMe "ERROR: Token invalidation failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            204)
                logMe "Jamf Pro user-account token successfully invalidated."
                ;;

            401)
                logMe "Jamf Pro user-account token was already invalid."
                ;;

            *)
                logMe "WARNING: Unexpected token invalidation response: HTTP ${http_status}" >&2
                return 1
                ;;
        esac
        # Request and status handling
        } always {
            /bin/rm -f -- "$response_file"
    }
    return 0
}

function JAMF_get_policy_list ()
{
    # PURPOSE:
    #   Retrieve the Jamf Pro policy list as JSON and store it in
    #   the global PolicyList variable.
    #
    # RETURNS:
    #   0 = Success
    #   1 = General failure

    local response_file=""
    local http_status=""
    local curl_status=0

    JAMF_ensure_valid_token || return 1

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.policies.XXXXX") || {
        logMe "ERROR: Unable to create policy response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure policy response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --get --output "$response_file" --write-out '%{http_code}' \
                --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/policies")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Policy lookup failed. curl exit code: ${curl_status}"
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Policy lookup returned HTTP ${http_status}."

            if [[ -s "$response_file" ]]; then
                /usr/bin/head -c 500 "$response_file" >&2
                /usr/bin/printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Policy lookup returned an empty response."
            return 1
        fi

        if ! /usr/bin/jq -e 'type == "object" and (.policies | type == "array")' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Policy lookup did not return the expected JSON structure."
            return 1
        fi

        PolicyList=$(<"$response_file")

        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function format_jamf_date ()
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

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --message "**Problems retrieving JAMF Info**<br><br>Error Message: $1"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

}

###############################################
#
# Application Specific functions
#
###############################################

function welcomemsg ()
{
    message="This utility will extract available Self Service policy icons from Jamf Pro and save them to the folder you select below."

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
        --helpmessage ""
        --width 800
        --height 480
        --ignorednd
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
        --infotext "${jamfpro_url}"
        --textfield "Select a storage location",fileselect,filetype=folder,required
    )
	
			
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" --json 2>/dev/null)
    returnCode=$?
    case "$returnCode" in
        0)
            ;;
        2)
            cleanup_and_exit 0
            ;;
        *)
            logMe "ERROR: Welcome dialog exited with code ${returnCode}."
            cleanup_and_exit 1
            ;;
    esac

    if ! ssStoragePath=$(/usr/bin/jq -er '."Select a storage location" | strings | select(length > 0)' <<< "$temp"); then
        logMe "ERROR: A valid storage location was not selected."
        display_failure_message "A valid storage location was not selected."
        cleanup_and_exit 1
    fi

    if [[ ! -d "$ssStoragePath" ]]; then
        logMe "ERROR: Selected storage location is not a directory: ${ssStoragePath}"
        display_failure_message "The selected storage location is not valid."
        cleanup_and_exit 1
    fi

    if [[ ! -w "$ssStoragePath" ]]; then
        logMe "ERROR: Selected storage location is not writable: ${ssStoragePath}"
        display_failure_message "The selected storage location is not writable."
        cleanup_and_exit 1
    fi
}

function JAMF_extract_policy_icons ()
{
    local policy_id="${1:-}"
    local list_index="${2:-}"
    local policyJSON=""
    local PolicyName=""
    local formatted_ss_policy_name=""
    local ss_policy_check="false"
    local ss_icon=""
    local ss_iconName=""
    local ss_iconURI=""
    local ss_icon_filepath=""
    local download_file=""
    local http_status=""
    local curl_status=0

    if [[ -z "$policy_id" || "$policy_id" != <-> ]]; then
        logMe "ERROR: Invalid policy ID passed to JAMF_extract_policy_icons: ${policy_id:-empty}"
        return 1
    fi

    if [[ -z "$list_index" || "$list_index" != <-> ]]; then
        logMe "ERROR: Invalid list index passed for policy ${policy_id}: ${list_index:-empty}"
        return 1
    fi

    if ! policyJSON=$(JAMF_retrieve_policy_details "$policy_id"); then
        logMe "ERROR: Unable to retrieve details for policy ${policy_id}."

        update_display_list "Update" "$list_index" "Policy Lookup Failed" "fail"
        return 1
    fi

    PolicyName=$(/usr/bin/jq -r '.policy.general.name // empty' <<< "$policyJSON")
    ss_icon=$(/usr/bin/jq -r '.policy.self_service.self_service_icon.id // empty' <<< "$policyJSON")
    ss_iconName=$(/usr/bin/jq -r '.policy.self_service.self_service_icon.filename // empty' <<< "$policyJSON")
    ss_iconURI=$(/usr/bin/jq -r '.policy.self_service.self_service_icon.uri // empty' <<< "$policyJSON")
    ss_policy_check=$(/usr/bin/jq -r '.policy.self_service.use_for_self_service // false' <<< "$policyJSON")

    [[ -n "$PolicyName" ]] || PolicyName="Policy ${policy_id}"

    formatted_ss_policy_name=$(make_apfs_safe "$PolicyName")

    logMe "Processing dialog index ${list_index}: ${PolicyName} [ID: ${policy_id}]"

    if [[ "$ss_policy_check" != "true" || -z "$ss_icon" || -z "$ss_iconName" || -z "$ss_iconURI" ]]; then

        update_display_list "Update" "$list_index" "No Icon" "fail"
        return 0
    fi

    if [[ "$ss_iconURI" != http://* && "$ss_iconURI" != https://* ]]; then

        logMe "ERROR: Policy ${policy_id} returned an invalid icon URI."
        update_display_list "Update" "$list_index" "Invalid Icon URI" "fail"
        return 1
    fi

    ss_iconName=$(make_apfs_safe "$ss_iconName")

    if ! update_display_list "Update" "$list_index" "Working" "wait"; then
        logMe "WARNING: Unable to update SwiftDialog for policy ${policy_id}."
    fi

    ss_icon_filepath="${formatted_ss_policy_name}-${policy_id}-${ss_iconName}"
    download_file="${ssStoragePath}/.${ss_icon_filepath}.download"

    logMe "Downloading ${ss_icon_filepath} to ${ssStoragePath}."

    http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$download_file" --write-out '%{http_code}' "$ss_iconURI")

    curl_status=$?

    if (( curl_status != 0 )); then
        /bin/rm -f -- "$download_file"
        logMe "ERROR: Icon download failed for policy ${policy_id}. curl exit code: ${curl_status}"
        update_display_list "Update" "$list_index" "Download Failed" "fail"

        return 1
    fi

    if [[ "$http_status" != "200" || ! -s "$download_file" ]]; then
        /bin/rm -f -- "$download_file"
        logMe "ERROR: Icon download for policy ${policy_id} returned HTTP ${http_status} or an empty response."
        update_display_list "Update" "$list_index" "Download Failed" "fail"

        return 1
    fi

    if ! /bin/mv -f -- "$download_file" "${ssStoragePath}/${ss_icon_filepath}"
    then
        /bin/rm -f -- "$download_file"
        logMe "ERROR: Unable to save the icon for policy ${policy_id}."
        update_display_list "Update" "$list_index" "Save Failed" "fail"
        return 1
    fi

    if ! update_display_list "Update" "$list_index" "Finished" "success"; then
        logMe "WARNING: Unable to display completion for policy ${policy_id}."
    fi
    return 0
}

function JAMF_retrieve_policy_details ()
{
    # PURPOSE:
    #   Retrieve one Jamf Pro policy as JSON.
    #
    # PARAMETERS:
    #   $1 = Jamf Pro policy ID
    #
    # OUTPUT:
    #   Policy JSON is written to stdout on success.
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local policy_id="${1:-}"
    local response_file=""
    local http_status=""
    local curl_status=0

    if [[ -z "$policy_id" || "$policy_id" != <-> ]]; then
        logMe "ERROR: Invalid policy ID passed to JAMF_retrieve_policy_details: ${policy_id:-empty}"
        return 1
    fi

    if [[ -z "$api_token" ]]; then
        logMe "ERROR: No Jamf API token is available for policy ${policy_id}."
        return 1
    fi

    response_file=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.policy.${policy_id}.XXXXX"
    ) || {
        logMe "ERROR: Unable to create response file for policy ${policy_id}."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure response file for policy ${policy_id}."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/policies/id/${policy_id}")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Policy ${policy_id} lookup failed. curl exit code: ${curl_status}"
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Policy ${policy_id} lookup returned HTTP ${http_status}."
            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Policy ${policy_id} lookup returned an empty response."
            return 1
        fi

        if ! /usr/bin/jq -e 'type == "object" and(.policy | type == "object")' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Policy ${policy_id} did not return the expected JSON structure."
            return 1
        fi

        /bin/cat "$response_file"
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function make_apfs_safe ()
{
    local value="${1:-}"

    value="${value//$'\r'/}"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    value="${value//:/_}"
    value="${value//\//-}"
    value="${value//\\/-}"
    value="${value//|/-}"

    while [[ "$value" == *"  "* ]]; do
        value="${value//  / }"
    done

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    while [[ "$value" == .* ]]; do
        value="${value#.}"
    done

    [[ -n "$value" ]] || value="Unnamed"

    print -r -- "$value"
}
########################################################################################
#
# Main Script
#
####################################################################################################

typeset api_token
typeset jamfpro_url
typeset ssStoragePath
typeset -g PolicyList
typeset -a worker_pids
typeset -i worker_failures=0


autoload -Uz is-at-least
zmodload zsh/datetime

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
make_temp_files || cleanup_and_exit 1
JAMF_get_server || cleanup_and_exit 1
JAMF_check_connection || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1
create_infobox_message
OVERLAY_ICON=$(JAMF_which_self_service)

welcomemsg

# Download all Jamf Pro policy ID numbers


JAMF_get_policy_list || {
    logMe "Unable to retrieve policy list"
    cleanup_and_exit 1
}

create_display_list || cleanup_and_exit 1

PolicyIDs=("${(@f)$(/usr/bin/jq -r '.policies[]| select(.id | type == "number") | (.id | floor)' <<< "$PolicyList")}")
if (( ${#PolicyIDs[@]} == 0 )); then
    logMe "WARNING: No policy IDs were returned by Jamf Pro."
    display_failure_message "No Jamf Pro policies were returned."
    cleanup_and_exit 1
fi

PoliciesCount=${#PolicyIDs[@]}

logMe "Checking $PoliciesCount policies for Self Service icons ..."

# Loop thru all of the policies by multiple background processes

maxCurrentJobs=10
worker_pids=()
worker_failures=0

JAMF_ensure_valid_token || {
    logMe "ERROR: Unable to obtain a valid Jamf API token."
    cleanup_and_exit 1
}

for (( policy_array_index = 1; policy_array_index <= ${#PolicyIDs[@]}; policy_array_index++ )); do
    item="${PolicyIDs[$policy_array_index]}"

    # Zsh arrays begin at 1, but SwiftDialog list indexes begin at 0.
    dialog_list_index=$(( policy_array_index - 1 ))

    JAMF_extract_policy_icons \
        "$item" \
        "$dialog_list_index" &

    worker_pids+=("$!")

    if (( ${#worker_pids[@]} >= maxCurrentJobs )); then
        logMe "Waiting for ${#worker_pids[@]} policy workers in the current batch."

        for worker_pid in "${worker_pids[@]}"; do
            if ! wait "$worker_pid"; then
                (( worker_failures++ ))
                logMe "WARNING: Worker PID ${worker_pid} returned a failure."
            fi
        done

        worker_pids=()

        if ! JAMF_ensure_valid_token; then
            logMe "ERROR: Unable to renew the Jamf API token between worker batches."
            cleanup_and_exit 1
        fi
    fi
done

if (( ${#worker_pids[@]} > 0 )); then
    logMe "Waiting for ${#worker_pids[@]} workers in the final batch."

    for worker_pid in "${worker_pids[@]}"; do
        if ! wait "$worker_pid"; then
            (( worker_failures++ ))
            logMe "WARNING: Worker PID ${worker_pid} returned a failure."
        fi
    done
fi

worker_pids=()

logMe "All Self Service icon workers have returned."

DirectoryCount=$(/usr/bin/find "$ssStoragePath" -maxdepth 1 -type f ! -name '.*.download' | awk 'END { print NR + 0 }')

logMe "${DirectoryCount} Self Service icon files downloaded to ${ssStoragePath}."

if (( worker_failures > 0 )); then
    completion_message="Finished with ${worker_failures} errors"
    logMe "WARNING: ${worker_failures} policy workers encountered errors."
else
    completion_message="All Done!"
    logMe "All Self Service policy workers completed successfully."
fi

update_display_list "progress" "" "" "$completion_message" "100"
update_display_list "buttonenable"
logMe "SwiftDialog completion button enabled."

# Now wait specifically for the user to close SwiftDialog.
if [[ -n "${DIALOG_PROCESS:-}" ]]; then
    wait "$DIALOG_PROCESS" 2>/dev/null
fi

cleanup_and_exit 0
