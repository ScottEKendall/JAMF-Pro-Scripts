#!/bin/zsh
#
# JAMFRetrieveExpireDates
#
# by: Scott Kendall
#
# Written: 04/22/2026
# Last updated: 10/08/2026
#
# Script Purpose: This script is designed to retrieve the expiration dates of PKI, ADE, VPP & APNS tokens and Configuration Profiles from JAMF Pro 
#
# 1.0 - Initial
# 1.1 - Minor wording change from APNS Token to APNS Certificate, Also added some additional verbiage to the welcome message to clarify tokens and/or certificates
# 1.2 - Removed extraneous "echo" statements that were used for testing and debugging purposes
#       Change APNS Sync date to show date & time in 12 hour format with AM/PM
#       Made window resizable and moveable to accommodate for longer lists of expiring items
#       Optimized the API calls to reduce the number of calls being made to the server and speed up the retrieval process
#       Fixed issue of the jamf_cli for devices calling the incorrect API endpoints
# 1.3 - Added check for Computer & Device Invitations and retrieval of their expiration dates
# 2.0 - Major "under the hood" production improvements
#     - Added OAuth and Classic API authentication support
#     - Added support for different JAMF instances (not just primary)
#     - Added automatic token management and renewal
#     - Added enrollment invitation expiration monitoring
#     - Added centralized date parsing and expiration processing
#     - Added comprehensive API validation and error handling
#     - Added secure temporary-file management and cleanup
#     - Enhanced configuration profile certificate scanning
#     - Added operational health monitoring and threshold alerts
#     - Improved SwiftDialog user experience and progress reporting
#     - Expanded logging, diagnostics, and recovery handling
#     - Significant security, reliability, and performance improvements

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="JAMFRetrieveExpireDates"
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_VERSION="2.0"

FREE_DISK_SPACE=$(/bin/df -g / | /usr/bin/awk 'NR == 2 { print $4 }')
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.0.0"
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

SD_WINDOW_TITLE="Retrieve Expiration Dates"
SD_ICON_FILE="/System/Applications/Calendar.app"
OVERLAY_ICON="SF=checkmark.seal.fill,weight=bold,color=green,bgcolor=none"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

THRESHOLD_DAYS_WARNING=60   # Number of days before expiration to trigger a warning log message
THRESHOLD_DAYS_CRITICAL=14   # Number of days before expiration to trigger a critical log message
ADE_SYNC_WARNING_THRESHOLD=2 # Number of days since last sync to trigger a warning log message

typeset -gr MAIN_PID=$$

##################################################
#
# Passed in variables
# 
#################################################

JAMF_PARAMETER_USER="${3:-}"     # Passed in by JAMF automatically
CLIENT_ID="${4:-}"               # credentials  for JAMF Pro login
CLIENT_SECRET="${5:-}"
JAMF_SERVER="${6:-}"            # JAMF server to check again...leave it blank for active PROD server
                            
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
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
    else
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"
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
    if [[ ! -e "$SD_BANNER_IMAGE" ]] && [[ "$SD_BANNER_IMAGE" =~ \.(jpg|png|heic)$ ]]; then
        if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"
        then
            logMe "WARNING: Support-file installation failed." >&2
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        if ! /usr/local/bin/jamf policy -event "$JQ_FILE_INSTALL_POLICY"; then
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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br><br>"
    SD_INFO_BOX_MSG+="#### Expiration Thresholds ####<br>"
    SD_INFO_BOX_MSG+="Warning: ${THRESHOLD_DAYS_WARNING} days<br>"
    SD_INFO_BOX_MSG+="Critical: ${THRESHOLD_DAYS_CRITICAL} days<br>"
    SD_INFO_BOX_MSG+="ADE: ${ADE_SYNC_WARNING_THRESHOLD} days overdue<br>"
}

function cleanup_files ()
{
    # Perform a clean-up on all of the temp files that were created at run-time
    (( ZSH_SUBSHELL == 0 )) || return 0
    [[ "$$" == "$MAIN_PID" ]] || return 0

    local file=""

    for file in \
        "${JSON_DIALOG_BLOB:-}" \
        "${DIALOG_COMMAND_FILE:-}"
    do
        [[ -n "$file" && -e "$file" ]] &&
            /bin/rm -f -- "$file"
    done
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - EXIT HUP INT TERM

    if [[ -n "$api_token" ]]; then
        JAMF_invalidate_token || true
    fi

    cleanup_files
    exit "$exit_code"
}

function handle_signal ()
{
    local signal_name="$1"

    trap - EXIT HUP INT TERM

    logMe "WARNING: Script interrupted by ${signal_name}."

    if [[ -n "$api_token" ]]; then
        JAMF_invalidate_token || true
    fi

    cleanup_files
    exit 1
}

function handle_exit ()
{
    local exit_code=$?

    trap - EXIT HUP INT TERM

    if [[ -n "${api_token:-}" ]]; then
        JAMF_invalidate_token || true
    fi

    cleanup_files
    return "$exit_code"
}

function make_temp_files ()
{
    # Make some temp files    
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

function check_for_sudo ()
{
    if ! admin_user; then
        print -r -- "ERROR: This script must be run as root." >&2
        exit 1
    fi

    return 0
}

function update_display_list ()
{
    # setopt -s nocasematch
    # This function updates the Swift Dialog list display with easy to implement parameter passing...
    # The Swift Dialog native structure is very strict with the command structure...this routine makes
    # it easier to implement
    #
    # Param list
    #
    # $1 = update/change
    # $2 - Affected item (2nd field in JSON Blob listitem entry)
    # $3 = list-item title
    # $4 = status text
    # $5 = status
    # $6 = Optional progress value:
    #      increment - Increment progress by one
    #      reset     - Reset progress to zero
    #      complete  - Complete the progress bar
    #      integer   - Set progress to the specified value
    # The :l modifier converts the action parameter to lowercase.

    case "${1:l}" in
 
        "create" | "show" )
 
            # Display the Dialog prompt
            "$SW_DIALOG" --progress --jsonfile "${JSON_DIALOG_BLOB}" --commandfile "${DIALOG_COMMAND_FILE}" &
            DIALOG_PROCESS=$! #Grab the process ID of the background process
            ;;
     
        "add" )
            local title_text="${2:-}"
            local status_text="${4:-}"

            title_text="${title_text//$'\r'/}"
            title_text="${title_text//$'\n'/ }"

            status_text="${status_text//$'\r'/}"
            status_text="${status_text//$'\n'/<br>}"

            print -r -- "listitem: add, title: ${title_text}, status: ${3}, statustext: ${status_text}" >> "$DIALOG_COMMAND_FILE"
            ;;

        "buttonenable" )

            # Enable button 1
            print -r -- "button1: enable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            local status_text="${4:-}"

            status_text="${status_text//$'\r'/}"
            status_text="${status_text//$'\n'/<br>}"

            print -r -- "listitem: title: ${3}, status: ${5}, statustext: ${status_text}" >> "$DIALOG_COMMAND_FILE"

            [[ -n "${6:-}" ]] && print -r -- "progress: ${6}" >> "$DIALOG_COMMAND_FILE"

            /bin/sleep 0.1
            ;;
  
        "progress" )
            [[ -n "${6:-}" ]] && print -r -- "progress: ${6}" >> "$DIALOG_COMMAND_FILE"
            [[ -n "${5:-}" ]] && print -r -- "progresstext: ${5}" >> "$DIALOG_COMMAND_FILE"
            ;;
  
    esac
}

function display_failure_message ()
{
    local errorMessage="${1:-An unknown error occurred.}"
    local buttonpress=0
    local -a MainDialogBody

    MainDialogBody=(
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --subtitle "$BANNER_SUBTITLE"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "**Unable to Complete the Request**<br><br>${errorMessage}"
        --icon "$SD_ICON_FILE"
        --overlayicon warning
        --iconsize 128
        --messagefont "name=Arial,size=17"
        --button1text "OK"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    return "$buttonpress"
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
    /bin/chmod 600 "$response_file"

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
        rm -f -- "$response_file"
    }
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
        logMe "ERROR: Unable to create token-invalidation response file." >&2
        return 1
    }

    /bin/chmod 600 "$response_file"
    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --request POST --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth/invalidate-token")
        curl_status=$?

        api_token=""
        api_token_expires_epoch=0

        if (( curl_status != 0 )); then
            logMe "ERROR: Token invalidation failed. curl exit code: ${curl_status}" >&2
            /bin/rm -f -- "$response_file"
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
                /bin/rm -f -- "$response_file"
                return 1
                ;;
        esac
        # Request and status handling
        } always {
            /bin/rm -f -- "$response_file"
    }
    return 0
}

