#!/bin/zsh
#
# JAMFRecoveryLock.sh
#
# by: Scott Kendall
#
# Written: 03/31/2025
# Last updated: 10/08/2026

# Script to View, Set, or Clear Recovery Lock on managed Apple Silicon Macs.
#
# The operator enters a target hostname or serial number and selects an action
# through SwiftDialog. The script uses the Jamf Pro API to locate the target
# computer, retrieve its stored Recovery Lock password, or submit a Set
# Recovery Lock MDM command.

# Key Functionalities:
# - Allows an operator to search for a managed Mac by hostname or serial number.
# - Supports Jamf API Client credentials or Jamf username/password credentials.
# - Retrieves the stored Recovery Lock password from Jamf Pro.
# - Submits Set or Clear Recovery Lock MDM commands.
# - Uses the Recovery Lock password supplied through parameter 6 for Set.
# - Invalidates user-account API tokens and clears OAuth tokens from memory.
# 
# Requirements:
# - The target computer must be an Apple Silicon Mac running macOS 11.5 or later.
# - Jamf Pro 11.30 or later is required by the v4 computer-inventory endpoints.
# - Jamf Pro API permissions: 
#   - Send Set Recovery Lock Command
#   - View MDM Command Information
#   - Read Computers
#   - View Recovery Lock
#
# Usage:
#
# - Parameter 3: Jamf logged-in username
# - Parameter 4: Jamf API Client ID or username
# - Parameter 5: Jamf API Client Secret or password
# - Parameter 6: Recovery Lock password used by the Set action
# - The operator selects View, Set, or Clear in SwiftDialog.

# - For details, refer: 
#   https://learn.jamf.com/en-US/bundle/technical-articles/page/Recovery_Lock_Enablement_in_macOS_Using_the_Jamf_Pro_API.html
# 
#  Karthikeyan Marappan / Scott Kendall
# 
# 1.0 - Initial code
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.2 - Reworked top section for better idea of what can be modified
#       renamed all JAMF functions to begin with JAMF_
# 1.3 - Verified working against JAMF API 11.20
#       Added option to detect which SS/SS+ we are using and grab the appropriate icon
#       Now works with JAMF Client/Secret or Username/password authentication
#       Change variable declare section around for better readability
#       Bumped Swift Dialog to v2.5.0
# 1.4 - Fixed invalid function call to invalidate JAMF token
#       Fixed determination of which SS/SS+ the script should be using
#       Added function to check and make sure the JAMF credentials are passed
#       Renamed utility to JAMFRecoveryLock.sh
# 1.5 - Added option to view recovery password
#       new APIs for set/clear recovery Lock
#       Show http results after set/clear command
# 1.6 - Had to increase window height for Tahoe & SD v3.0
# 1.7 - Changed JAMF 'policy -trigger' to JAMF 'policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Verified compatibility with Jamf Pro 11.30
#       Updated Recovery Lock workflows to use current Jamf Pro API endpoints
#       Improved API token handling and validation for both OAuth Client Credentials and Classic API authentication
#       Added automatic token renewal logic when tokens approach expiration
#       Improved Jamf Pro connection validation and error handling
#       Added additional API response validation to prevent unexpected processing failures
#       Enhanced computer lookup logic to ensure a single unique device match before executing Recovery Lock actions
#       Improved Recovery Lock password retrieval handling when no password is stored in Jamf Pro
#       Added validation for Set Recovery Lock operations when no Recovery Lock password is supplied
#       Improved temporary file security by applying restricted permissions to API response files
#       Enhanced cleanup routines to properly invalidate and remove API tokens at script completion
#       Improved logging consistency throughout the workflow
#       Improved SwiftDialog response validation and error handling
#       Enhanced support file and banner image detection logic
#       General code cleanup, optimization, and stability improvements
######################################################################################################
#
# Global "Common" variables (do not change these!)
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
SCRIPT_NAME="JAMFRecoveryLock"

FREE_DISK_SPACE=$(/bin/df -g / | /usr/bin/awk 'NR == 2 { print $4 }')
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
echo "Setting Default values"
SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles 2>/dev/null) || SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage 2>/dev/null) || SD_BANNER_IMAGE="GE_SD_BannerImage.png"
BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding 2>/dev/null) || BANNER_TEXT_PADDING=10
BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle 2>/dev/null) || BANNER_SUBTITLE=""
BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor 2>/dev/null) || BANNER_TEXT_COLOR="white"

