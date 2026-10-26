#!/bin/zsh
#
# RetrieveFV
#
# by: Scott Kendall
#
# Written: 12/20/2024
# Last updated: 10/26/2026
#
# Script Purpose: View Users Filevault Key
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - Use new Jamf API calls / Add more info in dialog screens
# 1.3 - Change welcome dialog to have a more friendly greeting
# 1.4 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.5 - dialog text changes / fix PBCOPY issue / Added overlay icon / Add title shadow
# 2.0 - Fixed tons of typos
#       You can now use Jamf classic & modern credentials
#       Added feature to read in defaults file
#       Add verification of Jamf credentials and error trapping if ID doesn't have rights
#       Compatible with Jamf 11.21 and higher using the new APIs
# 2.1 - Had to increase window height for Tahoe & SD v3.0
# 2.2 - Changed Jamf 'policy -trigger' to 'Jamf policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.3 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.4 - Production hardening and Jamf API reliability improvements
#       Support for multiple servers.
#       Added root validation and hardened log file/directory permissions
#       Improved SwiftDialog installation, version validation, and error handling
#       Improved support-file and jq installation/validation
#       Added centralized user-context initialization and cleanup/exit handling
#       Added reusable Jamf curl argument builder and Jamf date parser
#       Hardened Jamf Pro server and connectivity validation
#       Hardened Classic API and OAuth token retrieval and validation
#       Added token expiration tracking and automatic token renewal
#       Improved Jamf API token invalidation and cleanup
#       Reworked device lookup using Jamf Pro computer inventory API
#       Added handling for zero, single, and multiple device matches
#       Hardened FileVault recovery key retrieval and API error handling
#       Added secure temporary API response files with automatic cleanup
#       Improved SwiftDialog JSON validation and required-field handling
#       Added structured function return-code handling throughout main workflow
#       Improved clipboard failure detection and logging


######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="JamfRetrieveFV"
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


###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################

# Display items (banner / icon)

SD_WINDOW_TITLE="View FileVault Key"
SD_ICON="computer"
OVERLAY_ICON="SF=key.fill,color=black,bgcolor=none"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

####################
#
# JAMF API Keys Used
#
####################

JAMF_API_KEY="api/v4/computers-inventory"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_PARAMETER_USER="${3:-}"    #If run from Jamf, this will be the logged in user. If run from terminal, this will be empty (and will use the logged in user)
CLIENT_ID="${4:-}"              #Client ID for Jamf API authentication (if using Client ID/Secret)
CLIENT_SECRET="${5:-}"          #Client Secret for Jamf API authentication (if using Client ID/Secret)
JAMF_SERVER="${6:-}"            #Override the Jamf server URL if needed (if not passed, will use the defaults file or the local Jamf binary to determine the server URL)

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

    Jamf_LOGGED_IN_USER="${JAMF_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${Jamf_LOGGED_IN_USER%%.*}}"
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
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

###########################
#
# Jamf functions
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

function JAMF_which_self_service ()
{
    local app_path=""
    app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)

    [[ -z "$app_path" ]] &&app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
    [[ -z "$app_path" || ! -e "$app_path" ]] && app_path="SF=wrench.and.screwdriver.fill"
    print -r -- "$app_path"
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

        if ! expiration_epoch=$(format_jamf_date "$expires" "+%s"); then
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

