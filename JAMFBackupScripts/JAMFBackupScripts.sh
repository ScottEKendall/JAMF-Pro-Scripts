#!/bin/zsh
#
# JAMFScriptBackup
#
# by: Scott Kendall
#
# Written: 05/28/2025
# Last updated: 10/22/2026
#
# Script Purpose: Exract all of the scripts from the JAMF server and store them on a local drive
#
# 1.0 - Initial
# 1.1 - Created a few new functions to reduce complexity / document function details / renamed all JAMF functions to start with JAMF......
# 1.2 - Add function to check for valid JAMF credentials
#       Fixed function to check which SS/SS+ is being used
#       Reworked top section for better idea of what can be modified
#       Bumped SwiftDialog min version to 2.5.0
# 1.3 - Changed JAMF 'policy -trigger' to JAMF 'policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
#       Fixed function to check which SS/SS+ is being used (again)
#       Had to increase window height for Tahoe & SD v3.0
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Added category-based script backup folders
#       Added APFS-safe formatting for category and script filenames
#       Added an Uncategorized fallback for missing Jamf categories
#       Added Jamf script IDs to exported filenames to prevent collisions
#       Added destination-folder creation and write validation
#       Added detection and cleanup of empty or failed script exports
#       Added successful and failed backup counters
#       Added JSON backup manifest containing script metadata and totals
#       Added automatic token validation during long-running exports
#       Added current-script and total-script progress reporting
#       Added JSON structure validation for the script summary response
#       Improved failure reporting in SwiftDialog and the script log

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="JAMFScriptBackup"
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
MIN_SD_REQUIRED_VERSION="3.1.0"
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

SUPPORT_DIR="${SUPPORT_DIR%/}"

