#!/bin/zsh --no-rcs
#
# JAMFStaticGroupUtility.sh
#
# by: Scott Kendall
#
# Written: 10/09/2025
# Last updated: 10/19/2026
#
# Script Purpose: View, Add or Delete JAMF static group members
#

######################
#
# Script Parameters:
#
#####################
#
#   Parameter 4: API client ID (Classic or Modern)
#   Parameter 5: API client secret
#   Parameter 6: Single / Migrate action
#   Parameter 7: JAMF Static Group name
# 	Parameter 8: Action to take on group (Add/Remove)
#	Parameter 9: Show the dialog window (Yes/No)
#   Parameter 10: View / Migrate groups
#   Parameter 11: Admin access (wether or not user can choose any machine)
#
# 1.0 - Initial
# 1.1 - Add function to make sure Client / Secret are passed into the script
# 1.2 - Added options to pass group action (Add/Remove) and whether or not to show to selection window
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 2.0 - Add option to do a copy of group membership from one computer to another
# 2.1 - Optimized header variables section
#       Optimized some JAMF functions for faster processing
# 2.2 - Changed JAMF 'policy -trigger' to JAMF 'policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.3 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.4 - Had to add MAC_HOSTNAME=$(scutil --get HostName) to the global variables section to get the hostname for comparison in the list item creation function.  This is because the "HostName" variable was not 
#       being passed into the create_listitem_message_body function correctly and was always evaluating as blank, which caused the script to never recognize a match and display all items as "Not Found"
# 3.0 - Added ability to remove a computer from all static groups
#       Added support for API pagination
#       Added modern inventory retrieval framework
#       Added reusable curl argument framework
#       Added API token lifecycle management
#       Added enhanced parameter validation
#       Added expanded usage documentation
#       Optimized static group discovery
#       Optimized inventory retrieval
#       Rewrote JAMF API functions to use temp files and always cleanup blocks
#       Improved HTTP response handling
#       Improved API failure handling
#       Improved logging consistency
#       Improved support for large Jamf environments
#       Fixed inventory retrieval limitations
#       Fixed static group enumeration limitations
#       Fixed multiple edge cases involving token validation and API responses

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
SCRIPT_NAME="JAMFStaticGroupUtility"

FREE_DISK_SPACE=$(/bin/df -g / | awk 'NR == 2 { print $4 }')
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)
MAC_HOSTNAME=$(/usr/sbin/scutil --get HostName 2>/dev/null)
[[ -z "$MAC_HOSTNAME" ]] && MAC_HOSTNAME=$(/usr/sbin/scutil --get ComputerName 2>/dev/null)
[[ -z "$MAC_HOSTNAME" ]] && MAC_HOSTNAME=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)

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
#MAC-KCJGJT4W22
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

SD_WINDOW_TITLE="JAMF Static Group Utility"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="${ICON_FILES}ToolbarCustomizeIcon.icns"
HELP_MESSAGE="**Single Group Method**<br> \
1.  Select the group<br> \
2.  Type in the HOSTNAME of the device<br> \
3.  Choose Action to perform<br> \
    1.  (Add) device to group<br> \
    2.  (Delete) device from group<br> \
    3.  (View) see if device is group<br><br> \
**Migrate Options**<br><br> \
1. Select (Old) System to migrate FROM<br> \
2. Select (New) system to migrate TO<br>"
 
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
REQUEST_TYPE=${6:-"single"}     # single/migrate
JAMF_GROUP_NAME=${7}          
JAMF_GROUP_ACTION=${8:-"Add"}
SHOW_WINDOW=${9:-"Yes"}  
ACTION_TAKEN=${10:-"view"}      #view or migrate groups
ACCESS_TYPE=${11:-""}           #whether or not user can choose any machine (normal/admin)

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


###########################
#
# JAMF functions
#
###########################


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

function JAMF_get_classic_api_token ()
{
    local responseFile=""
    local http_code=""
    local curlExitCode=0
    local token=""
    local expires=""
    local expiration_epoch=""
    local -a curlArgs

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.classic-token.XXXXX") || {
        logMe "ERROR: Unable to create Classic API token response file." >&2
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure Classic API token response file." >&2
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    {
        JAMF_build_curl_args "$responseFile"
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

            if [[ -s "$responseFile" ]]; then
                logMe "ERROR: Response begins with:" >&2
                head -c 500 "$responseFile" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$responseFile" ]]; then
            logMe "ERROR: Classic API token response was empty." >&2
            return 1
        fi

        if ! jq -e 'type == "object"' "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Classic API token response was not valid JSON." >&2
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$responseFile"); then
            logMe "ERROR: Classic API response did not contain a bearer token." >&2
            return 1
        fi

        if ! expires=$(jq -er '.expires | strings | select(length > 0)' "$responseFile"); then
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
        /bin/rm -f -- "$responseFile"
    }
}

function JAMF_get_access_token ()
{
    local responseFile=""
    local http_code=""
    local curlExitCode=0
    local token=""
    local expires_in=0
    local -a curlArgs
    
    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create OAuth response file" >&2
        return 1
    }
    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure OAuth token response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi
    

    JAMF_build_curl_args "$responseFile"
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

            if [[ -s "$responseFile" ]]; then
                logMe "ERROR: Response begins with:" >&2
                head -c 500 "$responseFile" >&2
                printf '\n' >&2
            else
                logMe "ERROR: OAuth response body was empty." >&2
            fi

            return 1
        fi

        if ! jq -e . "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: OAuth token response was not valid JSON" >&2
            return 1
        fi

        if ! token=$(jq -er '.access_token | strings | select(length > 0)' "$responseFile"); then
            logMe "ERROR: OAuth response did not contain an access token" >&2
            return 1
        fi

        if ! expires_in=$(jq -er '.expires_in | numbers | floor | select(. > 0)' "$responseFile"); then
            logMe "ERROR: OAuth response did not contain a valid expires_in value." >&2
            return 1
        fi

        api_token="$token"
        api_token_expires_epoch=$(( EPOCHSECONDS + expires_in ))
        logMe "OAuth access token successfully obtained."
        return 0
    } always {
        /bin/rm -f -- "$responseFile"
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
    local responseFile=""
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

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.invalidate.XXXXX") || {
        logMe "ERROR: Unable to create token-invalidation response file."
        api_token=""
        api_token_expires_epoch=0
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure token-invalidation response file."
        api_token=""
        api_token_expires_epoch=0
        /bin/rm -f -- "$responseFile"
        return 1
    fi
    {
        JAMF_build_curl_args "$responseFile"
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
            /bin/rm -f -- "$responseFile"
    }
    return 0
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

function JAMF_retrieve_paginated_results ()
{
    # PURPOSE:
    #   Retrieve every page from a paginated Jamf Pro API endpoint and
    #   combine all page results into one JSON object.
    #
    # PARAMETERS:
    #   $1 = API endpoint without query parameters
    #   $2 = Page size, optional; defaults to 100
    #   $3 = Sort expression, optional
    #   $4 = Filter expression, optional
    #
    # RETURN:
    #   JSON object containing:
    #       {
    #           "totalCount": <combined result count>,
    #           "results": [...]
    #       }
    #
    # EXAMPLE:
    #   JAMF_retrieve_paginated_results \
    #       "api/v3/computer-groups/static-groups" \
    #       100 \
    #       "id:asc"

    local endpoint="${1:-}"
    local pageSize="${2:-100}"
    local sortExpression="${3:-}"
    local filterExpression="${4:-}"

    local responseFile=""
    local aggregateFile=""
    local mergedFile=""
    local httpCode=""
    local curlExitCode=0
    local returnedCount=0
    local totalCount=0
    local aggregateCount=0
    local -i page=0
    local -a curlArgs

    if [[ -z "$endpoint" ]]; then
        logMe "ERROR: JAMF_retrieve_paginated_results called without an API endpoint."
        return 1
    fi

    if [[ "$pageSize" != <-> ]] || (( pageSize <= 0 )); then
        logMe "ERROR: Invalid pagination page size: ${pageSize:-<empty>}"
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Failed to validate the Jamf Pro API token."
        return 1
    fi

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.page-response.XXXXX") || {
        logMe "ERROR: Unable to create paginated response file."
        return 1
    }

    aggregateFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.page-aggregate.XXXXX") || {
        logMe "ERROR: Unable to create pagination aggregate file."
        /bin/rm -f -- "$responseFile"
        return 1
    }

    mergedFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.page-merged.XXXXX") || {
        logMe "ERROR: Unable to create pagination merge file."
        /bin/rm -f -- "$responseFile" "$aggregateFile"
        return 1
    }

    if ! /bin/chmod 600 "$responseFile" "$aggregateFile" "$mergedFile"; then
        logMe "ERROR: Unable to secure pagination temporary files."
        /bin/rm -f -- "$responseFile" "$aggregateFile" "$mergedFile"
        return 1
    fi

    {
        if ! printf '%s\n' '{"results":[]}' > "$aggregateFile"; then
            logMe "ERROR: Unable to initialize pagination aggregate data."
            return 1
        fi

        while true; do
            : > "$responseFile"

            if ! JAMF_ensure_valid_token; then
                logMe "ERROR: Unable to ensure a valid token before retrieving page ${page}."
                return 1
            fi

            JAMF_build_curl_args "$responseFile"
            curlArgs=("${CURL_ARGS[@]}")
            curlArgs+=(
                --write-out "%{http_code}"
                --get
                --header "Accept: application/json"
                --header "Authorization: Bearer ${api_token}"
                --data-urlencode "page=${page}"
                --data-urlencode "page-size=${pageSize}"
            )

            [[ -n "$sortExpression" ]] && curlArgs+=(--data-urlencode "sort=${sortExpression}")
            [[ -n "$filterExpression" ]] && curlArgs+=(--data-urlencode "filter=${filterExpression}")

            logMe "Retrieving page ${page} from '${endpoint}'."

            httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}/${endpoint}")

            curlExitCode=$?

            if (( curlExitCode != 0 )); then
                logMe "ERROR: curl failed while retrieving page ${page} from '${endpoint}'. curl exit code: ${curlExitCode}."

                if [[ -s "$responseFile" ]]; then
                    logMe "ERROR: Response begins with:"
                    head -c 1000 "$responseFile" >&2
                    printf '\n' >&2
                fi

                return 1
            fi

            case "$httpCode" in
                200)
                    ;;

                400)
                    logMe "ERROR: Invalid pagination request for '${endpoint}' on page ${page}."
                    return 1
                    ;;

                401)
                    logMe "ERROR: Unauthorized while retrieving page ${page} from '${endpoint}' (HTTP 401)."
                    return 1
                    ;;

                403)
                    logMe "ERROR: Insufficient privileges while retrieving page ${page} from '${endpoint}' (HTTP 403)."
                    return 1
                    ;;

                404)
                    logMe "ERROR: Endpoint '${endpoint}' was not found (HTTP 404)."
                    return 1
                    ;;

                *)
                    logMe "ERROR: Unexpected HTTP ${httpCode} while retrieving page ${page} from '${endpoint}'."

                    if [[ -s "$responseFile" ]]; then
                        logMe "ERROR: Response begins with:"
                        head -c 1000 "$responseFile" >&2
                        printf '\n' >&2
                    else
                        logMe "ERROR: Response body was empty."
                    fi

                    return 1
                    ;;
            esac

            if [[ ! -s "$responseFile" ]]; then
                logMe "ERROR: Jamf Pro returned an empty response for page ${page} from '${endpoint}'."
                return 1
            fi

            if ! jq -e 'type == "object" and (.results | type == "array")' "$responseFile" >/dev/null 2>&1; then

                logMe "ERROR: Page ${page} from '${endpoint}' did not contain a valid results array."
                return 1
            fi

            if ! returnedCount=$(jq -er '.results | length' "$responseFile"); then
                logMe "ERROR: Unable to determine the result count for page ${page}."
                return 1
            fi

            if [[ "$returnedCount" != <-> ]]; then
                logMe "ERROR: Page ${page} returned an invalid result count: ${returnedCount}"
                return 1
            fi

            if ! totalCount=$(jq -er '
                if (.totalCount | type) == "number" then
                    .totalCount
                else
                    0
                end' "$responseFile"); then

                logMe "ERROR: Unable to determine the total result count for '${endpoint}'."
                return 1
            fi

            if ! jq -s '{results:
                        (
                            (.[0].results // []) +
                            (.[1].results // [])
                        )
                }' "$aggregateFile" "$responseFile" > "$mergedFile"; then

                logMe "ERROR: Unable to merge page ${page} into the pagination aggregate."
                return 1
            fi

            if ! /bin/mv -f -- "$mergedFile" "$aggregateFile"; then
                logMe "ERROR: Unable to replace pagination aggregate data."
                return 1
            fi

            if ! aggregateCount=$(jq -er '.results | length' "$aggregateFile"); then
                logMe "ERROR: Unable to determine the accumulated pagination result count."
                return 1
            fi

            logMe "Page ${page} returned ${returnedCount} result(s); ${aggregateCount} accumulated."

            if (( returnedCount == 0 )); then
                break
            fi

            if (( totalCount > 0 && aggregateCount >= totalCount )); then
                break
            fi

            if (( returnedCount < pageSize )); then
                break
            fi

            (( page++ ))
        done

        if ! jq --argjson totalCount "$aggregateCount" '.totalCount = $totalCount' "$aggregateFile"; then

            logMe "ERROR: Unable to construct the completed paginated response."
            return 1
        fi

        logMe "Pagination completed for '${endpoint}'. Retrieved ${aggregateCount} total result(s)."
        return 0

    } always {
        /bin/rm -f -- \
            "$responseFile" \
            "$aggregateFile" \
            "$mergedFile"
    }
}