function JAMF_get_deviceID ()
{
    # PURPOSE:
    #   Locate a single computer in Jamf Pro and return the requested ID.
    #
    # PARAMETERS:
    #   $1 = Search type ("Hostname" or "Serial Number")
    #   $2 = Search value
    #   $3 = jq filter to return desired field
    #
    # RETURNS:
    #   0 = Success
    #   1 = General failure
    #   2 = No matching computer found
    #   3 = Multiple matching computers found

    local search_type="$1"
    local search_value="$2"
    local jq_filter="$3"

    local filter_type=""
    local response_file=""
    local http_status=""
    local curl_status=0
    local result_count=0
    local device_id=""
    local error_message=""
    local -a curlArgs


    case "$search_type" in
        "Hostname")
            filter_type="general.name"
            ;;
        "Serial Number")
            filter_type="hardware.serialNumber"
            ;;
        *)
            logMe "ERROR: Unsupported search type: ${search_type}"
            return 1
            ;;
    esac

    JAMF_ensure_valid_token || return 1

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.inventory.XXXXX") || {
        logMe "ERROR: Unable to create inventory response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure inventory response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    JAMF_build_curl_args "$response_file"
    curlArgs=("${CURL_ARGS[@]}")
    curlArgs+=(
        --write-out "%{http_code}"
        --get
        --header "Authorization: Bearer ${api_token}"
        --header "Accept: application/json"
        --data-urlencode "section=GENERAL"
        --data-urlencode "page=0"
        --data-urlencode "page-size=100"
        --data-urlencode "sort=general.name:asc"
        --data-urlencode "filter=${filter_type}==${search_value}"
    )

    {
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/$JAMF_API_KEY")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Computer lookup failed. curl exit code: ${curl_status}"
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Computer lookup returned HTTP ${http_status}"

            if [[ -s "$response_file" ]]; then
                error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // empty' "$response_file" 2>/dev/null)
                [[ -n "$error_message" ]] && logMe "Jamf error: ${error_message}"
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Computer lookup returned an empty response."
            return 1
        fi

        if ! jq -e 'type == "object" and (.results | type == "array")' "$response_file" >/dev/null 2>&1
        then
            logMe "ERROR: Invalid JSON returned from Jamf."
            return 1
        fi

        if ! result_count=$(jq -er '.results | length' "$response_file"); then
            logMe "ERROR: Unable to determine result count."
            return 1
        fi

        case "$result_count" in
            0)
                logMe "ERROR: No computer matched ${search_type}: ${search_value}"
                return 2
                ;;
            1)
                ;;
            *)
                logMe "ERROR: Multiple computers matched ${search_type}: ${search_value}"
                return 3
                ;;
        esac

        if ! device_id=$(/usr/bin/jq -er "$jq_filter" "$response_file"); then
            logMe "ERROR: Requested identifier not found in Jamf response."
            return 1
        fi

        if [[ -z "$device_id" || "$device_id" == "null" ]]; then
            logMe "ERROR: Jamf returned an empty identifier."
            return 1
        fi

        ID="$device_id"

        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

###########################
#
# Application Specific functions
#
###########################

function display_welcome_message ()
{
    local -a MainDialogBody
    local message
    local -i buttonpress
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}"
        --infobox "${SD_INFO_BOX_MSG}"
        --infotext "$jamfpro_url"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 100
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you wish to see the FV Recovery Key for. \n\n You must also provide a reason for retrieving the Recovery Key."
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --textfield "Reason,required"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 480
        --json
        --moveable
    )

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?
    case "$buttonpress" in
        0)
            ;;

        2)
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with status ${buttonpress}."
            return 1
            ;;
    esac

    if ! /usr/bin/jq -e . <<< "$message" >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog returned invalid JSON."
        return 1
    fi

    search_type=$(/usr/bin/jq -r '.SelectedOption // empty' <<< "$message")
    computer_id=$(/usr/bin/jq -r '.Device // empty' <<< "$message")
    reason=$(/usr/bin/jq -r '.Reason // empty' <<< "$message")

    if [[ -z "$search_type" || -z "$computer_id" || -z "$reason" ]]; then
        logMe "ERROR: SwiftDialog did not return all required input values."
        return 1
    fi

    return 0
}

function invalid_device_message ()
{
    local -a dialogarray
    dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}" 
        --overlayicon warning
        --infobox "${SD_INFO_BOX_MSG}"
        --message "Device inventory not found for $computer_id. \nPlease make sure the device name or serial is correct."
        --messagefont "name=Arial,size=17"
        --ontop
        --height 460
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --moveable
    )
        
    "$SW_DIALOG" "${dialogarray[@]}" 2>/dev/null
    cleanup_and_exit
}