if [[ "${SD_BANNER_IMAGE#/SupportFiles/}" != "$SD_BANNER_IMAGE" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE#/}"
elif [[ "${SD_BANNER_IMAGE:0:1}" != "/" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
fi

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="JAMF Script Backup"
OVERLAY_ICON="/Applications/Self Service.app"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"

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
CLIENT_ID="${4:-}"              #Client ID for JAMF API authentication (if using Client ID/Secret)
CLIENT_SECRET="${5:-}"          #Client Secret for JAMF API authentication (if using Client ID/Secret)
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
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}" >&2
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
    JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog JSON file."
        return 1
    }

    DIALOG_COMMAND_FILE=$(
        mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX") || {
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

function update_dialog_json ()
{
    # PURPOSE:
    #   Replace JSON_DIALOG_BLOB with complete JSON received through stdin.
    #
    # RETURN:
    #   0 = JSON validated and installed
    #   1 = Update failed

    local temporaryJSON=""

    if [[ -z "${JSON_DIALOG_BLOB:-}" ]]; then
        logMe "ERROR: JSON_DIALOG_BLOB is not defined."
        return 1
    fi

    temporaryJSON=$(mktemp "/var/tmp/${SCRIPT_NAME}.dialog-update.XXXXX") || {
        logMe "ERROR: Unable to create temporary SwiftDialog JSON file."
        return 1
    }

    {
        if ! /bin/chmod 600 "$temporaryJSON"; then
            logMe "ERROR: Unable to secure temporary SwiftDialog JSON file."
            return 1
        fi

        if ! /bin/cat > "$temporaryJSON"; then
            logMe "ERROR: Unable to write temporary SwiftDialog JSON file."
            return 1
        fi

        if [[ ! -s "$temporaryJSON" ]]; then
            logMe "ERROR: SwiftDialog JSON update produced an empty file."
            return 1
        fi

        if ! jq -e . "$temporaryJSON" >/dev/null 2>&1; then
            logMe "ERROR: SwiftDialog JSON update produced invalid JSON."

            while IFS= read -r line; do
                logMe "JSON: ${line}"
            done < "$temporaryJSON"

            return 1
        fi

        if ! /bin/cp "$temporaryJSON" "$JSON_DIALOG_BLOB"; then
            logMe "ERROR: Unable to replace the SwiftDialog JSON file."
            return 1
        fi

        return 0

    } always {
        /bin/rm -f -- "$temporaryJSON"
    }
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

    local responseFile="${1:-}"

    CURL_ARGS=(
        --silent
        --show-error
        --location
        --connect-timeout 15
        --max-time 60
    )

    if [[ -n "$responseFile" ]]; then
        CURL_ARGS+=(
            --output "$responseFile"
        )
    fi

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

function JAMF_get_classic_api_token ()
{
    local response_file=""
    local http_code=""
    local curlExitCode=0
    local token=""
    local expires=""
    local expiration_epoch=""
    local -a curlArgs

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.classic-token.XXXXX") || {
        logMe "ERROR: Unable to create Classic API token response file." >&2
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure Classic API token response file." >&2
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        JAMF_build_curl_args "$response_file"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --request POST
            --user "${CLIENT_ID}:${CLIENT_SECRET}"
            --header "Accept: application/json"
        )

        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v1/auth/token")
        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: Classic API token request failed. curl exit code: ${curlExitCode}" >&2
            return 1
        fi

        if [[ "$http_code" != "200" ]]; then
            logMe "ERROR: Classic API token request returned HTTP ${http_code}." >&2

            if [[ -s "$response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                head -c 500 "$response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Classic API token response was empty." >&2
            return 1
        fi

        if ! jq -e 'type == "object"' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Classic API token response was not valid JSON." >&2
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic API response did not contain a bearer token." >&2
            return 1
        fi

        if ! expires=$(jq -er '.expires | strings | select(length > 0)' "$response_file"); then
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
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_get_access_token ()
{
    local response_file=""
    local http_code=""
    local curlExitCode=0
    local token=""
    local expires_in=0
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
        --header "Accept: application/json"
        --header "Content-Type: application/x-www-form-urlencoded"
        --data-urlencode "client_id=${CLIENT_ID}" 
        --data-urlencode "grant_type=client_credentials" 
        --data-urlencode "client_secret=${CLIENT_SECRET}"
    )

    {
        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/oauth/token")

        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: OAuth token request failed, curl exit ${curlExitCode}" >&2
            return 1
        fi

        if [[ "$http_code" != "200" ]]; then
            logMe "ERROR: OAuth token request returned HTTP ${http_code}." >&2

            if [[ -s "$response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                head -c 500 "$response_file" >&2
                printf '\n' >&2
            else
                logMe "ERROR: OAuth response body was empty." >&2
            fi

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
    local -i renewal_buffer=60
    local -i current_epoch=$EPOCHSECONDS

    if [[ -n "${api_token:-}" ]] &&
       (( api_token_expires_epoch > 0 )) &&
       (( current_epoch + renewal_buffer <= api_token_expires_epoch )); then
        return 0
    fi

    logMe "Jamf API token is missing or expires within ${renewal_buffer} seconds. Requesting a new token."

    api_token=""
    api_token_expires_epoch=0

    case "$JAMF_TOKEN" in
        new)
            if ! JAMF_get_access_token; then
                logMe "ERROR: Unable to obtain a new OAuth access token." 1>&2
                return 1
            fi
            ;;

        classic)
            if ! JAMF_get_classic_api_token; then
                logMe "ERROR: Unable to obtain a new Classic API bearer token." 1>&2
                return 1
            fi
            ;;

        *)
            logMe "ERROR: Unknown authentication type: ${JAMF_TOKEN}" 1>&2
            return 1
            ;;
    esac

    if [[ -z "${api_token:-}" ]]; then
        logMe "ERROR: Token request completed without returning an API token." 1>&2
        api_token_expires_epoch=0
        return 1
    fi

    if (( api_token_expires_epoch <= EPOCHSECONDS )); then
        logMe "ERROR: Token request returned an invalid expiration epoch: ${api_token_expires_epoch}" 1>&2
        api_token=""
        api_token_expires_epoch=0
        return 1
    fi

    return 0

}

function JAMF_invalidate_token ()
{
    local response_file=""
    local http_code=""
    local curlExitCode=0
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

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.invalidate.XXXXX") || {
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
        JAMF_build_curl_args "$response_file"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --request POST
            --header "Accept: application/json"
            --header "Authorization: Bearer ${api_token}"
            )

        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v1/auth/invalidate-token")
        curlExitCode=$?

        api_token=""
        api_token_expires_epoch=0

        if (( curlExitCode != 0 )); then
            logMe "ERROR: Token invalidation failed. curl exit code: ${curlExitCode}" >&2
            return 1
        fi

        case "$http_code" in
            204)
                logMe "Jamf Pro user-account token successfully invalidated."
                ;;

            401)
                logMe "Jamf Pro user-account token was already invalid."
                ;;

            *)
                logMe "WARNING: Unexpected token invalidation response: HTTP ${http_code}" >&2
                return 1
                ;;
        esac
        # Request and status handling
        } always {
            /bin/rm -f -- "$response_file"
    }
    return 0
}

