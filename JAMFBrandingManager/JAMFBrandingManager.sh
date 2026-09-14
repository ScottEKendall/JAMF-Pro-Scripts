#!/bin/zsh
#
# JAMF Self Service Branding Manager
#
# by: Scott Kendall
#
# Written: 09/04/2026
# Last updated: 09/14/2026
#
# Script Purpose: Select from a variety of Self service banners and upload them to the server
#
# 1.0 - Initial production release
#       - View and download Jamf branding images
#       - Modify Self Service branding text
#       - Upload and assign banner images
#       - Maintain image ID cross-reference data
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="JAMFBrandingManager"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
MAIN_PID=$$

FREE_DISK_SPACE=$(/bin/df -k / | /usr/bin/awk 'NR == 2 { printf "%.0f", $4 / 1024 / 1024 }')
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

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

SD_WINDOW_TITLE="Self Service Banner Manager"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="/System/Applications/App Store.app"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_INSTALL_POLICY="install_jq"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_PARAMETER_USER=${3:-""}    # Passed in by JAMF automatically
CLIENT_ID=${4}                  # user name for JAMF Pro
CLIENT_SECRET=${5}
JAMF_SERVER=${6:-""}            # Jamf Pro server URL
WALLPAPER_DIR=${7:-""}          # directory where the wallpapers are stored
[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF credentials we are using 

# Number of branding images to retrieve from the server
# Adjust this number accordingly...the more iamges you download, the longer it will take to load the previews
BRANDING_IMAGES_DOWNLOADS=10

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
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}"
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
    # Install Swift dialog From Jamf
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from Jamf
    #
    # RETURN: None

	/usr/local/bin/jamf policy -event "${DIALOG_INSTALL_POLICY}"
}