function Jamf_retrieve_filevault_key ()
{
    local response_file=""
    local http_status=""
    local curl_status=0
    local recovery_key=""
    local error_message=""
    local -a curlArgs

    JAMF_ensure_valid_token || {
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    }

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.filevault.XXXXX") || {
        logMe "ERROR: Unable to create FileVault response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure FileVault response file."
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

        http_status=$(/usr/bin/curl "${curlArgs[@]}" "${jamfpro_url}/${JAMF_API_KEY}/${ID}/filevault")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: FileVault key request failed. curl exit code: ${curl_status}"
            return 1
        fi

    case "$http_status" in
        200)
            ;;

        404)
            logMe "FileVault recovery key is not available for Jamf computer ID: ${ID}"
            return 2
            ;;

        401|403)
            logMe "ERROR: Jamf Pro denied access to the FileVault recovery key. HTTP ${http_status}"

            if [[ -s "$response_file" ]]; then
                error_message=$(/usr/bin/jq -r '.errors[0].description //.errors[0].message //.message //.error_description //empty ' "$response_file" 2>/dev/null)
                [[ -n "$error_message" ]] && logMe "Jamf error: ${error_message}"
            fi

            return 1
            ;;

        *)
            logMe "ERROR: FileVault key request returned HTTP ${http_status}."

            if [[ -s "$response_file" ]]; then
                error_message=$(/usr/bin/jq -r '.errors[0].description //.errors[0].message //.message //.error_description //empty ' "$response_file" 2>/dev/null)
                [[ -n "$error_message" ]] && logMe "Jamf error: ${error_message}"
            fi

            return 1
            ;;
    esac

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: FileVault key request returned an empty response."
            return 1
        fi

        if ! /usr/bin/jq -e 'type == "object"' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: FileVault key response was not valid JSON."
            return 1
        fi

        if ! recovery_key=$(/usr/bin/jq -er '.personalRecoveryKey| strings| select(length > 0)' "$response_file"); then
            logMe "ERROR: No personal FileVault recovery key was returned."
            return 2
        fi

        filevault_recovery_key_retrieved="$recovery_key"

        logMe "FileVault recovery key successfully retrieved."
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function display_failure_message ()
{
    local -a MainDialogBody
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "**Problems retrieving Jamf Info**<br><br>Error Message: $1"
        --icon "${SD_ICON}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null

}

function display_status_message ()
{
    local -a MainDialogBody
    if ! /usr/bin/printf '%s' "$filevault_recovery_key_retrieved" | /usr/bin/pbcopy; then
        logMe "WARNING: Unable to copy the FileVault recovery key to the clipboard."
    fi
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}" 
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon SF="checkmark.circle.fill, color=green,weight=heavy"
        --message "The Recovery Key for $computer_id is: <br>**$filevault_recovery_key_retrieved**<br><br>This key has also been copied to the clipboard"
        --messagefont "name=Arial,size=17" 
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --width 900
        --height 480
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    cleanup_and_exit
}
####################################################################################################
#
# Main Script
#
####################################################################################################
typeset -g jamfpro_url=""
typeset -g api_token=""
typeset -gi api_token_expires_epoch=0
typeset -g ID=""
typeset -g reason=""
typeset -g computer_id=""
typeset -g search_type=""
typeset -g filevault_recovery_key_retrieved=""
typeset -gi filevault_status=0
typeset -gi device_lookup_status=0

autoload -Uz is-at-least
zmodload zsh/datetime

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
JAMF_get_server || cleanup_and_exit 1
JAMF_check_connection || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1

create_infobox_message

if ! display_welcome_message; then
    display_failure_message "Unable to process the dialog response."
    cleanup_and_exit 1
fi

JAMF_get_deviceID "$search_type" "$computer_id" '.results[0].id'

device_lookup_status=$?

case "$device_lookup_status" in
    0)
        ;;

    2)
        invalid_device_message
        ;;

    3)
        display_failure_message "Multiple Jamf computer records matched ${computer_id}. Please use the device serial number."
        cleanup_and_exit 1
        ;;

    *)
        display_failure_message "Unable to search Jamf Pro for ${computer_id}."
        cleanup_and_exit 1
        ;;
esac

logMe "Jamf computer ID successfully located: ${ID}"

Jamf_retrieve_filevault_key
filevault_status=$?

case "$filevault_status" in
    0)
        ;;

    2)
        display_failure_message "A FileVault recovery key is not available for ${computer_id}."
        cleanup_and_exit 1
        ;;

    *)
        display_failure_message "Unable to retrieve the FileVault recovery key for ${computer_id}."
        cleanup_and_exit 1
        ;;
esac

display_status_message
cleanup_and_exit 0