function JAMF_retrieve_script_summary ()
{
    # PURPOSE:
    #   Retrieve script summary JSON from a Jamf API endpoint.
    #
    # RETURN:
    #   JSON payload on stdout

    local apiPath="${1:-}"
    local responseFile=""
    local httpCode=""
    local curlExitCode=0
    local -a curlArgs

    [[ -z "$apiPath" ]] && {
        logMe "ERROR: No API path was provided."
        return 1
    }

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.summary.XXXXX") || {
        logMe "ERROR: Unable to create temporary response file."
        return 1
    }

    {
        /bin/chmod 600 "$responseFile" || {
            logMe "ERROR: Unable to secure temporary response file."
            return 1
        }

        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")

        curlArgs+=(
            --write-out "%{http_code}"
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/json"
        )

        httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}${apiPath}")
        curlExitCode=$?

        (( curlExitCode == 0 )) || {
            logMe "ERROR: Script summary request failed. curl exit code: ${curlExitCode}"
            return 1
        }

        [[ "$httpCode" == "200" ]] || {
            logMe "ERROR: Script summary request returned HTTP ${httpCode}."

            if [[ -s "$responseFile" ]]; then
                logMe "ERROR: Response begins with:"
                head -c 500 "$responseFile"
                printf '\n'
            fi

            return 1
        }

        [[ -s "$responseFile" ]] || {
            logMe "ERROR: Script summary response was empty."
            return 1
        }

        if ! jq -e 'type == "object" and (.scripts | type == "array")' "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Script summary response did not contain a valid scripts array."
            return 1
        fi

        cat "$responseFile"

    } always {
        /bin/rm -f -- "$responseFile"
    }
}

function JAMF_retrieve_script_details ()
{
    # PURPOSE:
    #   Retrieve detailed JSON data from a Jamf API endpoint.
    #
    # PARAMETERS:
    #   $1 = Jamf API path
    #
    # RETURN:
    #   JSON payload on stdout

    local apiPath="${1:-}"
    local responseFile=""
    local httpCode=""
    local curlExitCode=0
    local -a curlArgs

    [[ -z "$apiPath" ]] && {
        logMe "ERROR: No API path was provided."
        return 1
    }

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.json.XXXXX") || {
        logMe "ERROR: Unable to create temporary response file."
        return 1
    }

    {
        /bin/chmod 600 "$responseFile" || {
            logMe "ERROR: Unable to secure temporary response file."
            return 1
        }

        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")

        curlArgs+=(
            --write-out "%{http_code}"
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/json"
        )

        httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}${apiPath}")
        curlExitCode=$?

        (( curlExitCode == 0 )) || {
            logMe "ERROR: Script details request failed. curl exit code: ${curlExitCode}"
            return 1
        }

        [[ "$httpCode" == "200" ]] || {
            logMe "ERROR: Script details request returned HTTP ${httpCode}."

            if [[ -s "$responseFile" ]]; then
                logMe "ERROR: Response begins with:"
                head -c 500 "$responseFile"
                printf '\n'
            fi

            return 1
        }

        [[ -s "$responseFile" ]] || {
            logMe "ERROR: Script details response was empty."
            return 1
        }

        jq -e . "$responseFile" >/dev/null 2>&1 || {
            logMe "ERROR: Script details response was not valid JSON."
            return 1
        }

        cat "$responseFile"

    } always {
        /bin/rm -f -- "$responseFile"
    }
}


