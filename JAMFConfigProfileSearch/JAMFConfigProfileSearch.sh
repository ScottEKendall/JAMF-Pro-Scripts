#!/bin/zsh
#
# JAMFConfigProfileSearch
#
# by: Scott Kendall
#
# Written: 10/16/2025
# Last updated: 10/26/2026
#
# Script Purpose: Search for strings inside all Configuration Profiles
#
# 1.0 - Initial
# 1.1 - Add function to make sure Client / Secret are passed into the script
# 1.2 - Made grep search case insenstive
#       Added option to read in config variables from a .plist file if exists
# 1.3 - Changed JAMF 'policy -trigger' to JAMF 'policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Hardened Jamf Pro API communication and error handling
#       Added centralized curl argument handling with connection and request timeouts
#       Added HTTP response, JSON/XML, and empty-response validation
#       Improved OAuth and Classic API token handling, expiration tracking, and cleanup
#       Converted Configuration Profile retrieval and processing to JSON
#       Added secured temporary files and centralized cleanup handling
#       Added parallel Configuration Profile processing with controlled worker limits
#       Added serialized SwiftDialog command-file updates for parallel workers
#       Improved SwiftDialog startup, readiness checks, progress updates, and error handling
#       Changed profile searches to case-insensitive literal-text matching
#       Improved validation, logging, and failure handling throughout the script

######################################################################################################
#
# Global "Common" variables (do not change these!)
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="JAMFConfigProfileSearch"

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | grep "Free Space" | awk '{print $6}' | cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

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

SUPPORT_DIR="${SUPPORT_DIR%/}"

if [[ "${SD_BANNER_IMAGE#/SupportFiles/}" != "$SD_BANNER_IMAGE" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE#/}"
elif [[ "${SD_BANNER_IMAGE:0:1}" != "/" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
fi

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="JAMF Config Profile Search"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

BACKGROUND_TASKS=20                 # Number of background tasks to run in parallel
#EMAIL_APP='com.microsoft.outlook'   # Use the bundle identifier of your email app. you can find it by this command "osascript -e 'id of app "<appname>"' "

####################
#
# JAMF API Keys Used
#
####################

JAMF_API_KEY="JSSResource/osxconfigurationprofiles"

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
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}" >&2
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

    if [[ -n "${DIALOG_PROCESS:-}" ]] && kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
        write_dialog_command "quit:" 2>/dev/null
    fi

    if [[ -n "${api_token:-}" ]]; then
        if ! JAMF_invalidate_token; then
            logMe "WARNING: Unable to invalidate the Jamf Pro API token."
        fi
    fi

    [[ -n "${JSON_DIALOG_BLOB:-}" ]] && rm -f -- "$JSON_DIALOG_BLOB"
    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && rm -f -- "$DIALOG_COMMAND_FILE"
    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && rm -rf -- "${DIALOG_COMMAND_FILE}.lock"

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
        rm -f -- "$JSON_DIALOG_BLOB"
        JSON_DIALOG_BLOB=""
        return 1
    }

    if ! /usr/sbin/chown "$USER_UID" \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"; then

        logMe "ERROR: Unable to set temporary dialog-file ownership."

        rm -f -- \
            "$JSON_DIALOG_BLOB" \
            "$DIALOG_COMMAND_FILE"

        JSON_DIALOG_BLOB=""
        DIALOG_COMMAND_FILE=""

        return 1
    fi


    if ! chmod 600 \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"; then

        logMe "ERROR: Unable to secure temporary dialog files."

        rm -f -- \
            "$JSON_DIALOG_BLOB" \
            "$DIALOG_COMMAND_FILE"

        JSON_DIALOG_BLOB=""
        DIALOG_COMMAND_FILE=""
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
        --arg button1Text "$button1Text" \
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

    if ! write_dialog_command "progresstext: Preparing configuration profile list..."; then
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
        if ! JAMF_SERVER=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null); then
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
    if ! chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure OAuth token response file."
        rm -f -- "$response_file"
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
    local error_message=""
    local -a curlArgs

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.classic-token.XXXXX") || {
        logMe "ERROR: Unable to create Classic API token response file."
        return 1
    }

    if ! chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure Classic API token response file."
        rm -f -- "$response_file"
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
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v1/auth/token")
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
                    head -c 500 "$response_file" >&2
                    printf '\n' >&2
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
        rm -f -- "$response_file"
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

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.invalidate.XXXXX") || {
        logMe "ERROR: Unable to create token-invalidation response file."
        return 1
    }

    if ! chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure token-invalidation response file."
        rm -f -- "$response_file"
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
        rm -f -- "$response_file"
    }
}