function JAMF_get_paginated_inventory_records ()
{
    # PURPOSE:
    #   Retrieve every page of matching computer inventory records.
    #
    # PARAMETERS:
    #   $1 = Inventory section
    #   $2 = Optional Jamf API filter
    #   $3 = Optional page size; defaults to 100
    #
    # RETURN:
    #   Combined JSON object containing all matching results.

    local inventorySection="${1:-}"
    local filterCondition="${2:-}"
    local pageSize="${3:-100}"

    local responseFile=""
    local aggregateFile=""
    local mergedFile=""
    local httpCode=""
    local curlExitCode=0
    local returnedCount=0
    local totalCount=0
    local aggregateCount=0
    local -i page=0
    local -a curlArgs

    if [[ -z "$inventorySection" ]]; then
        logMe "ERROR: JAMF_get_paginated_inventory_records called without an inventory section."
        return 1
    fi

    if [[ "$pageSize" != <-> ]] || (( pageSize <= 0 )); then
        logMe "ERROR: Invalid inventory page size: ${pageSize:-<empty>}"
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Failed to validate the Jamf Pro API token."
        return 1
    fi

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.inventory-page.XXXXX") || {
        logMe "ERROR: Unable to create inventory page response file."
        return 1
    }

    aggregateFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.inventory-aggregate.XXXXX") || {
        logMe "ERROR: Unable to create inventory aggregate file."
        /bin/rm -f -- "$responseFile"
        return 1
    }

    mergedFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.inventory-merged.XXXXX") || {
        logMe "ERROR: Unable to create inventory merge file."
        /bin/rm -f -- "$responseFile" "$aggregateFile"
        return 1
    }

    if ! /bin/chmod 600 "$responseFile" "$aggregateFile" "$mergedFile"; then

        logMe "ERROR: Unable to secure inventory pagination files."
        /bin/rm -f -- "$responseFile" "$aggregateFile" "$mergedFile"
        return 1
    fi

    {
        if ! printf '%s\n' '{"results":[]}' > "$aggregateFile"; then
            logMe "ERROR: Unable to initialize inventory aggregate data."
            return 1
        fi

        while true; do
            : > "$responseFile"

            if ! JAMF_ensure_valid_token; then
                logMe "ERROR: Unable to ensure a valid token before inventory page ${page}."
                return 1
            fi

            JAMF_build_curl_args "$responseFile"
            curlArgs=("${CURL_ARGS[@]}")
            curlArgs+=(
                --write-out "%{http_code}"
                --get
                --header "Authorization: Bearer ${api_token}"
                --header "Accept: application/json"
                --data-urlencode "section=${inventorySection}"
                --data-urlencode "page=${page}"
                --data-urlencode "page-size=${pageSize}"
                --data-urlencode "sort=general.name:asc"
            )

            [[ -n "$filterCondition" ]] && curlArgs+=(--data-urlencode "filter=${filterCondition}")
            
            logMe "Retrieving inventory page ${page} for section '${inventorySection}'."

            httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v4/computers-inventory")

            curlExitCode=$?

            if (( curlExitCode != 0 )); then
                logMe "ERROR: curl failed while retrieving inventory page ${page}. curl exit code: ${curlExitCode}."
                return 1
            fi

            case "$httpCode" in
                200)
                    ;;

                400)
                    logMe "ERROR: Invalid inventory request. Section='${inventorySection}', filter='${filterCondition}', page=${page}."
                    return 1
                    ;;

                401)
                    logMe "ERROR: Unauthorized while retrieving inventory page ${page} (HTTP 401)."
                    return 1
                    ;;

                403)
                    logMe "ERROR: Insufficient privileges while retrieving inventory page ${page} (HTTP 403)."
                    return 1
                    ;;

                404)
                    logMe "ERROR: Computer inventory endpoint was not found (HTTP 404)."
                    return 1
                    ;;

                *)
                    logMe "ERROR: Unexpected HTTP ${httpCode} while retrieving inventory page ${page}."

                    if [[ -s "$responseFile" ]]; then
                        logMe "ERROR: Response begins with:"
                        head -c 1000 "$responseFile" >&2
                        printf '\n' >&2
                    else
                        logMe "ERROR: Response body was empty."
                    fi

                    return 1
                    ;;
            esac

            if ! jq -e 'type == "object" and (.results | type == "array")' "$responseFile" >/dev/null 2>&1; then

                logMe "ERROR: Inventory page ${page} returned an unexpected JSON structure."
                return 1
            fi

            if ! returnedCount=$(jq -er '.results | length' "$responseFile"); then
                logMe "ERROR: Unable to determine the inventory result count for page ${page}."
                return 1
            fi

            if ! totalCount=$(jq -er 'if (.totalCount | type) == "number" then
                    .totalCount
                else
                    0
                end' "$responseFile"); then

                logMe "ERROR: Unable to determine the inventory total count."
                return 1
            fi

            if ! jq -s '{
                    results:
                        (
                            (.[0].results // []) +
                            (.[1].results // [])
                        )
                }' "$aggregateFile" "$responseFile" > "$mergedFile"; then

                logMe "ERROR: Unable to merge inventory page ${page}."
                return 1
            fi

            if ! /bin/mv -f -- "$mergedFile" "$aggregateFile"; then
                logMe "ERROR: Unable to replace inventory aggregate data."
                return 1
            fi

            if ! aggregateCount=$(jq -er '.results | length' "$aggregateFile"); then
                logMe "ERROR: Unable to determine the accumulated inventory count."
                return 1
            fi

            logMe "Inventory page ${page} returned ${returnedCount} result(s); ${aggregateCount} accumulated."

            if (( returnedCount == 0 )); then
                break
            fi

            if (( totalCount > 0 && aggregateCount >= totalCount )); then
                break
            fi

            if (( returnedCount < pageSize )); then
                break
            fi

            (( page++ ))
        done

        if ! jq --argjson totalCount "$aggregateCount" '.totalCount = $totalCount' "$aggregateFile"; then

            logMe "ERROR: Unable to construct the completed inventory response."
            return 1
        fi

        logMe "Inventory pagination completed. Retrieved ${aggregateCount} total result(s)."
        return 0

    } always {
        /bin/rm -f -- \
            "$responseFile" \
            "$aggregateFile" \
            "$mergedFile"
    }
}

