#!/bin/zsh
##
# by: Scott Kendall
#
# Written: 03/31/2025
# Last updated: 10/20/2026
#
# Script Purpose: This script retrieves the Mac Hardware UUID, fetches the corresponding Computer ID from Jamf Pro, 
# checks for any failed MDM commands, and clears them if found.
#
# Uses JAMF API Client and Roles.
# Add Parameter 4 & 5 with API Client ID & Client Secret when running in JAMF Policy.
# API Role Privileges Required: Read Computers, Flush MDM Commands.
#
# Adapted from the script by Karthikey-Mac.  Original Source here: https://gist.github.com/karthikeyan-mac/4c46121ddd95b43465bd1b5e53ce571c
# 
# 1.0 - Initial code
# 1.1 - Changed wording of results screen to include device ID
# 1.2 - Added support for jq to pase results.  Also put in logic to install JQ from JAMF if missing
# 1.3 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.4 - Verified working agains JAMF API 11.20
#       Added option to detect which SS/SS+ we are using and grab the appropriate icon
#       Now works with JAMF Client/Secret or Username/password authentication
#       Change variable declare section around for better readability
#       Bumped Swift Dialog to v2.5.0
# 1.5 - Had to increase window height for Tahoe & SD v3.0
# 1.6 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
# 1.7 - Fixed incorrect variable name in retreival of the JAMF credentials
#       Fixed issue of not finding Self Service Plus path
#       Adjusted window height after fixing icon issue
# 1.8 - Hardened JAMF API operations and improved failed-command reporting
#       Added support for passing a Jamf Pro server URL as Parameter 6.
#       Added validation and sanitization of the Jamf Pro server URL before use.
#       Hardened device lookup error handling and now exits immediately on lookup failure.
#       Improved failed MDM command reporting with human-readable command summaries.
#       Added display of command status, issued date, and failed date information.
#       Added fallback handling for missing or blank command attributes.
#       Improved SwiftDialog formatting and readability for failed-command results.
#       Increased failed-command dialog width for improved display of long command names.
#       Replaced raw API JSON display with support-friendly formatted output.
#       Added validation of failed-command JSON structure before processing.
#       Added explicit propagation of failed-command retrieval errors to script exit status.
#       Removed reliance on global failed-command variables and improved function scoping.
#       Improved parameter validation and error reporting throughout JAMF API workflows.
#       Standardized logging output and cleaned up script diagnostics.
#       Updated server detection logic to support either passed-in or locally configured URLs.
#       General code cleanup and production hardening.

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="ClearFailedMDM"
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

SD_WINDOW_TITLE="Clear Failed MDM Commands"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON=""

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

###########################
#
# JAMF functions
#
###########################

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
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v4/computers-inventory")
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

        #ID="$device_id"
        printf '%s' "$device_id"
        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_get_failed_commands ()
{
    # PURPOSE:
    #   Retrieve the count of failed MDM commands for a computer.
    #
    # PARAMETERS:
    #   $1 = Computer ID
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local computerID="${1:-}"
    local responseFile=""
    local httpCode=""
    local curlExitCode=0
    local failedCommands=0
    local -a curlArgs
    local failedMDM=""

    [[ "$computerID" == <-> ]] || {
        logMe "ERROR: Invalid computer ID passed to JAMF_get_failed_commands: ${computerID}"
        return 1
    }

    JAMF_ensure_valid_token || return 1

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.failedmdm.XXXXX") || {
        logMe "ERROR: Unable to create failed-command response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure failed-command response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    {
        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")

        curlArgs+=(
            --write-out "%{http_code}"
            --request GET
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/json"
        )

        httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}/JSSResource/computerhistory/id/${computerID}/subset/commands")

        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: Failed-command query failed. curl exit code: ${curlExitCode}"
            return 1
        fi

        if [[ "$httpCode" != "200" ]]; then
            logMe "ERROR: Failed-command query returned HTTP ${httpCode}"

            if [[ -s "$responseFile" ]]; then
                logMe "ERROR: Response body begins with:"
                /usr/bin/head -c 500 "$responseFile" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$responseFile" ]]; then
            logMe "ERROR: Failed-command query returned an empty response."
            return 1
        fi


        if ! jq -e 'type == "object" and (.computer_history.commands.failed | type == "array")' "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Invalid failed-command JSON structure."
            return 1
        fi
        
        failedCommands=$(jq -er '.computer_history.commands.failed | length' "$responseFile") || {
            logMe "ERROR: Unable to determine failed command count."
            return 1
        }

        if (( failedCommands > 0 )); then
            failedMDM=$(jq -r '.computer_history.commands.failed[] |"• \(.name)\n\n" +
            "    Status: \((.status | select(length > 0)) // "Unknown")\n" +
            "    Issued: \((.issued | select(length > 0)) // "Unknown")\n" +
            "    Failed: \((.failed | select(length > 0)) // "Unknown")\n"
            ' "$responseFile")
            display_status_message "Fail" "${failedMDM}" "${computerID}"
        else
            display_status_message "Clear"
        fi
        return 0

    } always {
        /bin/rm -f -- "$responseFile"
    }
}