###########################
#
# App Specific Functions
#
###########################

function welcomemsg ()
{
    message="This script will extract all of the system scripts from your JAMF server and store them in local folder structure.  Please select a destination folder location below:"
    HELP_MESSAGE="All of the system scripts from your JAMF server<br>will be extract and stored in the location of your choice."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage "$HELP_MESSAGE"
        --width 800
        --height 480
        --ignorednd
        --ontop
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
        --textfield "Select a storage location",fileselect,filetype=folder,required
    )
	
			
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

	ssStoragePath=$( echo $temp | /usr/bin/grep "location" | awk -F ": " '{print $NF}' | tr -d '\' | tr -d '"')

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
        --arg button2Text "Cancel" \
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
            moveable: true,
            quitkey: "0",
            ontop: true,
            vieworder: "textfield, dropdown, listitem, selectitems",
            width: 840,
            height: 660,
            messageposition: "top",
            button1text: $button1Text,
            button2text: $button2Text
        }'
}

function create_listitem_message_body ()
{
    # PURPOSE:
    #   Add one item to the SwiftDialog listitem array.
    #
    # PARAMETERS:
    #   $1 = Item title
    #   $2 = Item icon, optional
    #   $3 = Status text, optional
    #   $4 = Status, optional
    #
    # EXAMPLE:
    #   create_listitem_message_body \
    #       "Static Group Name" \
    #       "SF=desktopcomputer.and.macbook" \
    #       "Found" \
    #       "success"

    local title="${1:-}"
    local icon="${2:-}"
    local statusText="${3:-}"
    local statusSD="${4:-}"

    if [[ -z "$title" ]]; then
        logMe "ERROR: List-item title was not provided."
        return 1
    fi

    if ! jq \
        --arg title "$title" \
        --arg icon "$icon" \
        --arg statusText "$statusText" \
        --arg status "$statusSD" \
        '
        .listitem = (.listitem // []) |
        .listitem += [
            {
                title: $title
            }
            +
            (
                if $icon != "" then
                    {icon: $icon}
                else
                    {}
                end
            )
            +
            (
                if $status != "" then
                    {status: $status}
                else
                    {}
                end
            )
            +
            (
                if $statusText != "" then
                    {statustext: $statusText}
                else
                    {}
                end
            )
        ]
        ' "$JSON_DIALOG_BLOB" |
        update_dialog_json; then

        logMe "ERROR: Unable to add list item '${title}' to SwiftDialog JSON."
        return 1
    fi

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

    case "${action:l}" in

        create|show)
            "$SW_DIALOG" --progress --infotext "${jamfpro_url}" --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" &
            DIALOG_PROCESS=$!

            # if ! wait_for_dialog_ready; then
            #     return 1
            # fi

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
            if [[ -z "$list_index" ]]; then
                logMe "ERROR: Invalid SwiftDialog list index: ${list_index:-empty}"
                return 1
            fi

            status_text="${status_text//$'\r'/}"
            status_text="${status_text//$'\n'/<br>}"

            dialog_command="listitem: index: ${list_index}, status: ${status_value}, statustext: ${status_text}"

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

function create_display_list ()
{
    local scriptName=""

    if ! construct_dialog_header_settings "The following JAMF scripts will be backed up to:<br>${ssStoragePath}" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct SwiftDialog JSON."
        return 1
    fi

    while IFS= read -r scriptName; do
        [[ -n "$scriptName" ]] || continue
        logMe "Located script: ${scriptName}"

        if ! create_listitem_message_body "$scriptName" "" "Pending..." "pending"; then
            return 1
        fi
    done < <(jq -r '.scripts[] | .name| strings| select(length > 0)' <<< "$ScriptList")
    update_display_list "create"
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

###############################################
#
# Application Specific functions
#
###############################################

function extract_script_details ()
{
    # PURPOSE:
    #   Retrieve a Jamf script and export it into a category folder.
    #
    # PARAMETERS:
    #   $1 = Jamf script ID
    #   $2 = Zero-based SwiftDialog list index
    #
    # RETURN:
    #   0 = Script successfully exported
    #   1 = Script could not be exported

    local scriptID="${1:-}"
    local listIndex="${2:-}"
    local scriptName=""
    local scriptInfo=""
    local scriptCategory=""
    local scriptFileName=""
    local scriptContents=""
    local formattedCategory=""
    local formattedScriptName=""
    local categoryPath=""
    local destinationFile=""
    local jsonBlob=""
    local manifestEntry=""
    local progressPercent=0
    local currentScriptNumber=0

    if [[ -z "$scriptID" ]]; then
        logMe "ERROR: No Jamf script ID was provided."
        return 1
    fi

    if [[ "$listIndex" != <-> ]]; then
        logMe "ERROR: Invalid list index for script ID ${scriptID}: ${listIndex:-empty}"
        return 1
    fi

    currentScriptNumber=$(( listIndex + 1 ))

    update_display_list "Update" "$listIndex" "Retrieving..." "wait"

    if ! jsonBlob=$(JAMF_retrieve_script_details "/JSSResource/scripts/id/${scriptID}"); then
        logMe "ERROR: Unable to retrieve details for script ID ${scriptID}."

        update_display_list "Update" "$listIndex" "Retrieval Failed!" "fail"

        failedMigration+=("Script ID ${scriptID}")
        (( failedBackupCount++ ))

        return 1
    fi

    if ! scriptName=$(jq -er '.script.name | strings | select(length > 0)' <<< "$jsonBlob"); then
        scriptName="Script ID ${scriptID}"
    fi

    if ! scriptInfo=$(jq -er '.script.info | strings' <<< "$jsonBlob"); then
        scriptInfo=""
    fi

    if ! scriptCategory=$(jq -er '.script.category | strings | select(length > 0)' <<< "$jsonBlob"); then
        scriptCategory="Uncategorized"
    fi

    if ! scriptFileName=$(jq -er '.script.filename | strings | select(length > 0)' <<< "$jsonBlob"); then
        scriptFileName="$scriptName"
    fi

    if ! scriptContents=$(jq -er '.script.script_contents | strings' <<< "$jsonBlob"); then
        scriptContents=""
    fi

    case "${scriptCategory:l}" in
        ""|none|null)
            scriptCategory="Uncategorized"
            ;;
    esac

    formattedScriptName=$(make_apfs_safe "$scriptFileName")
    formattedCategory=$(make_apfs_safe "$scriptCategory")

    case "${formattedCategory:l}" in
        ""|unnamed|none|null)
            formattedCategory="Uncategorized"
            ;;
    esac

    [[ -n "$formattedScriptName" ]] || formattedScriptName="Script_${scriptID}"

    # Avoid adding a second .sh extension when Jamf already supplies one.
    formattedScriptName="${formattedScriptName%.sh}"
    formattedScriptName="${formattedScriptName%.SH}"

    categoryPath="${ssStoragePath}/${formattedCategory}"
    destinationFile="${categoryPath}/${scriptID}_${formattedScriptName}.sh"

    if [[ -z "${scriptContents//[[:space:]]/}" ]]; then
        logMe "ERROR: Script '${scriptName}' contains no exportable content."

        update_display_list "Update" "$listIndex" "Empty Script!" "fail"
        failedMigration+=("${scriptName} [ID: ${scriptID}]")
        (( failedBackupCount++ ))
        return 1
    fi

    if ! /bin/mkdir -p -- "$categoryPath"; then
        logMe "ERROR: Unable to create category folder: ${categoryPath}"
        update_display_list "Update" "$listIndex" "Folder Failed!" "fail"
        failedMigration+=("${scriptName} [ID: ${scriptID}]")
        (( failedBackupCount++ ))
        return 1
    fi

    update_display_list "Update" "$listIndex" "Exporting..." "wait"
    if ! print -r -- "$scriptContents" > "$destinationFile"; then
        logMe "ERROR: Unable to write script backup: ${destinationFile}"

        /bin/rm -f -- "$destinationFile"
        update_display_list "Update" "$listIndex" "Write Failed!" "fail"
        failedMigration+=("${scriptName} [ID: ${scriptID}]")
        (( failedBackupCount++ ))

        return 1
    fi

    if [[ ! -s "$destinationFile" ]]; then
        logMe "ERROR: Script backup was created but is empty: ${destinationFile}"

        /bin/rm -f -- "$destinationFile"

        update_display_list "Update" "$listIndex" "Empty Export!" "fail"
        failedMigration+=("${scriptName} [ID: ${scriptID}]")
        (( failedBackupCount++ ))
        return 1
    fi

    if ! manifestEntry=$(jq -n \
        --arg id "$scriptID" \
        --arg name "$scriptName" \
        --arg info "$scriptInfo" \
        --arg category "$scriptCategory" \
        --arg filename "$scriptFileName" \
        --arg backupFile "${formattedCategory}/${scriptID}_${formattedScriptName}.sh" \
        '{
            id: $id,
            name: $name,
            info: $info,
            category: $category,
            filename: $filename,
            backupFile: $backupFile,
            status: "success"
        }'); then

        logMe "WARNING: Unable to create manifest entry for script ID ${scriptID}."
    else
        backupManifestEntries+=("$manifestEntry")
    fi

    (( successfulBackupCount++ ))

    logMe "Exported '${scriptName}' to '${destinationFile}'."

    update_display_list "Update" "$listIndex" "Finished" "success"
    if (( scriptCount > 0 )); then
        progressPercent=$(( 100 * currentScriptNumber / scriptCount ))
    else
        progressPercent=100
    fi

    update_display_list "progress" "" "" "Exporting ${currentScriptNumber} of ${scriptCount}: ${formattedScriptName}" "$progressPercent"
    return 0
}