###########################
#
# Application functions
#
###########################

function days_until_expiration ()
{
    local date_value="$1"
    local expiration_epoch
    local current_epoch

    [[ -n "$date_value" ]] || {
        logMe "ERROR: Cannot calculate expiration because the date is empty." >&2
        return 1
    }

    if ! expiration_epoch=$(
        /bin/date -j -f "%m/%d/%Y" "${date_value%% *}" "+%s" 2>/dev/null
    ); then
        logMe "ERROR: Invalid expiration date: ${date_value}" >&2
        return 1
    fi

    current_epoch=$(/bin/date "+%s")
    print -r -- $(( (expiration_epoch - current_epoch) / 86400 ))
}

function days_since_date ()
{
    local date_value="$1"
    local date_epoch
    local current_epoch

    [[ -n "$date_value" ]] || {
        logMe "ERROR: Cannot calculate elapsed days because the date is empty." >&2
        return 1
    }

    if ! date_epoch=$(/bin/date -j -f "%m/%d/%Y" "${date_value%% *}" "+%s" 2>/dev/null); then
        logMe "ERROR: Invalid prior date: ${date_value}" >&2
        return 1
   fi

    current_epoch=$(/bin/date "+%s")

    print -r -- $(( (current_epoch - date_epoch) / 86400 ))
}