function JAMF_clear_failed_mdm_commands ()
{
    # PURPOSE:
    #   Flush all failed MDM commands for a computer.
    #
    # PARAMETERS:
    #   $1 = Computer ID
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local computerID="${1:-}"
    local responseFile=""
    local httpCode=""
    local curlExitCode=0
    local -a curlArgs

    [[ "$computerID" == <-> ]] || {
        logMe "ERROR: Invalid computer ID passed to JAMF_clear_failed_mdm_commands: ${computerID}"
        return 1
    }

    JAMF_ensure_valid_token || return 1

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.flushmdm.XXXXX") || {
        logMe "ERROR: Unable to create MDM flush response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure MDM flush response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    {
        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")

        curlArgs+=(
            --write-out "%{http_code}"
            --request DELETE
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/xml"
        )

        httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}/JSSResource/commandflush/computers/id/${computerID}/status/Failed")
        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: Failed-command flush request failed. curl exit code: ${curlExitCode}"
            return 1
        fi

        case "$httpCode" in
            200|201|202|204)
                logMe "Failed MDM commands successfully cleared for computer ID ${computerID}."

                if [[ -s "$responseFile" ]]; then
                    logMe "Flush response received from Jamf."
                fi

                return 0
                ;;
            *)
                logMe "ERROR: Failed-command flush returned HTTP ${httpCode}"

                if [[ -s "$responseFile" ]]; then
                    logMe "ERROR: Response body begins with:"
                    /usr/bin/head -c 500 "$responseFile" >&2
                    printf '\n' >&2
                fi

                return 1
                ;;
        esac

    } always {
        /bin/rm -f -- "$responseFile"
    }
}

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

###########################
#
# App Specific Functions
#
###########################

function welcomemsg ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitledetail "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON}"
        --iconsize 128
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you want to check and/or clear the failed MDM commands on."
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --textfield "Device,required"
        --button1text "Continue"
        --button2text "Quit"
        --infobox "${SD_INFO_BOX_MSG}"
        --ontop
        --height 460
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0

    search_type=$(echo $message | jq -r ".SelectedOption" )
    computer_id=$(echo $message | jq -r ".Device" )
}

function display_status_message ()
{
    # PARMS:
    #   $1 = Clear | Fail
    #   $2 = Failed MDM report text

    local messageStatus="${1:-}"
    local failedReport="${2:-}"
    local buttonpress
    local computerID="${3:-}"

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON}"
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --button1text "Quit"
        --ontop
        --json
        --moveable
    )

    if [[ "$messageStatus" == "Fail" ]]; then
        MainDialogBody+=(--height 700 --width 1100 --messagefont "size=18" --button2text "Clear" --overlayicon warning)
        MainDialogBody+=(--message "The following failed MDM commands were found on device ${computer_id}:<br><br>${failedReport}<br><br>Do you want to clear the errors at this time?")
    else
        MainDialogBody+=(--height 420 --message "No failed MDM commands were found for device ${computer_id}." --overlayicon "SF=checkmark.circle.fill,color=green,weight=heavy")
    fi

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    [[ "$buttonpress" == "2" ]] && JAMF_clear_failed_mdm_commands "$computerID"
}
####################################################################################################
#
# Main ScriptMBP-Y3FV9XFV6D
#
####################################################################################################
autoload -Uz is-at-least
zmodload zsh/datetime

declare jamfpro_url
declare api_token
declare api_authentication_check
declare ID
declare reason
declare access_token
declare token_expires_in
declare token_expiration_epoch
declare search_type
declare computer_id
declare redeploy_resonse
typeset -ga CURL_ARGS
typeset -g ID


autoload 'is-at-least'


check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
make_temp_files || cleanup_and_exit 1
create_infobox_message
JAMF_get_server || cleanup_and_exit 1
JAMF_check_connection || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1

SD_ICON=$(JAMF_which_self_service)
JAMF_ensure_valid_token || cleanup_and_exit 1

welcomemsg

# Perform JAMF API calls to locate device and clear MDM failures
if ! ID=$(JAMF_get_deviceID "${search_type}" "${computer_id}" ".results[0].id"); then
    cleanup_and_exit 1
fi
logMe "Device ID: $ID"
JAMF_get_failed_commands "$ID" || cleanup_and_exit 1
cleanup_and_exit 0