function check_support_files ()
{
    if [[ "$SD_BANNER_IMAGE" != /* && -e "${SUPPORT_DIR}/${SD_BANNER_IMAGE}" ]]; then
        SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
    fi

    if [[ ! -e "$SD_BANNER_IMAGE" ]]; then
        logMe "SwiftDialog support files are missing. Attempting installation."

        if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"; then
            logMe "ERROR: Support-file installation failed." >&2
            return 1
        fi

        if [[ "$SD_BANNER_IMAGE" != /* && -e "${SUPPORT_DIR}/${SD_BANNER_IMAGE}" ]]; then
            SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
        fi
    fi

    if [[ ! -e "$SD_BANNER_IMAGE" ]]; then
        logMe "ERROR: SwiftDialog banner image remains unavailable: ${SD_BANNER_IMAGE}" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        if ! /usr/local/bin/jamf policy -event "$JQ_INSTALL_POLICY"; then
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

function create_infobox_message ()
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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
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

    if [[ -z "$WALLPAPER_DIR" ]]; then
        # Change this line if you want to change the deafult location of your branding images
        WALLPAPER_DIR="${USER_DIR}/Pictures/"
    elif [[ "$WALLPAPER_DIR" == "~/"* ]]; then
        WALLPAPER_DIR="${USER_DIR}/${WALLPAPER_DIR#\~/}"
    fi

    BANNER_CROSS_REF_FILE="${WALLPAPER_DIR}/BannerCrossRef.csv"

    JAMF_LOGGED_IN_USER="${JAMF_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"

    return 0
}

function cleanup_files ()
{
    local tempFile=""

    (( ZSH_SUBSHELL == 0 )) || return 0
    [[ "$$" == "$MAIN_PID" ]] || return 0

    for tempFile in "${TEMP_FILES[@]}"; do
        [[ -n "$tempFile" && -e "$tempFile" ]] && rm -f -- "$tempFile"
    done

    [[ -d "${BANNER_LOCK_DIR:-}" ]] && rmdir "$BANNER_LOCK_DIR" 2>/dev/null

    if [[ -n "${api_token:-}" ]]; then
        Jamf_invalidate_token >/dev/null 2>&1
    fi
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - EXIT
    cleanup_files
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM
trap 'cleanup_files' EXIT

function check_for_sudo ()
{
	# Ensures that script is run as ROOT
    if ! admin_user; then
        print -u2 "ERROR: ${SCRIPT_NAME} must be run as root."
		cleanup_and_exit 1
	fi
}

function display_failure_message ()
{
    local errorMessage="${1:-An unknown error occurred.}"
    local buttonpress=0

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

function Jamf_check_credentials ()
{
    if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
        logMe "ERROR: Jamf client ID or client secret is missing." >&2
        return 1
    fi

    logMe "Valid credentials passed."
    return 0
}

function Jamf_check_connection ()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None

    if ! /usr/local/bin/jamf -checkjssconnection -retry 5; then
        logMe "Error: JSS connection not active."
        return 1
    fi
    logMe "JSS connection active!"
}

function Jamf_get_server ()
{
    if [[ -z "$JAMF_SERVER" ]]; then
        jamfpro_url=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url) || {
            logMe "ERROR: Unable to read Jamf Pro URL" >&2
            return 1
        }
        logMe "No server passed in, defaulting to: $jamfpro_url"
    else
        jamfpro_url="${JAMF_SERVER%/}"
        logMe "Jamf Pro server is: $jamfpro_url"
    fi
}

function Jamf_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local appPath=""

    appPath=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)

    if [[ -z "$appPath" || ! -e "$appPath" ]]; then
        appPath=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
    fi

    if [[ -n "$appPath" && -e "$appPath" ]]; then
        printf '%s\n' "$appPath"
    else
        printf '%s\n' "/System/Applications/App Store.app"
    fi
}

function Jamf_get_classic_api_token ()
{
    local response_file
    local http_status
    local curl_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create Classic token response file" >&2
        return 1
    }

    {
        http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' -X POST -u "${CLIENT_ID}:${CLIENT_SECRET}" -H "Accept: application/json" "${jamfpro_url}/api/v1/auth/token")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Classic token request failed, curl exit ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Classic token request returned HTTP ${http_status}" >&2
            return 1
        fi

        if ! jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Classic token response was not valid JSON" >&2
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic response did not contain a bearer token" >&2
            return 1
        fi

        api_token="$token"
        logMe "Classic bearer token successfully obtained."
        return 0

    } always {
        rm -f -- "$response_file"
    }
}

function Jamf_validate_token () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

    local http_status
    http_status=$(curl -sS --write-out '%{http_code}' --output /dev/null --request GET --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth") || return 1
    [[ "$http_status" == "200" ]]
}

function Jamf_get_access_token ()
{
    local response_file
    local http_status
    local curl_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create OAuth response file" >&2
        return 1
    }

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

        api_token="$token"
        logMe "OAuth access token successfully obtained."
        return 0
    } always {
        rm -f -- "$response_file"
    }
}

function Jamf_invalidate_token ()
{
    local returnval
    local curl_status

    if [[ -z "$api_token" ]]; then
        logMe "INFO: No Jamf token is available to invalidate."
        return 0
    fi
    returnval=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${api_token}" -X POST "${jamfpro_url}/api/v1/auth/invalidate-token")
    curl_status=$?

    if (( curl_status != 0 )); then
        logMe "ERROR: Token invalidation failed, curl exit ${curl_status}" >&2
        api_token=""
        return 1
    fi

    case "$returnval" in
        204)
            logMe "Token successfully invalidated"
            ;;

        401)
            logMe "Token already invalid"
            ;;

        *)
            logMe "ERROR: Unexpected token invalidation response: HTTP ${returnval}" >&2
            api_token=""
            return 1
            ;;
    esac

    api_token=""
    return 0
}

function Jamf_read_images ()
{
    local endpoint="$1"
    local response_file
    local http_status
    local curl_status


    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}_image_${endpoint}.XXXXXX") || {
        logMe "ERROR: Unable to create temporary response file" >&2
        return 1
    }
    chmod 644 "$response_file" || {
        logMe "ERROR: Unable to set readable permissions on ${response_file}." >&2
        rm -f -- "$response_file"
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: image/*" "${jamfpro_url%/}/api/v1/branding-images/download/${endpoint}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving ${endpoint}, exit code ${curl_status}" >&2
            rm -f -- "$response_file"
            return 1
        fi

        case "$http_status" in
            200)
                echo "$response_file"
                ;;

            401|403|404)
                logMe "ERROR: Unable to retrieve image ${endpoint}, HTTP ${http_status}." >&2
                [[ -s "$response_file" ]] && cat "$response_file" >&2
                rm -f -- "$response_file"
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected image response, HTTP ${http_status}." >&2
                [[ -s "$response_file" ]] && cat "$response_file" >&2
                rm -f -- "$response_file"
                return 1
                ;;
        esac
    }
}

function Jamf_read_branding ()
{
    local responseFile=""
    local httpStatus=""
    local curlStatus=0
    local brandingID=""

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}_branding_list.XXXXXX") || {
        logMe "ERROR: Unable to create branding-list response file." >&2
        return 1
    }

    chmod 600 "$responseFile" || {
        rm -f -- "$responseFile"
        return 1
    }

    {
        httpStatus=$(
            curl -sS -L -o "$responseFile" -w '%{http_code}' --connect-timeout 30 --max-time 120 -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
                --url "${jamfpro_url%/}/api/v1/self-service/branding/macos?page=0&page-size=100&sort=id%3Aasc" )
        curlStatus=$?

        if (( curlStatus != 0 )); then
            logMe "ERROR: Unable to retrieve branding records, curl exit ${curlStatus}." >&2
            return 1
        fi

        if [[ "$httpStatus" != "200" ]]; then
            logMe "ERROR: Branding lookup returned HTTP ${httpStatus}." >&2
            [[ -s "$responseFile" ]] && cat "$responseFile" >&2
            return 1
        fi

        if ! jq -e . "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Branding lookup returned invalid JSON." >&2
            return 1
        fi

        local resultCount=""

        resultCount=$(jq -er '.results | length' "$responseFile") || {
            logMe "ERROR: Unable to determine the branding record count." >&2
            return 1
        }

        if (( resultCount == 0 )); then
            logMe "ERROR: No macOS branding records were returned." >&2
            return 1
        fi

        if (( resultCount > 1 )); then
            logMe "ERROR: Multiple macOS branding records were returned; unable to safely determine the active record." >&2
            jq -r '.results[] | "ID=\(.id) Name=\(.brandingName // "")"' "$responseFile" >&2
            return 1
        fi
        brandingID=$(jq -er '.results[0].id | select(. != null) | tostring | select(length > 0)' "$responseFile") || {
            logMe "ERROR: No branding record ID was returned." >&2
            return 1
        }
        
        printf '%s\n' "$brandingID"
        return 0

    } always {
        rm -f -- "$responseFile"
    }
}

function Jamf_read_branding_details ()
{
    local endpoint="$1"
    local response_file
    local http_status
    local curl_status

    response_file="/var/tmp/${SCRIPT_NAME}_${endpoint}.XXXX"
    [[ -e "$response_file" ]] && rm -f -- "$response_file"
    response_file=$(mktemp "$response_file") || {
        logMe "ERROR: Unable to create temporary response file" >&2
        return 1
    }
    chmod 600 "$response_file" || {
    rm -f -- "$response_file"
    return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url%/}/api/v1/self-service/branding/macos/${endpoint}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving ${endpoint}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                cat "$response_file"
                ;;

            401)
                logMe "ERROR: Authentication failed retrieving ${endpoint}, HTTP 401" >&2
                cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege retrieving ${endpoint}, HTTP 403" >&2
                cat "$response_file" >&2
                return 1
                ;;

            404)
                logMe "ERROR: Resource not found: ${endpoint}, HTTP 404" >&2
                cat "$response_file" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response for ${endpoint}, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
        } always {
        rm -f -- "$response_file"
    }
}

function Jamf_write_branding ()
{
    local endpoint="$1"
    local jsonPayload="$2"
    local responseFile=""
    local httpStatus=""
    local curlStatus=0

    if [[ ! "$endpoint" =~ '^[0-9]+$' ]]; then
        logMe "ERROR: Invalid branding endpoint ID: ${endpoint}" >&2
        return 1
    fi

    if ! printf '%s' "$jsonPayload" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: Refusing to send invalid branding JSON." >&2
        return 1
    fi

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}_branding_write.XXXXXX") || {
        logMe "ERROR: Unable to create branding response file." >&2
        return 1
    }

    chmod 600 "$responseFile" || {
        rm -f -- "$responseFile"
        return 1
    }

    {
        httpStatus=$(curl -sS -L -o "$responseFile" -w '%{http_code}' --connect-timeout 30 --max-time 120 -H "Content-Type: application/json" -H "Authorization: Bearer ${api_token}" \
                --request PUT --url "${jamfpro_url%/}/api/v1/self-service/branding/macos/${endpoint}" -H "Accept: application/json" --data-binary "$jsonPayload" )
        curlStatus=$?

        if (( curlStatus != 0 )); then
            logMe "ERROR: Branding update failed with curl exit ${curlStatus}." >&2
            [[ -s "$responseFile" ]] && cat "$responseFile" >&2
            return 1
        fi

        case "$httpStatus" in
            200)
                logMe "Successfully updated branding ID ${endpoint}."
                return 0
                ;;
            401)
                logMe "ERROR: Authentication failed updating branding ID ${endpoint}, HTTP 401." >&2
                ;;
            403)
                logMe "ERROR: Insufficient privilege updating branding ID ${endpoint}, HTTP 403." >&2
                ;;
            404)
                logMe "ERROR: Branding ID ${endpoint} was not found, HTTP 404." >&2
                ;;
            *)
                logMe "ERROR: Branding update returned HTTP ${httpStatus}." >&2
                ;;
        esac

        [[ -s "$responseFile" ]] && cat "$responseFile" >&2
        return 1

    } always {
        rm -f -- "$responseFile"
    }
}

function Jamf_upload_branding_image ()
{
    local imagePath="${1:-}"
    local responseFile=""
    local httpStatus=""
    local curlStatus=0
    local response=""
    local imageURL=""
    local imageID=""

    [[ -z "$imagePath" || ! -f "$imagePath" ]] && {logMe "ERROR: Branding image does not exist: ${imagePath}" >&2; return 1; }

    [[ ! -r "$imagePath" ]] && {logMe "ERROR: Branding image is not readable: ${imagePath}" >&2; return 1;}

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}_upload.XXXXXX") || {
        logMe "ERROR: Unable to create upload response file." >&2
        return 1
    }

    chmod 600 "$responseFile" || {
        rm -f -- "$responseFile"
        logMe "ERROR: Unable to secure upload response file." >&2
        return 1
    }

    {
        logMe "Uploading branding image: ${imagePath:t}"

        # Do not manually specify Content-Type. curl generates the multipart boundary correctly when --form is used.

        httpStatus=$(curl -s -S -L --connect-timeout 30 --max-time 300 -o "$responseFile" -w '%{http_code}' \
            --request POST --url "${jamfpro_url%/}/api/self-service/branding/images" -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" --form "file=@${imagePath}" )

        curlStatus=$?

        if (( curlStatus != 0 )); then
            logMe "ERROR: Image upload failed with curl exit code ${curlStatus}." >&2
            [[ -s "$responseFile" ]] && cat "$responseFile" >&2
            return 1
        fi

        response=$(<"$responseFile")

        # Jamf documents HTTP 201 as a successful image upload.
        if [[ "$httpStatus" != "201" ]]; then
            logMe "ERROR: Image upload returned HTTP ${httpStatus}." >&2
            [[ -n "$response" ]] && logMe "Server response: ${response}" >&2
            return 1
        fi

        if [[ -n "$response" ]] &&
            ! printf '%s' "$response" | jq -e . >/dev/null 2>&1
        then
            logMe "ERROR: Upload succeeded, but the response was not valid JSON." >&2
            logMe "Server response: ${response}" >&2
            return 1
        fi

        # The response may contain a URL for the newly uploaded image.
        imageURL=$(printf '%s' "$response" | jq -r '.url // .href // .link // empty')

        # If the response URL ends with a numeric path component, use it as the ID.
        [[ "$imageURL" =~ '/([0-9]+)/?$' ]] && imageID="$match[1]"

        if [[ -z "$imageID" ]]; then
            logMe "ERROR: Upload response did not contain a recognizable image ID." >&2
            logMe "Server response: ${response}" >&2
            return 1
        fi

        [[ -n "$imageURL" ]] && logMe "Image URL: $imageURL"

        if [[ -n "$imageID" ]]; then
            logMe "Image ID: $imageID"
            REPLY="$imageID"
        elif [[ -n "$imageURL" ]]; then
            REPLY="$imageURL"
        else
            # Preserve the complete response if its format differs by Jamf version.
            REPLY="$response"
            [[ -n "$response" ]] && logMe "API response: $response"
        fi
        return 0

    } always {
        rm -f -- "$responseFile"
    }
}

######################################################
#
# Application functions (common)
#
######################################################

function initialize_dialog_options ()
{
    # Reset the array each time so options from a previous dialog
    # cannot carry over into the next dialog.
    helpmessage="### Self Service Banner Manager

This utility allows you to manage the branding displayed in Jamf Self Service and Self Service+.

### Available Actions

**View / Download Banner Images**
- Preview banner images currently stored on the Jamf Pro server.
- Download a banner image to your local banner repository.

**View / Change macOS Branding Text**
- View the active Self Service branding configuration.
- Modify sidebar and homepage text.
- Changes are written directly to the active Jamf branding record.

**Set / Upload Banner Images**
- Preview local banner images.
- Assign an existing Jamf image to Self Service.
- Automatically upload new images when no existing image ID is found.
- Updates the active branding record to use the selected banner.

**Populate Cross Reference List**
- Maintain a CSV file that maps banner filenames to Jamf image IDs.
- Existing mappings prevent duplicate image uploads.

Recommended banner size: **1500 x 320 pixels**

### Tips

- Banner filenames should be unique.
- Do not use commas in image filenames.
- Populate the Cross Reference list to avoid uploading duplicate images.
- Changes take effect immediately after the branding record is updated."

    MainDialogBody=(
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --subtitle "$BANNER_SUBTITLE"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "$SD_ICON_FILE"
        --overlayicon "$OVERLAY_ICON"
        --infobox "$SD_INFO_BOX_MSG"
        --infotext "$jamfpro_url"
        --helpmessage "$helpmessage"
        --ontop
        --moveable
        --quitkey 0
        --json
    )
}

function welcome_menu ()
{
    local message=""
    local buttonpress=0

    initialize_dialog_options

    # Display a welcome message with system info and instructions
    MainDialogBody+=(
        --message "$SD_DIALOG_GREETING ${SD_FIRST_NAME}!  This utility allows you to view or change several macOS Branding options. You can choose to preview / set branding images, change the branding text, or cross reference a list of images.<br><br>Local image directory:<br>${WALLPAPER_DIR}."
        --selecttitle "Banner Action:",radio --selectvalues "View / Download banner images from server, View / Change macOS Branding Text, Set / Upload banner images to server, Populate Cross Reference list"
        --width 800
        --height 520
        --button1text "Continue"
        --button2text "Quit"
        )

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" ) #)2>/dev/null )
    buttonpress=$?
    case "$buttonpress" in
        0)
            if ! BannerOption=$(printf '%s' "$message" | plutil -extract SelectedOption raw - 2>/dev/null); then
                logMe "ERROR: Unable to parse the selected banner action." >&2
                BannerOption="quit"
            fi
            ;;

        2)
            BannerOption="quit"
            ;;

        *)
            logMe "WARNING: Welcome dialog exited with code ${buttonpress}" >&2
            BannerOption="quit"
            ;;
    esac
    logMe "${BannerOption} was chosen"
}

###########################
#
# View / Download Banner Images functions
#
##########################

function welcome_read_images ()
{
    local imageFile=""
    local imageStart=1
    local counter=$imageStart
    local message=""
    local buttonpress=0
    local selectedIndex=""
    local imageNumber=""
    local wallpaperNamesString=""
    local destinationFile=""
    local -a wallpaperNames=()
    local -a imageIDs=()
    local -a imageFiles=()

    "${SW_DIALOG}" --notification --style banner --identifier "banner" --title "Retrieving Jamf Banner Images" --message "Please be patient" --button1text "Dismiss" >/dev/null 2>&1

    initialize_dialog_options

    message="Banner images ${imageStart} through ${BRANDING_IMAGES_DOWNLOADS} have been preloaded from the Jamf Pro server.  Use the chevrons to preview each banner.  "
    message+="If you want to retrieve a specific image, choose the image name from the list below and click on 'Retrieve' and it will be stored in $WALLPAPER_DIR"

    MainDialogBody+=(
        --message "$message"
        --width 1000
        --height 550
        --button1text "Retrieve"
        --button2text "Back"
        )

    while (( counter <= BRANDING_IMAGES_DOWNLOADS )); do
        if imageFile=$(Jamf_read_images "$counter"); then
            if [[ -f "$imageFile" ]]; then
                logMe "Banner image ${counter} found at: ${imageFile}"
                wallpaperNames+=("Jamf Banner Image #${counter}")
                imageIDs+=("$counter")
                imageFiles+=("$imageFile")

                MainDialogBody+=(--image "$imageFile" --imagecaption "Jamf Banner Image #${counter}")
            fi
        else
            logMe "Banner image ${counter} was not available."
        fi
        ((counter++))
    done
    
    wallpaperNamesString="${(j:,:)wallpaperNames}"

    MainDialogBody+=(--selecttitle "Choose a banner",dropdown,required --selectvalues "${wallpaperNamesString}")

    if (( ${#imageIDs[@]} == 0 )); then
        logMe "ERROR: No banner images were available in the requested range." >&2
        display_failure_message "No Jamf banner images were available in the requested range."
        return 1
    fi
    message=$("$SW_DIALOG" "${MainDialogBody[@]}" ) #)2>/dev/null )
    buttonpress=$?
    case "$buttonpress" in
        0) ;;
        2) remove_temp_images "${imageFiles[@]}"; return 0 ;;
        *) remove_temp_images "${imageFiles[@]}"; return 1 ;;
    esac

    selectedIndex=$(printf '%s' "$message" | jq -er '.SelectedIndex') || return 1
    imageNumber="${imageIDs[$(( selectedIndex + 1 ))]}"

    if ! imageFile=$(Jamf_read_images "$imageNumber"); then
        logMe "ERROR: Unable to download selected Jamf image ID ${imageNumber}." >&2
        remove_temp_images "${imageFiles[@]}"
        return 1
    fi

    if [[ ! -d "$WALLPAPER_DIR" ]]; then
        mkdir -p -- "$WALLPAPER_DIR" || {
            logMe "ERROR: Unable to create wallpaper directory: ${WALLPAPER_DIR}" >&2
            rm -f -- "$imageFile"
            remove_temp_images "${imageFiles[@]}"
            return 1
        }
    fi

    destinationFile="${WALLPAPER_DIR}/JAMF Banner Image #${imageNumber}.png"

    if ! mv -f -- "$imageFile" "$destinationFile"; then
        logMe "ERROR: Unable to save the downloaded image to ${destinationFile}." >&2
        rm -f -- "$imageFile"
        remove_temp_images "${imageFiles[@]}"
        return 1
    fi

    if ! /usr/sbin/chown "$USER_UID" "$destinationFile"; then
        logMe "WARNING: Unable to assign ${destinationFile} to ${LOGGED_IN_USER}." >&2
    fi

    chmod 600 "$destinationFile" || {
        logMe "WARNING: Unable to secure downloaded image ${destinationFile}." >&2
    }

    remove_temp_images "${imageFiles[@]}"
    logMe "Banner image ${imageNumber} retrieved and stored at: ${destinationFile}"
    return 0

}

function remove_temp_images ()
{
    local imageFile=""

    for imageFile in "$@"; do
        [[ -n "$imageFile" && -f "$imageFile" ]] && rm -f -- "$imageFile"
    done
}

###########################
#
# View / Change Branding functions
#
##########################

function welcome_read_branding_text ()
{
    local brandingName
    local brandingNameSecondary
    local brandingIconID
    local brandingHeaderImageID
    local brandingHeading
    local brandingSubheading
    local applicationName
    local ssBrandingId=2
    local brandingIconName=""
    local brandingHeaderImageName=""
    local message=""
    local buttonpress=0
    local json=""
    local brandingJSON=""
  

    # We need to determine what is the first branding ID ()
    if ! ssBrandingId=$(Jamf_read_branding); then
        logMe "Problems retrieving current branding info"
        display_failure_message "Unable to read branding information from Jamf Pro"
        return 1
    fi
    logMe "Found Banner ID# $ssBrandingId"

    json=$(Jamf_read_branding_details "$ssBrandingId") || {
        logMe "ERROR: Unable to read branding information from Jamf Pro" >&2
        display_failure_message "Unable to read branding information from Jamf Pro"
        return 1
    }
    # Extract the relevant branding information from the JSON response
    brandingName=$(printf '%s' "$json" | jq -r '.brandingName // ""')
    brandingNameSecondary=$(printf '%s' "$json" | jq -r '.brandingNameSecondary // ""')
    brandingIconID=$(printf '%s' "$json" | jq -r '.iconId // ""')
    brandingHeaderImageID=$(printf '%s' "$json" | jq -r '.brandingHeaderImageId // ""')
    brandingHeading=$(printf '%s' "$json" | jq -r '.homeHeading // ""')
    brandingSubheading=$(printf '%s' "$json" | jq -r '.homeSubheading // ""')
    # Extract the image names for the icon and header image using their IDs

    if [[ "$brandingIconID" =~ ^[0-9]+$ ]]; then
        if ! brandingIconName=$(Jamf_read_images "$brandingIconID"); then
            logMe "WARNING: Unable to retrieve branding icon ID ${brandingIconID}." >&2
            brandingIconName=""
        fi
    else
        logMe "WARNING: Branding record contains an invalid icon ID: ${brandingIconID}" >&2
        brandingIconName=""
    fi

    if [[ "$brandingHeaderImageID" =~ ^[0-9]+$ ]]; then
        if ! brandingHeaderImageName=$(Jamf_read_images "$brandingHeaderImageID"); then
            logMe "WARNING: Unable to retrieve branding header image ID ${brandingHeaderImageID}." >&2
            brandingHeaderImageName=""
        fi
    else
        logMe "WARNING: Branding record contains an invalid header image ID: ${brandingHeaderImageID}" >&2
        brandingHeaderImageName=""
    fi

    initialize_dialog_options

    MainDialogBody+=(
        --message "[INFO: Branding ID# $ssBrandingId].  Your current branding settings are shown below.  You can change the text from here and then click 'Submit' to save your changes.  Changes to the image can be made from the Main Menu."
        --textfield "Sidebar Heading",value="$brandingName",name=brandingName
        --textfield "Sidebar Subheading",value="$brandingNameSecondary",name=brandingNameSecondary
        --textfield "Homepage Heading",value="$brandingHeading",name=brandingHeading
        --textfield "Homepage Subheading",value="$brandingSubheading",name=brandingSubheading
        --button2text "Back"
        --button1text "Submit"
        --width 1000
        --height 700
    )
    [[ -f "$brandingIconName" ]] && MainDialogBody+=(--image "$brandingIconName" --imagecaption "Icon Image")
    [[ -f "$brandingHeaderImageName" ]] && MainDialogBody+=(--image "$brandingHeaderImageName" --imagecaption "Header Image")

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$? 
    case "$buttonpress" in
        0)
            ;;
        2)
            remove_temp_images "$brandingIconName" "$brandingHeaderImageName"
            return 0
            ;;
        *)
            logMe "WARNING: Branding dialog exited with code ${buttonpress}." >&2
            return 1
            ;;
    esac
    # Construct the revised JSON file and write it back out to the server
   
   if ! printf '%s' "$message" |
        jq -e 'type == "object" and has("brandingName") and has("brandingNameSecondary") and has("brandingHeading") and has("brandingSubheading")' >/dev/null 2>&1
    then
        logMe "ERROR: SwiftDialog did not return the expected branding fields." >&2
        logMe "SwiftDialog response: ${message}" >&2
        return 1
    fi

    applicationName=$(printf '%s' "$json" | jq -r '.applicationName // "Self Service+"')
    brandingName=$(printf '%s' "$message" | jq -r '.brandingName // ""')
    brandingNameSecondary=$(printf '%s' "$message" | jq -r '.brandingNameSecondary // ""')
    brandingHeading=$(printf '%s' "$message" | jq -r '.brandingHeading // ""')
    brandingSubheading=$(printf '%s' "$message" | jq -r '.brandingSubheading // ""')
    # Validate the JSON file
    if [[ ! "$brandingIconID" =~ '^[0-9]+$' || ! "$brandingHeaderImageID" =~ '^[0-9]+$' ]]; then
        logMe "ERROR: Branding record contains invalid image IDs." >&2
        return 1
    fi
    brandingJSON=$(
        jq -n \
            --arg applicationName "$applicationName" \
            --arg brandingName "$brandingName" \
            --arg brandingNameSecondary "$brandingNameSecondary" \
            --argjson iconId "$brandingIconID" \
            --argjson brandingHeaderImageId "$brandingHeaderImageID" \
            --arg homeHeading "$brandingHeading" \
            --arg homeSubheading "$brandingSubheading" \
            '{
                applicationName: $applicationName,
                brandingName: $brandingName,
                brandingNameSecondary: $brandingNameSecondary,
                iconId: $iconId,
                brandingHeaderImageId: $brandingHeaderImageId,
                homeHeading: $homeHeading,
                homeSubheading: $homeSubheading
            }'
    ) || {
            logMe "ERROR: Unable to construct updated branding JSON." >&2
            return 1
            }

    logMe "Writing out Banner ID# $ssBrandingId"
    # Write out the constructed JQ string back to the server.  This only udpates the text, not the icons
    if ! Jamf_write_branding "$ssBrandingId" "$brandingJSON"; then
        display_failure_message "Unable to update the Self Service branding text."
        return 1
    fi
    remove_temp_images "$brandingIconName" "$brandingHeaderImageName"
    return 0
}

###########################
#
# Set Banner Images functions
#
##########################

function welcome_set_images ()
{
    local message=""
    local buttonpress=0
    local selectedIndex=""
    local selectedWallpaperPath=""
    local wallpaperID=""
    local bannerName=""
    local ssBrandingId=""
    local json=""
    local brandingJSON=""
    local applicationName=""
    local brandingName=""
    local brandingNameSecondary=""
    local brandingIconID=""
    local brandingHeaderImageID=""
    local brandingHeading=""
    local brandingSubheading=""
    local lookupName=""

    if ! find_wallpapers; then
        display_failure_message "No banner images were found in ${WALLPAPER_DIR}."
        return 1
    fi

    initialize_dialog_options
    MainDialogBody+=(
        --message "Use the chevrons to preview each banner, then choose the matching banner name below. If the image can be cross-referenced to an existing upload, that Jamf image ID will be used. Otherwise, the image will be uploaded and added to the cross-reference file.<br><br>The recommended image dimensions are 1500 x 320 pixels. Copy banner images to:<br>${WALLPAPER_DIR}"
        --width 1020
        --height 630
        --button1text "Select Banner"
        --button2text "Back"
    )

    if ! load_in_crossref_banner; then
        logMe "INFO: No cross-reference data was loaded. Local images will be treated as new uploads."
        BannerLookup=()
    fi

    if ! process_for_display; then
        display_failure_message "No valid banner images were available for display."
        return 1
    fi

    if ! add_banner_selection_to_dialog; then
        display_failure_message "Unable to construct the banner selection list."
        return 1
    fi

    message=$("$SW_DIALOG" "${MainDialogBody[@]}")
    buttonpress=$?

    case "$buttonpress" in
        0)
            ;;
        2)
            logMe "Banner selection canceled."
            return 0
            ;;
        *)
            logMe "ERROR: Banner selection dialog exited with code ${buttonpress}." >&2
            return 1
            ;;
    esac

    if ! printf '%s' "$message" | jq -e 'type == "object" and (.SelectedIndex | type == "number") and (.SelectedOption | type == "string")' >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog returned invalid banner selection data." >&2
        logMe "SwiftDialog response: ${message}" >&2
        return 1
    fi

    selectedIndex=$(printf '%s' "$message" | jq -er '.SelectedIndex')
    #selectedOption=$(printf '%s' "$message" | jq -er '.SelectedOption')

    selectedWallpaperPath="${wallpaperPaths[$(( selectedIndex + 1 ))]-}"

    if [[ -z "$selectedWallpaperPath" || ! -f "$selectedWallpaperPath" ]]; then
        logMe "ERROR: Unable to map selection index ${selectedIndex} to a local banner file." >&2
        return 1
    fi


    # Extract an existing Jamf image ID from a selection such as:
    # GE_Summer_Banner (6)
    bannerName="${selectedWallpaperPath:t}"
    lookupName="${(L)bannerName}"
    wallpaperID="${BannerLookup[$lookupName]-}"

    if [[ -n "$wallpaperID" ]]; then
        logMe "Using existing Jamf image ID ${wallpaperID} for ${bannerName}."
    else
        logMe "No existing cross-reference was found for ${bannerName}. Uploading image."

        REPLY=""

        if ! Jamf_upload_branding_image "$selectedWallpaperPath"; then
            display_failure_message "Unable to upload ${bannerName}."
            return 1
        fi

        wallpaperID="$REPLY"

        if [[ ! "$wallpaperID" =~ '^[0-9]+$' ]]; then
            logMe "ERROR: Upload did not return a valid numeric Jamf image ID: ${wallpaperID}" >&2
            return 1
        fi

        if ! add_crossref_entry "$wallpaperID" "$bannerName"; then
            logMe "ERROR: Image ${bannerName} was uploaded as Jamf image ID ${wallpaperID}, but the CSV cross-reference could not be updated." >&2
            display_failure_message "The image was uploaded, but its cross-reference entry could not be saved."
            return 1
        fi
    fi

    if [[ ! "$wallpaperID" =~ '^[0-9]+$' ]]; then
        logMe "ERROR: Invalid selected Jamf image ID: ${wallpaperID}" >&2
        return 1
    fi

    if ! ssBrandingId=$(Jamf_read_branding); then
        logMe "ERROR: Unable to determine the active branding ID." >&2
        display_failure_message "Unable to read branding information from Jamf Pro."
        return 1
    fi

    if [[ ! "$ssBrandingId" =~ '^[0-9]+$' ]]; then
        logMe "ERROR: Invalid active branding ID returned: ${ssBrandingId}" >&2
        return 1
    fi

    logMe "Found active branding ID ${ssBrandingId}."

    json=$(Jamf_read_branding_details "$ssBrandingId") || {
        logMe "ERROR: Unable to read branding ID ${ssBrandingId}." >&2
        display_failure_message "Unable to read branding information from Jamf Pro."
        return 1
    }

    if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        logMe "ERROR: Branding details were not a valid JSON object." >&2
        return 1
    fi

    applicationName=$(printf '%s' "$json" | jq -r '.applicationName // "Self Service+"')
    brandingName=$(printf '%s' "$json" | jq -r '.brandingName // ""')
    brandingNameSecondary=$(printf '%s' "$json" | jq -r '.brandingNameSecondary // ""')
    brandingIconID=$(printf '%s' "$json" | jq -r '.iconId // ""')
    brandingHeaderImageID=$(printf '%s' "$json" | jq -r '.brandingHeaderImageId // ""')
    brandingHeading=$(printf '%s' "$json" | jq -r '.homeHeading // ""')
    brandingSubheading=$(printf '%s' "$json" | jq -r '.homeSubheading // ""')

    if [[ ! "$brandingIconID" =~ '^[0-9]+$' ]]; then
        logMe "ERROR: Branding record contains an invalid icon ID: ${brandingIconID}" >&2
        return 1
    fi

    logMe "Changing branding header image from ID ${brandingHeaderImageID:-unknown} to ID ${wallpaperID}."

    brandingJSON=$(
        jq -n \
            --arg applicationName "$applicationName" \
            --arg brandingName "$brandingName" \
            --arg brandingNameSecondary "$brandingNameSecondary" \
            --argjson iconId "$brandingIconID" \
            --argjson brandingHeaderImageId "$wallpaperID" \
            --arg homeHeading "$brandingHeading" \
            --arg homeSubheading "$brandingSubheading" \
            '{
                applicationName: $applicationName,
                brandingName: $brandingName,
                brandingNameSecondary: $brandingNameSecondary,
                iconId: $iconId,
                brandingHeaderImageId: $brandingHeaderImageId,
                homeHeading: $homeHeading,
                homeSubheading: $homeSubheading
            }'
    ) || {
        logMe "ERROR: Unable to construct updated branding JSON." >&2
        return 1
    }

    if ! Jamf_write_branding "$ssBrandingId" "$brandingJSON"; then
        display_failure_message "Unable to assign ${bannerName} to Self Service."
        return 1
    fi

    logMe "Successfully assigned ${bannerName}, Jamf image ID ${wallpaperID}, to branding ID ${ssBrandingId}."
    return 0
}

function find_wallpapers ()
{
    local file=""

    logMe "Scanning for banner images..."

    wallpaperFiles=()

    if [[ ! -d "$WALLPAPER_DIR" ]]; then
        logMe "ERROR: Wallpaper directory does not exist: ${WALLPAPER_DIR}" >&2
        return 1
    fi

    while IFS= read -r file; do
        wallpaperFiles+=("$file")
    done < <(find "$WALLPAPER_DIR" -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -print | sort )

    if (( ${#wallpaperFiles[@]} == 0 )); then
        logMe "ERROR: No banner image files were found in ${WALLPAPER_DIR}." >&2
        return 1
    fi

    logMe "Found ${#wallpaperFiles[@]} local banner image files."
    return 0
}

function process_for_display ()
{
    local wallpaperPath=""
    local baseName=""
    local wallpaperName=""
    local lookupName=""
    local bannerID=""
    local displayName=""

    wallpaperNames=()
    wallpaperPaths=()

    for wallpaperPath in "${wallpaperFiles[@]}"; do
        if [[ ! -f "$wallpaperPath" ]]; then
            logMe "WARNING: Banner file no longer exists: ${wallpaperPath}" >&2
            continue
        fi

        if [[ ! -r "$wallpaperPath" ]]; then
            logMe "WARNING: Banner file is not readable: ${wallpaperPath}" >&2
            continue
        fi

        # Full filename, including extension.
        baseName="${wallpaperPath:t}"

        # Filename without the final extension.
        wallpaperName="${baseName:r}"

        if [[ "$baseName" == *","* ]]; then
            logMe "WARNING: Skipping banner with comma in filename: ${baseName}" >&2
            continue
        fi

        # Cross-reference keys are stored in lowercase.
        lookupName="${(L)baseName}"

        # Retrieve the Jamf banner ID.
        bannerID="${BannerLookup[$lookupName]-}"

        if [[ -n "$bannerID" ]]; then
            displayName="${wallpaperName} (${bannerID})"
            logMe "Banner match: Name=[${baseName}] LookupKey=[${lookupName}] Jamf ID #[${bannerID}]"
        else
            displayName="$wallpaperName"
            logMe "No Banner ID found for lookup key [${lookupName}]"
        fi

        wallpaperNames+=("$displayName")
        wallpaperPaths+=("$wallpaperPath")

        MainDialogBody+=(
            --image "$wallpaperPath"
            --imagecaption "$displayName"
        )
    done

    if (( ${#wallpaperNames[@]} == 0 )); then
        logMe "ERROR: No valid banner images were available for display." >&2
        return 1
    fi

    return 0
}

function load_in_crossref_banner ()
{
    local BannerID=""
    local BannerName=""
    local lookupName=""
    local loadedCount=0

    BannerLookup=()

    if [[ ! -f "$BANNER_CROSS_REF_FILE" ]]; then
        logMe "WARNING: Banner cross-reference file does not exist: ${BANNER_CROSS_REF_FILE}" >&2
        return 1
    fi

    if [[ ! -r "$BANNER_CROSS_REF_FILE" ]]; then
        logMe "WARNING: Banner cross-reference file is not readable: ${BANNER_CROSS_REF_FILE}" >&2
        return 1
    fi

    while IFS=',' read -r BannerID BannerName || [[ -n "$BannerID$BannerName" ]]; do

        # Remove carriage returns that may exist in Windows-formatted CSV files.
        BannerID="${BannerID//$'\r'/}"
        BannerName="${BannerName//$'\r'/}"

        # Trim leading and trailing whitespace.
        BannerID="${${BannerID#"${BannerID%%[![:space:]]*}"}%"${BannerID##*[![:space:]]}"}"
        BannerName="${${BannerName#"${BannerName%%[![:space:]]*}"}%"${BannerName##*[![:space:]]}"}"

        # Remove optional surrounding quotes.
        BannerID="${BannerID#\"}"
        BannerID="${BannerID%\"}"
        BannerName="${BannerName#\"}"
        BannerName="${BannerName%\"}"

        if [[ -z "$BannerID" || -z "$BannerName" ]]; then
            logMe "WARNING: Skipping invalid banner cross-reference row."
            continue
        fi

        # Normalize the associative-array key to lowercase.
        lookupName="${(L)BannerName}"

        if [[ -n "${BannerLookup[$lookupName]-}" ]]; then
            logMe "WARNING: Duplicate banner name [${BannerName}]. Replacing Jamf ID #[${BannerLookup[$lookupName]}] with Jamf ID #[${BannerID}]."
        fi

        BannerLookup[$lookupName]="$BannerID"
        (( loadedCount++ ))

        logMe "Loaded cross-reference: Name=[${BannerName}] LookupKey=[${lookupName}] Jamf ID #[${BannerID}]"

    done < "$BANNER_CROSS_REF_FILE"

    logMe "Loaded ${loadedCount} banner cross-reference rows"
    logMe "Associative array contains ${#BannerLookup[@]} unique banner names"

    return 0
}

function add_banner_selection_to_dialog ()
{
    local wallpaperNamesString=""

    if (( ${#wallpaperNames[@]} == 0 )); then
        logMe "ERROR: No banner names are available for the selection list." >&2
        return 1
    fi

    wallpaperNamesString="${(j:,:)wallpaperNames}"
    MainDialogBody+=(--selecttitle "Choose a banner",dropdown,required --selectvalues "$wallpaperNamesString")
    return 0
}

###########################
#
# Populate Cross Reference functions
#
##########################

function welcome_crossreference ()
{
    local DDMCrossRef=""
    local message=""
    local retval=""
    local buttonpress=0
    local crossrefData=""

    DDMCrossRef=$(read_crossref_file)

    initialize_dialog_options

    message="Jamf only uses the ID number of the image.  You can create a CSV file that contains the Banner Name and the corresponding ID for each image. If you are using an existing image that is already on the server, the existing image will be used instead of uploading a brand new image.<br><br>"
    message+="You can locate a previously uploaded image by using the _Read Banner Images from Server_ option in the main menu.  The ID number will be displayed in the list of images.<br><br>"
    message+="1.  Enter the ID and name of your image separated by a comma (do not prefix with a path)<br>"
    message+="    _Example: 1, Summer Image.png_<br>"
    message+="2.  Make sure to put a return at the end of each line.<br>"
    message+="3.  The file will be saved here:<br><br>**$BANNER_CROSS_REF_FILE**<br>"
    MainDialogBody+=(
        --message "$message"
        --messagefont name=Arial,size=17
        --textfield "Banner Cross Reference",value="$DDMCrossRef,editor,required",name=crossref
        --button1text "Continue"
        --button2text "Back"
        --width 1000
        --height 740
    )
    retval=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    case "$buttonpress" in
        0)

            crossrefData=$(printf '%s' "$retval" | jq -er '.crossref') || {
                logMe "ERROR: Unable to parse the cross-reference editor contents." >&2
                return 1
            }

            write_crossref_file "$crossrefData"
            ;;

        2)
            logMe "Cross-reference editing canceled."
            return 0
            ;;

        *)
            logMe "WARNING: Welcome dialog exited with code ${buttonpress}" >&2
            BannerOption="quit"
            ;;
    esac

}

function read_crossref_file ()
{
    local CSV_CONTENT
    if [[ ! -f "$BANNER_CROSS_REF_FILE" ]]; then
        logMe "INFO: Cross-reference file does not exist yet; starting with an empty editor." >&2
        printf ''
        return 0
    fi
    # Read file, replace newlines with spaces to maintain single-line# then remove trailing spaces.
    CSV_CONTENT=$(cat "$BANNER_CROSS_REF_FILE") # | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    logMe "File '$BANNER_CROSS_REF_FILE' loaded into the editor" 1>&2
    printf '%s\n' "$CSV_CONTENT"
}

function write_crossref_file ()
{
    local inputData="${1:-}"
    local crossRefDir="${BANNER_CROSS_REF_FILE:h}"
    local tempFile=""
    local line=""
    local bannerID=""
    local bannerName=""
    local validCount=0

    if [[ ! -d "$crossRefDir" ]]; then
        mkdir -p -- "$crossRefDir" || {
            logMe "ERROR: Unable to create directory: ${crossRefDir}" >&2
            return 1
        }
    fi

    tempFile=$(mktemp "${crossRefDir}/.BannerCrossRef.XXXXXX") || {
        logMe "ERROR: Unable to create temporary cross-reference file." >&2
        return 1
    }

    {
        chmod 600 "$tempFile" || return 1

        for line in "${(f)inputData}"; do
            line="${line//$'\r'/}"

            [[ -z "${line//[[:space:]]/}" ]] && continue

            IFS=',' read -r bannerID bannerName <<< "$line"

            bannerID="${${bannerID#"${bannerID%%[![:space:]]*}"}%"${bannerID##*[![:space:]]}"}"
            bannerName="${${bannerName#"${bannerName%%[![:space:]]*}"}%"${bannerName##*[![:space:]]}"}"

            if [[ ! "$bannerID" =~ ^[0-9]+$ ]]; then
                logMe "ERROR: Invalid Jamf image ID in cross-reference row: ${line}" >&2
                return 1
            fi

            if [[ -z "$bannerName" || "$bannerName" == *","* ]]; then
                logMe "ERROR: Invalid banner filename in cross-reference row: ${line}" >&2
                return 1
            fi

            printf '%s,%s\n' "$bannerID" "$bannerName" >> "$tempFile" || return 1
            (( validCount++ ))
        done

        if (( validCount == 0 )); then
            logMe "ERROR: Refusing to replace the cross-reference file with no valid entries." >&2
            return 1
        fi

        /usr/sbin/chown "$USER_UID" "$tempFile" || {
            logMe "WARNING: Unable to assign temporary file ownership to ${LOGGED_IN_USER}." >&2
        }

        mv -f -- "$tempFile" "$BANNER_CROSS_REF_FILE" || {
            logMe "ERROR: Unable to replace ${BANNER_CROSS_REF_FILE}." >&2
            return 1
        }

        tempFile=""
        logMe "Contents written to: ${BANNER_CROSS_REF_FILE}" >&2
        return 0

    } always {
        [[ -n "$tempFile" && -e "$tempFile" ]] && rm -f -- "$tempFile"
    }
}

function add_crossref_entry ()
{
    local bannerID="${1:-}"
    local bannerName="${2:-}"
    local lookupKey=""
    local crossRefDir="${BANNER_CROSS_REF_FILE:h}"

    if [[ ! "$bannerID" =~ '^[0-9]+$' ]]; then
        logMe "ERROR: Invalid Jamf image ID for cross-reference: ${bannerID}" >&2
        return 1
    fi

    if [[ -z "$bannerName" ]]; then
        logMe "ERROR: Cannot add a cross-reference with an empty banner name." >&2
        return 1
    fi

    if [[ "$bannerName" == *","* ||
          "$bannerName" == *$'\n'* ||
          "$bannerName" == *$'\r'* ]]; then
        logMe "ERROR: Banner filename is not safe for the CSV: ${bannerName}" >&2
        return 1
    fi

    lookupKey="${(L)bannerName}"

    if [[ -n "${BannerLookup[$lookupKey]-}" ]]; then
        logMe "Cross-reference already exists for ${bannerName}: ${BannerLookup[$lookupKey]}"
        return 0
    fi

    if [[ ! -d "$crossRefDir" ]]; then
        mkdir -p -- "$crossRefDir" || {
            logMe "ERROR: Unable to create cross-reference directory: ${crossRefDir}" >&2
            return 1
        }
    fi

    if [[ ! -e "$BANNER_CROSS_REF_FILE" ]]; then
        touch "$BANNER_CROSS_REF_FILE" || {
            logMe "ERROR: Unable to create cross-reference file: ${BANNER_CROSS_REF_FILE}" >&2
            return 1
        }

        /usr/sbin/chown "$USER_UID" "$BANNER_CROSS_REF_FILE" || {
            logMe "WARNING: Unable to assign ownership of the cross-reference file to ${LOGGED_IN_USER}." >&2
        }

        chmod 600 "$BANNER_CROSS_REF_FILE" || {
            logMe "ERROR: Unable to secure cross-reference file: ${BANNER_CROSS_REF_FILE}" >&2
            return 1
        }
    fi

    if ! printf '%s,%s\n' "$bannerID" "$bannerName" >> "$BANNER_CROSS_REF_FILE"; then
        logMe "ERROR: Unable to append to cross-reference file: ${BANNER_CROSS_REF_FILE}" >&2
        return 1
    fi

    BannerLookup[$lookupKey]="$bannerID"

    logMe "Added cross-reference: ${bannerName} -> ${bannerID}"
    return 0
}
####################################################################################################
#
# Main Script
#
####################################################################################################

typeset -ga wallpaperNames
typeset -ga wallpaperPaths
typeset -g BannerOption
typeset -gA BannerLookup
typeset -ga MainDialogBody
typeset -ga wallpaperFiles

autoload -Uz is-at-least

check_for_sudo

if ! initialize_user_context; then
    cleanup_and_exit 0
fi

if ! create_log_directory; then
    cleanup_and_exit 1
fi

if ! check_swift_dialog_install; then
    cleanup_and_exit 1
fi

if ! check_support_files; then
    cleanup_and_exit 1
fi

create_infobox_message

if ! Jamf_check_connection; then
    cleanup_and_exit 1
fi

if ! Jamf_check_credentials; then
    cleanup_and_exit 1
fi

if ! Jamf_get_server; then
    cleanup_and_exit 1
fi
OVERLAY_ICON=$(Jamf_which_self_service)

create_infobox_message


while true; do
    welcome_menu
    [[ "$BannerOption" == "quit" ]] && cleanup_and_exit 0

    if [[ "$BannerOption" == *"Populate"* ]]; then
        welcome_crossreference
        continue
    fi
    # Check if the Jamf Pro server is using the new API or the classic API
    # If the client ID is longer than 30 characters, then it is using the new API

    case "$JAMF_TOKEN" in
        new)
            if ! Jamf_get_access_token; then
                display_failure_message "Unable to obtain a Jamf OAuth access token."
                continue
            fi
            ;;

        classic)
            if ! Jamf_get_classic_api_token; then
                display_failure_message "Unable to obtain a Jamf bearer token."
                continue
            fi
            ;;

        *)
            logMe "ERROR: Unknown Jamf authentication mode: ${JAMF_TOKEN}" >&2
            display_failure_message "The Jamf authentication mode is invalid."
            continue
            ;;
    esac

    typeset -i operation_status=0

    case "$BannerOption" in

        *"View / Download"*) welcome_read_images || operation_status=$? ;;
        *"macOS Branding"*)   welcome_read_branding_text || operation_status=$? ;;
        *"Set / Upload"*)    welcome_set_images || operation_status=$? ;;
        *)
            logMe "ERROR: Invalid option selected: ${BannerOption}" >&2
            cleanup_and_exit 1
            ;;
    esac

    if ! Jamf_invalidate_token; then
        logMe "WARNING: Unable to invalidate the Jamf token" >&2
    fi

    if (( operation_status != 0 )); then
        logMe "WARNING: Selected operation ended with status ${operation_status}" >&2
    fi
done