function JAMF_retrieve_data_blob ()
{
    # PURPOSE: Retrieve data from a Jamf Pro API endpoint
    # RETURN: XML or JSON response
    # PARAMETERS:
    #   $1 = API endpoint
    #   $2 = Optional jq filter

    local endpoint="${1:-}"
    local jqFilter="${2:-}"
    local responseFile
    local http_code
    local curlExitCode
    local retval
    local -a curlArgs

    [[ -z "$endpoint" ]] && {
        logMe "ERROR: JAMF_retrieve_data_blob called without an API endpoint."
        return 1
    }

    JAMF_ensure_valid_token || {
        logMe "ERROR: Failed to validate Jamf API token."
        return 1
    }
    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.retrieve-blob.XXXXX") || {
        logMe "ERROR: Failed to create data blob response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Failed to secure temporary API response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    {
        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --header "Accept: application/json"
            --header "Authorization: Bearer ${api_token}"
            )
  
        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/${endpoint}")
        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: curl failed while retrieving '${endpoint}' (curl exit code: ${curlExitCode})."
            return 1
        fi

        case "$http_code" in
            200|201)
                ;;
            401)
                logMe "ERROR: Unauthorized access to '${endpoint}' (HTTP 401)."
                return 1
                ;;
            403)
                logMe "ERROR: Insufficient privileges for '${endpoint}' (HTTP 403)."
                return 1
                ;;
            404)
                logMe "WARNING: Resource not found for '${endpoint}' (HTTP 404)."
                return 1
                ;;
            *)
                logMe "ERROR: Unexpected HTTP response (${http_code}) from '${endpoint}'."

                if [[ -s "$responseFile" ]]; then
                    logMe "ERROR: Response begins with:"
                    head -c 1000 "$responseFile" >&2
                    printf '\n' >&2
                else
                    logMe "Response body was empty."
                fi

                return 1
                ;;
        esac

        retval="$(<"$responseFile")"

        if [[ -n "$jqFilter" ]]; then
            logMe "Applying jq filter: ${jqFilter}"

            retval=$(printf '%s\n' "$retval" | jq "[.[] | select(${jqFilter})]") || {
                logMe "ERROR: jq filter failed for endpoint '${endpoint}'."
                return 1
            }

            [[ -z "$retval" ]] && retval="[]"
        fi

        printf "%s" "$retval"

    } always {
        [[ -n "$responseFile" && -f "$responseFile" ]] && /bin/rm -f "$responseFile"
    }
}

function JAMF_retrieve_static_group_id ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID of static group
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = Static group name

    local groupName="${1:-}"
    local responseFile
    local http_code
    local curlExitCode
    local groupID
    local resultCount=0
    local -a curlArgs

    [[ -z "$groupName" ]] && {
        logMe "ERROR: JAMF_retrieve_static_group_id called without a group name."
        return 1
    }

        if ! JAMF_ensure_valid_token; then
            logMe "ERROR: Failed to validate Jamf API token."
            return 1
        fi

        responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.group-id.XXXXX") || {
            logMe "ERROR: Failed to create static-group response file."
            return 1
        }
        if ! /bin/chmod 600 "$responseFile"; then
            logMe "ERROR: Failed to secure static-group response file."
            /bin/rm -f -- "$responseFile"
            return 1
        fi

    {
        logMe "Looking up static group ID for '${groupName}'."

        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --get
            --header "Accept: application/json"
            --header "Authorization: Bearer ${api_token}"
            --data-urlencode "page=0" 
            --data-urlencode "page-size=100" 
            --data-urlencode "sort=id:asc" 
            --data-urlencode "filter=name==\"${groupName}\""
            )

        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v3/computer-groups/static-groups")

        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: curl failed while searching for static group '${groupName}' (curl exit code: ${curlExitCode})."
            return 1
        fi

        case "$http_code" in
            200)
                ;;
            401)
                logMe "ERROR: Unauthorized while retrieving static group '${groupName}' (HTTP 401)."
                return 1
                ;;
            403)
                logMe "ERROR: Insufficient privileges while retrieving static group '${groupName}' (HTTP 403)."
                return 1
                ;;
            404)
                logMe "WARNING: Static group '${groupName}' was not found (HTTP 404)."
                return 2
                ;;
            *)
                logMe "ERROR: Unexpected HTTP response (${http_code}) while retrieving static group '${groupName}'."

                if [[ -s "$responseFile" ]]; then
                    logMe "Response body follows:"
                    while IFS= read -r line; do
                        logMe "    ${line}"
                    done < "$responseFile"
                else
                    logMe "Response body was empty."
                fi

                return 1
                ;;
        esac

        if ! resultCount=$(jq -er '.results | length' "$responseFile"); then
            logMe "ERROR: Unable to determine static group search result count."
            return 1
        fi

        case "$resultCount" in
            0)
                logMe "WARNING: No static group found matching '${groupName}'."
                return 2
                ;;

            1)
                if ! groupID=$(jq -er '.results[0].id' "$responseFile"); then
                    logMe "ERROR: Static group response did not contain a valid ID."
                    return 1
                fi
                ;;

            *)
                logMe "ERROR: Multiple static groups matched '${groupName}'."
                return 1
                ;;
        esac

        logMe "Found static group '${groupName}' with ID ${groupID}."

        printf "%s" "$groupID"

    } always {
        [[ -n "$responseFile" && -f "$responseFile" ]] && \
            /bin/rm -f "$responseFile"
    }
}

function JAMF_retrieve_static_group_members ()
{
    # PURPOSE: Retrieve the members of a static group
    # RETURN: Raw JSON response containing group membership
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static Group ID

    local groupID="${1:-}"
    local responseFile
    local http_code
    local curlExitCode
    local retval
    local -a curlArgs

    [[ -z "$groupID" ]] && {
        logMe "ERROR: JAMF_retrieve_static_group_members called without a group ID."
        return 1
    }

    JAMF_ensure_valid_token || {
        logMe "ERROR: Failed to validate Jamf API token."
        return 1
    }

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.retrieve_members.XXXXX") || {
        logMe "ERROR: Failed to create retrieve_members response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Failed to secure temporary API response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi
    {
        #logMe "Retrieving static group members for group ID ${groupID}."

        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --header "Accept: application/json"
            --header "Authorization: Bearer ${api_token}"
            )

        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/JSSResource/computergroups/id/${groupID}")

        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: curl failed while retrieving static group ${groupID} (curl exit code: ${curlExitCode})."
            return 1
        fi

        case "$http_code" in
            200)
                #logMe "Successfully retrieved static group ${groupID}."
                ;;
            401)
                logMe "ERROR: Unauthorized access while retrieving static group ${groupID} (HTTP 401)."
                return 1
                ;;
            403)
                logMe "ERROR: Insufficient privileges while retrieving static group ${groupID} (HTTP 403)."
                return 1
                ;;
            404)
                logMe "WARNING: Static group ${groupID} was not found (HTTP 404)."
                return 2
                ;;
            *)
                logMe "ERROR: Unexpected HTTP response (${http_code}) while retrieving static group ${groupID}."

                if [[ -s "$responseFile" ]]; then
                    logMe "Response body follows:"
                    while IFS= read -r line; do
                        logMe "    ${line}"
                    done < "$responseFile"
                else
                    logMe "Response body was empty."
                fi

                return 1
                ;;
        esac

        if ! jq -e 'type == "object" and (.computer_group | type == "object")' "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Unexpected response structure returned for static group ${groupID}."
            return 1
        fi

        retval="$(<"$responseFile")"

        [[ -z "$retval" ]] && {
            logMe "ERROR: Empty response returned for static group ${groupID}."
            return 1
        }

        printf "%s" "$retval"

    } always {
        [[ -n "$responseFile" && -f "$responseFile" ]] && /bin/rm -f "$responseFile"
    }
}

function JAMF_static_group_action_by_name ()
{
    # PURPOSE: Add or remove a computer from a static group by computer name
    # RETURN : Status message
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS:
    #   $1 = Static Group ID
    #   $2 = Computer name
    #   $3 = Action (Add|Remove)

    local groupID="${1:-}"
    local computerName="${2:-}"
    local action="${3:-}"

    local escapedComputerName=""

    local apiData
    local responseFile
    local responseBody
    local curlExitCode
    local http_code
    local retval
    local -a curlArgs
    local -i returnCode=0


    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Failed to validate Jamf API token."
        return 1
    fi

    if [[ "$groupID" != <-> ]]; then
        logMe "ERROR: Invalid static group ID: ${groupID:-<empty>}"
        return 1
    fi

    if [[ -z "$computerName" ]]; then
        logMe "ERROR: Computer name was not provided."
        return 1
    fi

    if ! escapedComputerName=$(xml_escape "$computerName"); then
        logMe "ERROR: Unable to XML-escape computer name '${computerName}'."
        return 1
    fi

    case "${action:l}" in
        add)
            apiData="<computer_group><computer_additions><computer><name>${escapedComputerName}</name></computer></computer_additions></computer_group>"
            ;;

        remove)
            apiData="<computer_group><computer_deletions><computer><name>${escapedComputerName}</name></computer></computer_deletions></computer_group>"
            ;;

        *)
            retval="Invalid static group action: ${action}"
            logMe "ERROR: ${retval}"
            printf '%s' "$retval"
            return 1
            ;;
    esac

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.group-action.XXXXX") || {
        logMe "ERROR: Failed to create static-group action response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Failed to secure static-group action response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    {


        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --header "Authorization: Bearer ${api_token}" 
            --header "Content-Type: application/xml" 
            --header "Accept: application/xml"
            --data "$apiData"
            --request PUT
            )

        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/JSSResource/computergroups/id/${groupID}")

        curlExitCode=$?

        responseBody=$(/bin/cat "$responseFile" 2>/dev/null)

        if (( curlExitCode != 0 )); then
            retval="CURL error ${curlExitCode} occurred while attempting to ${action:l} computer '${computerName}' in static group ${groupID}."
            logMe "$retval" 1>&2

            [[ -n "$responseBody" ]] && logMe "API response body: $responseBody" 1>&2

            printf "%s" "$retval"
            return 1
        fi

        case "$http_code" in
            200|201|204)
                retval="Successfully completed ${action:l} operation for '${computerName}' in static group ${groupID}."
                ;;

            409)
                retval="Jamf Pro reported a conflict while attempting to ${action:l} '${computerName}' in static group ${groupID}."
                returnCode=1

                [[ -n "$responseBody" ]] &&
                    logMe "HTTP 409 response body: ${responseBody}"
                ;;

            *)
                retval="HTTP ${http_code} returned while attempting to ${action:l} '${computerName}' in static group ${groupID}."
                returnCode=1

                [[ -n "$responseBody" ]] &&
                    logMe "Unexpected API response body: ${responseBody}"
                ;;
        esac

        logMe "$retval"
        printf '%s' "$retval"
        return "$returnCode"

    } always {
        [[ -f "$responseFile" ]] && /bin/rm -f "$responseFile"
    }
}