[[ -e ${SUPPORT_DIR}/${SD_BANNER_IMAGE} ]] && SD_BANNER_IMAGE="${SUPPORT_DIR}${SD_BANNER_IMAGE}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Swift Dialog version requirements

MIN_SD_REQUIRED_VERSION="3.1.0"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# Display items (banner / icon)

SD_WINDOW_TITLE="Recovery Lock Actions"
OVERLAY_ICON=""
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_PARAMETER_USER="$3"
CLIENT_ID="$4"
CLIENT_SECRET="$5"
LOCK_CODE="$6"

CLIENT_ID_REGEX='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
[[ "$CLIENT_ID" =~ ${CLIENT_ID_REGEX} ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic"

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
    local LOG_DIR="${LOG_FILE%/*}"

    if ! admin_user; then
        return 0
    fi

    if [[ ! -d "$LOG_DIR" ]]; then
        if ! /bin/mkdir -p "$LOG_DIR"; then
            print -r -- "ERROR: Unable to create log directory: ${LOG_DIR}" >&2
            return 1
        fi
    fi

    /bin/chmod 755 "$LOG_DIR" || return 1

    if [[ ! -e "$LOG_FILE" ]] ; then
        /usr/bin/touch "$LOG_FILE" || return 1
    fi
    /bin/chmod 644 "$LOG_FILE" || return 1

    return 0
}

function logMe ()
{
    local log_message
    log_message="$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"

    if admin_user; then
        print -r -- "$log_message" | tee -a "$LOG_FILE" >&2
    else
        print -r -- "$log_message" >&2
    fi
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
    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install Swift Dialog."
        return 1
    fi

    /usr/local/bin/jamf policy -event "${DIALOG_INSTALL_POLICY}"
    local jamf_exit="$?"

    if [[ "$jamf_exit" -ne 0 ]]; then
        logMe "ERROR: Jamf Pro policy failed while installing Swift Dialog. Exit code: $jamf_exit"
        return 1
    fi

    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "ERROR: Swift Dialog still missing after install attempt."
        return 1
    fi
}

function check_support_files ()
{
    if [[ -f "$SD_BANNER_IMAGE" ]]; then
        logMe "Banner image found: ${SD_BANNER_IMAGE}"
    else
        logMe "Banner image not found: ${SD_BANNER_IMAGE}"
        logMe "Running support-file installation policy."

        if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"; then
            logMe "WARNING: Support-file installation policy failed."
        fi

        if [[ -f "$SD_BANNER_IMAGE" ]]; then
            logMe "Banner image successfully installed: ${SD_BANNER_IMAGE}"
        else
            logMe "WARNING: Banner image remains unavailable: ${SD_BANNER_IMAGE}"
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        logMe "jq is not installed. Running jq installation policy."

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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}"
}

function check_for_sudo ()
{
    if ! admin_user; then
        print -r -- "ERROR: This script must be run as root." >&2
        exit 1
    fi

    return 0
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - EXIT HUP INT TERM

    if [[ -n "$api_token" ]]; then
        JAMF_invalidate_token || true
    fi

    exit "$exit_code"
}

###########################
#
# JAMF functions
#
###########################

function JAMF_check_credentials ()
{
    # PURPOSE: Check to make sure the Client ID & Secret are passed correctly
    # RETURN: None
    # EXPECTED: None

    if [[ -z $CLIENT_ID ]] || [[ -z $CLIENT_SECRET ]]; then
        logMe "Client/Secret info is not valid"
        return 1
    fi
    logMe "Valid credentials passed"
    return 0
}

