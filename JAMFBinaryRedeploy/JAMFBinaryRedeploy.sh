#!/bin/zsh
#
# JAMFBinaryRedeploy.sh
#
# by: Scott Kendall
#
# Written: 03/06/2025
# Last updated: 10/12/2026
#
# Script Purpose: Redeploy the JAMF binary on a device
#   This script is a combination of documentation taken from here:
#       https://www.modtitan.com/2022/02/jamf-binary-self-heal-with-jamf-api.html
#   and here:
#       https://snelson.us/2022/08/jamf-binary-self-heal-via-terminal/

#
# 1.0 - Initial
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.2 - Now works with JAMF API Client/Secret or Username/password authentication
#     - Change variable declare section around for better readability
# 1.3 - Made API changes for JAMF Pro 11.20 and higher
# 1.4 - Added function to check JAMF credentials are passed
#       Fixed function to determine which SS/SS+ is being used
# 1.5 - Added option for manual enroll with instructions on how to perform
#       Moved more items into functions from the main script to clean up things
#       Moved all "exit" commands into the clean_and_exit function to make sure temp files are erased
# 1.6 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
#       Put more error trapping around invalid privileges
#       Fixed display issues with Swift Dialog 3.0
# 2.0 - Updated SwiftDialog minimum version to 3.1.0
#       Added OAuth client credential and Classic API authentication support
#       Added API token expiration tracking, renewal, and invalidation
#       Migrated computer lookup to the Jamf Pro computer inventory API
#       Added HTTP status, curl status, JSON, and empty-response validation
#       Added secured temporary files with guaranteed cleanup
#       Added hostname and serial-number searches
#       Added manual Jamf binary installation instructions
#       Added user confirmation, reason capture, and audit logging
#       Added managed subtitle, banner color, and padding settings
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
SCRIPT_NAME="JAMFBinaryRedeploy"

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

SD_WINDOW_TITLE="JAMF Binary Self Heal"
SD_ICON="/Applications/Self Service.app"
OVERLAY_ICON="warning"

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

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - EXIT INT TERM

    if [[ -n "$api_token" ]]; then
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

    normalized_date=$(print -r -- "$normalized_date" | /usr/bin/sed -E -e 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/' -e 's/\.([0-9]+)([+-][0-9]{4})$/\2/' -e 's/\.([0-9]+)$//')

    # Remove fractional seconds while preserving any timezone offset.
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

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --get --output "$response_file" --write-out '%{http_code}' \
                --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" --data-urlencode "section=GENERAL" --data-urlencode "page=0" --data-urlencode "page-size=100" \
                --data-urlencode "sort=general.name:asc" --data-urlencode "filter=${filter_type}==\"${search_value}\"" "${jamfpro_url}/api/v4/computers-inventory")

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

        if ! device_id=$(jq -er "$jq_filter" "$response_file"); then
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