function JAMF_get_inventory_record ()
{
    # PURPOSE: Retrieve inventory data from Jamf Pro
    # RETURN: Inventory record in JSON format
    # PARAMETERS:
    #   $1 = Inventory section
    #   $2 = Optional filter condition

    local inventorySection="${1:-}"
    local filterCondition="${2:-}"

    local responseFile=""
    local responseBody=""
    local http_code=""
    local curlExitCode=0
    local -a curlArgs

    if [[ -z "$inventorySection" ]]; then
        logMe "ERROR: JAMF_get_inventory_record called without an inventory section."
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Failed to validate the Jamf Pro API token."
        return 1
    fi

    responseFile=$(
        mktemp "/var/tmp/${SCRIPT_NAME}.inventory.XXXXX"
    ) || {
        logMe "ERROR: Failed to create temporary inventory response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Failed to secure temporary inventory response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    {

        JAMF_build_curl_args "$responseFile"
        curlArgs=("${CURL_ARGS[@]}")
        curlArgs+=(
            --write-out "%{http_code}"
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/json"
            --get
            --data-urlencode "section=${inventorySection}"
        )

        [[ -n "$filterCondition" ]] && curlArgs+=(--data-urlencode "filter=${filterCondition}")

        http_code=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v4/computers-inventory")
        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: curl failed while retrieving inventory section '${inventorySection}'. curl exit code: ${curlExitCode}."

            if [[ -s "$responseFile" ]]; then
                logMe "ERROR: Response begins with:"
                head -c 1000 "$responseFile" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        case "$http_code" in
            200)
                ;;

            400)
                logMe "ERROR: Invalid inventory request. Section='${inventorySection}', filter='${filterCondition}'."
                return 1
                ;;

            401)
                logMe "ERROR: Unauthorized while retrieving inventory section '${inventorySection}' (HTTP 401)."
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privileges while retrieving inventory section '${inventorySection}' (HTTP 403)."
                return 1
                ;;

            404)
                logMe "ERROR: Inventory endpoint was not found while retrieving section '${inventorySection}' (HTTP 404)."
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected HTTP response ${http_code} while retrieving inventory section '${inventorySection}'."

                if [[ -s "$responseFile" ]]; then
                    logMe "ERROR: Response begins with:"
                    head -c 1000 "$responseFile" >&2
                    printf '\n' >&2
                fi

                return 1
                ;;
        esac

        if [[ ! -s "$responseFile" ]]; then
            logMe "ERROR: Jamf Pro returned an empty inventory response."
            return 1
        fi

        if ! jq -e 'type == "object"' "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Jamf Pro inventory response was not valid JSON."
            return 1
        fi

        responseBody="$(<"$responseFile")"
        printf '%s' "$responseBody"

    } always {
        [[ -n "$responseFile" && -f "$responseFile" ]] && /bin/rm -f -- "$responseFile"
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
    normalized_date=$(print -r -- "$normalized_date" | sed -E 's/\.([0-9]+)([+-][0-9]{4})$/\2/; s/\.([0-9]+)$//')
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

function xml_escape ()
{
    local value="${1:-}"

    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&apos;}"

    print -r -- "$value"
}

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function create_listitem_list ()
{
    # PARAMETERS:
    #   $1 = Dialog message
    #   $2 = Data type
    #   $3 = jq expression returning member names
    #   $4 = Source JSON
    #   $5 = List-item icon

    local dialogMessage="${1:-}"
    local dataType="${2:-json}"
    local jqExpression="${3:-}"
    local sourceJSON="${4:-}"
    local itemIcon="${5:-}"
    local memberNamesJSON="[]"
    local dialogReturnCode=0

    if [[ "${dataType:l}" != "json" ]]; then
        logMe "ERROR: Unsupported list-item data type: ${dataType}"
        return 1
    fi

    if ! jq -e . \
        <<< "$sourceJSON" >/dev/null 2>&1; then

        logMe "ERROR: List-item source data is not valid JSON."
        return 1
    fi

    if ! memberNamesJSON=$(jq -c "[
                ${jqExpression}
                | strings
                | select(length > 0)
            ]
            | unique
            | sort" <<< "$sourceJSON"); then
        logMe "ERROR: Unable to parse static-group member names."
        return 1
    fi

    if ! construct_dialog_header_settings "$dialogMessage" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct the membership-list dialog."
        return 1
    fi

    if ! jq --argjson memberNames "$memberNamesJSON" --arg selectedComputer "$hostName" --arg itemIcon "$itemIcon" \
        '.listitem = [
            $memberNames[] |
            {
                title: .,
                icon: $itemIcon
            }
            +
            (
                if . == $selectedComputer then
                    {
                        status: "success",
                        statustext: "Found"
                    }
                else
                    {}
                end
            )
        ]' "$JSON_DIALOG_BLOB" |
        update_dialog_json; then

        logMe "ERROR: Unable to construct the membership-list JSON."
        return 1
    fi

    validate_dialog_json || return 1

    "$SW_DIALOG" --json --jsonfile "$JSON_DIALOG_BLOB"

    dialogReturnCode=$?

    case "$dialogReturnCode" in
        0|2)
            return 0
            ;;

        *)
            logMe "ERROR: Membership dialog exited with code ${dialogReturnCode}."
            return 1
            ;;
    esac
}

function validate_dialog_json ()
{
    # PURPOSE:
    #   Validate the completed SwiftDialog JSON file.
    #
    # RETURN:
    #   0 = Valid JSON
    #   1 = Missing, empty, or invalid JSON

    if [[ -z "${JSON_DIALOG_BLOB:-}" ]]; then
        logMe "ERROR: JSON_DIALOG_BLOB is not defined."
        return 1
    fi

    if [[ ! -s "$JSON_DIALOG_BLOB" ]]; then
        logMe "ERROR: SwiftDialog JSON file is missing or empty."
        return 1
    fi

    if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog JSON file is invalid."

        while IFS= read -r line; do
            logMe "JSON: ${line}"
        done < "$JSON_DIALOG_BLOB"

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
    local button1Text="OK"
    local button2Text="Cancel"
    local titleFont="shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"

    case "${REQUEST_TYPE:l}-${ACTION_TAKEN:l}" in
        migrate-migrate)
            button1Text="Migrate"
            button2Text="Quit"
            ;;

        *)
            button1Text="OK"
            button2Text="Cancel"
            ;;
    esac

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
        --arg button1Text "$button1Text" \
        --arg button2Text "$button2Text" \
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

function create_dropdown_message_body ()
{
    # PURPOSE:
    #   Add one dropdown to the SwiftDialog selectitems array.
    #
    # PARAMETERS:
    #   $1 = Display title
    #   $2 = Values as a JSON array
    #   $3 = Default value, optional
    #   $4 = Internal field name, optional
    #   $5 = Required value: true, false, yes, or no
    #
    # EXAMPLE:
    #   create_dropdown_message_body "Old Computer Name" '["MAC-001","MAC-002"]' "MAC-001" "oldsystem" true

    local title="${1:-}"
    local valuesJSON="${2:-[]}"
    local defaultValue="${3:-}"
    local fieldName="${4:-}"
    local requiredValue="${5:-true}"
    local requiredJSON="false"

    if [[ -z "$title" ]]; then
        logMe "ERROR: Dropdown title was not provided."
        return 1
    fi

    if ! jq -e 'type == "array"' <<< "$valuesJSON" >/dev/null 2>&1; then

        logMe "ERROR: Values for dropdown '${title}' are not a valid JSON array."
        return 1
    fi

    case "${requiredValue:l}" in
        true|yes)
            requiredJSON="true"
            ;;

        false|no)
            requiredJSON="false"
            ;;

        *)
            logMe "ERROR: Invalid required value for dropdown '${title}': ${requiredValue}"
            return 1
            ;;
    esac

    if ! jq \
        --arg title "$title" \
        --argjson values "$valuesJSON" \
        --arg defaultValue "$defaultValue" \
        --arg fieldName "$fieldName" \
        --argjson required "$requiredJSON" \
        '
        .selectitems = (.selectitems // []) |
        .selectitems += [
            {
                title: $title,
                values: $values
            }
            +
            (
                if $defaultValue != "" then
                    {default: $defaultValue}
                else
                    {}
                end
            )
            +
            (
                if $fieldName != "" then
                    {
                        name: $fieldName,
                        required: $required
                    }
                else
                    {}
                end
            )
        ]
        ' "$JSON_DIALOG_BLOB" |
        update_dialog_json; then

        logMe "ERROR: Unable to add dropdown '${title}' to SwiftDialog JSON."
        return 1
    fi

    return 0
}

function create_radio_message_body ()
{
    # PURPOSE:
    #   Add one radio-button group to the SwiftDialog selectitems array.
    #
    # PARAMETERS:
    #   $1 = Display title
    #   $2 = Values as a JSON array
    #   $3 = Internal field name, optional
    #   $4 = Default value, optional
    #   $5 = Required value: true, false, yes, or no
    #
    # EXAMPLE:
    #   create_radio_message_body \
    #       "Group Action:" \
    #       '["View Users","Add Users","Remove Users"]' \
    #       "groupaction" \
    #       "View Users" \
    #       true

    local title="${1:-}"
    local valuesJSON="${2:-[]}"
    local fieldName="${3:-}"
    local defaultValue="${4:-}"
    local requiredValue="${5:-true}"
    local requiredJSON="false"

    if [[ -z "$title" ]]; then
        logMe "ERROR: Radio-button title was not provided."
        return 1
    fi

    if ! jq -e 'type == "array"' <<< "$valuesJSON" >/dev/null 2>&1; then
        logMe "ERROR: Values for radio group '${title}' are not a valid JSON array."
        return 1
    fi

    case "${requiredValue:l}" in
        true|yes)
            requiredJSON="true"
            ;;

        false|no)
            requiredJSON="false"
            ;;

        *)
            logMe "ERROR: Invalid required value for radio group '${title}': ${requiredValue}"
            return 1
            ;;
    esac

    if ! jq \
        --arg title "$title" \
        --argjson values "$valuesJSON" \
        --arg fieldName "$fieldName" \
        --arg defaultValue "$defaultValue" \
        --argjson required "$requiredJSON" \
        '
        .selectitems = (.selectitems // []) |
        .selectitems += [
            {
                title: $title,
                values: $values,
                style: "radio",
                required: $required
            }
            +
            (
                if $fieldName != "" then
                    {name: $fieldName}
                else
                    {}
                end
            )
            +
            (
                if $defaultValue != "" then
                    {default: $defaultValue}
                else
                    {}
                end
            )
        ]
        ' "$JSON_DIALOG_BLOB" |
        update_dialog_json; then

        logMe "ERROR: Unable to add radio group '${title}' to SwiftDialog JSON."
        return 1
    fi

    return 0
}