function JAMF_which_self_service ()
{
    local app_path=""
    app_path=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)

    [[ -z "$app_path" ]] && app_path=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
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
    normalized_date=$(print -r -- "$normalized_date" | sed -E 's/\.([0-9]+)([+-][0-9]{4})$/\2/; s/\.([0-9]+)$//')
    normalized_date="${normalized_date#"${normalized_date%%[![:space:]]*}"}"
    normalized_date="${normalized_date%"${normalized_date##*[![:space:]]}"}"

    if parsed_date=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(date -j -f "%Y-%m-%d %H:%M:%S%z" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(date -j -f "%Y-%m-%d %H:%M:%S" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    if parsed_date=$(date -j -f "%Y-%m-%d" "$normalized_date" "$output_format" 2>/dev/null); then
        print -r -- "$parsed_date"
        return 0
    fi

    return 1
}

function JAMF_retrieve_data_blob ()
{
    # PURPOSE:
    #   Retrieve data from a Jamf Pro API endpoint using the current
    #   bearer token.
    #
    # PARAMETERS:
    #   $1 = API endpoint
    #   $2 = Response format: json or xml
    #
    # RETURN:
    #   Response body written to stdout
    #
    # RETURNS:
    #   0 = Success
    #   1 = Failure

    local api_endpoint="${1:-}"
    local format="${2:-json}"
    local response_file=""
    local http_status=""
    local curl_status=0
    local error_message=""
    local -a curlArgs

    if [[ -z "$api_endpoint" ]]; then
        logMe "ERROR: No Jamf Pro API endpoint was provided."
        return 1
    fi

    case "${format:l}" in
        json|xml)
            format="${format:l}"
            ;;
        *)
            logMe "ERROR: Unsupported API response format: ${format}"
            return 1
            ;;
    esac

    if [[ -z "${api_token:-}" ]]; then
        logMe "ERROR: No Jamf Pro API token is available."
        return 1
    fi

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.api.XXXXX") || {
        logMe "ERROR: Unable to create Jamf Pro API response file."
        return 1
    }

    if ! chmod 600 "$response_file"; then
        logMe "ERROR: Unable to secure Jamf Pro API response file."
        rm -f -- "$response_file"
        return 1
    fi

    {
        JAMF_build_curl_args "$response_file"
        curlArgs=("${CURL_ARGS[@]}")

        curlArgs+=(
            --write-out "%{http_code}"
            --request GET
            --header "Authorization: Bearer ${api_token}"
            --header "Accept: application/${format}"
        )

        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/${api_endpoint#/}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Jamf Pro API request failed for ${api_endpoint}. curl exit code: ${curl_status}"
            return 1
        fi

        case "$http_status" in
            2??)
                ;;
            *)
                logMe "ERROR: Jamf Pro API request failed for ${api_endpoint}. HTTP status: ${http_status}"

                if [[ -s "$response_file" ]]; then
                    if jq -e . "$response_file" >/dev/null 2>&1; then
                        error_message=$(jq -r '.errors[0].description //.errors[0].message //.message //.error_description //.error //empty' "$response_file" 2>/dev/null)
                        [[ -n "$error_message" ]] && logMe "Jamf error: ${error_message}"
                    fi
                fi

                return 1
                ;;
        esac

        if [[ ! -s "$response_file" ]]; then
            logMe "ERROR: Jamf Pro returned an empty response for ${api_endpoint}."
            return 1
        fi

        case "$format" in
            json)
                if ! jq -e . "$response_file" >/dev/null 2>&1; then
                    logMe "ERROR: Jamf Pro returned invalid JSON for ${api_endpoint}."
                    return 1
                fi
                ;;

            xml)
                if ! xmllint --noout "$response_file" 2>/dev/null; then
                    logMe "ERROR: Jamf Pro returned invalid XML for ${api_endpoint}."
                    return 1
                fi
                ;;
        esac

        cat "$response_file"
        return 0

    } always {
        rm -f -- "$response_file"
    }
}