function JAMF_renew_binary ()
{
    local jamf_id="${1:-}"
    local response_file=""
    local http_status=""
    local curl_status=0
    local error_message=""

    REDEPLOY_ERROR=""

    if [[ -z "$jamf_id" ]]; then
        REDEPLOY_ERROR="No Jamf computer ID was provided for redeployment."
        logMe "ERROR: ${REDEPLOY_ERROR}"
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        REDEPLOY_ERROR="Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.redeploy.XXXXX") || {
        REDEPLOY_ERROR="Unable to create the temporary redeploy response file."
        logMe "ERROR: ${REDEPLOY_ERROR}"
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        REDEPLOY_ERROR="Unable to secure the temporary redeploy response file."
        logMe "ERROR: ${REDEPLOY_ERROR}"
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --request POST --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/api/v1/jamf-management-framework/redeploy/${jamf_id}")
        curl_status=$?

        if (( curl_status != 0 )); then
            REDEPLOY_ERROR="Unable to communicate with Jamf Pro. curl exit code: ${curl_status}."
            logMe "ERROR: ${REDEPLOY_ERROR}"
            return 1
        fi

        case "$http_status" in
            200|201|202|204)
                logMe "Jamf binary redeploy request was accepted for computer ID ${jamf_id}."
                return 0
                ;;

            401)
                REDEPLOY_ERROR="Jamf Pro rejected the API token."
                ;;

            403)
                REDEPLOY_ERROR="The API account does not have permission to redeploy the Jamf management framework."
                ;;

            404)
                REDEPLOY_ERROR="Jamf computer ID ${jamf_id} was not found."
                ;;

            *)
                if [[ -s "$response_file" ]]; then
                    error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // empty' "$response_file" 2>/dev/null)
                fi

                REDEPLOY_ERROR="Jamf Pro returned HTTP ${http_status}."

                if [[ -n "$error_message" ]]; then
                    REDEPLOY_ERROR="${REDEPLOY_ERROR} ${error_message}"
                fi
                ;;
        esac

        logMe "ERROR: ${REDEPLOY_ERROR}"
        return 1

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function display_welcome_message ()
{
    local -a MainDialogBody
    local message=""
    local buttonpress=0

     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},padding=${BANNER_TEXT_PADDING}"
        --messagefont "name=Arial,size=17"
        --iconsize 100
        --message "${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}. Please enter the serial number or hostname of the device on which you want to redeploy the Jamf binary.<br><br>You can also redeploy the Jamf binary manually. Click **Manual Method** for instructions."
        --textfield "Device,required"
        --textfield "Reason,required"
        --infobuttontext "Manual Method"
        --button1text "Continue"
        --button2text "Quit"
        --quitoninfo
        --vieworder "dropdown,textfield"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --ontop
        --json
        --height 480
        --moveable
     )
	
     message=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )


    buttonpress=$?
    breakLoop=true
        case "$buttonpress" in
        0)
            ;;
        2)
            logMe "User canceled the operation."
            cleanup_and_exit 0
            ;;
        3)
            logMe "User requested manual deployment steps."
            breakLoop=false
            if ! display_manual_deploy; then
                logMe "ERROR: Unable to display manual deployment steps."
                return 1
            fi
            return 0
            ;;
        *)
            logMe "ERROR: SwiftDialog exited with code ${buttonpress}."
            cleanup_and_exit 1
            ;;
    esac

    if ! search_type=$(printf '%s' "$message" | jq -er '.Serial.selectedValue'); then
        logMe "ERROR: Unable to parse the selected search type."
        cleanup_and_exit 1
    fi

    if ! computer_id=$(printf '%s' "$message" | jq -er '.Device | strings | select(length > 0)'); then
        logMe "ERROR: Unable to parse the target device."
        cleanup_and_exit 1
    fi

    if ! reason=$(printf '%s' "$message" | jq -er '.Reason'); then
        logMe "ERROR: Unable to parse the selected reason."
        cleanup_and_exit 1
    fi
    computer_id="${computer_id#"${computer_id%%[![:space:]]*}"}"
    computer_id="${computer_id%"${computer_id##*[![:space:]]}"}"

    reason="${reason#"${reason%%[![:space:]]*}"}"
    reason="${reason%"${reason##*[![:space:]]}"}"

    if [[ -z "$computer_id" ]]; then
        logMe "ERROR: The device search value is empty."
        cleanup_and_exit 1
    fi

    if [[ -z "$reason" ]]; then
        logMe "ERROR: The redeployment reason is empty."
        cleanup_and_exit 1
    fi

    return 0
}

function display_manual_deploy ()
{
    local -a MainDialogBody
    local displayManualSteps=""
    local manualSteps=""
    local buttonpress=0

    displayManualSteps=$(
    cat <<EOF
mkdir -p /usr/local/jamf/bin
curl -fL -o /tmp/jamf "${jamfpro_url}/bin/jamf"
chmod 755 /tmp/jamf
mv /tmp/jamf /usr/local/jamf/bin/jamf
/usr/local/jamf/bin/jamf createConf -url "${jamfpro_url}"
/usr/local/jamf/bin/jamf enroll -prompt
/usr/local/jamf/bin/jamf policy
EOF
)
    manualSteps="$displayManualSteps"
    displayManualSteps="${displayManualSteps//$'\n'/<br>}"

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},padding=${BANNER_TEXT_PADDING}"
        --messagefont "name=Arial,size=17"
        --iconsize 100
        --message "These are the steps that you need to perform on the workstation to manually download the JAMF binary from the Jamf Pro server:<br><br>$displayManualSteps"
        --button1text "Back"
        --button2text "Quit"
        --infobuttontext "Copy to clipboard"
        --quitoninfo
        --ontop
        --height 420
        --moveable
     )
	
    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null

    buttonpress=$?

    case "$buttonpress" in
        0)
            logMe "User returned from the manual deployment dialog."
            return 0
            ;;

        2)
            logMe "User exited from the manual deployment dialog."
            cleanup_and_exit 0
            ;;

        3)
            print -rn -- "$manualSteps" | /usr/bin/pbcopy
            logMe "Manual deployment steps copied to the clipboard."
            return 0
            ;;

        *)
            logMe "ERROR: Manual deployment dialog exited with code ${buttonpress}."
            return 1
            ;;
    esac

}