function create_textfield_message_body ()
{
    # PURPOSE:
    #   Add one text field to the SwiftDialog textfield array.
    #
    # PARAMETERS:
    #   $1 = Internal field name
    #   $2 = Display title
    #   $3 = Required value: true, false, yes, or no
    #   $4 = Default value, optional
    #
    # EXAMPLE:
    #   create_textfield_message_body \
    #       "HostName" \
    #       "Computer Hostname" \
    #       true \
    #       "$MAC_HOSTNAME"

    local fieldName="${1:-}"
    local title="${2:-}"
    local requiredValue="${3:-true}"
    local defaultValue="${4:-}"
    local requiredJSON="false"

    if [[ -z "$fieldName" ]]; then
        logMe "ERROR: Text-field name was not provided."
        return 1
    fi

    if [[ -z "$title" ]]; then
        logMe "ERROR: Text-field title was not provided."
        return 1
    fi

    case "${requiredValue:l}" in
        true|yes)
            requiredJSON="true"
            ;;

        false|no)
            requiredJSON="false"
            ;;

        *)
            logMe "ERROR: Invalid required value for text field '${fieldName}': ${requiredValue}"
            return 1
            ;;
    esac

    if ! jq \
        --arg fieldName "$fieldName" \
        --arg title "$title" \
        --arg defaultValue "$defaultValue" \
        --argjson required "$requiredJSON" \
        '
        .textfield = (.textfield // []) |
        .textfield += [
            {
                name: $fieldName,
                title: $title,
                required: $required
            }
            +
            (
                if $defaultValue != "" then
                    {value: $defaultValue}
                else
                    {}
                end
            )
        ]
        ' "$JSON_DIALOG_BLOB" |
        update_dialog_json; then

        logMe "ERROR: Unable to add text field '${fieldName}' to SwiftDialog JSON."
        return 1
    fi

    return 0
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

function set_dialog_button1_disabled ()
{
    # PURPOSE:
    #   Set the SwiftDialog button1disabled property.
    #
    # PARAMETERS:
    #   $1 = true, false, yes, or no

    local disabledValue="${1:-true}"
    local disabledJSON="false"

    case "${disabledValue:l}" in
        true|yes)
            disabledJSON="true"
            ;;

        false|no)
            disabledJSON="false"
            ;;

        *)
            logMe "ERROR: Invalid button1disabled value: ${disabledValue}"
            return 1
            ;;
    esac

    if ! jq --argjson disabled "$disabledJSON" '.button1disabled = $disabled' "$JSON_DIALOG_BLOB" | update_dialog_json; then

        logMe "ERROR: Unable to update button1disabled."
        return 1
    fi

    return 0
}

function construct_dropdown_list_items ()
{
    # PURPOSE:
    #   Extract dropdown values from a JSON response.
    #
    # PARAMETERS:
    #   $1 = Source JSON
    #   $2 = jq expression that returns individual values
    #
    # RETURN:
    #   Compact JSON array written to stdout
    #
    # EXAMPLE:
    #   construct_dropdown_list_items \
    #       "$groupList" \
    #       '.results[]?.name'

    local sourceJSON="${1:-}"
    local jqExpression="${2:-}"

    if [[ -z "$sourceJSON" ]]; then
        logMe "ERROR: Dropdown source JSON was not provided."
        return 1
    fi

    if [[ -z "$jqExpression" ]]; then
        logMe "ERROR: Dropdown jq expression was not provided."
        return 1
    fi

    if ! jq -e . <<< "$sourceJSON" >/dev/null 2>&1; then
        logMe "ERROR: Dropdown source is not valid JSON."
        return 1
    fi

    if ! jq -c "[
            ${jqExpression}
            | strings
            | select(length > 0)
        ]
        | unique
        | sort" <<< "$sourceJSON"; then

        logMe "ERROR: Unable to construct dropdown values."
        return 1
    fi

    return 0
}
####################################################################################################
#
# App Specific Functions
#
####################################################################################################


function validate_script_parameters ()
{
    case "${REQUEST_TYPE:l}" in
        single|migrate)
            ;;
        *)
            logMe "ERROR: Invalid Request Type: ${REQUEST_TYPE:-<empty>}"
            show_usage
            return 1
            ;;
    esac

    case "${SHOW_WINDOW:l}" in
        yes|no)
            ;;
        *)
            logMe "ERROR: Invalid ShowWindow value: ${SHOW_WINDOW:-<empty>}"
            show_usage
            return 1
            ;;
    esac

    case "${ACTION_TAKEN:l}" in
        view|migrate)
            ;;
        *)
            logMe "ERROR: Invalid ActionTaken value: ${ACTION_TAKEN:-<empty>}"
            show_usage
            return 1
            ;;
    esac

    case "${ACCESS_TYPE:l}" in
        ""|normal|admin)
            ;;
        *)
            logMe "ERROR: Invalid AccessType value: ${ACCESS_TYPE:-<empty>}"
            show_usage
            return 1
            ;;
    esac

    if [[ "${REQUEST_TYPE:l}" == "single" ]]; then

        case "${JAMF_GROUP_ACTION:l}" in
            add|remove|view|removeall|"remove all"|"add users"|"remove users"|"view users")

                ;;
            *)
                logMe "ERROR: Invalid GroupAction value: ${JAMF_GROUP_ACTION:-<empty>}"
                show_usage
                return 1
                ;;
        esac

        if [[ "${SHOW_WINDOW:l}" == "no" ]] && [[ -z "$JAMF_GROUP_NAME" ]]; then
            logMe "ERROR: Group name must be supplied when running non-interactively."
            show_usage
            return 1
        fi
    fi

    return 0
}

function update_display_list ()
{
	# Function to handle various aspects of the Swift Dialog behaviour
    #
    # RETURN: None
	# VARIABLES expected: JSON_DIALOG_BLOB & Window variables should be set
	# PARMS List
	#
	# #1 - Action to be done ("Create, Destroy, "Update", "change")
	# #2 - Progress bar % (pass as integer)
	# #3 - Application Title (must match the name in the dialog list entry)
	# #4 - Progress Text (text to be display on bottom on window)
	# #5 - Progress indicator (wait, success, fail, pending)
	# #6 - List Item Text (text to be displayed while updating list entry)

	## i.e. update_display_list "Update" "8" "Google Chrome" "Calculating Chrome" "pending" "Working..."
	## i.e.	update_display_list "Update" "8" "Google Chrome" "" "success" "Done"

	case "$1:l" in

        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            printf '%s\n' "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "listcreate" )
            printf '%s\n' "listitem: show" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "create")
            "$SW_DIALOG" --progress --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" --height 800 --width 920 &

            dialogPID=$!

            if [[ -z "$dialogPID" ]]; then
                logMe "ERROR: Unable to obtain the SwiftDialog process ID."
                return 1
            fi

            /bin/sleep 0.2

            if ! /bin/kill -0 "$dialogPID" 2>/dev/null; then
                logMe "ERROR: SwiftDialog failed to remain running."
                return 1
            fi

            return 0
            ;;
        "buttonenable" )

                # Enable button 1
                printf '%s\n' "button1: enable" >> "${DIALOG_COMMAND_FILE}"
                ;;

        "destroy" )
        
            #
            # Kill the progress bar and clean up
            #
            printf '%s\n' "quit:" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonchange" )

            # change text of button 1
            printf '%s\n' "button1text: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar
            printf '%s\n' "listitem: title: $3, status: $5, statustext: $6" >> "${DIALOG_COMMAND_FILE}"
            printf '%s\n' "progress: $2" >> "${DIALOG_COMMAND_FILE}"

            /bin/sleep .5
            ;;

        "progress" )

            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            printf '%s\n' "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"
            printf '%s\n' "progresstext: ${5}" >> "${DIALOG_COMMAND_FILE}"
            ;;
        *)
            logMe "ERROR: Unsupported dialog update operation: ${1:-<empty>}"
            return 1
            ;;

	esac
    return 0
}