function JAMF_which_self_service ()
{
    local retval=""

    retval=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)
    [[ -z "$retval" ]] && retval=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
    print -r -- "$retval"
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
        JAMF_SERVER=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url) || {
            logMe "ERROR: Unable to read Jamf Pro URL" >&2
            return 1
        }
        logMe "No server passed in, defaulting to: $JAMF_SERVER"
        
    fi
    jamfpro_url="${JAMF_SERVER%/}"
    logMe "Jamf Pro server is: $jamfpro_url"
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
    local response_file
    local http_status
    local curl_status

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
            return 1
        }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure token-invalidation response file."
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
                --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" --data-urlencode "section=GENERAL" --data-urlencode "page=0" --data-urlencode "page-size=2" \
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

        print -r -- "$device_id"
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_send_recovery_lock_command ()
{
    local management_id="$1"
    local recovery_password="$2"

    local payload=""
    local response_file=""
    local http_status=""
    local curl_status=0
    local response=""

    [[ -n "$management_id" ]] || {
        logMe "ERROR: No management ID supplied."
        return 1
    }

    JAMF_ensure_valid_token || return 1

    #
    # Build JSON payload safely
    #
    if ! payload=$(jq -n \
            --arg managementID "$management_id" \
            --arg recoveryPassword "$recovery_password" \
            '{
                clientData: [
                    {
                        managementId: $managementID,
                        clientType: "COMPUTER"
                    }
                ],
                commandData: {
                    commandType: "SET_RECOVERY_LOCK",
                    newPassword: $recoveryPassword
                }
            }'
    ); then
        logMe "ERROR: Failed to construct Recovery Lock payload."
        return 1
    fi

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.recoverylock.XXXXX") || {
        logMe "ERROR: Unable to create response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location \
                --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --request POST --header "Authorization: Bearer ${api_token}" --header "Content-Type: application/json" --header "Accept: application/json" --data "$payload" \
                "${jamfpro_url}/api/v2/mdm/commands")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Recovery Lock request failed. curl exit code: ${curl_status}"
            return 1
        fi

        #
        # Validate Jamf response
        #
        case "$http_status" in
            200|201|202)
                ;;
            *)
                logMe "ERROR: Recovery Lock request returned HTTP ${http_status}"

                if [[ -s "$response_file" ]]; then
                    response=$(<"$response_file")
                    logMe "Jamf Response: ${response}"
                fi

                return 1
                ;;
        esac

        #
        # Return body to caller
        #
        if [[ -s "$response_file" ]]; then
            response=$(<"$response_file")
        else
            response="Command accepted by Jamf Pro."
        fi

        if [[ -n "$recovery_password" ]]; then
            logMe "Recovery Lock SET command successfully submitted for ${computer_id}"
        else
            logMe "Recovery Lock CLEAR command successfully submitted for ${computer_id}"
        fi

        print -r -- "$response"
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_view_recovery_lock ()
{
    local computer_id="$1"

    local response_file=""
    local http_status=""
    local curl_status=0
    local recovery_password=""
    local error_message=""

    [[ -n "$computer_id" ]] || {
        logMe "ERROR: No computer ID supplied."
        return 1
    }

    JAMF_ensure_valid_token || return 1

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.recoverylockview.XXXXX") || {
        logMe "ERROR: Unable to create Recovery Lock response file."
        return 1
    }

    if ! /bin/chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure Recovery Lock response file."
        /bin/rm -f -- "$response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/api/v4/computers-inventory/${computer_id}/view-recovery-lock-password")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Recovery Lock lookup failed. curl exit code: ${curl_status}"
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Recovery Lock lookup returned HTTP ${http_status}"

            if [[ -s "$response_file" ]]; then
                error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // empty' "$response_file" 2>/dev/null)

                [[ -n "$error_message" ]] &&
                    logMe "Jamf error: ${error_message}"
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Recovery Lock lookup returned an empty response."
            return 1
        fi

        if ! jq -e 'type == "object"' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Invalid JSON returned from Jamf."
            return 1
        fi
        
        if ! recovery_password=$(jq -r '.recoveryLockPassword // empty' "$response_file"); then
            logMe "ERROR: Unable to parse the Recovery Lock password response."
            return 1
        fi

        if [[ -z "$recovery_password" ]]; then
            print -r -- "No Recovery Lock password is currently stored in Jamf Pro."
            return 0
        fi

        print -r -- "$recovery_password"
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

####################################################################################################
#
# Application Specific functions
#
####################################################################################################