function inventory_not_found ()
{
    local -a dialogarray

    dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},padding=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON}" 
        --overlayicon "${OVERLAY_ICON}"
        --alignment center
        --message "**Device inventory not found!** <br><br>Please make sure the device name or serial is correct."
        --ontop
        --moveable
     )

    "$SW_DIALOG" "${dialogarray[@]}" 2>/dev/null
    cleanup_and_exit 1
}

function confirm_user_choice ()
{
    local -a dialogarray
    local buttonpress=0
    # confirm that the user wants to continue

    dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}"
        --overlayicon "${OVERLAY_ICON}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},padding=${BANNER_TEXT_PADDING}"
        --message "Jamf record **${ID}** was found for **${computer_id}**.<br><br>Redeploying the Jamf management framework may cause the device to repeat portions of the enrollment process.<br><br>Are you sure you want to continue?"
        --ontop
        --moveable
        --button1text "Continue"
        --button2text "Cancel"
    )

    "$SW_DIALOG" "${dialogarray[@]}" 2>/dev/null
    buttonpress=$?

        case "$buttonpress" in
        0)
            return 0
            ;;
        2)
            logMe "User canceled the operation."
            cleanup_and_exit 0
            ;;
        *)
            logMe "ERROR: SwiftDialog exited with code ${buttonpress}."
            cleanup_and_exit 1
            ;;
    esac

}

function show_results () 
{
    local -a dialogarray

    logMe "Jamf binary redeploy command sent to computer ID ${ID}."

    # Show the result

    dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --icon "${SD_ICON}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},padding=${BANNER_TEXT_PADDING}"
        --messagefont "name=Arial,size=17"
        --overlayicon "SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
        --message "The request to redeploy the Jamf binary on **${computer_id}** was accepted.<br><br>This operation may cause the device to repeat portions of the enrollment process."
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${dialogarray[@]}" 2>/dev/null
    cleanup_and_exit 0

}

function display_failure_message ()
{
     local -a MainDialogBody

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},padding=${BANNER_TEXT_PADDING}"
        --messagefont "name=Arial,size=17"
        --message "**Jamf Binary Redeploy Failed**<br><br>${1}"
        --icon "${SD_ICON}"
        --overlayicon warning
        --iconsize 128
        --button1text "OK"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    return 0
}

########################
#
# Start of Main Program
#
########################

typeset -g api_token=""
typeset -gi api_token_expires_epoch=0
typeset -g jamfpro_url=""
typeset -g ID=""
typeset -g reason=""
typeset -g search_type=""
typeset -g computer_id=""
typeset -g REDEPLOY_ERROR=""
typeset -gi lookup_status=0
typeset -g breakLoop=false

autoload -Uz is-at-least
zmodload zsh/datetime
breakLoop=false

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1
JAMF_get_server || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1

SD_ICON=$(JAMF_which_self_service)

if ! JAMF_check_connection; then
    display_failure_message "Unable to connect to the Jamf Pro server. Review the script log for details."
    cleanup_and_exit 1
fi

while true; do
    if ! display_welcome_message; then
        logMe "ERROR: Unable to display the welcome dialog."
        cleanup_and_exit 1
    fi
    if [[ $breakLoop == true ]]; then
        break
    fi
done
JAMF_ensure_valid_token || cleanup_and_exit 1

ID=""

JAMF_get_deviceID "$search_type" "$computer_id" '.results[0].id'
lookup_status=$?

case "$lookup_status" in
    0)
        logMe "Device ID #${ID}"
        ;;

    2)
        inventory_not_found
        ;;

    3)
        display_failure_message "Multiple Jamf records matched ${search_type}: ${computer_id}"
        cleanup_and_exit 1
        ;;

    *)
        display_failure_message "Unable to retrieve the Jamf record for ${computer_id}. Review the script log for details."
        cleanup_and_exit 1
        ;;
esac

# Confirm they want to continue and do the redeploy command

confirm_user_choice

logMe "Redeploy requested by ${JAMF_LOGGED_IN_USER} for ${computer_id}; reason: ${reason}"

if JAMF_renew_binary "$ID"; then
    show_results
else
    display_failure_message "${REDEPLOY_ERROR:-The Jamf binary redeploy request failed. Review the script log for details.}"
    cleanup_and_exit 1
fi