function retrieve_user_systems ()
{
    # PURPOSE:
    #   Retrieve computers available to the current user.
    #
    # RETURN:
    #   JSON array containing computer names.

    local userName=""
    local userSystems=""
    local inventoryJSON=""
    local userSystemsJSON="[]"

    if [[ "${ACCESS_TYPE:l}" == "admin" ]]; then
        if ! inventoryJSON=$(JAMF_get_paginated_inventory_records "GENERAL" "" 100); then
            logMe "ERROR: Unable to retrieve the computer inventory."
            return 1
        fi

        if ! userSystems=$(jq -er '.results[]?.general.name| strings| select(length > 0)' <<< "$inventoryJSON"); then
            logMe "ERROR: Unable to parse computer names from inventory."
            return 1
        fi
    else
        if ! inventoryJSON=$(JAMF_get_paginated_inventory_records "USER_AND_LOCATION" "general.name=='${MAC_HOSTNAME}'" 100); then
            logMe "ERROR: Unable to retrieve the local computer assignment."
            return 1
        fi

        if ! userName=$(jq -er '
                [
                    .results[]?.userAndLocation.username
                    | strings
                    | select(length > 0)
                ]
                | unique
                | if length == 1 then
                    .[0]
                  else
                    error("Expected exactly one assigned username")
                  end' <<< "$inventoryJSON"); then
            logMe "ERROR: Unable to determine the assigned username for '${MAC_HOSTNAME}'."
            return 1
        fi

        if ! inventoryJSON=$(JAMF_get_paginated_inventory_records "GENERAL" "userAndLocation.username=='${userName}'" 100); then
        #if ! inventoryJSON=$(JAMF_get_inventory_record "GENERAL" "userAndLocation.username=='${userName}'"); then
            logMe "ERROR: Unable to retrieve systems assigned to '${userName}'."
            return 1
        fi

        if ! userSystems=$(jq -er '.results[]?.general.name| strings| select(length > 0)' <<< "$inventoryJSON"); then
            logMe "ERROR: Unable to parse systems assigned to '${userName}'."
            return 1
        fi

        logMe "INFO: Retrieved systems assigned to '${userName}'."
    fi

    if [[ -z "$userSystems" ]]; then
        logMe "ERROR: No systems were returned."
        return 1
    fi

    if ! userSystemsJSON=$(jq -Rsc '
            split("\n")
            | map(select(length > 0))
            | unique
            | sort' <<< "$userSystems"); then
        logMe "ERROR: Unable to construct the computer-name JSON array."
        return 1
    fi

    if ! jq -e 'type == "array" and length > 0' <<< "$userSystemsJSON" >/dev/null 2>&1; then

        logMe "ERROR: Computer-name JSON array is invalid or empty."
        return 1
    fi

    print -r -- "$userSystemsJSON"
    return 0
}

function display_msg_single ()
{
    # PURPOSE:
    #   Display the single-computer action dialog.
    #
    # ACTIONS:
    #   View Users
    #   Add Users
    #   Remove Users
    #   Remove All
    #
    # RETURN:
    #   Sets the following global variables:
    #       action
    #       hostName
    #       selectedGroup
    #
    #   For Remove All, selectedGroup is intentionally cleared because
    #   the workflow must search every static group.
    local groupList=""
    local groupValuesJSON="[]"
    local actionValuesJSON='["View Users","Add Users","Remove Users","Remove All"]'
    local message=""
    local dialogResults=""
    local selectedAction=""
    local enteredHostName=""
    local dialogSelectedGroup=""
    local returnCode=0

    if ! groupList=$(JAMF_retrieve_paginated_results \
        "api/v3/computer-groups/static-groups" \
        100 \
        "id:asc"); then

        logMe "ERROR: Unable to retrieve all static computer groups."
        return 1
    fi

    if ! jq -e \
        'type == "object" and (.results | type == "array")' \
        <<< "$groupList" >/dev/null 2>&1; then

        logMe "ERROR: Static-group response does not contain a valid results array."
        return 1
    fi

    if [[ -z "$JAMF_GROUP_NAME" ]]; then
        message="Select a static group, enter the computer hostname, and choose the action to perform. The selected group is ignored when Remove All is chosen."

        if ! groupValuesJSON=$(construct_dropdown_list_items \
            "$groupList" \
            '.results[]?.name'); then

            logMe "ERROR: Unable to construct static-group choices."
            return 1
        fi

        if ! jq -e \
            'type == "array" and length > 0' \
            <<< "$groupValuesJSON" >/dev/null 2>&1; then

            logMe "ERROR: No static-group choices were returned."
            return 1
        fi
    else
        message="Choose the action to perform for the computer entered below.<br><br>Selected Group: ${JAMF_GROUP_NAME}<br><br>The selected group is ignored when Remove All is chosen."
    fi

    if ! construct_dialog_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct the single-computer dialog."
        return 1
    fi

    if [[ -z "$JAMF_GROUP_NAME" ]]; then
        if ! create_dropdown_message_body \
            "Select Group:" \
            "$groupValuesJSON" \
            "" \
            "selectedgroup" \
            true; then

            logMe "ERROR: Unable to add the static-group selector."
            return 1
        fi
    fi

    if ! create_radio_message_body \
        "Group Action:" \
        "$actionValuesJSON" \
        "groupaction" \
        "View Users" \
        true; then

        logMe "ERROR: Unable to add the group-action selector."
        return 1
    fi

    if ! create_textfield_message_body \
        "HostName" \
        "Computer Hostname" \
        true \
        "$MAC_HOSTNAME"; then

        logMe "ERROR: Unable to add the computer-hostname field."
        return 1
    fi

    validate_dialog_json || return 1

    dialogResults=$(
        "$SW_DIALOG" \
            --json \
            --jsonfile "$JSON_DIALOG_BLOB" \
            --vieworder "dropdown, radiobutton, listitem, textfield" \
            2>/dev/null
    )
    returnCode=$?

    case "$returnCode" in
        0)
            ;;

        2)
            logMe "INFO: User canceled the single-computer dialog."
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited with code ${returnCode}."
            return 1
            ;;
    esac

    if ! jq -e \
        'type == "object"' \
        <<< "$dialogResults" >/dev/null 2>&1; then

        logMe "ERROR: SwiftDialog returned invalid JSON."
        return 1
    fi

    if ! selectedAction=$(jq -er \
        '.groupaction.selectedValue |
         strings |
         select(length > 0)' \
        <<< "$dialogResults"); then

        logMe "ERROR: Unable to determine the selected group action."
        return 1
    fi

    case "${selectedAction:l}" in
        "view users"|"add users"|"remove users"|"remove all")
            action="$selectedAction"
            ;;

        *)
            logMe "ERROR: Unsupported group action returned by SwiftDialog: ${selectedAction:-<empty>}"
            return 1
            ;;
    esac

    if ! enteredHostName=$(jq -er \
        '.HostName |
         strings |
         gsub("^\\s+|\\s+$"; "") |
         select(length > 0)' \
        <<< "$dialogResults"); then

        logMe "ERROR: Unable to determine the entered computer hostname."
        return 1
    fi

    hostName="$enteredHostName"

    case "${action:l}" in
        "remove all")
            selectedGroup=""
            logMe "Selected action: Remove All"
            logMe "Selected computer: ${hostName}"
            logMe "INFO: Static-group selection will be ignored for Remove All."
            ;;

        "view users"|"add users"|"remove users")
            if [[ -n "$JAMF_GROUP_NAME" ]]; then
                selectedGroup="$JAMF_GROUP_NAME"
            else
                if ! dialogSelectedGroup=$(jq -er \
                    '.selectedgroup.selectedValue |
                     strings |
                     select(length > 0)' \
                    <<< "$dialogResults"); then

                    logMe "ERROR: Unable to determine the selected static group."
                    return 1
                fi

                selectedGroup="$dialogSelectedGroup"
            fi

            logMe "Selected action: ${action}"
            logMe "Selected static group: ${selectedGroup}"
            logMe "Selected computer: ${hostName}"
            ;;

        *)
            logMe "ERROR: Unsupported group action: ${action:-<empty>}"
            return 1
            ;;
    esac

    return 0
}

function show_system_choices ()
{
    # PURPOSE:
    #   Display the computer-selection dialog for viewing, migration,
    #   or removal from all static groups.
    #
    # PARAMETERS:
    #   $1 = JSON array of permitted computer names
    #
    # RETURN:
    #   0 = Selection completed
    #   1 = Validation or dialog failure
    local userSystemsJSON="${1:-[]}"
    local message=""
    local dialogResults=""
    local buttonPress=0

    if ! jq -e 'type == "array" and length > 0' <<< "$userSystemsJSON" >/dev/null 2>&1; then

        logMe "ERROR: Computer choices are not a populated JSON array."
        return 1
    fi

    case "${ACTION_TAKEN:l}" in
        view)
            message="${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}. Select the computer whose static group membership you want to view."
            ;;

        migrate)
            message="${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}. Select the source and destination computers, and then click Migrate."
            ;;

        removeall)
            message="${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}. Select the computer that should be removed from every static group in which it is found."
            ;;

        *)
            logMe "ERROR: Unsupported multi-group action: ${ACTION_TAKEN:-<empty>}"
            return 1
            ;;
    esac

    if ! construct_dialog_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to create the system-selection dialog."
        return 1
    fi

    case "${ACTION_TAKEN:l}" in
        view)
            if ! create_dropdown_message_body "Computer Name" "$userSystemsJSON" "$MAC_HOSTNAME" "oldsystem" true; then
                return 1
            fi
            ;;

        migrate)
            if ! create_dropdown_message_body "Source Computer Name" "$userSystemsJSON" "$MAC_HOSTNAME" "oldsystem" true; then
                return 1
            fi

            if ! create_dropdown_message_body "Destination Computer Name" "$userSystemsJSON" "" "newsystem" true; then
                return 1    
            fi
            ;;

        removeall)
            if ! create_dropdown_message_body "Computer to Remove" "$userSystemsJSON" "$MAC_HOSTNAME" "oldsystem" true; then
                return 1
            fi
            ;;
    esac

    validate_dialog_json || return 1

    dialogResults=$("$SW_DIALOG" --json --jsonfile "$JSON_DIALOG_BLOB" 2>/dev/null)
    buttonPress=$?

    case "$buttonPress" in
        0)
            ;;

        2)
            logMe "INFO: User canceled the system-selection dialog."
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited with code ${buttonPress}."
            return 1
            ;;
    esac

    if ! oldSystem=$(jq -er '.oldsystem.selectedValue | strings | select(length > 0)' <<< "$dialogResults"); then
        logMe "ERROR: Unable to determine the selected computer."
        return 1
    fi

    if ! jq -e --arg selected "$oldSystem" 'index($selected) != null' <<< "$userSystemsJSON" >/dev/null 2>&1; then
        logMe "ERROR: Selected computer is not in the permitted computer list."
        return 1
    fi

    if [[ "${ACTION_TAKEN:l}" == "migrate" ]]; then
        if ! newSystem=$(jq -er '.newsystem.selectedValue | strings | select(length > 0)' <<< "$dialogResults"); then
            logMe "ERROR: Unable to determine the selected destination computer."
            return 1
        fi

        if ! jq -e --arg selected "$newSystem" 'index($selected) != null' <<< "$userSystemsJSON" >/dev/null 2>&1; then
            logMe "ERROR: Selected destination computer is not in the permitted computer list."
            return 1
        fi

        if [[ "$oldSystem" == "$newSystem" ]]; then
            logMe "ERROR: The source and destination computers cannot be the same."
            return 1
        fi
    else
        newSystem=""
    fi

    logMe "Selected computer: ${oldSystem}"

    if [[ -n "$newSystem" ]]; then
        logMe "Selected destination computer: ${newSystem}"
    fi

    return 0
}