function show_backup_errors ()
{
    message="The below list of scripts could not be backed up for some reason!<br><br>"
    for item in "${failedMigration[@]}"; do
        message+="* $item<br>"
    done
    message+="<br>This might be due to improper formatting in the original script or invalid characters.  You might need to copy these scripts manually out of JAMF."

	MainDialogBody=(
        --message "$message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 800
        --height 480
        --ignorednd
        --quitkey 0
        --button1text "OK"
    )
	
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
}

function prepare_backup_destination ()
{
    # PURPOSE:
    #   Create and validate the destination folder for this backup.
    #
    # RETURN:
    #   0 = Destination is ready
    #   1 = Destination could not be prepared

    local selectedPath="${ssStoragePath:-}"
    local backupDate=""

    if [[ -z "$selectedPath" ]]; then
        logMe "ERROR: No backup destination was selected."
        return 1
    fi

    if [[ ! -d "$selectedPath" ]]; then
        logMe "ERROR: The selected destination does not exist: ${selectedPath}"
        return 1
    fi

    if [[ ! -w "$selectedPath" ]]; then
        logMe "ERROR: The selected destination is not writable: ${selectedPath}"
        return 1
    fi

    backupDate=$(/bin/date '+%Y-%m-%d_%H-%M-%S')
    ssStoragePath="${selectedPath}/Jamf_Script_Backup_${backupDate}"

    if ! /bin/mkdir -p -- "$ssStoragePath"; then
        logMe "ERROR: Unable to create backup folder: ${ssStoragePath}"
        return 1
    fi

    BACKUP_MANIFEST="${ssStoragePath}/BackupManifest.json"

    logMe "Backup destination created: ${ssStoragePath}"
    return 0
}