function JAMF_api_getpki ()
{
    # PURPOSE: Get PKI certificate information from Jamf Pro API
    # RETURNS:
    #   0 = Success
    #   1 = Failure
    #
    # OUTPUT:
    #   pki_expire_date
    #   expireDays

    local response_file
    local http_status
    local curl_status

    pki_expire_date=""
    expireDays="unknown"

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.pki.XXXXX") || {
        logMe "ERROR: Unable to create temporary PKI response file." >&2
        return 1
    }

    /bin/chmod 600 "$response_file"

    {
        
        JAMF_ensure_valid_token || return 1
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 60 --output "$response_file" --write-out '%{http_code}' \
                --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/api/v1/pki/certificate-authority/active")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: PKI request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: PKI request returned HTTP ${http_status}" >&2

            if [[ -s "$response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 500 "$response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: PKI response was empty." >&2
            return 1
        fi

        if ! jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: PKI response is not valid JSON." >&2
            return 1
        fi

        pki_expire_date=$(jq -er '.notAfter | strflocaltime("%m/%d/%Y")' "$response_file") || {
            logMe "ERROR: Unable to extract PKI expiration date." >&2
            return 1
        }

        if ! expireDays=$(days_until_expiration "$pki_expire_date"); then
            logMe "ERROR: Unable to calculate PKI expiration threshold." >&2
            pki_expire_date="Unable to determine expiration"
            expireDays="unknown"
            return 1
        fi

        logMe "PKI certificate expires on ${pki_expire_date} (${expireDays} days remaining)."

        return 0

    } always {
        /bin/rm -f -- "$response_file"
    }
}

function JAMF_api_getvpp ()
{
    local list_response_file
    local detail_response_file
    local http_status
    local curl_status
    local vpp_expire_date
    local vpp_account_name
    local minimum_expire_days=99999
    local id
    local -i valid_expiration_count=0
    local -i invalid_expiration_count=0
    local -i current_expire_days=0

    local -a vpp_array_ids
    local -a display_entries

    vpp_return_dates=""
    expireDays=99999

    list_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.vpp-list.XXXXX") || {
        logMe "ERROR: Unable to create VPP list response file." >&2
        return 1
    }

    detail_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.vpp-detail.XXXXX") || {
        logMe "ERROR: Unable to create VPP detail response file." >&2
        /bin/rm -f -- "$list_response_file"
        return 1
    }

    /bin/chmod 600 "$list_response_file" "$detail_response_file"

    {
        #
        # Retrieve the VPP account list
        #
        JAMF_ensure_valid_token || {
            logMe "ERROR: Unable to ensure a valid Jamf Pro API token before retrieving VPP accounts." >&2
            return 1
        }
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$list_response_file" --write-out '%{http_code}' \
                --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/vppaccounts")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Unable to retrieve VPP accounts. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: VPP account-list request returned HTTP ${http_status}." >&2

            if [[ -s "$list_response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 1000 "$list_response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$list_response_file" ]]; then
            logMe "ERROR: VPP account-list response is empty." >&2
            return 1
        fi

        if ! jq -e . "$list_response_file" >/dev/null 2>&1; then
            logMe "ERROR: VPP account-list response is not valid JSON." >&2
            logMe "ERROR: Response begins with:" >&2
            /usr/bin/head -c 1000 "$list_response_file" >&2
            printf '\n' >&2
            return 1
        fi

        vpp_array_ids=(${(f)"$(jq -r '.vpp_accounts[]? | .id // empty' "$list_response_file")"})

        if (( ${#vpp_array_ids[@]} == 0 )); then
            vpp_return_dates="No VPP accounts found"
            expireDays=99999
            return 0
        fi
        #
        # Retrieve each VPP account
        #
        for id in "${vpp_array_ids[@]}"; do

            JAMF_ensure_valid_token || return 1
            if [[ "$id" != <-> ]]; then
                logMe "ERROR: Invalid VPP account ID: [${id}]" >&2
                return 1
            fi

            : > "$detail_response_file" || {
                logMe "ERROR: Unable to clear the VPP detail response file." >&2
                return 1
            }

            http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$detail_response_file" --write-out '%{http_code}' \
                    --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/vppaccounts/id/${id}")

            curl_status=$?

            if (( curl_status != 0 )); then
                logMe "ERROR: Unable to retrieve VPP account ${id}. curl exit code: ${curl_status}" >&2
                return 1
            fi

            if [[ "$http_status" != "200" ]]; then
                logMe "ERROR: VPP account ${id} returned HTTP ${http_status}." >&2

                if [[ -s "$detail_response_file" ]]; then
                    logMe "ERROR: Response begins with:" >&2
                    /usr/bin/head -c 1000 "$detail_response_file" >&2
                    printf '\n' >&2
                fi

                return 1
            fi

            if [[ ! -s "$detail_response_file" ]]; then
                logMe "ERROR: VPP account ${id} returned an empty response." >&2
                return 1
            fi

            if ! jq -e . "$detail_response_file" >/dev/null 2>&1; then

                logMe "ERROR: VPP account ${id} returned invalid JSON." >&2
                logMe "ERROR: Response size: $(/usr/bin/stat -f '%z' "$detail_response_file") bytes" >&2
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 1000 "$detail_response_file" >&2
                printf '\n' >&2
                return 1
            fi

            #
            # Ensure this is a detail response, not another list response
            #
            if ! jq -e '.vpp_account | type == "object"' "$detail_response_file" >/dev/null 2>&1; then
                logMe "ERROR: VPP account ${id} returned valid JSON, but not the expected account-detail structure." >&2
                logMe "ERROR: Requested endpoint: /JSSResource/vppaccounts/id/${id}" >&2
                logMe "ERROR: JSON response:" >&2
                jq . "$detail_response_file" >&2
                return 1
            fi

            vpp_expire_date=$(jq -r '.vpp_account.expiration_date // empty' "$detail_response_file")
            vpp_account_name=$(jq -r '.vpp_account.name // empty' "$detail_response_file")

            [[ -n "$vpp_account_name" ]] ||
                vpp_account_name="VPP Account ${id}"

            if [[ -z "$vpp_expire_date" ]]; then
                logMe "WARNING: VPP account ${id} has no expiration date."

                display_entries+=("Unable to determine expiration - ${vpp_account_name}")
                (( invalid_expiration_count++ ))
                continue
            fi

            if ! vpp_expire_date=$(/bin/date -j -f "%Y/%m/%d" "$vpp_expire_date" "+%m/%d/%Y" 2>/dev/null); then
                logMe "WARNING: Invalid expiration date for VPP account ${id}: [${vpp_expire_date}]"
                display_entries+=("Invalid expiration date - ${vpp_account_name}")
                (( invalid_expiration_count++ ))
                continue
            fi

            if ! current_expire_days=$(days_until_expiration "$vpp_expire_date"); then
                logMe "WARNING: Unable to calculate expiration for VPP account ${id}."
                display_entries+=("${vpp_expire_date} - ${vpp_account_name}")
                (( invalid_expiration_count++ ))
                continue
            fi

            if (( current_expire_days < minimum_expire_days )); then
                minimum_expire_days=$current_expire_days
            fi

            (( valid_expiration_count++ ))
            display_entries+=("${vpp_expire_date} - ${vpp_account_name}")
        done

        if (( ${#display_entries[@]} == 0 )); then
            vpp_return_dates="No VPP expiration information found"
            expireDays=99999
            return 0
        fi

        vpp_return_dates="${(F)display_entries}"

        if (( valid_expiration_count == 0 )); then
            expireDays=-1
            logMe "ERROR: No VPP expiration dates could be evaluated." >&2
            return 1
        fi

        expireDays=$minimum_expire_days

        if (( invalid_expiration_count > 0 )); then
            logMe "WARNING: ${invalid_expiration_count} VPP account(s) could not be evaluated." >&2
        fi

        return 0

    } always {
        /bin/rm -f -- \
            "$list_response_file" \
            "$detail_response_file"
    }
}

function JAMF_api_getade ()
{
    local list_response_file=""
    local detail_response_file=""
    local http_status=""
    local curl_status=0
    local id=""
    local ade_expire_date=""
    local ade_account_name=""
    local -i current_expire_days=0
    local -i minimum_expire_days=99999
    local -i valid_expiration_count=0
    local -i invalid_expiration_count=0
    local -a ade_array_ids
    local -a display_entries
    local -i total_count=0
    local -i returned_count=0


    ade_return_dates=""
    expireDays=99999

    list_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.ade-list.XXXXX") || {
        logMe "ERROR: Unable to create ADE list response file." >&2
        return 1
    }

    detail_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.ade-detail.XXXXX") || {
        logMe "ERROR: Unable to create ADE detail response file." >&2
        /bin/rm -f -- "$list_response_file"
        return 1
    }

    if ! /bin/chmod 600 \
        "$list_response_file" \
        "$detail_response_file"
    then
        logMe "ERROR: Unable to secure ADE response files." >&2
        /bin/rm -f -- "$list_response_file" "$detail_response_file"
        return 1
    fi

    {
        JAMF_ensure_valid_token || return 1

        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$list_response_file" --write-out '%{http_code}' \
        --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/api/v1/device-enrollments?page=0&page-size=100&sort=id%3Aasc")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: ADE list request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: ADE list request returned HTTP ${http_status}." >&2

            if [[ -s "$list_response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 1000 "$list_response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$list_response_file" ]]; then
            logMe "ERROR: ADE list response was empty." >&2
            return 1
        fi

        if ! jq -e 'type == "object" and (.results | type == "array")' "$list_response_file" >/dev/null 2>&1
        then
            logMe "ERROR: ADE list response has an unexpected structure." >&2
            return 1
        fi
        
        total_count=$(jq -r '.totalCount // 0' "$list_response_file")
        returned_count=$(jq -r '.results | length' "$list_response_file")

        if (( total_count > returned_count )); then
            logMe "ERROR: ADE list was truncated. Returned ${returned_count} of ${total_count} instances." >&2
            ade_return_dates="ADE results were incomplete"
            expireDays=-1
            return 1
        fi


        ade_array_ids=(${(f)"$(jq -r '.results[]? | .id // empty' "$list_response_file")"})

        if (( ${#ade_array_ids[@]} == 0 )); then
            ade_return_dates="No ADE instances found"
            expireDays=99999
            return 0
        fi

        for id in "${ade_array_ids[@]}"; do
            if [[ "$id" != <-> ]]; then
                logMe "WARNING: Ignoring invalid ADE instance ID: [${id}]" >&2
                (( invalid_expiration_count++ ))
                continue
            fi

            if ! JAMF_ensure_valid_token; then
                logMe "ERROR: Unable to renew the Jamf Pro API token." >&2
                return 1
            fi

            : > "$detail_response_file" || {
                logMe "ERROR: Unable to clear the ADE detail response file." >&2
                return 1
            }

            http_status=$(curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$detail_response_file" --write-out '%{http_code}' \
                --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/api/v1/device-enrollments/${id}")
            curl_status=$?

            if (( curl_status != 0 )); then
                logMe "WARNING: ADE instance ${id} request failed. curl exit code: ${curl_status}" >&2
                (( invalid_expiration_count++ ))
                continue
            fi

            if [[ "$http_status" != "200" ]]; then
                logMe "WARNING: ADE instance ${id} returned HTTP ${http_status}." >&2

                if [[ -s "$detail_response_file" ]]; then
                    logMe "WARNING: Response begins with:" >&2
                    /usr/bin/head -c 1000 "$detail_response_file" >&2
                    printf '\n' >&2
                fi

                (( invalid_expiration_count++ ))
                continue
            fi

            if [[ ! -s "$detail_response_file" ]]; then
                logMe "WARNING: ADE instance ${id} returned an empty response." >&2
                (( invalid_expiration_count++ ))
                continue
            fi

            if ! jq -e 'type == "object"' "$detail_response_file" >/dev/null 2>&1; then
                logMe "WARNING: ADE instance ${id} returned invalid or unexpected JSON." >&2
                (( invalid_expiration_count++ ))
                continue
            fi

            ade_account_name=$(jq -r '.name | strings | select(length > 0)' "$detail_response_file" 2>/dev/null)
            [[ -n "$ade_account_name" ]] || ade_account_name="ADE Instance ${id}"

            ade_expire_date=$(jq -r '.tokenExpirationDate | strings | select(length > 0)' "$detail_response_file" 2>/dev/null)

            if [[ -z "$ade_expire_date" ]]; then
                logMe "WARNING: ADE instance ${id} has no token expiration date." >&2
                display_entries+=("Unable to determine expiration - ${ade_account_name}")
                (( invalid_expiration_count++ ))
                continue
            fi

            if ! ade_expire_date=$(format_jamf_date "$ade_expire_date" "+%m/%d/%Y" 2>/dev/null); then
                logMe "WARNING: Invalid expiration date for ADE instance ${id}." >&2
                display_entries+=("Unable to parse expiration - ${ade_account_name}")
                (( invalid_expiration_count++ ))
                continue
            fi

            if ! current_expire_days=$(days_until_expiration "$ade_expire_date"); then
                logMe "WARNING: Unable to calculate expiration for ADE instance ${id}." >&2
                display_entries+=("Unable to calculate expiration - ${ade_account_name}")
                (( invalid_expiration_count++ ))
                continue
            fi

            if (( current_expire_days < minimum_expire_days )); then
                minimum_expire_days=$current_expire_days
            fi

            (( valid_expiration_count++ ))
            display_entries+=("${ade_expire_date} - ${ade_account_name}")
        done

        if (( ${#display_entries[@]} == 0 )); then
            if (( invalid_expiration_count > 0 )); then
                ade_return_dates="Unable to evaluate ADE expiration information"
                expireDays=-1
                return 1
            fi

            ade_return_dates="No ADE instances found"
            expireDays=99999
            return 0
        fi

        ade_return_dates="${(F)display_entries}"

        if (( valid_expiration_count == 0 )); then
            expireDays=-1
            logMe "ERROR: No ADE expiration dates could be evaluated." >&2
            return 1
        fi

        expireDays=$minimum_expire_days

        if (( invalid_expiration_count > 0 )); then
            logMe "WARNING: ${invalid_expiration_count} ADE instance(s) could not be evaluated." >&2
        fi

        return 0

    } always {
        /bin/rm -f -- "$list_response_file" "$detail_response_file"
    }
}

function JAMF_api_getade_last_sync ()
{
    # PURPOSE: Get last ADE sync information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url

    local http_status=""
    local curl_status=0
    local list_response_file
    local raw_timestamp=""
    ade_last_sync="Unable to determine last sync"
    expireDays=-1

    JAMF_ensure_valid_token || return 1

    list_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.ade-list.XXXXX") || {
        logMe "ERROR: Unable to create ADE list response file." >&2
        return 1
    }

    if ! /bin/chmod 600 "$list_response_file"; then
        logMe "ERROR: Unable to secure ADE last-sync response file." >&2
        /bin/rm -f -- "$list_response_file"
        return 1
    fi

    {

        http_status=$(curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$list_response_file" --write-out '%{http_code}' \
            -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}/api/v1/device-enrollments/syncs") 

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: ADE last Sync request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: ADE last Sync request returned HTTP ${http_status}." >&2
            return 1
        fi

        if [[ ! -s "$list_response_file" ]]; then
            logMe "ERROR: ADE last Sync  response was empty." >&2
            return 1
        fi

        if ! jq -e 'type == "array" and length > 0 and (.[0].timestamp | type == "string")' "$list_response_file" >/dev/null 2>&1; then
            logMe "ERROR: ADE last-sync response has an unexpected structure." >&2
            expireDays=-1
            return 1
        fi

        # Retrieve the most recent successful synchronization timestamp.
   

        raw_timestamp=$(jq -er '.[0].timestamp' "$list_response_file") || {
            logMe "ERROR: Unable to extract ADE timestamp." >&2
            return 1
        }

        if ! ade_last_sync=$(format_jamf_date "$raw_timestamp" "+%m/%d/%Y %I:%M %p" 2>/dev/null); then
            logMe "ERROR: Unable to parse the ADE last-sync timestamp: ${raw_timestamp}" >&2
            ade_last_sync="Unable to determine last sync"
            expireDays=-1
            return 1
        fi

        if [[ -z "$ade_last_sync" || "$ade_last_sync" == "null" ]]; then
            logMe "ERROR: ADE last-sync response did not contain a timestamp." >&2
            expireDays=-1
            return 1
        fi
        if ! expireDays=$(days_since_date "$ade_last_sync"); then
            logMe "ERROR: Unable to calculate days since the last ADE sync." >&2
            expireDays=99999
            return 1
        fi

        logMe "ADE last sync was ${ade_last_sync} (${expireDays} days ago)."
        return 0

        } always {
            /bin/rm -f -- "$list_response_file"
    }
    
    #echo "$ade_last_sync" > /dev/null
}

function JAMF_api_getapns ()
{
    # PURPOSE:
    #   Retrieve APNS expiration or disablement information.
    #
    # RETURNS:
    #   0 = Request completed successfully
    #   1 = APNS information could not be evaluated

    local http_status=""
    local curl_status=0
    local raw_apns_date=""
    local apns_response_file=""

    apns_expire_date="Unable to retrieve APNS information"
    expireDays=-1

    JAMF_ensure_valid_token || return 1

    apns_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.apns-list.XXXXX") || {
        logMe "ERROR: Unable to create APNS response file." >&2
        return 1
    }

    if ! /bin/chmod 600 "$apns_response_file"; then
        logMe "ERROR: Unable to secure APNS response file." >&2
        /bin/rm -f -- "$apns_response_file"
        return 1
    fi

    {
        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$apns_response_file" --write-out '%{http_code}' \
            --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/api/v1/apns-client-push-status")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: APNS request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: APNS request returned HTTP ${http_status}." >&2

            if [[ -s "$apns_response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 1000 "$apns_response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$apns_response_file" ]]; then
            logMe "ERROR: APNS response was empty." >&2
            return 1
        fi

        if ! jq -e 'type == "object" and (.results | type == "array")' "$apns_response_file" >/dev/null 2>&1; then
            logMe "ERROR: APNS response returned invalid or unexpected JSON." >&2
            return 1
        fi

        raw_apns_date=$(jq -r '.results[0].disabledAt // empty | strings | select(length > 0)' "$apns_response_file")

        if [[ -z "$raw_apns_date" ]]; then
            apns_expire_date="No expiration alert"
            expireDays=100000
            return 0
        fi

        if ! apns_expire_date=$(format_jamf_date "$raw_apns_date" "+%m/%d/%Y"); then
            logMe "ERROR: Invalid APNS date: ${raw_apns_date}" >&2
            apns_expire_date="Unable to parse APNS information"
            expireDays=-1
            return 1
        fi

        if ! expireDays=$(days_until_expiration "$apns_expire_date"); then
            logMe "ERROR: Unable to calculate the APNS expiration threshold." >&2
            expireDays=-1
            return 1
        fi

        logMe "APNS date is ${apns_expire_date} (${expireDays} days remaining)."
        return 0

    } always {
        /bin/rm -f -- "$apns_response_file"
    }
}

function JAMF_api_getcomputer-profiles ()
{
    # PURPOSE: Get configuration profile information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url
    local ALL_PROFILES=""
    local DETAIL=""
    local NAME=""
    local RAW_DATE=""
    local CLEAN_DATE=""
    local FINAL_DATE=""
    local -a PROFILE_IDS
    local ID=""
    local -i counter=0
    local -i failed_count=0
    local -i processed_count=0
    local -a CERTIFICATES
    local CERTIFICATE_DATA=""
    local -i certificate_index=0
    local -i skipped_data_count=0

    # 1. Get the list of all profiles using the Classic API (JSON format)
    JAMF_ensure_valid_token || return 1

    if ! ALL_PROFILES=$(/usr/bin/curl --silent --show-error --fail-with-body --connect-timeout 15 --max-time 120 \
        --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/osxconfigurationprofiles"); then
        logMe "ERROR: Unable to retrieve computer configuration profiles." >&2
        return 1
    fi

    if ! print -r -- "$ALL_PROFILES" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: Computer configuration profile list returned invalid JSON." >&2
        return 1
    fi

    PROFILE_IDS=(${(f)"$(print -r -- "$ALL_PROFILES" | jq -r '.os_x_configuration_profiles[]? | .id // empty')"})
    
    counter=0
    for ID in "${PROFILE_IDS[@]}"; do
        certificate_index=0
        CERTIFICATES=()
        
        if [[ "$ID" != <-> ]]; then
            logMe "WARNING: Ignoring invalid computer configuration profile ID: [${ID}]" >&2
            (( failed_count++ ))
            continue
        fi
        if ! JAMF_ensure_valid_token; then
            logMe "ERROR: Unable to renew the Jamf Pro API token while processing profile ${ID}." >&2
            (( failed_count++ ))
            continue
        fi
        ((counter++))
        update_display_list "progress" "" "" "" "Scanning $counter/${#PROFILE_IDS[@]} Computer Configuration Profiles"
        # Fetch details for each individual profile

                
        if ! DETAIL=$(/usr/bin/curl --silent --show-error --fail-with-body --connect-timeout 15 --max-time 120 \
            --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/osxconfigurationprofiles/id/${ID}"); then
            logMe "WARNING: Unable to retrieve computer configuration profile ${ID}." >&2
            ((failed_count++))
            continue
        fi

        if ! print -r -- "$DETAIL" | jq -e '.os_x_configuration_profile | type == "object"' >/dev/null 2>&1; then
            logMe "WARNING: Computer configuration profile ${ID} returned an unexpected response." >&2
            ((failed_count++))
            continue
        fi

        NAME=$(print -r -- "$DETAIL" | jq -r '.os_x_configuration_profile.general.name // empty')
        [[ -n "$NAME" ]] || NAME="Profile ${ID}"
        
        # 3. Use jq to find the 'PayloadData' within the payload_content of each profile, which contains the JSON data for certificates.
        # This filter targets standard Certificate payloads.

        CERTIFICATES=(${(f)"$(print -r -- "$DETAIL" | jq -r '.os_x_configuration_profile.general.payloads // empty' | /usr/bin/tr -d '\r\n\t ' | /usr/bin/grep -oE '<data>[^<]+</data>' | /usr/bin/sed -E 's#</?data>##g')"})

        for CERTIFICATE_DATA in "${CERTIFICATES[@]}"; do
            RAW_DATE=$(print -r -- "$CERTIFICATE_DATA" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/openssl x509 -inform der -noout -enddate 2>/dev/null)
            [[ -z "$RAW_DATE" ]] && RAW_DATE=$(print -r -- "$CERTIFICATE_DATA" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/openssl x509 -inform pem -noout -enddate 2>/dev/null)
            if [[ -z "$RAW_DATE" ]]; then
                logMe "INFO: Profile ${NAME} (${ID}) contains a data payload that is not an X.509 certificate."
                (( skipped_data_count++ ))
                continue
            fi

            (( certificate_index++ ))
            (( processed_count++ ))

            update_display_list "add" "Computer - ${NAME} - Cert ${certificate_index}" "pending" "Checking certificate..." ""

            CLEAN_DATE="${RAW_DATE#notAfter=}"
            FINAL_DATE=""

            if ! FINAL_DATE=$(/bin/date -j -f "%b %e %T %Y %Z" "$CLEAN_DATE" "+%m/%d/%Y" 2>/dev/null); then
                FINAL_DATE="Unable to parse certificate expiration"
                expireDays=-1
                (( failed_count++ ))
            elif ! expireDays=$(days_until_expiration "$FINAL_DATE"); then
                FINAL_DATE="Unable to calculate certificate expiration"
                expireDays=-1
                (( failed_count++ ))
            fi

            check_warning_threshold "$expireDays"

            update_display_list "update" "" "Computer - ${NAME} - Cert ${certificate_index}" "$FINAL_DATE" "$liststatus"

            logMe "Computer Profile ${NAME} (${ID}) expires on ${FINAL_DATE} (${expireDays} days remaining)."
        done
    done
    logMe "Computer configuration profile scan completed. Certificates evaluated: ${processed_count}; failures: ${failed_count}."

    if (( failed_count > 0 )); then
        return 1
    fi

    return 0
}

function JAMF_api_getdevice-profiles ()
{
    # PURPOSE: Get configuration profile information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url
    local ALL_PROFILES=""
    local DETAIL=""
    local NAME=""
    local RAW_DATE=""
    local CLEAN_DATE=""
    local FINAL_DATE=""
    local -a PROFILE_IDS
    local ID=""
    local -i counter=0
    local -i processed_count=0
    local -i failed_count=0
    local -a CERTIFICATES
    local CERTIFICATE_DATA=""
    local -i certificate_index=0
    local -i skipped_data_count=0

    # 1. Get the list of all profiles using the Classic API (JSON format)
    JAMF_ensure_valid_token || return 1

    if ! ALL_PROFILES=$(/usr/bin/curl --silent --show-error --fail-with-body --connect-timeout 15 --max-time 120 \
        --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/mobiledeviceconfigurationprofiles"); then
        logMe "ERROR: Unable to retrieve device configuration profiles." >&2
        return 1
    fi

    if ! print -r -- "$ALL_PROFILES" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: Device configuration profile list returned invalid JSON." >&2
        return 1
    fi

    PROFILE_IDS=(${(f)"$(print -r -- "$ALL_PROFILES" |jq -r '.configuration_profiles[]? | .id // empty')"})

    counter=0
    for ID in "${PROFILE_IDS[@]}"; do
        certificate_index=0
        CERTIFICATES=()
        if [[ "$ID" != <-> ]]; then
            logMe "WARNING: Ignoring invalid device configuration profile ID: [${ID}]" >&2
            (( failed_count++ ))
            continue
        fi

            if ! JAMF_ensure_valid_token; then
                logMe "ERROR: Unable to renew the Jamf Pro API token while processing profile ${ID}." >&2
                (( failed_count++ ))
                continue
            fi
        ((counter++))
        update_display_list "progress" "" "" "" "Scanning $counter/${#PROFILE_IDS[@]} Device Configuration Profiles"

        # Fetch details for each individual profile
                        
        if ! DETAIL=$(/usr/bin/curl --silent --show-error --fail-with-body --connect-timeout 15 --max-time 120 \
            --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/mobiledeviceconfigurationprofiles/id/${ID}"); then
            logMe "WARNING: Unable to retrieve device configuration profile ${ID}." >&2
            ((failed_count++))
            continue
        fi

        if ! print -r -- "$DETAIL" | jq -e '.configuration_profile | type == "object"' >/dev/null 2>&1; then
            logMe "WARNING: device configuration profile ${ID} returned an unexpected response." >&2
            ((failed_count++))
            continue
        fi
        
       NAME=$(print -r -- "$DETAIL" | jq -r '.configuration_profile.general.name // empty')
       [[ -n "$NAME" ]] || NAME="Profile ${ID}"
        
        # 3. Use jq to find the 'PayloadData' within the payload_content of each profile, which contains the JSON data for certificates.
        # This filter targets standard Certificate payloads.

        CERTIFICATES=(${(f)"$(print -r -- "$DETAIL" | jq -r '.configuration_profile.general.payloads // empty' | /usr/bin/tr -d '\r\n\t ' | /usr/bin/grep -oE '<data>[^<]+</data>' | /usr/bin/sed -E 's#</?data>##g')"})

        for CERTIFICATE_DATA in "${CERTIFICATES[@]}"; do
            RAW_DATE=$(print -r -- "$CERTIFICATE_DATA" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/openssl x509 -inform der -noout -enddate 2>/dev/null)
            [[ -z "$RAW_DATE" ]] && RAW_DATE=$(print -r -- "$CERTIFICATE_DATA" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/openssl x509 -inform pem -noout -enddate 2>/dev/null)
            if [[ -z "$RAW_DATE" ]]; then
                logMe "INFO: Profile ${NAME} (${ID}) contains a data payload that is not an X.509 certificate."
                (( skipped_data_count++ ))
                continue
            fi

            (( certificate_index++ ))
            (( processed_count++ ))

            update_display_list "add" "Device - ${NAME} - Cert ${certificate_index}" "pending" "Checking certificate..." ""

            CLEAN_DATE="${RAW_DATE#notAfter=}"
            FINAL_DATE=""

            if ! FINAL_DATE=$(/bin/date -j -f "%b %e %T %Y %Z" "$CLEAN_DATE" "+%m/%d/%Y" 2>/dev/null); then
                FINAL_DATE="Unable to parse certificate expiration"
                expireDays=-1
                (( failed_count++ ))
            elif ! expireDays=$(days_until_expiration "$FINAL_DATE"); then
                FINAL_DATE="Unable to calculate certificate expiration"
                expireDays=-1
                (( failed_count++ ))
            fi

            check_warning_threshold "$expireDays"

            update_display_list "update" "" "Device - ${NAME} - Cert ${certificate_index}" "$FINAL_DATE" "$liststatus"

            logMe "Device Profile ${NAME} (${ID}) expires on ${FINAL_DATE} (${expireDays} days remaining)."
        done

    done
    logMe "Device configuration profile scan completed. Certificates evaluated: ${processed_count}; failures: ${failed_count}."

    if (( failed_count > 0 )); then
        return 1
    fi

    return 0

}

function JAMF_api_get_computer_enrollment_invitations ()
{
    # PURPOSE:
    #   Retrieve computer enrollment invitations and add their
    #   expiration dates to the Swift Dialog list.
    #
    # RETURNS:
    #   0 = All available invitations were evaluated successfully
    #   1 = The invitation list could not be retrieved
    #   2 = The list was retrieved, but one or more invitations could not be evaluated

    #
    # NOTES:
    #   Failure to process one invitation does not prevent the remaining
    #   invitations from being evaluated.

    local list_response_file=""
    local detail_response_file=""
    local http_status=""
    local curl_status=0
    local id=""
    local raw_expiration_date=""
    local formatted_expiration_date=""
    local invitation_id=""
    local current_expire_days=""
    local processed_count=0
    local failed_count=0

    local -a invitation_array_ids

    JAMF_ensure_valid_token || return 1

    list_response_file=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.computer_invitation-list.XXXXX") || {
        logMe "ERROR: Unable to create computer invitation list response file." >&2
        return 1
    }

    detail_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.computer_invitation-detail.XXXXX"
    ) || {
        logMe "ERROR: Unable to create computer invitation detail response file." >&2
        /bin/rm -f -- "$list_response_file"
        return 1
    }

    /bin/chmod 600 "$list_response_file" "$detail_response_file"

    {

        : > "$list_response_file" || {
            logMe "ERROR: Unable to clear computer invitation list response file." >&2
            return 1
        }

        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$list_response_file" --write-out '%{http_code}' \
            --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/computerinvitations")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Computer invitation list request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Computer invitation list returned HTTP ${http_status}." >&2

            if [[ -s "$list_response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 1000 "$list_response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$list_response_file" ]]; then
            logMe "ERROR: Computer invitation list response was empty." >&2
            return 1
        fi

        if ! jq -e . "$list_response_file" >/dev/null 2>&1; then
            logMe "ERROR: Computer invitation list response was not valid JSON." >&2
            return 1
        fi

        invitation_array_ids=(${(f)"$(jq -r '.computer_invitations[]?| select((.expiration_date? | type == "string") and (.expiration_date | length > 0) and (.expiration_date != "Unlimited")) | .id // empty' "$list_response_file")"})
 
        if (( ${#invitation_array_ids[@]} == 0 )); then
            logMe "No expiring computer enrollment invitations were found."
            return 0
        fi

        for id in "${invitation_array_ids[@]}"; do
            if [[ "$id" != <-> ]]; then
                logMe "WARNING: Ignoring invalid computer invitation ID: [${id}]" >&2
                (( failed_count++ ))
                continue
            fi

            if ! JAMF_ensure_valid_token; then
                logMe "ERROR: Unable to renew the Jamf Pro API token." >&2
                return 1
            fi

             : > "$detail_response_file" || {
                logMe "ERROR: Unable to clear computer invitation detail response file." >&2
                return 1
            }

            http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$detail_response_file" --write-out '%{http_code}' \
                --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/computerinvitations/id/${id}")
            curl_status=$?

            if (( curl_status != 0 )); then
                logMe "WARNING: Computer invitation ${id} request failed. curl exit code: ${curl_status}" >&2
                (( failed_count++ ))
                continue
            fi

            if [[ "$http_status" != "200" ]]; then
                logMe "WARNING: Computer invitation ${id} returned HTTP ${http_status}." >&2

                if [[ -s "$detail_response_file" ]]; then
                    logMe "WARNING: Response begins with:" >&2
                    /usr/bin/head -c 1000 "$detail_response_file" >&2
                    printf '\n' >&2
                fi

                (( failed_count++ ))
                continue
            fi

            if [[ ! -s "$detail_response_file" ]]; then
                logMe "WARNING: Computer invitation ${id} returned an empty response." >&2
                (( failed_count++ ))
                continue
            fi

            if ! jq -e . "$detail_response_file" >/dev/null 2>&1; then
                logMe "WARNING: Computer invitation ${id} returned invalid JSON." >&2
                (( failed_count++ ))
                continue
            fi

            if ! jq -e '.computer_invitation | type == "object"' "$detail_response_file" >/dev/null 2>&1; then
                logMe "WARNING: Computer invitation ${id} returned an unexpected JSON structure." >&2
                (( failed_count++ ))
                continue
            fi

            invitation_id=$(jq -r '.computer_invitation.id // empty' "$detail_response_file")

            raw_expiration_date=$(jq -r '.computer_invitation.expiration_date// empty| strings| select(length > 0)' "$detail_response_file")


            [[ -n "$invitation_id" ]] || invitation_id="$id"

            if [[ -z "$raw_expiration_date" ||
                  "$raw_expiration_date" == "null" ||
                  "$raw_expiration_date" == "Unlimited" ]]
            then
                logMe "WARNING: Computer invitation ${id} has no finite expiration date." >&2
                (( failed_count++ ))
                continue
            fi

            if ! formatted_expiration_date=$(format_jamf_date "$raw_expiration_date" "+%m/%d/%Y %I:%M %p" 2>/dev/null); then
                logMe "WARNING: Unable to parse computer invitation ${id} expiration date: [${raw_expiration_date}]" >&2
                (( failed_count++ ))
                continue
            fi

            if ! current_expire_days=$(days_until_expiration "$formatted_expiration_date"); then
                logMe "WARNING: Unable to calculate expiration threshold for computer invitation ${id}." >&2
                (( failed_count++ ))
                continue
            fi

            check_warning_threshold "$current_expire_days" "cert"

            update_display_list "add" "Computer Enrollment Invitation (${invitation_id})" "$liststatus" "$formatted_expiration_date"
            logMe "Computer invitation ${invitation_id} expires on ${formatted_expiration_date} (${current_expire_days} days remaining)."

            (( processed_count++ ))
        done

        logMe "Computer enrollment invitation scan completed. Evaluated: ${processed_count}; unable to evaluate: ${failed_count}."

        if (( failed_count > 0 )); then
            return 2
        fi

        return 0

    } always {
        /bin/rm -f -- "$list_response_file" "$detail_response_file"
    }
}

function JAMF_api_get_device_enrollment_invitations ()
{
    # PURPOSE:
    #   Retrieve mobile device enrollment invitations and add their
    #   expiration dates to the Swift Dialog list.
    #
    # RETURNS:
    #   0 = All available invitations were evaluated successfully
    #   1 = The invitation list could not be retrieved
    #   2 = The list was retrieved, but one or more invitations could not be evaluated

    #
    # NOTES:
    #   Failure to process one invitation does not prevent the remaining
    #   invitations from being evaluated.

    local list_response_file=""
    local detail_response_file=""
    local http_status=""
    local curl_status=0
    local id=""
    local raw_expiration_date=""
    local formatted_expiration_date=""
    local invitation_id=""
    local current_expire_days=""
    local processed_count=0
    local failed_count=0

    local -a invitation_array_ids

    JAMF_ensure_valid_token || return 1

    list_response_file=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.mobile-invitation-list.XXXXX") || {
        logMe "ERROR: Unable to create mobile invitation list response file." >&2
        return 1
    }

    detail_response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.mobile-invitation-detail.XXXXX"
    ) || {
        logMe "ERROR: Unable to create mobile invitation detail response file." >&2
        /bin/rm -f -- "$list_response_file"
        return 1
    }

    /bin/chmod 600 "$list_response_file" "$detail_response_file"

    {

        : > "$list_response_file" || {
            logMe "ERROR: Unable to clear mobile invitation list response file." >&2
            return 1
        }

        http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$list_response_file" --write-out '%{http_code}' \
            --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/mobiledeviceinvitations")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Mobile invitation list request failed. curl exit code: ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Mobile invitation list returned HTTP ${http_status}." >&2

            if [[ -s "$list_response_file" ]]; then
                logMe "ERROR: Response begins with:" >&2
                /usr/bin/head -c 1000 "$list_response_file" >&2
                printf '\n' >&2
            fi

            return 1
        fi

        if [[ ! -s "$list_response_file" ]]; then
            logMe "ERROR: Mobile invitation list response was empty." >&2
            return 1
        fi

        if ! jq -e . "$list_response_file" >/dev/null 2>&1; then
            logMe "ERROR: Mobile invitation list response was not valid JSON." >&2
            return 1
        fi

        invitation_array_ids=(${(f)"$(jq -r '.mobile_device_invitations[]?| select((.expiration_date? | type == "string") and (.expiration_date | length > 0) and (.expiration_date != "Unlimited")) | .id // empty' "$list_response_file")"})

        if (( ${#invitation_array_ids[@]} == 0 )); then
            logMe "No expiring mobile device enrollment invitations were found."
            return 0
        fi

        for id in "${invitation_array_ids[@]}"; do
            if [[ "$id" != <-> ]]; then
                logMe "WARNING: Ignoring invalid mobile invitation ID: [${id}]" >&2
                (( failed_count++ ))
                continue
            fi

            if ! JAMF_ensure_valid_token; then
                logMe "ERROR: Unable to renew the Jamf Pro API token." >&2
                return 1
            fi

            : > "$detail_response_file" || {
                logMe "ERROR: Unable to clear mobile invitation detail response file." >&2
                return 1
            }

            http_status=$(/usr/bin/curl --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$detail_response_file" --write-out '%{http_code}' \
                --request GET --header "Authorization: Bearer ${api_token}" --header "Accept: application/json" "${jamfpro_url}/JSSResource/mobiledeviceinvitations/id/${id}")
            curl_status=$?

            if (( curl_status != 0 )); then
                logMe "WARNING: Mobile invitation ${id} request failed. curl exit code: ${curl_status}" >&2
                (( failed_count++ ))
                continue
            fi

            if [[ "$http_status" != "200" ]]; then
                logMe "WARNING: Mobile invitation ${id} returned HTTP ${http_status}." >&2

                if [[ -s "$detail_response_file" ]]; then
                    logMe "WARNING: Response begins with:" >&2
                    /usr/bin/head -c 1000 "$detail_response_file" >&2
                    printf '\n' >&2
                fi

                (( failed_count++ ))
                continue
            fi

            if [[ ! -s "$detail_response_file" ]]; then
                logMe "WARNING: Mobile invitation ${id} returned an empty response." >&2
                (( failed_count++ ))
                continue
            fi

            if ! jq -e . "$detail_response_file" >/dev/null 2>&1; then
                logMe "WARNING: Mobile invitation ${id} returned invalid JSON." >&2
                (( failed_count++ ))
                continue
            fi

            if ! jq -e '.mobile_device_invitation | type == "object"' "$detail_response_file" >/dev/null 2>&1; then
                logMe "WARNING: Mobile invitation ${id} returned an unexpected JSON structure." >&2
                (( failed_count++ ))
                continue
            fi

            invitation_id=$(jq -r '.mobile_device_invitation.id // empty' "$detail_response_file")

            raw_expiration_date=$(jq -r '.mobile_device_invitation.expiration_date// empty| strings| select(length > 0)' "$detail_response_file")
 
            [[ -n "$invitation_id" ]] || invitation_id="$id"

            if [[ -z "$raw_expiration_date" ||
                  "$raw_expiration_date" == "null" ||
                  "$raw_expiration_date" == "Unlimited" ]]
            then
                logMe "WARNING: Device invitation ${id} has no finite expiration date." >&2
                (( failed_count++ ))
                continue
            fi

            if ! formatted_expiration_date=$(format_jamf_date "$raw_expiration_date" "+%m/%d/%Y %I:%M %p" 2>/dev/null); then
                logMe "WARNING: Unable to parse device invitation ${id} expiration date: [${raw_expiration_date}]" >&2
                (( failed_count++ ))
                continue
            fi

            if ! current_expire_days=$(days_until_expiration "$formatted_expiration_date"); then
                logMe "WARNING: Unable to calculate expiration threshold for device invitation ${id}." >&2
                (( failed_count++ ))
                continue
            fi

            check_warning_threshold "$current_expire_days" "cert"

            update_display_list "add" "Device Enrollment Invitation (${invitation_id})" "$liststatus" "$formatted_expiration_date"
            logMe "Device invitation ${invitation_id} expires on ${formatted_expiration_date} (${current_expire_days} days remaining)."

            (( processed_count++ ))
        done

        logMe "Device enrollment invitation scan completed. Evaluated: ${processed_count}; unable to evaluate: ${failed_count}."

        if (( failed_count > 0 )); then
            return 2
        fi

        return 0

    } always {
        /bin/rm -f -- "$list_response_file" "$detail_response_file"
    }
}

function check_warning_threshold ()
{
    local days_until="$1"
    local mode="$2"

    if [[ "$days_until" != <-> && "$days_until" != -<-> ]]; then
        liststatus="error"

        if (( ICON_OVERLAY_STATUS < 1 )); then
            ICON_OVERLAY_STATUS=1
            OVERLAY_ICON="SF=exclamationmark.triangle.fill,weight=heavy,color=yellow,bgcolor=none"
            print -r -- "overlayicon: ${OVERLAY_ICON}" >> "$DIALOG_COMMAND_FILE"
        fi

        return 1
    fi

  # --- ADE SYNC LOGIC ---
    if [[ "$mode" == "ade_sync" ]]; then
        liststatus="success"

        if (( days_until >= ADE_SYNC_WARNING_THRESHOLD )); then
            liststatus="fail"

            if (( ICON_OVERLAY_STATUS < 2 )); then
                ICON_OVERLAY_STATUS=2
                OVERLAY_ICON="SF=xmark.app.fill,weight=heavy,color=red,bgcolor=none"
                print -r -- "overlayicon: ${OVERLAY_ICON}" >> "$DIALOG_COMMAND_FILE"
            fi
        fi

        return 0
    fi

    # --- CERTIFICATE / GENERAL LOGIC ---
    if (( days_until <= THRESHOLD_DAYS_CRITICAL )); then
        liststatus="fail"

        if (( ICON_OVERLAY_STATUS < 2 )); then
            ICON_OVERLAY_STATUS=2
            OVERLAY_ICON="SF=xmark.app.fill,weight=heavy,color=red,bgcolor=none"
            print -r -- "overlayicon: ${OVERLAY_ICON}" >> "$DIALOG_COMMAND_FILE"
        fi
    elif (( days_until <= THRESHOLD_DAYS_WARNING )); then
        liststatus="error"

        if (( ICON_OVERLAY_STATUS < 1 )); then
            ICON_OVERLAY_STATUS=1
            OVERLAY_ICON="SF=exclamationmark.triangle.fill,weight=heavy,color=yellow,bgcolor=none"
            print -r -- "overlayicon: ${OVERLAY_ICON}" >> "$DIALOG_COMMAND_FILE"
        fi
    else
        liststatus="success"
    fi

    return 0
}

function mark_operational_warning ()
{
    if (( ICON_OVERLAY_STATUS < 1 )); then
        ICON_OVERLAY_STATUS=1
        OVERLAY_ICON="SF=exclamationmark.triangle.fill,weight=heavy,color=yellow,bgcolor=none"

        print -r -- "overlayicon: ${OVERLAY_ICON}" >> "$DIALOG_COMMAND_FILE"
    fi

    (( SCRIPT_FAILURE_COUNT++ ))
}

function welcomemsg ()
{

    local helpmessage="The token information can be found on your JAMF server in these location(s):<br><br>**PKI** - <br>Settings > Global Management > PKI Certificates<br><br>**VPP** - <br>Settings > Global Management > Volume Purchasing<br><br>**ADE** - <br>Settings > Global Management > Automated Device Enrollment<br><br>**APNS** - <br>Settings > Global Management > Push Certificates<br><br>**Configuration Profiles** - <br>Computers > Configuration Profiles<br>Devices > Configuration Profiles"

    local message="${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}. These are the expiration dates for your PKI, ADE, VPP, APNS, Computer and Device Configuration Profile tokens and certificates. Please review and take action if any items are nearing expiration."
    message+="<br><br>**Note:** This information is pulled directly from Jamf Pro and may not reflect local certificate information stored on this device.<br>"

    if ! jq -n \
        --arg icon "$SD_ICON_FILE" \
        --arg message "$message" \
        --arg bannerimage "$SD_BANNER_IMAGE" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg infobox "$SD_INFO_BOX_MSG" \
        --arg overlayicon "$OVERLAY_ICON" \
        --arg helpmessage "$helpmessage" \
        --arg infotext "$jamfpro_url" \
        --arg bannertitle "$SD_WINDOW_TITLE" \
        '{
            icon: $icon,
            message: $message,
            bannerimage: $bannerimage,
            subtitle: $subtitle,
            infobox: $infobox,
            overlayicon: $overlayicon,
            helpmessage: $helpmessage,
            ontop: true,
            infotext: $infotext,
            bannertitle: $bannertitle,
            titlefont: "shadow=1",
            button1text: "OK",
            button1disabled: true,
            height: "75%",
            width: 1000,
            resizable: true,
            moveable: true,
            json: true,
            quitkey: 0,
            messageposition: "top",
            listitem: [
                {
                    title: "PKI Token",
                    status: "pending",
                    statustext: "pending"
                },
                {
                    title: "VPP Token",
                    status: "pending",
                    statustext: "pending"
                },
                {
                    title: "ADE Token",
                    status: "pending",
                    statustext: "pending"
                },
                {
                    title: "ADE Last Sync",
                    status: "pending",
                    statustext: "pending"
                },
                {
                    title: "APNS Certificate",
                    status: "pending",
                    statustext: "pending"
                }
            ]
        }' > "$JSON_DIALOG_BLOB"
    then
        logMe "ERROR: Unable to construct the Swift Dialog configuration." >&2
        return 1
    fi

    if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
        logMe "ERROR: Generated Swift Dialog configuration is invalid JSON." >&2
        return 1
    fi

    update_display_list "create"
}

####################################################################################################
#
# Main Script
#
####################################################################################################
typeset -g pki_expire_date
typeset -g vpp_return_dates
typeset -g ade_return_dates
typeset -g ade_last_sync
typeset -g apns_expire_date
typeset -gi expireDays=100000
typeset -g api_token=""
typeset -gi api_token_expires_epoch=0
typeset -g jamfpro_url=""
typeset -g liststatus=""
typeset -gi ICON_OVERLAY_STATUS=0
typeset -gi SCRIPT_FAILURE_COUNT=0

autoload -Uz is-at-least

if ! zmodload zsh/datetime 2>/dev/null; then
    print -r -- "ERROR: Unable to load the zsh/datetime module." >&2
    exit 1
fi

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
initialize_user_context || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
JAMF_get_server || cleanup_and_exit 1
JAMF_check_credentials || cleanup_and_exit 1
make_temp_files || cleanup_and_exit 1


create_infobox_message
if ! JAMF_check_connection; then
    display_failure_message "Problems determining the JAMF connection"
    cleanup_and_exit 1
fi


case "$JAMF_TOKEN" in
    new)
        JAMF_get_access_token || {
            logMe "ERROR: Unable to obtain an OAuth access token." >&2
            cleanup_and_exit 1
        }
        ;;
    classic)
        JAMF_get_classic_api_token || {
            logMe "ERROR: Unable to obtain a Classic API bearer token." >&2
            cleanup_and_exit 1
        }
        ;;
    *)
        logMe "ERROR: Unknown Jamf Pro authentication type: ${JAMF_TOKEN}" >&2
        cleanup_and_exit 1
        ;;
esac

# Set the icon overlay status to 0 (no icon) by default, this will be updated if any items are within the warning threshold
# 0 = normal, 1 = warning, 2 = critical

welcomemsg || {logMe "ERROR: Unable to create or launch the Swift Dialog interface." >&2; cleanup_and_exit 1;}

# Get PKI Expiration Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for PKI expiration..." 0
logMe "Retrieving PKI certificate information..."

if JAMF_api_getpki; then
    check_warning_threshold "$expireDays" "cert"
    update_display_list "update" "" "PKI Token" "$pki_expire_date" "$liststatus"
else
    mark_operational_warning
    update_display_list "update" "" "PKI Token" "${pki_expire_date:-Unable to retrieve PKI information}" "error"
fi
#JAMF_api_getpki || cleanup_and_exit 1
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "PKI Token" "$pki_expire_date" "$liststatus"

# Get VPP Expiration Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for VPP expiration..." 10
logMe "Retrieving VPP license information..."
if ! JAMF_api_getvpp; then
    display_failure_message "Retrieve VPP tokens returned a value of $vpp_return_dates<br><br>Please make sure you have access rights for this function"
    cleanup_and_exit 1
fi
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "VPP Token" "$vpp_return_dates" "$liststatus"

# Get ADE Expiration Date(s) and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for ADE expiration..." 20
logMe "Retrieving ADE license information..."
if JAMF_api_getade; then
    check_warning_threshold "$expireDays" "cert"
    update_display_list "update" "" "ADE Token" "$ade_return_dates" "$liststatus"
else
    mark_operational_warning
    update_display_list "update" "" "ADE Token" "${ade_return_dates:-Unable to retrieve ADE information}" "error"
fi


# Get ADE Last Sync Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for ADE last sync expiration..." 30
logMe "Retrieving ADE last sync information..."
if JAMF_api_getade_last_sync; then
    check_warning_threshold "$expireDays" "ade_sync"
    update_display_list "update" "" "ADE Last Sync" "$ade_last_sync" "$liststatus" 
else
    mark_operational_warning
    update_display_list "update" "" "ADE Last Sync" "${ade_last_sync:-Unable to retrieve ADE information}" "error"
fi


# Get APNS Expiration Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for APNS expiration..." 40
logMe "Retrieving APNS certificate information..."
if JAMF_api_getapns; then
    check_warning_threshold "$expireDays" "cert"
    update_display_list "update" "" "APNS Certificate" "$apns_expire_date" "$liststatus"
else
    mark_operational_warning
    update_display_list "update" "" "APNS Certificate" "${apns_expire_date:-Unable to retrieve APNS information}" "error"
fi

# Get Computer Enrollment Invitation Expiration Date(s) and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for computer enrollment invitation expiration..." 50
logMe "Retrieving computer enrollment invitation information..."
JAMF_api_get_computer_enrollment_invitations
computer_invitation_status=$?

case "$computer_invitation_status" in
    0)
        ;;
    2)
        update_display_list "add" "Computer Enrollment Invitations" "error" "Some invitations could not be evaluated"
        mark_operational_warning
        ;;
    *)
        update_display_list "add" "Computer Enrollment Invitations" "error" "Unable to retrieve invitation information"
        mark_operational_warning
        ;;
esac

# Get Device Enrollment Invitation Expiration Date(s) and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for device enrollment invitation expiration..." 60
logMe "Retrieving device enrollment invitation information..."
JAMF_api_get_device_enrollment_invitations
device_invitation_status=$?

case "$device_invitation_status" in
    0)
        ;;
    2)
        update_display_list "add" "Device Enrollment Invitations" "error" "Some invitations could not be evaluated"
        mark_operational_warning
        ;;
    *)
        update_display_list "add" "Device Enrollment Invitations" "error" "Unable to retrieve invitation information"
        mark_operational_warning
        ;;
esac

# Get Configuration Profile Certificate Expiration Dates and check if they are within the warning threshold.
update_display_list "progress" "" "" "" "Checking for Configuration Profile expiration..." 70
logMe "Retrieving computer configuration profile certificate information..."
if ! JAMF_api_getcomputer-profiles; then
    logMe "ERROR: Unable to evaluate computer configuration profile certificates." >&2
    mark_operational_warning
    update_display_list "add" "Computer Configuration Profiles" "error" "Unable to evaluate one or more certificate expirations"
fi
# Get Device Configuration Profile Certificate Expiration Dates and check if they are within the warning threshold.
update_display_list "progress" "" "" "" "Checking for Device Configuration Profile expiration..." 80
logMe "Retrieving device configuration profile certificate information..."

if ! JAMF_api_getdevice-profiles; then
    logMe "ERROR: Unable to evaluate device configuration profile certificates." >&2
    mark_operational_warning
    update_display_list "add" "Device Configuration Profiles" "error" "Unable to evaluate one or more certificate expirations"
fi

# All done, enable the button so the user can exit the dialog
update_display_list "progress" "" "" "" "Done!" 100
update_display_list "buttonenable" "OK"

wait "$DIALOG_PROCESS"
dialog_exit_status=$?

if (( dialog_exit_status != 0 )); then
    logMe "WARNING: Swift Dialog exited with status ${dialog_exit_status}." >&2
fi

if (( SCRIPT_FAILURE_COUNT > 0 )); then
    logMe "WARNING: Script completed with ${SCRIPT_FAILURE_COUNT} retrieval or evaluation issue(s)." >&2
    cleanup_and_exit 1
fi

cleanup_and_exit 0