function display_msg_migrate ()
{
    # PURPOSE:
    #   Discover and display the static-group memberships for the selected
    #   computer. Depending on ACTION_TAKEN, the user may view the groups,
    #   or migrate the memberships.
    #
    # RETURN:
    #   0 = Operation completed successfully or no changes were required
    #   1 = Discovery, dialog, validation, or removal failure
    #   2 = User canceled the operation
    local message=""
    local groupID=""
    local groupName=""
    local groupMembers=""
    local buttonPress=0
    local destructiveAction="false"
    local -i i=0
    local -i totalGroups=${#staticGroupIDs[@]}
    local -i progressPercent=0
    local -i membershipLookupFailures=0
    local -i operationFailures=0
    local -i operationSuccesses=0

    membersofGroup=()
    groupNumbers=()

    if (( totalGroups == 0 )); then
        logMe "ERROR: No static groups are available for membership discovery."
        return 1
    fi

    case "${ACTION_TAKEN:l}" in
        view)
            message="${oldSystem} is a member of the following static group(s)."
            ;;

        migrate)
            destructiveAction="true"
            message="${oldSystem} is a member of the following static group(s). If this looks correct, click Migrate to add ${newSystem} to these groups. Otherwise, click Quit."
            ;;

        *)
            logMe "ERROR: Unsupported membership action: ${ACTION_TAKEN:-<empty>}"
            return 1
            ;;
    esac

    if ! construct_dialog_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct the membership dialog."
        return 1
    fi

    if ! create_listitem_message_body "-- Static Group Membership --" "" "" ""; then
        logMe "ERROR: Unable to create the membership-list header."
        return 1
    fi

    if ! set_dialog_button1_disabled true; then
        logMe "ERROR: Unable to disable the primary dialog button."
        return 1
    fi

    validate_dialog_json || return 1

    if ! update_display_list "Create"; then
        logMe "ERROR: Unable to launch the membership dialog."
        return 1
    fi

    if [[ -z "${dialogPID:-}" ]] ||
       ! /bin/kill -0 "$dialogPID" 2>/dev/null; then

        logMe "ERROR: SwiftDialog did not remain running."
        return 1
    fi

    for (( i = 1; i <= totalGroups; i++ )); do
        progressPercent=$(( i * 100 / totalGroups ))
        groupID="${staticGroupIDs[i]}"
        groupName="${staticGroupName[i]}"

        if ! update_display_list "progress" "" "" "" "Checking static group ${i} of ${totalGroups}" "$progressPercent"; then

            logMe "ERROR: Unable to update membership-discovery progress."
            return 1
        fi

        if ! groupMembers=$(JAMF_retrieve_static_group_members "$groupID"); then
            (( membershipLookupFailures++ ))
            logMe "ERROR: Unable to retrieve members for static group ID ${groupID}."
            continue
        fi

        if jq -e --arg computerName "$oldSystem" '.computer_group.computers[]? | select(.name == $computerName)' <<< "$groupMembers" >/dev/null 2>&1; then
            logMe "${oldSystem} found in static group '${groupName}'."
            if ! update_display_list "add" "$groupName" "success" "Member"; then
                logMe "ERROR: Unable to add '${groupName}' to the membership dialog."
                return 1
            fi

            groupNumbers+=("$groupID")
            membersofGroup+=("$groupName")
        fi
    done

    if (( membershipLookupFailures > 0 )) &&
       [[ "$destructiveAction" == "true" ]]; then

        if ! update_display_list "progress" "" "" "" "Unable to verify ${membershipLookupFailures} static group(s). No changes will be made." 100; then
            return 1
        fi

        if ! update_display_list "buttonchange" "Close"; then
            return 1
        fi

        if ! update_display_list "buttonenable"; then
            return 1
        fi

        logMe "ERROR: The operation was blocked because ${membershipLookupFailures} static group membership lookup(s) failed."

    elif (( ${#groupNumbers[@]} == 0 )); then

        if ! update_display_list "progress" "" "" "" "${oldSystem} is not a member of any static groups." 100; then
            return 1
        fi

        if ! update_display_list "buttonchange" "Close"; then
            return 1
        fi

        if ! update_display_list "buttonenable"; then
            return 1
        fi

    else
        if ! update_display_list "progress" "" "" "" "${oldSystem} is a member of ${#groupNumbers[@]} static group(s)." 100; then
            return 1
        fi

        if ! update_display_list "buttonenable"; then
            return 1
        fi
    fi

    wait "$dialogPID"
    buttonPress=$?

    case "$buttonPress" in
        0)
            ;;

        2)
            logMe "INFO: User canceled the membership operation."
            return 2
            ;;

        *)
            logMe "ERROR: Membership dialog exited with code ${buttonPress}."
            return 1
            ;;
    esac

    if (( membershipLookupFailures > 0 )) &&
       [[ "$destructiveAction" == "true" ]]; then

        logMe "ERROR: No changes were made because membership verification was incomplete."
        return 1
    fi

    if (( ${#groupNumbers[@]} == 0 )); then
        logMe "INFO: ${oldSystem} has no static-group memberships to process."
        return 0
    fi

    case "${ACTION_TAKEN:l}" in
        view)
            return 0
            ;;

        migrate)
            return 0
            ;;

        *)
            logMe "ERROR: Unsupported membership operation: ${ACTION_TAKEN:-<empty>}"
            return 1
            ;;
    esac
}

function static_group_remove_all ()
{
    # PURPOSE:
    #   Remove one computer from every static computer group in which
    #   it is currently a member.
    #
    # PARAMETERS:
    #   $1 = Computer hostname
    #
    # RETURN:
    #   0 = Completed successfully or no memberships were found
    #   1 = Discovery, confirmation, or removal failure
    #   2 = User canceled the operation
    local computerName="${1:-}"
    local groupBlob=""
    local groupMembers=""
    local groupID=""
    local groupName=""
    local retval=""
    local confirmationMessage=""
    local dialogResults=""
    local dialogReturnCode=0
    local -i membershipLookupFailures=0
    local -i operationFailures=0
    local -i operationSuccesses=0
    local -a matchingGroupIDs=()
    local -a matchingGroupNames=()
    local -i i=0

    if [[ -z "$computerName" ]]; then
        logMe "ERROR: static_group_remove_all called without a computer name."
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid token before retrieving static groups."
        return 1
    fi

    logMe "Retrieving all static computer groups for Remove All."

    if ! groupBlob=$(JAMF_retrieve_paginated_results \
        "api/v3/computer-groups/static-groups" \
        100 \
        "id:asc"); then

        logMe "ERROR: Unable to retrieve all static computer groups."
        return 1
    fi

    if ! jq -e \
        'type == "object" and (.results | type == "array")' \
        <<< "$groupBlob" >/dev/null 2>&1; then

        logMe "ERROR: Static-group response does not contain a valid results array."
        return 1
    fi

    while IFS=$'\t' read -r groupID groupName; do
        if [[ "$groupID" != <-> || -z "$groupName" ]]; then
            logMe "WARNING: Ignoring malformed static-group record."
            continue
        fi

        logMe "Checking static group '${groupName}' with ID ${groupID}."

        if ! groupMembers=$(JAMF_retrieve_static_group_members "$groupID"); then
            (( membershipLookupFailures++ ))
            logMe "ERROR: Unable to retrieve members for static group '${groupName}' with ID ${groupID}."
            continue
        fi

        if jq -e --arg computerName "$computerName" '.computer_group.computers[]? | select(.name == $computerName)' <<< "$groupMembers" >/dev/null 2>&1; then
            logMe "Computer '${computerName}' was found in static group '${groupName}'."

            matchingGroupIDs+=("$groupID")
            matchingGroupNames+=("$groupName")
        fi

    done < <(
        jq -r '
            .results[]?
            | select(
                (.id != null)
                and (.name | type == "string")
                and (.name | length > 0)
            )
            | [.id, .name]
            | @tsv
        ' <<< "$groupBlob"
    )

    if (( membershipLookupFailures > 0 )); then
        logMe "ERROR: Remove All was stopped because ${membershipLookupFailures} static group membership lookup(s) failed."

        progressResults+=(
            "Remove All was stopped. Unable to verify ${membershipLookupFailures} static group(s), so no changes were made."
        )

        return 1
    fi

    if (( ${#matchingGroupIDs[@]} == 0 )); then
        logMe "INFO: Computer '${computerName}' is not a member of any static computer groups."

        progressResults+=(
            "Computer '${computerName}' is not a member of any static computer groups."
        )

        return 0
    fi

    if (( ${#matchingGroupIDs[@]} != ${#matchingGroupNames[@]} )); then
        logMe "ERROR: Matching static-group ID and name counts do not match."
        return 1
    fi

    logMe "Computer '${computerName}' was found in ${#matchingGroupIDs[@]} static group(s)."

    confirmationMessage="The computer ${computerName} was found in ${#matchingGroupIDs[@]} static group(s). Review the groups below and click Remove All to continue. Click Quit to cancel. No changes have been made yet."

    if ! construct_dialog_header_settings "$confirmationMessage" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct the Remove All confirmation dialog."
        return 1
    fi

    if ! jq '.button1text = "Remove All"| .button2text = "Quit" | .listitem = []' "$JSON_DIALOG_BLOB" | update_dialog_json; then
        logMe "ERROR: Unable to configure the Remove All confirmation dialog."
        return 1
    fi

    for groupName in "${matchingGroupNames[@]}"; do
        if ! create_listitem_message_body "$groupName" "SF=desktopcomputer.and.macbook" "Member" "success"; then
            logMe "ERROR: Unable to add '${groupName}' to the confirmation dialog."
            return 1
        fi
    done

    validate_dialog_json || return 1

    dialogResults=$("$SW_DIALOG" --json --jsonfile "$JSON_DIALOG_BLOB" --vieworder "listitem" 2>/dev/null)
    dialogReturnCode=$?

    case "$dialogReturnCode" in
        0)
            logMe "User confirmed Remove All for '${computerName}'."
            ;;

        2)
            logMe "INFO: User canceled Remove All for '${computerName}'."
            return 2
            ;;

        *)
            logMe "ERROR: Remove All confirmation dialog exited with code ${dialogReturnCode}."
            return 1
            ;;
    esac

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid token before removing static-group memberships."
        return 1
    fi

    for (( i = 1; i <= ${#matchingGroupIDs[@]}; i++ )); do
        groupID="${matchingGroupIDs[i]}"
        groupName="${matchingGroupNames[i]}"

        logMe "Removing '${computerName}' from static group '${groupName}' with ID ${groupID}."

        if retval=$(JAMF_static_group_action_by_name "$groupID" "$computerName" "remove"); then
            (( operationSuccesses++ ))
            progressResults+=("Successfully removed '${computerName}' from '${groupName}'.")
        else
            (( operationFailures++ ))
            progressResults+=("Failed to remove '${computerName}' from '${groupName}': ${retval}")
        fi
    done

    logMe "Remove All completed with ${operationSuccesses} successful removal(s) and ${operationFailures} failure(s)."

    if (( operationFailures > 0 )); then
        logMe "ERROR: ${operationFailures} static-group removal operation(s) failed."
        return 1
    fi

    return 0
}

function static_group_single ()
{
    # PURPOSE:
    #   Perform an action against one static group or remove one computer
    #   from every static group in which it is a member.
    local retval=""
    local groupID=""
    local memberList=""
    local hostnameFound=""
    local removeAllReturnCode=0

    if [[ "${SHOW_WINDOW:l}" == "yes" ]]; then
        if ! display_msg_single; then
            logMe "ERROR: Unable to complete the single-computer selection dialog."
            return 1
        fi
    else
        selectedGroup="$JAMF_GROUP_NAME"
        action="$JAMF_GROUP_ACTION"
        hostName="$MAC_HOSTNAME"
    fi

    logMe "Selected action: ${action}"
    logMe "Selected computer: ${hostName}"

    case "${action:l}" in
        "remove all"|removeall)
            static_group_remove_all "$hostName"
            removeAllReturnCode=$?

            case "$removeAllReturnCode" in
                0)
                    return 0
                    ;;

                2)
                    logMe "INFO: Remove All was canceled by the user."
                    return 0
                    ;;

                *)
                    logMe "ERROR: Unable to remove '${hostName}' from all static groups."
                    return 1
                    ;;
            esac
            ;;

        add|"add users"|remove|"remove users"|view|"view users")
            ;;

        *)
            logMe "ERROR: Unsupported static group action: ${action:-<empty>}"
            return 1
            ;;
    esac

    logMe "Selected static group: ${selectedGroup}"

    if [[ -z "$selectedGroup" ]]; then
        logMe "ERROR: A static group was not selected."
        return 1
    fi

    if ! groupID=$(JAMF_retrieve_static_group_id "$selectedGroup"); then
        logMe "ERROR: Unable to resolve static group '${selectedGroup}'."
        return 1
    fi

    if [[ "$groupID" != <-> ]]; then
        logMe "ERROR: Invalid static group ID returned for '${selectedGroup}': ${groupID}"
        return 1
    fi

    case "${action:l}" in
        add|"add users")
            logMe "Adding '${hostName}' to '${selectedGroup}'."

            if ! retval=$(JAMF_static_group_action_by_name "$groupID" "$hostName" "add"); then
                logMe "ERROR: Unable to add '${hostName}' to '${selectedGroup}'."
                progressResults+=("${retval} ${selectedGroup}")
                return 1
            fi

            progressResults+=("${retval} ${selectedGroup}")
            ;;

        remove|"remove users")
            logMe "Removing '${hostName}' from '${selectedGroup}'."

            if ! retval=$(JAMF_static_group_action_by_name "$groupID" "$hostName" "remove"); then
                logMe "ERROR: Unable to remove '${hostName}' from '${selectedGroup}'."
                progressResults+=("${retval} ${selectedGroup}")
                return 1
            fi

            progressResults+=("${retval} ${selectedGroup}")
            ;;

        view|"view users")
            if ! memberList=$(JAMF_retrieve_static_group_members "$groupID"); then
                logMe "ERROR: Unable to retrieve members of '${selectedGroup}'."
                return 1
            fi

            if jq -e --arg computerName "$hostName" '.computer_group.computers[]? |select(.name == $computerName)' <<< "$memberList" >/dev/null 2>&1; then
                hostnameFound="is"
            else
                hostnameFound="is not"
            fi

            if ! create_listitem_list "The following are the members of <br>${selectedGroup}.<br><br>The computer ${hostnameFound} in this group." "json" \
                '.computer_group.computers[]?.name' "$memberList" "SF=desktopcomputer.and.macbook"; then
                logMe "ERROR: Unable to display static group members."
                return 1
            fi
            ;;

        *)
            logMe "ERROR: Unsupported static group action: ${action:-<empty>}"
            return 1
            ;;
    esac

    return 0
}