###############################################
#
# Configuration Profile Search functions
#
###############################################


function retrieve_configuration_profiles ()
{
    # PURPOSE:
    #   Retrieve all Jamf Pro configuration profiles, populate the
    #   SwiftDialog list, and scan each profile in parallel.
    #
    # RETURN:
    #   0 = Success
    #   1 = Failure
    #
    # EXPECTED:
    #   JAMF_API_KEY
    #   BACKGROUND_TASKS
    #   searchString

    local profileList=""
    local filteredProfiles=""
    local profileCount=0
    local -a profileIDs

    logMe "Examining configuration profiles."

    #
    # Retrieve configuration profile summary
    #
    if ! profileList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve configuration profiles."
        return 1
    fi

    #
    # Validate returned JSON
    #
    if ! print -r -- "$profileList" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: Invalid JSON returned while retrieving configuration profiles."
        return 1
    fi

    #
    # Create a filtered profile dataset containing only profiles
    # with a valid numeric ID and non-empty name.
    #
    # This same dataset is used for both the worker ID list and
    # SwiftDialog list so their indexes remain aligned.
    #
    if ! filteredProfiles=$(
        print -r -- "$profileList" | jq -c '
            {
                os_x_configuration_profiles: [
                    .os_x_configuration_profiles[]?
                    | select(
                        (.id | type) == "number"
                        and
                        (.name | type) == "string"
                        and
                        (.name | length) > 0
                    )
                ]
            }
        '); then
        logMe "ERROR: Unable to prepare configuration profile data."
        return 1
    fi

    #
    # Extract profile IDs from the same filtered dataset that will
    # be used to create the SwiftDialog list.
    #
    profileIDs=("${(@f)$(print -r -- "$filteredProfiles" | jq -r '.os_x_configuration_profiles[].id')}")

    profileCount=${#profileIDs[@]}

    if (( profileCount == 0 )); then
        logMe "No valid configuration profiles were returned by Jamf Pro."
        return 1
    fi

    logMe "Found ${profileCount} configuration profiles to examine."

    #
    # Create and display the SwiftDialog list using the same
    # filtered profile dataset used to create profileIDs.
    #
    if ! create_listitem_list "The following configuration profiles are being examined for your search key: **${searchString}**" "json" \
        ".os_x_configuration_profiles[].name" "$filteredProfiles" "SF=gear.circle.fill,color=brown"
    then
        logMe "ERROR: Unable to create the configuration profile display list."
        return 1
    fi

    #
    # Scan configuration profiles in parallel.
    #
    if ! execute_in_parallel "$BACKGROUND_TASKS" "${profileIDs[@]}"; then
        logMe "ERROR: One or more configuration profiles could not be processed."
        return 1
    fi

    #
    # Complete the SwiftDialog progress display
    #
    if ! update_display_list "progress" "" "" "Finished Scanning" "100"; then
        logMe "WARNING: Unable to complete the SwiftDialog progress display."
    fi

    if ! update_display_list "buttonenable"; then
        logMe "WARNING: Unable to enable the SwiftDialog completion button."
    fi

    logMe "Finished examining ${profileCount} configuration profiles."

    if [[ -n "${DIALOG_PROCESS:-}" ]] &&
        kill -0 "$DIALOG_PROCESS" 2>/dev/null; then
        wait "$DIALOG_PROCESS" 2>/dev/null
    fi

    return 0
}
function extract_profile_details ()
{
    local profileID="${1:-}"
    local profileIndex="${2:-}"
    local profileJSON=""
    local profileName=""
    local profileContents=""

    [[ -n "$profileID" ]] || return 1
    [[ "$profileIndex" == <-> ]] || return 1

    if ! profileJSON=$(JAMF_retrieve_data_blob "${JAMF_API_KEY}/id/${profileID}" "json"); then
        logMe "ERROR: Unable to retrieve configuration profile ID ${profileID}."
        update_display_list "update" "$profileIndex" "Unable to retrieve profile" "fail" || logMe "WARNING: Unable to update SwiftDialog for profile ID ${profileID}."
        return 1
    fi

    if ! profileName=$(print -r -- "$profileJSON" | jq -er '.os_x_configuration_profile.general.name | strings | select(length > 0)'); then
        logMe "ERROR: Configuration profile ID ${profileID} did not contain a valid profile name."
        update_display_list "update" "$profileIndex" "Invalid profile data" "fail"
        return 1
    fi

    if ! profileContents=$(print -r -- "$profileJSON" | jq -er '.os_x_configuration_profile.general.payloads | strings | select(length > 0)'); then
        if ! update_display_list "update" "$profileIndex" "Not exported!" "pending"; then
            logMe "ERROR: Unable to update SwiftDialog for profile ${profileName}."
            return 1
        fi

        logMe "Profile ${profileName:-$profileID} was returned without exported payload contents."
        return 0
    fi


    if ! update_display_list "update" "$profileIndex" "Working..." "wait"; then
        logMe "ERROR: Unable to update SwiftDialog for profile ${profileName}."
        return 1
    fi

    if print -r -- "$profileContents" | grep -Fqi -- "$searchString"; then
        logMe "Found search string in: ${profileName}"

        if ! update_display_list "update" "$profileIndex" "Found!" "success"; then
            logMe "ERROR: Unable to update SwiftDialog for profile ${profileName}."
            return 1
        fi
    else
        logMe "Not found in: ${profileName}"

        if ! update_display_list "update" "$profileIndex" "Not Found" "pending"; then
            logMe "ERROR: Unable to update SwiftDialog for profile ${profileName}."
            return 1
        fi
    fi
    return 0
}

function welcomemsg ()
{
    local message=""
    local temp=""
    local returnCode=0
    local -a MainDialogBody
    message="Enter your criteria below to search thru all of your Configuration Profiles.  Searches are not case sensitive.  Results will be displayed on the next screen."


	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --ontop
        --moveable
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --helpmessage "$HELP_MESSAGE"
        --infobox "${SD_INFO_BOX_MSG}"
        --infotext "${jamfpro_url}"
        --textfield "Search string",required,name=searchstring
        --width 820
        --height 480
        --ignorednd
        --json
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")


    temp=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    case "$returnCode" in
        0)
            ;;
        2)
            cleanup_and_exit 0
            ;;
        *)
            logMe "ERROR: Search dialog exited with return code ${returnCode}."
            return 1
            ;;
    esac
    if ! searchString=$(print -r -- "$temp" | jq -er '.searchstring | strings | gsub("^\\s+|\\s+$"; "") | select(length > 0)'); then
        logMe "ERROR: No valid search string was provided."
        return 1
    fi
    return 0
}