function create_backup_manifest ()
{
    # PURPOSE:
    #   Create a JSON manifest describing the completed backup.
    #
    # RETURN:
    #   0 = Manifest successfully created
    #   1 = Manifest creation failed

    local temporaryManifest=""
    local scriptsJSON="[]"

    if [[ -z "${BACKUP_MANIFEST:-}" ]]; then
        logMe "ERROR: BACKUP_MANIFEST is not defined."
        return 1
    fi

    temporaryManifest=$(mktemp \
        "/var/tmp/${SCRIPT_NAME}.manifest.XXXXX") || {
        logMe "ERROR: Unable to create temporary manifest file."
        return 1
    }

    {
        if ! /bin/chmod 600 "$temporaryManifest"; then
            logMe "ERROR: Unable to secure temporary manifest file."
            return 1
        fi

        if (( ${#backupManifestEntries[@]} > 0 )); then
            if ! scriptsJSON=$(printf '%s\n' \
                "${backupManifestEntries[@]}" |
                jq -s '.'); then

                logMe "ERROR: Unable to assemble script manifest entries."
                return 1
            fi
        fi

        if ! jq -n \
            --arg created "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" \
            --arg server "$jamfpro_url" \
            --arg destination "$ssStoragePath" \
            --argjson found "$scriptCount" \
            --argjson successful "$successfulBackupCount" \
            --argjson failed "$failedBackupCount" \
            --argjson scripts "${scriptsJSON:-[]}" \
            '{
                created: $created,
                jamfServer: $server,
                destination: $destination,
                totals: {
                    found: $found,
                    successful: $successful,
                    failed: $failed
                },
                scripts: $scripts
            }' > "$temporaryManifest"; then

            logMe "ERROR: Unable to build backup manifest."
            return 1
        fi

        if ! jq -e . "$temporaryManifest" >/dev/null 2>&1; then
            logMe "ERROR: Backup manifest contains invalid JSON."
            return 1
        fi

        if ! /bin/mv -f -- \
            "$temporaryManifest" \
            "$BACKUP_MANIFEST"; then

            logMe "ERROR: Unable to save backup manifest: ${BACKUP_MANIFEST}"
            return 1
        fi

        temporaryManifest=""
        logMe "Backup manifest created: ${BACKUP_MANIFEST}"

        return 0

    } always {
        [[ -n "$temporaryManifest" ]] &&
            /bin/rm -f -- "$temporaryManifest"
    }
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload -Uz is-at-least
zmodload zsh/datetime

declare api_token
declare jamfpro_url
declare ssStoragePath
typeset ScriptList
typeset HELP_MESSAGE=""

declare -a failedMigration
declare -a backupManifestEntries

integer scriptCount=0
integer successfulBackupCount=0
integer failedBackupCount=0
integer count=0

BACKUP_MANIFEST=""


check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
make_temp_files || cleanup_and_exit 1
create_infobox_message
OVERLAY_ICON=$(JAMF_which_self_service)
JAMF_get_server || cleanup_and_exit 1
JAMF_check_connection || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1
JAMF_ensure_valid_token || cleanup_and_exit 1
welcomemsg
prepare_backup_destination || cleanup_and_exit 1
ScriptList=$(JAMF_retrieve_script_summary "/JSSResource/scripts") || cleanup_and_exit 1
ScriptIDs=($(jq -r '.scripts[].id' <<< "$ScriptList"))
scriptCount=${#ScriptIDs[@]}

create_display_list || cleanup_and_exit 1

count=0

for item in "${ScriptIDs[@]}"; do
    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid token before processing script ID ${item}."

        update_display_list "Update" "$count" "Authentication Failed!" "fail"
        failedMigration+=("Script ID ${item}")
        (( failedBackupCount++ ))
        (( count++ ))

        continue
    fi

    if ! extract_script_details "$item" "$count"; then
        logMe "WARNING: Failed to process script ID ${item}."
    fi

    (( count++ ))
done

if ! create_backup_manifest; then
    logMe "WARNING: The script backup completed, but the backup manifest could not be created."
fi

if (( failedBackupCount > 0 )); then
    completionText="Backup complete: ${successfulBackupCount} succeeded, ${failedBackupCount} failed"
else
    completionText="Backup complete: ${successfulBackupCount} scripts exported"
fi

update_display_list "progress" "" "" "$completionText" "100"
update_display_list "buttonenable"
wait

(( ${#failedMigration[@]} > 0 )) && show_backup_errors

cleanup_and_exit 0