function static_group_multiple ()
{
    local userSystemsJSON=""
    local groupBlob=""
    local retval=""
    local groupID=""
    local groupName=""
    local displayReturnCode=0
    local -i i=0
    local -i operationFailures=0
    local -i operationSuccesses=0

    if ! userSystemsJSON=$(retrieve_user_systems); then
        logMe "ERROR: Unable to retrieve available computer choices."
        return 1
    fi

    if ! show_system_choices "$userSystemsJSON"; then
        logMe "ERROR: Unable to display the computer-selection dialog."
        return 1
    fi

    if ! groupBlob=$(JAMF_retrieve_paginated_results "api/v3/computer-groups/static-groups" 100 "id:asc"); then
        logMe "ERROR: Unable to retrieve all static computer groups."
        return 1
    fi

    if ! jq -e 'type == "object" and (.results | type == "array")' <<< "$groupBlob" >/dev/null 2>&1; then
        logMe "ERROR: Static-group response does not contain a valid results array."
        return 1
    fi

    staticGroupIDs=()
    staticGroupName=()

    while IFS=$'\t' read -r groupID groupName; do

        if [[ "$groupID" != <-> || -z "$groupName" ]]; then
            logMe "WARNING: Ignoring malformed static-group record."
            continue
        fi

        staticGroupIDs+=("$groupID")
        staticGroupName+=("$groupName")

    done < <(jq -r '
            .results[]?
            | select(
                (.id != null)
                and (.name | type == "string")
                and (.name | length > 0)
            )
            | [.id, .name]
            | @tsv' <<< "$groupBlob"
    )

    if (( ${#staticGroupIDs[@]} == 0 )); then
        logMe "ERROR: No static computer groups were returned."
        return 1
    fi

    if (( ${#staticGroupIDs[@]} != ${#staticGroupName[@]} )); then
        logMe "ERROR: Static-group ID and name counts do not match."
        return 1
    fi

    logMe "Retrieved ${#staticGroupIDs[@]} static computer group(s)."

    display_msg_migrate
    displayReturnCode=$?

    case "$displayReturnCode" in

        0)
            ;;
            
        2)
            logMe "INFO: User canceled the requested operation."
            return 0
            ;;
            
        *)
            logMe "ERROR: Membership display failed."
            return 1
            ;;
    esac

    if [[ "${ACTION_TAKEN:l}" == "view" ]]; then
        return 0
    fi

    if (( ${#groupNumbers[@]} == 0 )); then
        logMe "INFO: No static-group memberships found."
        return 0
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain valid API token."
        return 1
    fi

    case "${ACTION_TAKEN:l}" in

        migrate)

            for (( i=1; i<=${#groupNumbers[@]}; i++ )); do

                groupID="${groupNumbers[i]}"
                groupName="${membersofGroup[i]}"

                if retval=$(JAMF_static_group_action_by_name "$groupID" "$newSystem" "add"); then
                    (( operationSuccesses++ ))
                    progressResults+=("Successfully added '${newSystem}' to '${groupName}'.")
                else
                    (( operationFailures++ ))
                    progressResults+=("Failed to add '${newSystem}' to '${groupName}': ${retval}")
                fi
            done
            ;;
        *)
            logMe "ERROR: Unsupported ActionTaken value: ${ACTION_TAKEN:-<empty>}"
            return 1
            ;;
    esac
    logMe "Migration completed with ${operationSuccesses} success(es) and ${operationFailures} failure(s)."
    if (( operationFailures > 0 )); then
        return 1
    fi

    return 0
}

function show_usage ()
{
    logMe "RequestType : ${REQUEST_TYPE}"
    logMe "GroupName   : ${JAMF_GROUP_NAME}"
    logMe "GroupAction : ${JAMF_GROUP_ACTION}"
    logMe "ShowWindow  : ${SHOW_WINDOW}"
    logMe "ActionTaken : ${ACTION_TAKEN}"
    logMe "AccessType  : ${ACCESS_TYPE}"

    cat <<'EOF'
JAMFStaticGroupUtility.sh

PURPOSE:
    View, add, remove, or migrate Jamf static group memberships.

USAGE:

    JAMFStaticGroupUtility.sh \
        <ignored1> \
        <ignored2> \
        <loggedInUser> \
        <ClientID> \
        <ClientSecret> \
        <RequestType> \
        <GroupName> \
        <GroupAction> \
        <ShowWindow> \
        <ActionTaken> \
        <AccessType>

PARAMETERS:

    Parameter 4  - Client ID or API Username
    Parameter 5  - Client Secret or API Password

    Parameter 6  - Request Type
                   single | migrate

    Parameter 7  - Static Group Name
                   Required when:
                   RequestType=single AND ShowWindow=No

    Parameter 8  - Group Action
                   Add | Remove | View

    Parameter 9  - Show Window
                   Yes | No

    Parameter 10 - Action Taken
                   View | Migrate

    Parameter 11 - Access Type
                   Normal | Admin

EXAMPLES:

View a group interactively:

    Parameter 6  = single
    Parameter 7  = ""
    Parameter 8  = View
    Parameter 9  = Yes
    Parameter 10 = View
    Parameter 11 = Normal

Add local Mac to a specific group silently:

    Parameter 6  = single
    Parameter 7  = Marketing Macs
    Parameter 8  = Add
    Parameter 9  = No
    Parameter 10 = View
    Parameter 11 = Normal

Migrate memberships from one computer to another:

    Parameter 6  = migrate
    Parameter 9  = Yes
    Parameter 10 = Migrate
    Parameter 11 = Admin

Interactive Remove All:

    Parameter 6  = single
    Parameter 7  = ""
    Parameter 8  = RemoveAll
    Parameter 9  = Yes
    Parameter 10 = View
    Parameter 11 = Admin

VALID VALUES:

RequestType :
    single
    migrate

GroupAction :
    add
    remove
    view
    removeall

Interactive choices :
    Add Users
    Remove Users
    View Users
    Remove All

ShowWindow :
    yes
    no

ActionTaken :
    view
    migrate

AccessType :
    normal
    admin
EOF
}
####################################################################################################
#
# Main Script
#
####################################################################################################
autoload -Uz is-at-least
zmodload zsh/datetime

typeset -g jamfpro_url
typeset -g selectedGroup
typeset -g action
typeset -g hostName
typeset -g oldSystem
typeset -g newSystem
typeset -g dialogPID
typeset -ga staticGroupIDs=()
typeset -ga staticGroupName=()
typeset -ga groupNumbers=()
typeset -ga membersofGroup=()
typeset -ga progressResults=()
typeset -g api_token=""
typeset -gi SCRIPT_EXIT_CODE=0
typeset -gi api_token_expires_epoch=0
typeset -ga CURL_ARGS

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
validate_script_parameters || cleanup_and_exit 1

if [[ "${SHOW_WINDOW:l}" == "yes" || "${REQUEST_TYPE:l}" == "migrate" ]]; then

    initialize_user_context || cleanup_and_exit 1
    check_swift_dialog_install || cleanup_and_exit 1
    check_support_files || cleanup_and_exit 1
    make_temp_files || cleanup_and_exit 1
    create_infobox_message
fi

JAMF_get_server || cleanup_and_exit 1
JAMF_check_connection || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1
JAMF_ensure_valid_token || cleanup_and_exit 1

# Determine if this is a single or migrate request
case "${REQUEST_TYPE:l}" in
    single)
        if ! static_group_single; then
            SCRIPT_EXIT_CODE=1
        fi
        ;;

    migrate)
        if ! static_group_multiple; then
            SCRIPT_EXIT_CODE=1
        fi
        ;;

    *)
        logMe "ERROR: Unsupported request type: ${REQUEST_TYPE:-<empty>}"
        SCRIPT_EXIT_CODE=1
        ;;
esac

# Show the reults if there are any
if (( ${#progressResults[@]} > 0 )); then
    if [[ "${SHOW_WINDOW:l}" == "yes" ]]; then
        combined_string="${(j:<br>:)progressResults}"

        "$SW_DIALOG" \
            --title "Static Group Results" \
            --icon "$SD_ICON_FILE" \
            --message "$combined_string" \
            --messagefont "size=12" \
            --width 1000 \
            --height 700 \
            --ontop
    else
        for result in "${progressResults[@]}"; do
            logMe "$result"
        done
    fi
fi

cleanup_and_exit "$SCRIPT_EXIT_CODE"