function execute_in_parallel ()
{
    # PURPOSE:
    #   Process configuration profiles in parallel while limiting
    #   the number of concurrent workers.
    #
    # PARAMETERS:
    #   $1      = Maximum concurrent jobs
    #   $2...$n = Configuration profile IDs
    #
    # RETURNS:
    #   0 = All profile tasks succeeded
    #   1 = One or more profile tasks failed

    local -i max_jobs="${1:-1}"
    local -i failure_count=0
    local -i profile_index=0
    local profileID=""
    local pid=""
    local -a pids

    shift

    if (( max_jobs < 1 )); then
        logMe "ERROR: Invalid parallel-job limit: ${max_jobs}"
        return 1
    fi

    for profileID in "$@"; do

        extract_profile_details "$profileID" "$profile_index" &
        pids+=("$!")

        (( profile_index++ ))

        #
        # Once the worker limit is reached, wait for the current
        # batch to finish before starting another batch.
        #
        if (( ${#pids[@]} >= max_jobs )); then

            for pid in "${pids[@]}"; do
                if ! wait "$pid"; then
                    (( failure_count++ ))
                fi
            done

            pids=()
        fi
    done

    #
    # Wait for any remaining workers.
    #
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            (( failure_count++ ))
        fi
    done

    if (( failure_count > 0 )); then
        logMe "ERROR: ${failure_count} parallel configuration-profile task(s) failed."
        return 1
    fi

    return 0
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload -Uz is-at-least
zmodload zsh/datetime

HELP_MESSAGE="Enter a word, phrase, identifier, or value to search across all Jamf Pro Configuration Profiles.<br><br>The search is not case-sensitive and treats your entry as literal text. \
<br><br>Profiles containing the search text will display **Found!** when the scan is complete.<br><br>**Not exported!** indicates that Jamf Pro did not return exported payload content for that profile."

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
retrieve_configuration_profiles || cleanup_and_exit 1
cleanup_and_exit 0