function display_welcome_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you want to set or clear the recovery lock on.  Please Note: This only works on Apple Silicon Macs."
        --messagefont name=Arial,size=17
        --textfield "Device,required"
        --button1text "Continue"
        --button2text "Quit"
        --infobox "${SD_INFO_BOX_MSG}"
        --vieworder "dropdown,textfield"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
		--selecttitle "Action,required"
		--selectvalues "View, Set, Clear"
		--selectdefault "View"
        --ontop
        --height 460
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    case "$buttonpress" in
        0)
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

    if ! search_type=$(printf '%s' "$message" | jq -er '.Serial.selectedValue'); then
        logMe "ERROR: Unable to parse the selected search type."
        cleanup_and_exit 1
    fi

    if ! computer_id=$(printf '%s' "$message" | jq -er '.Device | strings | select(length > 0)'); then
        logMe "ERROR: Unable to parse the target device."
        cleanup_and_exit 1
    fi

    if ! lockMode=$(printf '%s' "$message" | jq -er '.Action.selectedValue'); then
        logMe "ERROR: Unable to parse the selected action."
        cleanup_and_exit 1
    fi
}

function display_status_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --overlayicon SF="checkmark.circle.fill, color=green,weight=heavy,bgcolor=none"
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 440
        --json
        --moveable
    )

    case ${lockMode} in
        "View" )
            MainDialogBody+=(--message "Recovery lock for ${computer_id} is: **$1**")
            ;;
        "Set" )
            MainDialogBody+=(--message "Recovery Lock command was submitted for ${computer_id}.<br><br>**Jamf result:**<br><br>$1")
            ;;
        "Clear" )
            MainDialogBody+=(--message "Recovery lock cleared for ${computer_id}.<br><br>**JAMF Results:** <br><br>$1")
            ;;
    esac

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
}

function display_failure_message ()
{
    local failure_message="${1:-Device ID ${computer_id} was not found. Please try again.}"
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "$failure_message"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 440
        --json
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    cleanup_and_exit 1
}

####################################################################################################
#
# Main Script
#
####################################################################################################
declare jamfpro_url
declare api_token
declare ID

declare search_type
declare computer_id

autoload -Uz is-at-least
zmodload zsh/datetime

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
create_infobox_message

OVERLAY_ICON=$(JAMF_which_self_service)

display_welcome_message

logMe "Action Taken: "$lockMode

# Perform JAMF API calls to locate device and clear MDM failures
JAMF_get_server || cleanup_and_exit 1
if ! JAMF_check_connection; then
    display_failure_message "Problems determining the JAMF connection"
fi

JAMF_check_credentials || cleanup_and_exit 1

case "${lockMode}" in
    "View" )
        JAMF_ensure_valid_token || cleanup_and_exit 1

        if ! ID=$(JAMF_get_deviceID "$search_type" "$computer_id" '.results[0].id'); then
            display_failure_message "No unique Jamf computer record was found for ${computer_id}."
        fi

        if ! results=$(JAMF_view_recovery_lock "$ID"); then
            display_failure_message "Unable to retrieve the Recovery Lock password from Jamf Pro."
        fi
        ;;

    "Set" )

        [[ -z "$LOCK_CODE" ]] && display_failure_message "The Set action requires a Recovery Lock password in Jamf parameter 6."

        JAMF_ensure_valid_token || cleanup_and_exit 1

        if ! ID=$(JAMF_get_deviceID "$search_type" "$computer_id" '.results[0].general.managementId'); then
            display_failure_message "No unique Jamf computer record was found for ${computer_id}."
        fi

        if ! results=$(JAMF_send_recovery_lock_command "$ID" "$LOCK_CODE"); then
            display_failure_message "Failed to submit the Recovery Lock command to Jamf Pro."
        fi
        ;;

    "Clear" )
        JAMF_ensure_valid_token || cleanup_and_exit 1

        if ! ID=$(JAMF_get_deviceID "$search_type" "$computer_id" '.results[0].general.managementId'); then
            display_failure_message "No unique Jamf computer record was found for ${computer_id}."
        fi

        if ! results=$(JAMF_send_recovery_lock_command "$ID" ""); then
            display_failure_message "Failed to clear Recovery Lock through Jamf Pro."
        fi
        ;;
esac
logMe "Recovery Lock ${lockMode} workflow completed successfully for ${computer_id}."
display_status_message "$results"
cleanup_and_exit 0

