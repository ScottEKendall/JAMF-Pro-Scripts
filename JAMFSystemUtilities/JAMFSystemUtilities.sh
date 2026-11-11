#!/bin/zsh
#
# JAMFSystemUtilities
#
# by: Scott Kendall
#
# Written: 06/03/2025
# Last updated: 11/11/2026
#
# Script Purpose:
#   Provide an interactive SwiftDialog-based utility for exporting,
#   backing up, inspecting, and comparing Jamf Pro objects and data.
#
#   Supported operations include:
#     - Computer Policies
#     - Computer Extension Attributes
#     - Configuration Profiles
#     - Smart and Static Computer Groups
#     - Failed MDM commands
#     - Configuration Profile comparison
#     - VCF contact cards and email recipient lists
#     - Application Usage
#     - Users assigned to multiple computers
#     - Self Service icons
#     - Jamf Pro scripts
#
# 1.0 - Initial
# 2.0 - Added options to export Smart /Static groups, 
#       export VCF cards for specific groups
#       send email to specific groups
#       added support for JAMF Pro OAuth API
# 2.1 - Added variable EMAIL_APP to allow users to choose which email app to use (have to use the bundle identifier)
# 2.2 - Added option to export Application Usage
# 2.3 - Fixed error logged and stored the error log in working directory
# 2.4 - Fixed a typo in line #1233..changed "frst" to "first"
#     - Delete the error log from previous runs before script starts
#     - Changed checkbox style to switch so the list is now scrollable
#     - Better error log report during failures
# 2.5 - used modern API for computer EAs
# 2.6 - Added option for export of multiple users per system
#     - Added option for export of Computer Policie
# 2.7 - Added option to compare two configuration profiles
# 2.8 - Changed variable declarations around for better readability
# 2.9 - Verified working agains JAMF API 11.20
#       Added option to detect which SS/SS+ we are using and grab the appropriate icon
#       Now works with JAMF Client/Secret or Username/password authentication
#       Change variable local section around for better readability
#       Bumped Swift Dialog to v2.5.0
#       Increased API search pages results from 100 to 1000
# 2.10- Added better error handling and display of error messages to the user.
#       Had to increase window height for Tahoe & SD v3.0
#       Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Added option to read in the defaults file
#       Fixed function to check which SS/SS+ is being used (again)
# 2.11- Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 3.0 - Migrated Jamf API retrieval and evaluation workflows from mixed XML parsing to JSON and jq.
#       Added complete computer-inventory pagination for workflows that process inventory-wide data.
#       Added support for retrieving all inventory pages and validating the combined result against Jamf totalCount.
#       Updated Failed MDM processing to use stable Jamf computer IDs instead of computer names.
#       Reworked Failed MDM evaluation to count actual failed-command objects and avoid false positives from empty containers.
#       Added JSON-based exports for Computer Policies, Computer Extension Attributes, Computer Groups, Application Usage,
#       Jamf users, and Self Service policy metadata.
#       Retained XML processing only for embedded Configuration Profile payloads and deployable .mobileconfig output.
#       Added bounded parallel execution with worker failure propagation to the final application exit status.
#       Added shared curl arguments, transport retries, timeout handling, HTTP-status validation, and conditional support for curl --retry-all-errors.
#       Added a dedicated Extension Attribute concurrency setting.
#       Hardened temporary-file creation, permissions, cleanup, JSON validation, and output-file validation.
#       Hardened SwiftDialog JSON construction by encoding dynamic values with jq and validating completed dialog documents.
#       Reworked group-based VCF exports to resolve and deduplicate Jamf users before starting parallel exports.
#       Added locked concurrent writes for exported email recipient lists.
#       Improved Smart Group criteria and Static Group member exports by processing each JSON object directly instead of maintaining parallel shell arrays.
#       Improved final reporting so processed-item counts and generated file counts are reported accurately for workflows where they are not one-to-one.
#       Improved token acquisition, expiration validation, renewal, invalidation, and cleanup for OAuth and user-account authentication.

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="JAMFSystemUtilities"
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

SD_WINDOW_TITLE="JAMF System Admin Tools"
OVERLAY_ICON=""
SD_ICON_FILE="https://i0.wp.com/macmule.com/wp-content/uploads/2020/08/2062092.png?resize=256%2C256&ssl=1"

# Trigger installs for Images & icons
# Create a policy in JAMF that will install the necessary files and make sure to given it a custom name that matches this trigger name

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
JQ_INSTALL_POLICY="install_jq"

BACKGROUND_TASKS=20                 # Number of background tasks to run in parallel
EA_BACKGROUND_TASKS=8
EMAIL_APP='com.microsoft.outlook'   # Use the bundle identifier of your email app. you can find it by this command "osascript -e 'id of app "<appname>"' "

##################################################
#
# Passed in variables
# 
#################################################               

JAMF_PARAMETER_USER="${3:-}"    #If run from JAMF, this will be the logged in user. If run from terminal, this will be empty (and will use the logged in user)
CLIENT_ID="${4:-}"              #Client ID for JAMF API authentication (if using Client ID/Secret)
CLIENT_SECRET="${5:-}"          #Client Secret for JAMF API authentication (if using Client ID/Secret)
JAMF_SERVER="${6:-}"            #Override the JAMF server URL if needed (if not passed, will use the defaults file or the local JAMF binary to determine the server URL)

# Determine which Jamf API authentication method is being used.
CLIENT_ID_REGEX='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
[[ "$CLIENT_ID" =~ ${CLIENT_ID_REGEX} ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" 

CURL_SUPPORTS_RETRY_ALL_ERRORS="false"

if /usr/bin/curl --help all 2>/dev/null |
    /usr/bin/grep -q -- '--retry-all-errors'
then
    CURL_SUPPORTS_RETRY_ALL_ERRORS="true"
fi


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
    # PURPOSE:
    #   Ensure the log directory and log file exist and have
    #   appropriate permissions.

    local LOG_DIR="${LOG_FILE%/*}"

    #
    # Logging to disk is only required when running as root.
    #

    admin_user || return 0

    if [[ -z "$LOG_DIR" || "$LOG_DIR" == "$LOG_FILE" ]]; then
        print -u2 -r -- "ERROR: Unable to determine log directory from: ${LOG_FILE}"
        return 1
    fi

    #
    # Create the log directory when necessary.
    #

    if [[ ! -d "$LOG_DIR" ]]; then
        if ! /bin/mkdir -p "$LOG_DIR"; then
            print -u2 -r -- "ERROR: Unable to create log directory: ${LOG_DIR}"
            return 1
        fi
    fi

    #
    # Set directory permissions.
    #

    if ! /bin/chmod 755 "$LOG_DIR"; then
        print -u2 -r -- "ERROR: Unable to set permissions on log directory: ${LOG_DIR}"
        return 1
    fi

    #
    # Create the log file when necessary.
    #

    if [[ ! -f "$LOG_FILE" ]]; then
        if ! /usr/bin/touch "$LOG_FILE"; then
            print -u2 -r -- "ERROR: Unable to create log file: ${LOG_FILE}"
            return 1
        fi
    fi

    #
    # Restrict the log file itself.
    #

    if ! /bin/chmod 640 "$LOG_FILE"; then
        print -u2 -r -- "ERROR: Unable to secure log file: ${LOG_FILE}"
        return 1
    fi

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

        if ! /usr/local/bin/jamf policy -event "$JQ_INSTALL_POLICY"; then
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

function make_temp_files ()
{
    JSON_DIALOG_BLOB=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog JSON file."
        return 1
    }

    DIALOG_COMMAND_FILE=$(
        /usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX") || {
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

function write_dialog_command ()
{
    # PURPOSE:
    #   Serialize and throttle writes to the SwiftDialog command file.
    #
    # PARAMETERS:
    #   $@ = One or more complete SwiftDialog commands

    local lockDirectory="${DIALOG_COMMAND_FILE}.lock"
    local command=""
    local -i attempts=0
    local -i maxAttempts=500
    local writeStatus=0

    if [[ -z "${DIALOG_COMMAND_FILE:-}" ]]; then
        logMe "ERROR: SwiftDialog command file is not defined."
        return 1
    fi

    if [[ ! -e "$DIALOG_COMMAND_FILE" ]]; then
        logMe "ERROR: SwiftDialog command file does not exist: ${DIALOG_COMMAND_FILE}"
        return 1
    fi

    #
    # Wait up to approximately 10 seconds for the command lock.
    #

    while ! /bin/mkdir "$lockDirectory" 2>/dev/null; do
        (( attempts++ ))

        if (( attempts >= maxAttempts )); then
            logMe "ERROR: Timed out waiting for the SwiftDialog command-file lock."

            #
            # Remove a potentially stale lock and fail this update.
            #

            /bin/rm -rf -- "$lockDirectory"
            return 1
        fi

        /bin/sleep 0.02
    done

    {
        for command in "$@"; do
            [[ -z "$command" ]] && continue

            if ! printf '%s\n' "$command"; then
                writeStatus=1
                break
            fi
        done
    } >> "$DIALOG_COMMAND_FILE"

    #
    # Hold the lock briefly after writing so another worker cannot
    # submit a table update while SwiftDialog is still processing
    # the preceding command.
    #

    /bin/sleep 0.05

    /bin/rmdir "$lockDirectory" 2>/dev/null || /bin/rm -rf -- "$lockDirectory"

    if (( writeStatus != 0 )); then
        logMe "ERROR: Unable to write to the SwiftDialog command file."
        return 1
    fi

    return 0
}

function update_display_list ()
{
    # PURPOSE:
    #   Send serialized updates to SwiftDialog.
    #
    # PARAMETERS:
    #   $1 = Action
    #   $2 = Progress value
    #   $3 = List-item title
    #   $4 = Progress text
    #   $5 = List-item status
    #   $6 = List-item status text

    local action="${1:l}"

    case "$action" in
        add)
            write_dialog_command "listitem: add, title: ${2}, status: ${3}, statustext: ${4}"
            ;;

        create)
            local dialogPID=0

            "$SW_DIALOG" \
                --progress \
                --jsonfile "$JSON_DIALOG_BLOB" \
                --commandfile "$DIALOG_COMMAND_FILE" \
                --height 800 \
                --width 920 &

            dialogPID=$!

            /bin/sleep 0.2

            if ! /bin/kill -0 "$dialogPID" 2>/dev/null; then
                logMe "ERROR: SwiftDialog progress process exited immediately."
                return 1
            fi

            return 0
            ;;

        buttonenable)
            write_dialog_command "button1: enable"
            ;;

        destroy)
            write_dialog_command "quit:"
            ;;

        buttonchange)
            write_dialog_command "button1text: ${2}"
            ;;

        update | change)
            if [[ -n "${2:-}" ]]; then
                write_dialog_command "listitem: title: ${3}, status: ${5}, statustext: ${6}" "progress: ${2}"
            else
                write_dialog_command "listitem: title: ${3}, status: ${5}, statustext: ${6}"
            fi
            ;;

        progress)
            if [[ -n "${5:-}" ]]; then
                write_dialog_command "progress: ${6}" "progresstext: ${5}"
            else
                write_dialog_command "progress: ${6}"
            fi
            ;;

        *)
            logMe "ERROR: Unsupported SwiftDialog update action: ${1:-empty}"
            return 1
            ;;
    esac

    return $?
}

function make_apfs_safe ()
{
    local value="${1:-}"
    print -r -- "$value" | /usr/bin/sed -e 's/:/_/g' -e 's/|/-/g' -e 's|/|-|g'
}

function display_failure_message ()
{
    local errorMessage="${1:-Unknown error}"
    local buttonPress=0
    local -a MainDialogBody=()

    MainDialogBody=(
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --titlefont shadow=1
        --message "**Problems retrieving JAMF Info**<br><br>Error Message: ${errorMessage}"
        --icon "$SD_ICON_FILE"
        --overlayicon warning
        --iconsize 128
        --button1text "OK"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonPress=$?
    return "$buttonPress"
}

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function close_dialog_json_array ()
{
    # PURPOSE:
    #   Remove the trailing comma from the current array item and
    #   append the closing array bracket.
    #
    # RETURNS:
    #   0 = Array closed successfully
    #   1 = Dialog JSON file is missing or inaccessible

    local dialogContent=""

    if [[ -z "${JSON_DIALOG_BLOB:-}" || ! -f "$JSON_DIALOG_BLOB" ]]; then
        logMe "ERROR: SwiftDialog JSON file is unavailable."
        return 1
    fi

    dialogContent=$(<"$JSON_DIALOG_BLOB")

    #
    # Command substitution strips trailing newlines, so a trailing
    # comma will be the final character when an item was appended.
    #

    dialogContent="${dialogContent%,}"

    if ! printf '%s\n' "${dialogContent}]" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to close SwiftDialog JSON array."
        return 1
    fi

    return 0
}

function append_dialog_json_item ()
{
    # PURPOSE:
    #   Append a validated JSON object followed by a comma.
    #
    # PARAMETERS:
    #   $1 = Compact JSON object

    local itemJSON="${1:-}"

    if [[ -z "$itemJSON" ]]; then
        logMe "ERROR: append_dialog_json_item received empty JSON."
        return 1
    fi

    if ! print -r -- "$itemJSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
        logMe "ERROR: append_dialog_json_item received invalid JSON."
        return 1
    fi

    if ! printf '%s,' "$itemJSON" >> "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to append SwiftDialog JSON item."
        return 1
    fi

    return 0
}

function append_dialog_json_separator ()
{
    # PURPOSE:
    #   Add a comma between top-level JSON properties.

    if ! printf ',\n' >> "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to append SwiftDialog JSON separator."
        return 1
    fi

    return 0
}

function close_dialog_json_object ()
{
    # PURPOSE:
    #   Close and validate the complete SwiftDialog JSON object.

    local dialogContent=""

    if [[ -z "${JSON_DIALOG_BLOB:-}" ||
          ! -f "$JSON_DIALOG_BLOB" ]]
    then
        logMe "ERROR: SwiftDialog JSON file is unavailable."
        return 1
    fi

    dialogContent=$(<"$JSON_DIALOG_BLOB")
    dialogContent="${dialogContent%,}"

    if ! printf '%s\n' "${dialogContent}}" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to close SwiftDialog JSON object."
        return 1
    fi

    if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog JSON construction produced invalid JSON."

        while IFS= read -r line; do
            logMe "JSON: ${line}"
        done < "$JSON_DIALOG_BLOB"

        return 1
    fi

    return 0
}

function construct_dialog_header_settings ()
{
    # PURPOSE:
    #   Write the shared header for progress/list dialogs.
    #
    # PARAMETERS:
    #   $1 = Dialog message
    #
    # OUTPUT:
    #   A partial JSON object on stdout. The final closing brace is
    #   intentionally removed so listitem can be appended.

    local message="${1:-}"
    local titleFont=""
    local headerJSON=""

    titleFont="shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"

    if ! headerJSON=$(
        jq -cn \
            --arg icon "$SD_ICON_FILE" \
            --arg message "$message" \
            --arg bannerImage "$SD_BANNER_IMAGE" \
            --arg subtitle "$BANNER_SUBTITLE" \
            --arg infoBox "$SD_INFO_BOX_MSG" \
            --arg overlayIcon "$OVERLAY_ICON" \
            --arg bannerTitle "$SD_WINDOW_TITLE" \
            --arg titleFont "$titleFont" \
            '{
                icon: $icon,
                message: $message,
                bannerimage: $bannerImage,
                subtitle: $subtitle,
                infobox: $infoBox,
                overlayicon: $overlayIcon,
                ontop: true,
                bannertitle: $bannerTitle,
                titlefont: $titleFont,
                button1text: "OK",
                moveable: true,
                json: true,
                quitkey: "0",
                messageposition: "top"
            }'
    )
    then
        logMe "ERROR: Unable to construct SwiftDialog progress header."
        return 1
    fi

    #
    # Remove the final brace and add a comma because another
    # top-level JSON property will follow.
    #

    headerJSON="${headerJSON%?}"

    printf '%s\n' "${headerJSON},"

    return 0
}

function create_listitem_list ()
{
    # PURPOSE:
    #   Build and display a SwiftDialog list from JSON data.
    #
    # PARAMETERS:
    #   $1 = Dialog message
    #   $2 = Retained temporarily for call compatibility
    #   $3 = jq expression producing list-item names
    #   $4 = JSON response
    #   $5 = List-item icon

    local message="${1:-}"
    local jqFilter="${3:-}"
    local jsonBlob="${4:-}"
    local icon="${5:-}"
    local line=""

    if [[ -z "$jqFilter" || -z "$jsonBlob" ]]; then
        logMe "ERROR: create_listitem_list received incomplete JSON input."
        return 1
    fi

    if ! print -r -- "$jsonBlob" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: create_listitem_list received invalid JSON."
        return 1
    fi

    if ! construct_dialog_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct SwiftDialog list header."
        return 1
    fi

    create_listitem_message_body "" "" "" "" "first" || return 1

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "null" ]] && continue
        create_listitem_message_body "$line" "$icon" "pending" "Pending..." || return 1
    done < <(print -r -- "$jsonBlob" | jq -r "$jqFilter")

    create_listitem_message_body "" "" "" "" "last" || return 1
    if ! update_display_list "Create"; then
        logMe "ERROR: Unable to open the SwiftDialog progress window."
        return 1
    fi

    return 0
}

function create_listitem_message_body ()
{
    # PURPOSE:
    #   Construct a SwiftDialog listitem array.
    #
    # PARAMETERS:
    #   $1 = Item title
    #   $2 = Icon
    #   $3 = Item status
    #   $4 = Status text
    #   $5 = first or last

    local title="${1:-}"
    local icon="${2:-}"
    local itemStatus="${3:-}"
    local statusText="${4:-}"
    local position="${5:l}"
    local itemJSON=""

    if [[ "$position" == "first" ]]; then
        if ! printf '%s' \
            '"button1disabled":true,"listitem":[' \
            >> "$JSON_DIALOG_BLOB"
        then
            logMe "ERROR: Unable to start SwiftDialog listitem array."
            return 1
        fi
    fi

    if [[ -n "$title" ]]; then
        if ! itemJSON=$(
            jq -cn \
                --arg title "$title" \
                --arg icon "$icon" \
                --arg itemStatus "$itemStatus" \
                --arg statusText "$statusText" \
                '{
                    title: $title,
                    icon: $icon,
                    status: $itemStatus,
                    statustext: $statusText
                }'
        )
        then
            logMe "ERROR: Unable to construct SwiftDialog list item."
            return 1
        fi

        append_dialog_json_item "$itemJSON" ||
            return 1
    fi

    if [[ "$position" == "last" ]]; then
        close_dialog_json_array ||
            return 1

        close_dialog_json_object ||
            return 1
    fi

    return 0
}

function create_textfield_message_body ()
{
    # PURPOSE:
    #   Construct a SwiftDialog textfield array.
    #
    # PARAMETERS:
    #   $1 = Internal field name
    #   $2 = Display title
    #   $3 = first or last

    local fieldName="${1:-}"
    local fieldTitle="${2:-}"
    local position="${3:l}"
    local today=""
    local itemJSON=""

    today=$(/bin/date +"%m/%d/%y")

    if [[ "$position" == "first" ]]; then
        if ! printf '%s' \
            '"textfield":[' \
            >> "$JSON_DIALOG_BLOB"
        then
            logMe "ERROR: Unable to start SwiftDialog textfield array."
            return 1
        fi
    fi

    if [[ -n "$fieldName" ]]; then
        if ! itemJSON=$(
            jq -cn \
                --arg name "$fieldName" \
                --arg title "$fieldTitle" \
                --arg value "$today" \
                '{
                    name: $name,
                    title: $title,
                    isdate: true,
                    required: true,
                    value: $value
                }'
        )
        then
            logMe "ERROR: Unable to construct SwiftDialog textfield."
            return 1
        fi

        append_dialog_json_item "$itemJSON" ||
            return 1
    fi

    if [[ "$position" == "last" ]]; then
        close_dialog_json_array ||
            return 1
    fi

    return 0
}

function create_dropdown_message_body ()
{
    # PURPOSE:
    #   Construct a SwiftDialog selectitems array.
    #
    # PARAMETERS:
    #   $1 = Dropdown title
    #   $2 = Comma-separated, JSON-encoded values
    #   $3 = first or last

    local dropdownTitle="${1:-}"
    local dropdownValues="${2:-}"
    local position="${3:l}"
    local valuesJSON="[]"
    local itemJSON=""

    if [[ "$position" == "first" ]]; then
        if ! printf '%s' \
            '"selectitems":[' \
            >> "$JSON_DIALOG_BLOB"
        then
            logMe "ERROR: Unable to start SwiftDialog dropdown array."
            return 1
        fi
    fi

    if [[ -n "$dropdownTitle" ]]; then
        if [[ -n "$dropdownValues" ]]; then
            if ! valuesJSON=$(
                printf '[%s]' "$dropdownValues" |
                    jq -c .
            )
            then
                logMe "ERROR: Dropdown values were not valid JSON for ${dropdownTitle}."
                return 1
            fi
        fi

        if ! itemJSON=$(
            jq -cn \
                --arg title "$dropdownTitle" \
                --argjson values "$valuesJSON" \
                '{
                    title: $title,
                    values: $values
                }'
        )
        then
            logMe "ERROR: Unable to construct SwiftDialog dropdown: ${dropdownTitle}"
            return 1
        fi

        append_dialog_json_item "$itemJSON" ||
            return 1
    fi

    if [[ "$position" == "last" ]]; then
        close_dialog_json_array ||
            return 1
    fi

    return 0
}

function construct_dropdown_list_items ()
{
    # PURPOSE:
    #   Create a comma-separated list of JSON-encoded dropdown values
    #   from a Jamf JSON collection.
    #
    # PARAMETERS:
    #   $1 = JSON content
    #   $2 = jq expression selecting a stream of objects
    #
    # EXAMPLE:
    #   construct_dropdown_list_items \
    #       "$GroupList" \
    #       '.computer_groups[]'
    #
    # OUTPUT:
    #   "1 - Group A","2 - Group B"
    #
    # RETURNS:
    #   0 = Values generated successfully
    #   1 = Missing input, invalid JSON, or jq failure

    local jsonBlob="${1:-}"
    local jqFilter="${2:-}"
    local dropdownItems=""

    if [[ -z "$jsonBlob" ]]; then
        logMe "ERROR: construct_dropdown_list_items called without JSON content."
        return 1
    fi

    if [[ -z "$jqFilter" ]]; then
        logMe "ERROR: construct_dropdown_list_items called without a jq filter."
        return 1
    fi

    if ! print -r -- "$jsonBlob" |
        jq -e . >/dev/null 2>&1
    then
        logMe "ERROR: construct_dropdown_list_items received invalid JSON."
        return 1
    fi

    if ! dropdownItems=$(
        print -r -- "$jsonBlob" |
            jq -r "
                ${jqFilter}
                |
                select(
                    .id != null
                    and
                    .name != null
                    and
                    (.name | tostring | length) > 0
                )
                |
                \"\(.id) - \(.name)\"
            " |
            jq -R . |
            /usr/bin/paste -sd ',' -
    )
    then
        logMe "ERROR: Unable to construct dropdown items using filter: ${jqFilter}"
        return 1
    fi

    print -r -- "$dropdownItems"

    return 0
}

function create_checkbox_message_body ()
{
    # PURPOSE:
    #   Construct a SwiftDialog checkbox array.
    #
    # PARAMETERS:
    #   $1 = Display label
    #   $2 = Internal field name
    #   $3 = Icon
    #   $4 = Checked: true or false
    #   $5 = Disabled: true or false
    #   $6 = first or last

    local label="${1:-}"
    local fieldName="${2:-}"
    local icon="${3:-}"
    local checked="${4:-false}"
    local disabled="${5:-false}"
    local position="${6:l}"
    local checkedJSON="false"
    local disabledJSON="false"
    local itemJSON=""

    [[ "$checked" == "true" ]] &&
        checkedJSON="true"

    [[ "$disabled" == "true" ]] &&
        disabledJSON="true"

    if [[ "$position" == "first" ]]; then
        if ! printf '%s' '"checkbox":[' >> "$JSON_DIALOG_BLOB"; then
            logMe "ERROR: Unable to start SwiftDialog checkbox array."
            return 1
        fi
    fi

    if [[ -n "$label" ]]; then
        if ! itemJSON=$(
            jq -cn \
                --arg name "$fieldName" \
                --arg label "$label" \
                --arg icon "$icon" \
                --argjson checked "$checkedJSON" \
                --argjson disabled "$disabledJSON" \
                '{
                    name: $name,
                    label: $label,
                    icon: $icon,
                    checked: $checked,
                    disabled: $disabled
                }'
        )
        then
            logMe "ERROR: Unable to construct SwiftDialog checkbox: ${label}"
            return 1
        fi

        append_dialog_json_item "$itemJSON" || return 1
    fi

    if [[ "$position" == "last" ]]; then
        close_dialog_json_array || return 1
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
    #   Build shared curl arguments for Jamf API requests.
    #
    # PARAMETERS:
    #   $1 = Optional response-file path

    local responseFile="${1:-}"

    CURL_ARGS=(
        --silent
        --show-error
        --location
        --connect-timeout 15
        --max-time 90
        --retry 3
        --retry-delay 2
        --retry-max-time 45
    )

    [[ "$CURL_SUPPORTS_RETRY_ALL_ERRORS" == "true" ]] && CURL_ARGS+=(--retry-all-errors)
    [[ -n "$responseFile" ]] && CURL_ARGS+=(--output "$responseFile")
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

function JAMF_which_self_service ()
{
    local app_path=""
    app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null)

    [[ -z "$app_path" ]] &&app_path=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null)
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

function JAMF_validate_token ()
{
    local httpStatus=""
    local curlExitCode=0
    local -a curlArgs=()

    [[ -n "${api_token:-}" ]] || return 1

    JAMF_build_curl_args

    curlArgs=("${CURL_ARGS[@]}")

    curlArgs+=(
        --write-out "%{http_code}"
        --output /dev/null
        --request GET
        --header "Authorization: Bearer ${api_token}"
    )

    httpStatus=$(/usr/bin/curl "${curlArgs[@]}" "${jamfpro_url}/api/v1/auth")
    curlExitCode=$?

    if (( curlExitCode != 0 )); then
        logMe "ERROR: Jamf token validation failed. curl exit code: ${curlExitCode}"
        return 1
    fi

    [[ "$httpStatus" == "200" ]]
}

function JAMF_get_classic_api_token ()
{
    local responseFile=""
    local http_status=""
    local curl_status=0
    local token=""
    local expires=""
    local expiration_epoch=""
    local error_message=""
    local -a curlArgs

    responseFile=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.classic-token.XXXXX") || {
        logMe "ERROR: Unable to create Classic API token response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure Classic API token response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    JAMF_build_curl_args "$responseFile"
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

            if [[ -s "$responseFile" ]]; then
                error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // .error // empty' "$responseFile" 2>/dev/null)

                if [[ -n "$error_message" ]]; then
                    logMe "Jamf error: ${error_message}"
                else
                    logMe "ERROR: Classic API response begins with:"
                    /usr/bin/head -c 500 "$responseFile" >&2
                    /usr/bin/printf '\n' >&2
                fi
            fi

            return 1
        fi

        if [[ ! -s "$responseFile" ]]; then
            logMe "ERROR: Classic API token response was empty."
            return 1
        fi

        if ! jq -e 'type == "object"' "$responseFile" >/dev/null 2>&1
        then
            logMe "ERROR: Classic API token response was not valid JSON."
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$responseFile"); then
            logMe "ERROR: Classic API response did not contain a bearer token."
            return 1
        fi

        if ! expires=$(jq -er '.expires | strings | select(length > 0)' "$responseFile"); then
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
        /bin/rm -f -- "$responseFile"
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
    local responseFile
    local http_status
    local curl_status
    local token
    local expires_in 
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

function JAMF_invalidate_token ()
{
    local responseFile=""
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

    responseFile=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.invalidate.XXXXX") || {
        logMe "ERROR: Unable to create token-invalidation response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
        logMe "ERROR: Unable to secure token-invalidation response file."
        /bin/rm -f -- "$responseFile"
        return 1
    fi

    JAMF_build_curl_args "$responseFile"
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

                if [[ -s "$responseFile" ]]; then
                    error_message=$(jq -r '.errors[0].description // .errors[0].message // .message // .error_description // .error // empty' "$responseFile" 2>/dev/null)
                    [[ -n "$error_message" ]] && logMe "Jamf error: ${error_message}"
                fi
                return 1
                ;;
        esac

    } always {
        api_token=""
        api_token_expires_epoch=0
        token_to_invalidate=""
        /bin/rm -f -- "$responseFile"
    }
}

function JAMF_retrieve_data_blob ()
{
    local endpoint="$1"
    local format="${2:-json}"
    local jq_filter="${3:-}"
    local responseFile
    local http_status
    local -a curlArgs
    local curl_status

    if [[ -z "$endpoint" ]]; then
        logMe "ERROR: JAMF_retrieve_data_blob called without an endpoint."
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi
    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary response file" >&2
        return 1
    }

    JAMF_build_curl_args "$responseFile"
    curlArgs=("${CURL_ARGS[@]}")
    curlArgs+=(
        --write-out "%{http_code}"
        --header "Authorization: Bearer ${api_token}"
        --header "Accept: application/${format}"
    )

    {
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/${endpoint}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving ${endpoint}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if [[ "$format" == "json" ]]; then
                    if ! jq -e . "$responseFile" >/dev/null 2>&1; then
                        logMe "ERROR: Invalid JSON returned by ${endpoint}" >&2
                        cat "$responseFile" >&2
                        return 1
                    fi

                    if [[ -n "$jq_filter" ]]; then
                        if ! jq "$jq_filter" "$responseFile"; then
                            logMe "ERROR: Unable to apply jq filter to ${endpoint}: ${jq_filter}" >&2
                            return 1
                        fi
                    else
                        cat "$responseFile"
                    fi
                else
                    cat "$responseFile"
                fi
                ;;

            401)
                logMe "ERROR: Authentication failed retrieving ${endpoint}, HTTP 401" >&2
                cat "$responseFile" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege retrieving ${endpoint}, HTTP 403" >&2
                cat "$responseFile" >&2
                return 1
                ;;

            404)
                logMe "ERROR: Resource not found: ${endpoint}, HTTP 404" >&2
                cat "$responseFile" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response for ${endpoint}, HTTP ${http_status}" >&2
                cat "$responseFile" >&2
                return 1
                ;;
        esac
    } always {
        rm -f -- "$responseFile"
        }
}

function JAMF_retrieve_data_blob_global ()
{    
    # PURPOSE: Extract the summary of the JAMF conmand results
    # RETURN:
    #   JSON response content on stdout
    #
    # PARAMETERS:
    #   $1 = Jamf API endpoint
    #   $2 = Response format, defaults to JSON
    #   $3 = Optional jq filter
    #   $4 = Suppress HTTP 404 logging when true
    # EXPECTED: 
    #   api_token - base64 hex code of your bearer token
    #  jamppro_url - the URL of your JAMF server
    
    local endpoint="$1"
    local format="${2:-json}"
    local jq_filter="${3:-}"
    local quiet404="${4:-false}"
    local responseFile
    local http_status
    local -a curlArgs
    local curl_status

    if [[ -z "$endpoint" ]]; then
        logMe "ERROR: JAMF_retrieve_data_blob_global called without an endpoint."
        return 1
    fi
    
        if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    responseFile=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary response file" >&2
        return 1
    }



    JAMF_build_curl_args "$responseFile"
    curlArgs=("${CURL_ARGS[@]}")
    curlArgs+=(
        --write-out "%{http_code}"
        --header "Authorization: Bearer ${api_token}"
        --header "Accept: application/${format}"
    )

    {
        http_status=$(curl "${curlArgs[@]}" "${jamfpro_url}/${endpoint}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving ${endpoint}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if [[ "$format" == "json" ]]; then
                    if ! jq -e . "$responseFile" >/dev/null 2>&1; then
                        logMe "ERROR: Invalid JSON returned by ${endpoint}" >&2
                        cat "$responseFile" >&2
                        return 1
                    fi

                    if [[ -n "$jq_filter" ]]; then
                        if ! jq "$jq_filter" "$responseFile"; then
                            logMe "ERROR: Unable to apply jq filter to ${endpoint}: ${jq_filter}" >&2
                            return 1
                        fi
                    else
                        cat "$responseFile"
                    fi
                else
                    cat "$responseFile"
                fi
                ;;

            401)
                logMe "ERROR: Authentication failed retrieving ${endpoint}, HTTP 401" >&2
                cat "$responseFile" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege retrieving ${endpoint}, HTTP 403" >&2
                cat "$responseFile" >&2
                return 1
                ;;

            404)
                if [[ "$quiet404" == "true" ]]; then
                    return 4
                fi

                logMe "ERROR: Resource not found: ${endpoint}, HTTP 404" >&2

                if [[ -s "$responseFile" ]]; then
                    cat "$responseFile" >&2
                fi

                return 1
                ;;
                

            *)
                logMe "ERROR: Unexpected Jamf response for ${endpoint}, HTTP ${http_status}" >&2
                cat "$responseFile" >&2
                return 1
                ;;
        esac
    } always {
        rm -f -- "$responseFile"
        }
}

function JAMF_get_inventory_record ()
{
    # PURPOSE:
    #   Retrieve inventory data from Jamf Pro
    #
    # PARAMETERS:
    #   $1 = Inventory section
    #   $2 = Optional filter condition
    #   $3 = Optional page number (default: 0)
    #   $4 = Optional page size (default: 1000)

    local inventorySection="${1:-}"
    local filterCondition="${2:-}"
    local page="${3:-0}"
    local pageSize="${4:-1000}"

    local responseFile=""
    local responseBody=""
    local http_code=""
    local curlExitCode=0
    local -a curlArgs

    if [[ -z "$inventorySection" ]]; then
        logMe "ERROR: JAMF_get_inventory_record called without an inventory section."
        return 1
    fi

    if [[ "$page" != <-> ]]; then
        logMe "ERROR: Invalid inventory page number: ${page}"
        return 1
    fi

    if [[ "$pageSize" != <-> ]] || (( pageSize < 1 )); then
        logMe "ERROR: Invalid inventory page size: ${pageSize}"
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
            --data-urlencode "page=${page}"
            --data-urlencode "page-size=${pageSize}"
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
                logMe "ERROR: Invalid inventory request. Section='${inventorySection}', filter='${filterCondition}', page=${page}, page-size=${pageSize}."
                [[ -s "$responseFile" ]] && head -c 1000 "$responseFile" >&2
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
        [[ -n "$responseFile" && -f "$responseFile" ]] &&
            /bin/rm -f -- "$responseFile"
    }
}

function JAMF_get_inventory_record_byID ()
{
    # PURPOSE:
    #   Retrieve one Jamf computer inventory section by computer ID.
    #
    # PARAMETERS:
    #   $1 = Jamf computer ID
    #   $2 = Inventory section
    #
    # RETURNS:
    #   JSON response on stdout

    local computerID="${1:-}"
    local inventorySection="${2:-GENERAL}"
    local responseFile=""
    local httpCode=""
    local curlExitCode=0
    local -a curlArgs

    if [[ "$computerID" != <-> ]]; then
        logMe "ERROR: Invalid computer ID passed to JAMF_get_inventory_record_byID: ${computerID}"
        return 1
    fi

    if [[ -z "$inventorySection" ]]; then
        logMe "ERROR: JAMF_get_inventory_record_byID called without an inventory section."
        return 1
    fi

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    responseFile=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.inventory-id.XXXXX"
    ) || {
        logMe "ERROR: Unable to create inventory response file."
        return 1
    }

    if ! /bin/chmod 600 "$responseFile"; then
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

        httpCode=$(curl "${curlArgs[@]}" "${jamfpro_url}/api/v4/computers-inventory/${computerID}" )

        curlExitCode=$?

        if (( curlExitCode != 0 )); then
            logMe "ERROR: Inventory request failed for computer ID ${computerID}. curl exit code: ${curlExitCode}."
            return 1
        fi

        if [[ "$httpCode" != "200" ]]; then
            logMe "ERROR: Inventory request returned HTTP ${httpCode} for computer ID ${computerID}."
            return 1
        fi

        if [[ ! -s "$responseFile" ]]; then
            logMe "ERROR: Empty inventory response for computer ID ${computerID}."
            return 1
        fi

        if ! jq -e 'type == "object"' "$responseFile" >/dev/null 2>&1; then
            logMe "ERROR: Invalid inventory JSON returned for computer ID ${computerID}."
            return 1
        fi

        cat "$responseFile"

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

###############################################
#
# Backup Self Service Icons functions
#
###############################################

function backup_ss_icons ()
{
    local JAMF_API_KEY="JSSResource/policies"
    local PolicyList=""
    local -a iconIDs=()
    local iconCount=0
    local DirectoryCount=0
    local logMsg=""
    local parallelStatus=0


    logMe "Backing up Self Service policy icons"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    if ! PolicyList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve the Jamf Pro policy list."
        return 1
    fi

    if ! print -r -- "$PolicyList" | jq -e '.policies | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Policy list did not contain a valid policies array."
        return 1
    fi

    iconIDs=("${(@f)$(print -r -- "$PolicyList" | jq -r '.policies[]?.id // empty')}")
    iconCount=${#iconIDs[@]}

    logMe "Processing ${iconCount} Jamf policies for Self Service icons."
    if ! create_listitem_list "The following Self Service icons are being downloaded from the Jamf server" "json" '.policies[]?.name // empty' "$PolicyList" "SF=app.badge"
    then
        logMe "ERROR: Unable to create the Self Service icon progress list."
        return 1
    fi

    if (( iconCount > 0 )); then
        execute_in_parallel "$BACKGROUND_TASKS" backup_ss_icons_detail "${iconIDs[@]}"
        parallelStatus=$?
    fi

    DirectoryCount=$(find "$location_SSIcons" -maxdepth 1 -type f 2>/dev/null | wc -l | xargs)
    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Self Service icon workers failed. ${DirectoryCount} custom icon files are currently present on disk."
    else
        logMsg="INFO: Self Service icon processing completed successfully. ${DirectoryCount} custom icon files are currently present on disk."
    fi

    logMe "$logMsg"

    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    return "$parallelStatus"
}

function backup_ss_icons_detail ()
{
    # PURPOSE:
    #   Retrieve a Jamf policy as JSON and download its
    #   Self Service icon when one is configured.
    #
    # PARAMETERS:
    #   $1 = Jamf policy ID

    local id="${1:-}"
    local JAMF_API_KEY="JSSResource/policies"
    local jsonBlob=""
    local PolicyName=""
    local useForSelfService="false"
    local iconID=""
    local iconName=""
    local iconURI=""
    local formattedIconName=""
    local exportedFilename=""
    local -a iconCurlArgs=()

    [[ -z "$id" ]] && return 0

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf policy ID: ${id}"
        return 1
    fi

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "${JAMF_API_KEY}/id/${id}" "json"); then
        logMe "ERROR: Unable to retrieve Jamf policy ID ${id}."
        return 1
    fi

    if ! print -r -- "$jsonBlob" | jq -e '.policy | objects' >/dev/null 2>&1; then
        logMe "ERROR: Invalid policy JSON returned for policy ID ${id}."
        return 1
    fi

    PolicyName=$(print -r -- "$jsonBlob" | jq -r '.policy.general.name // empty')
    [[ -z "$PolicyName" ]] && PolicyName="Policy ID ${id}"
    useForSelfService=$(print -r -- "$jsonBlob" | jq -r '.policy.self_service.use_for_self_service // false')

    #
    # Not every policy is available in Self Service.
    # This is an expected condition, not an error.
    #

    if [[ "$useForSelfService" != "true" ]]; then
        update_display_list "Update" "" "$PolicyName" "" "success" "Not in Self Service"
        return 0
    fi

    iconID=$(print -r -- "$jsonBlob" | jq -r '.policy.self_service.self_service_icon.id // empty')
    iconName=$(print -r -- "$jsonBlob" | jq -r '.policy.self_service.self_service_icon.filename // empty')
    iconURI=$(print -r -- "$jsonBlob" | jq -r '.policy.self_service.self_service_icon.uri // empty')

    #
    # A Self Service policy does not necessarily have a
    # custom icon.
    #

    if [[ -z "$iconID" || -z "$iconURI" ]]; then
        update_display_list "Update" "" "$PolicyName" "" "success" "No custom icon"
        return 0
    fi

    [[ -z "$iconName" ]] && iconName="SelfServiceIcon-${iconID}.png"

    formattedIconName=$(make_apfs_safe "$iconName")

    if [[ -z "$formattedIconName" ]]; then
        logMe "ERROR: Unable to create a valid icon filename for ${PolicyName}."
        update_display_list "Update" "" "$PolicyName" "" "fail" "Invalid icon filename"
        return 1
    fi

    exportedFilename="${location_SSIcons}/${formattedIconName}"

    update_display_list "Update" "" "$PolicyName" "" "wait" "Downloading..."
    logMe "Downloading Self Service icon for policy: ${PolicyName}"

    iconCurlArgs=(
        --silent
        --show-error
        --fail
        --location
        --connect-timeout 15
        --max-time 90
        --retry 3
        --retry-delay 2
        --retry-max-time 45
        --output "$exportedFilename"
    )

    [[ "$CURL_SUPPORTS_RETRY_ALL_ERRORS" == "true" ]] && iconCurlArgs+=(--retry-all-errors)

    if ! /usr/bin/curl "${iconCurlArgs[@]}" "$iconURI"; then
        logMe "ERROR: Unable to download Self Service icon for ${PolicyName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$PolicyName" "" "fail" "Icon download failed"
        return 1
    fi

    if [[ ! -s "$exportedFilename" ]]; then
        logMe "ERROR: Downloaded icon was empty for ${PolicyName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$PolicyName" "" "fail" "Empty icon"
        return 1
    fi

    update_display_list "Update" "" "$PolicyName" "" "success" "Icon downloaded"
    return 0
}

###############################################
#
# export failed MDM devices functions
#
###############################################

function export_failed_mdm_commands_menu ()
{
    local message=""
    local temp=""
    local returnCode=0
    local -a MainDialogBody=()

    message="**Export Failed MDM Commands**<br><br>You have selected to export the failed MDM commands.<br><br>There are some additional items to select:"
    MainDialogBody=(
        --message "$message"
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --checkbox "Clear failed items while exporting",name=ClearFailedMDMCommands
        --width 800
        --height 480
        --ignorednd
        --quitkey 0
        --json
        --button1text "OK"
        --button2text "Cancel"
    )

    temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    case "$returnCode" in
        0)
            ;;

        2)
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}."
            return 1
            ;;
    esac

    menu_clearFailedMDM=$( print -r -- "$temp" | jq -r '.ClearFailedMDMCommands // false' )
}

function export_failed_mdm_details ()
{
    # PURPOSE:
    #   Retrieve and export failed MDM command history for one computer
    #   using the Jamf Classic API JSON response.
    #
    # PARAMETERS:
    #   $1 = Jamf computer ID
    #
    # RETURNS:
    #   0 = Completed, skipped, or no failed commands
    #   1 = Retrieval, JSON parsing, export, or clearing failure

    local id="${1:-}"
    local jsonBlob=""
    local retrieveStatus=0
    local deviceName=""
    local deviceID=""
    local failedCommandsJSON=""
    local failedCount=0
    local formattedDeviceName=""
    local exportedFilename=""
    local MDMfailures=""

    [[ -z "$id" ]] && return 0

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf computer ID: ${id}"
        update_display_list "Update" "" "$id" "" "fail" "Invalid computer ID"
        return 1
    fi

    #
    # Retrieve computer history as JSON by stable Jamf computer ID.
    #
    # The final true argument suppresses generic error logging for
    # an expected HTTP 404 and returns status 4 to this worker.
    #

    jsonBlob=$(JAMF_retrieve_data_blob_global "JSSResource/computerhistory/id/${id}" "json" "" "true")
    retrieveStatus=$?

    case "$retrieveStatus" in
        0)
            ;;

        4)
            logMe "INFO: Computer history was not found for Jamf computer ID ${id}. Skipping."
            update_display_list "Update" "" "$id" "" "error" "History not found"
            return 0
            ;;

        *)
            logMe "ERROR: Unable to retrieve computer history for Jamf computer ID ${id}."
            update_display_list "Update" "" "$id" "" "fail" "Retrieval failed"
            return 1
            ;;
    esac

    #
    # Verify that the returned content is valid JSON.
    #

    if ! print -r -- "$jsonBlob" | jq -e 'type == "object"' >/dev/null 2>&1; then
        logMe "ERROR: Invalid JSON returned for Jamf computer ID ${id}."
        update_display_list "Update" "" "$id" "" "fail" "Invalid JSON response"
        return 1
    fi

    #
    # Extract the computer name and ID.
    #
    # Use the requested Jamf ID as the fallback in case the general
    # section is absent or contains an empty value.
    #

    deviceName=$(print -r -- "$jsonBlob" | jq -r '.computer_history.general.name// empty')
    deviceID=$(print -r -- "$jsonBlob" | jq -r '.computer_history.general.id// empty')

    [[ -z "$deviceName" ]] && deviceName="$id"
    [[ -z "$deviceID" ]] && deviceID="$id"

    #
    # Normalize the failed-command data into one JSON array.
    #
    # Depending on how Jamf converts the Classic API XML response,
    # the failed data may appear as:
    #
    #   commands.failed.command = [ ... ]
    #
    #   commands.failed.command = { ... }
    #
    #   commands.failed = [ ... ]
    #
    # An empty, missing, or unrecognized value becomes [].
    #

    if ! failedCommandsJSON=$(
        print -r -- "$jsonBlob" |
            jq -c '
                def as_array:
                    if . == null then
                        []
                    elif type == "array" then
                        .
                    elif type == "object" then
                        [.]
                    else
                        []
                    end;

                .computer_history.commands.failed as $failed
                |
                if $failed == null then
                    []
                elif ($failed | type) == "array" then
                    $failed
                elif ($failed | type) == "object"
                    and ($failed | has("command"))
                then
                    ($failed.command | as_array)
                else
                    []
                end
            '
    )
    then
        logMe "ERROR: Unable to parse failed MDM commands for ${deviceName}."
        update_display_list "Update" "" "$deviceName" "" "fail" "Command parsing failed"
        return 1
    fi

    #
    # Validate the normalized command array.
    #

    if ! print -r -- "$failedCommandsJSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
        logMe "ERROR: Normalized failed-command data was not an array for ${deviceName}."
        update_display_list "Update" "" "$deviceName" "" "fail" "Invalid command data"
        return 1
    fi

    #
    # Count the actual failed command objects rather than trusting
    # the Classic API size property.
    #

    failedCount=$(print -r -- "$failedCommandsJSON" | jq -r 'length')

    if [[ "$failedCount" != <-> ]]; then
        logMe "ERROR: Invalid failed-command count for ${deviceName}: ${failedCount}"
        update_display_list "Update" "" "$deviceName" "" "fail" "Invalid command count"
        return 1
    fi

    #
    # No failed command objects is a successful result.
    #

    if (( failedCount == 0 )); then
        update_display_list "Update" "" "$deviceName" "" "success" "No failed commands"
        return 0
    fi

    logMe "Found ${failedCount} failed MDM command(s) for ${deviceName}."

    #
    # Build the report directly from each command object.
    #
    # Keeping the fields together avoids maintaining separate name,
    # status, and date arrays that could become misaligned.
    #

    if ! MDMfailures=$(print -r -- "$failedCommandsJSON" | jq -r '
                .[] |
                "\(
                    .name
                    // .command_name
                    // .command
                    // "Unknown command"
                ) (\(
                    .status
                    // "Unknown status"
                )) @ \(
                    .date_time
                    // .dateTime
                    // .date
                    // "Unknown date"
                )"
            '); then
        logMe "ERROR: Unable to format failed MDM commands for ${deviceName}."
        update_display_list "Update" "" "$deviceName" "" "fail" "Command formatting failed"
        return 1
    fi

    if [[ -z "$MDMfailures" ]]; then
        logMe "ERROR: Jamf reported ${failedCount} failed command(s) for ${deviceName}, but no report content was generated."
        update_display_list "Update" "" "$deviceName" "" "fail" "Empty command report"
        return 1
    fi

    #
    # Create a safe report filename.
    #

    formattedDeviceName=$(make_apfs_safe "$deviceName")

    if [[ -z "$formattedDeviceName" ]]; then
        logMe "ERROR: Unable to create a valid filename for ${deviceName}."
        update_display_list "Update" "" "$deviceName" "" "fail" "Invalid filename"
        return 1
    fi

    exportedFilename="${location_FailedMDM}/${formattedDeviceName}.txt"
    update_display_list "Update" "" "$deviceName" "" "wait" "Working..."
    logMe "Exporting ${failedCount} failed MDM command(s) for ${deviceName}."

    #
    # Write the report.
    #

    if ! {
        printf 'Computer: %s\n' "$deviceName"
        printf 'Jamf Computer ID: %s\n' "$deviceID"
        printf 'Failed command count: %s\n\n' "$failedCount"
        printf '%s\n' "$MDMfailures"
    } > "$exportedFilename"
    then
        logMe "ERROR: Failed to export failed MDM commands for ${deviceName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$deviceName" "" "fail" "Export failed"
        return 1
    fi

    #
    # Clear failed MDM commands when requested.
    #

    if [[ "$menu_clearFailedMDM" == "true" ]]; then

        if [[ "$deviceID" != <-> ]]; then
            logMe "ERROR: Invalid device ID retrieved for ${deviceName}: ${deviceID}"
            update_display_list "Update" "" "$deviceName" "" "fail" "Invalid device ID"
            return 1
        fi

        logMe "Clearing ${failedCount} failed MDM command(s) for ${deviceName}."

        if JAMF_clear_failed_mdm_commands "$deviceID"; then
            update_display_list "Update" "" "$deviceName" "" "success" "Exported and cleared"
        else
            logMe "ERROR: Failed to clear MDM commands for ${deviceName}."

            update_display_list "Update" "" "$deviceName" "" "fail" "Exported, but clear failed"
            return 1
        fi

    else
        update_display_list "Update" "" "$deviceName" "" "success" "Exported ${failedCount} failed command(s)"
    fi

    return 0
}

function export_failed_mdm_devices ()
{
    # PURPOSE:
    #   Retrieve all Jamf computers and inspect each computer's
    #   history for failed MDM commands.
    #
    #   Computer IDs are retrieved from the modern inventory API
    #   and passed to export_failed_mdm_details for processing.
    #
    # RETURNS:
    #   0 = Processing completed successfully
    #   1 = Inventory retrieval, parsing, or worker failure

    local DeviceList=""
    local -a DeviceIDs=()
    local DeviceCount=0
    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""

    logMe "Exporting devices with failed MDM commands"
    logMe "Destination: ${location_FailedMDM}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Retrieve the Jamf computer inventory.
    #

    if ! DeviceList=$(JAMF_get_inventory_record "GENERAL" "" 0 1000); then
        logMe "ERROR: Unable to retrieve the Jamf Pro computer inventory list."
        return 1
    fi

    #
    # Validate the expected inventory JSON structure.
    #

    if ! print -r -- "$DeviceList" | jq -e 'type == "object" and (.results | type == "array")' >/dev/null 2>&1; then
        logMe "ERROR: Computer inventory response did not contain a valid results array."
        return 1
    fi

    #
    # Extract stable Jamf computer IDs.
    #
    # Using IDs instead of computer names prevents URL failures
    # caused by spaces and other characters in computer names.
    #

    DeviceIDs=("${(@f)$(print -r -- "$DeviceList" | jq -r '.results[]?.id | select(. != null) | tostring | select(test("^[0-9]+$"))')}")
    DeviceCount=${#DeviceIDs[@]}
    logMe "Found ${DeviceCount} computers to inspect for failed MDM commands."

    if (( DeviceCount == 0 )); then
        logMe "INFO: No computers were returned by Jamf Pro."
        return 0
    fi

    #
    # Create the SwiftDialog progress list using computer names.
    #
    if ! create_listitem_list "The following computers are being checked for failed MDM commands" "json" '.results[]?.general.name // empty' "$DeviceList" "SF=desktopcomputer.and.macbook"; then
        logMe "ERROR: Unable to create the Failed MDM progress list."
        return 1
    fi
    #
    # Inspect each computer in parallel.
    #

    execute_in_parallel "$BACKGROUND_TASKS" export_failed_mdm_details "${DeviceIDs[@]}"
    parallelStatus=$?
    #
    # Count only actual failed-MDM reports.
    #
    # This count is intentionally NOT compared against DeviceCount.
    # Computers without failed commands do not create report files.
    #
    DirectoryCount=$(find "$location_FailedMDM" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | xargs)
    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Failed MDM inspections failed. ${DirectoryCount} failed-command reports are currently present on disk."
    else
        logMsg="INFO: Failed MDM inspection completed for ${DeviceCount} computers. ${DirectoryCount} failed-command reports are currently present on disk."
    fi
    logMe "$logMsg"
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"

    return "$parallelStatus"
}


###############################################
#
# Backup System Scripts functions
#
###############################################

function backup_jamf_scripts ()
{
    local scriptList=""
    local -a scriptIDs=()
    local scriptCount=0
    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""
    # PURPOSE: Backup all of the JAMF scripts from JAMF
    logMe "Backing up System scripts"
    logMe "Destination: ${location_JAMFScripts}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    if ! scriptList=$(JAMF_retrieve_data_blob "api/v1/scripts?page=0&page-size=1000&sort=name%3Aasc" "json"); then
        logMe "ERROR: Unable to retrieve Jamf scripts."
        return 1
    fi
    if ! print -r -- "$scriptList" | jq -e '.results | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Script list did not contain a valid results array."
        return 1
    fi
    if ! create_listitem_list "The following System scripts are being downloaded from JAMF" "json" '.results[]?.name // empty' "$scriptList" "SF=apple.terminal.fill"; then
        logMe "ERROR: Unable to create the System Script progress list."
        return 1
    fi
    scriptIDs=("${(@f)$(print -r -- "$scriptList" | jq -r '.results[]?.id // empty')}")
    scriptCount=${#scriptIDs[@]}
    if (( scriptCount > 0 )); then
        execute_in_parallel "$BACKGROUND_TASKS" extract_script_details "${scriptIDs[@]}"
        parallelStatus=$?
    fi

    # Display how many Script files were downloaded.
    DirectoryCount=$(find "$location_JAMFScripts" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | xargs)
    
    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more System Script exports failed. ${DirectoryCount} files are currently present on disk."
    elif (( scriptCount != DirectoryCount )); then
        logMsg="WARNING: Expected ${scriptCount} System Scripts, but found ${DirectoryCount} files on disk."
    else
        logMsg="INFO: All ${scriptCount} System Scripts downloaded successfully."
    fi

    logMe "${logMsg}" 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
    return "$parallelStatus"
}

function extract_script_details ()
{
    # PURPOSE:
    #   Retrieve a Jamf script as JSON and export its script contents.
    #
    # PARAMETERS:
    #   $1 = Jamf script ID

    local id="${1:-}"
    local scriptName=""
    local scriptContents=""
    local formatted_scriptName=""
    local exported_filename=""
    local jsonBlob=""

    [[ -z "$id" ]] && return 0

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf script ID: ${id}"
        return 1
    fi


    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "api/v1/scripts/${id}" "json"); then
        return 1
    fi

    scriptName=$(print -r -- "$jsonBlob" | jq -r '.name // empty')

    # if the Script name is empty, then we will not be able to export it, so show as a failure and report it
    if [[ -z $scriptName ]]; then
        fix_import_errors "$jsonBlob" "Problems saving script"
        return 1
    fi
    scriptCategory=$(print -r -- "$jsonBlob" | jq -r '.categoryName // empty')
    scriptContents=$(print -r -- "$jsonBlob" | jq -r '.scriptContents // empty')

    # Remove any special characters that might mess with APFS
    formatted_scriptName=$(make_apfs_safe "$scriptName")

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $scriptContents ]]; then
        update_display_list "Update" "" "${scriptName}" "" "fail" "Not exported!"
        logMe "Script ${scriptName} not exported due to empty contents"
        printf 'Script Error: %s\n' "$scriptName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi    
    update_display_list "Update" "" "${scriptName}" "" "wait" "Working..."
    # Store the script in the destination folder
    exported_filename="$location_JAMFScripts/${formatted_scriptName}.sh"
    logMe "Exporting Script: ${scriptName}"
    if ! printf '%s\n' "$scriptContents" > "$exported_filename"; then
        logMe "ERROR: Unable to write System Script ${scriptName}."
        /bin/rm -f -- "$exported_filename"
        update_display_list "Update" "" "$scriptName" "" "fail" "Export failed"
        return 1
    fi        
    update_display_list "Update" "" "${scriptName}" "" "success" "Finished"
    return 0
}

###############################################
#
# Backup Computer Extensions attributes 
#
###############################################

function backup_computer_extensions ()
{
    # PURPOSE:
    #   Backup all Computer Extension Attributes from Jamf Pro.

    local ExtensionList=""
    local -a ExtensionIDs=()
    local ExtensionCount=0
    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""
    local JAMF_API_KEY="api/v1/computer-extension-attributes"

    logMe "Backing up Computer Extension Attributes"
    logMe "Destination: ${location_ComputerEA}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    if ! ExtensionList=$(JAMF_retrieve_data_blob "${JAMF_API_KEY}?page=0&page-size=1000&sort=name.asc" "json"); then
        logMe "ERROR: Unable to retrieve Computer Extension Attributes."
        return 1
    fi

    if ! print -r -- "$ExtensionList" | jq -e '.results | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Extension Attribute list did not contain a valid results array."
        return 1
    fi

    if ! create_listitem_list "The following Computer EAs are being downloaded from JAMF" "json" '.results[]?.name // empty' "$ExtensionList" "SF=apple.terminal.fill"; then
        logMe "ERROR: Unable to create the Extension Attribute progress list."
        return 1
    fi

    ExtensionIDs=("${(@f)$(print -r -- "$ExtensionList" | jq -r '.results[]?.id // empty')}")
    ExtensionCount=${#ExtensionIDs[@]}

    logMe "Found ${ExtensionCount} Computer Extension Attributes to export."

    if (( ExtensionCount > 0 )); then
        execute_in_parallel "$EA_BACKGROUND_TASKS" extract_extension_details "${ExtensionIDs[@]}"
        parallelStatus=$?
    fi

    DirectoryCount=$(find "$location_ComputerEA" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | xargs)

    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Computer Extension Attribute exports failed. ${DirectoryCount} files are currently present on disk."
    elif (( ExtensionCount != DirectoryCount )); then
        logMsg="WARNING: Expected ${ExtensionCount} Computer Extension Attributes, but found ${DirectoryCount} files on disk."
    else
        logMsg="INFO: All ${ExtensionCount} Computer Extension Attributes downloaded successfully."
    fi
    logMe "$logMsg"
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait

    return "$parallelStatus"
}

function extract_extension_details ()
{
    # PURPOSE:
    #   Retrieve one Computer Extension Attribute as JSON and
    #   export its input definition.
    #
    # PARAMETERS:
    #   $1 = Jamf Extension Attribute ID

    local id="${1:-}"
    local jsonBlob=""
    local extensionName=""
    local extensionType=""
    local formattedExtensionName=""
    local exportedFilename=""
    local fileDetails=""
    local JAMF_API_KEY="api/v1/computer-extension-attributes"

    [[ -z "$id" ]] && return 0

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Computer Extension Attribute ID: ${id}"
        return 1
    fi

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "${JAMF_API_KEY}/${id}" "json"); then
        logMe "ERROR: Unable to retrieve Computer Extension Attribute ID ${id}."
        update_display_list "Update" "" "Extension Attribute ID ${id}" "" "fail" "Retrieval failed"
        return 1
    fi

    if ! print -r -- "$jsonBlob" | jq -e 'type == "object"' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Extension Attribute JSON returned for ID ${id}."
        return 1
    fi

    extensionName=$(extract_json_value "$jsonBlob" '.name // empty')
    extensionType=$(extract_json_value "$jsonBlob" '.inputType // empty')

    if [[ -z "$extensionName" ]]; then
        logMe "ERROR: Computer Extension Attribute ID ${id} did not contain a name."
        update_display_list "Update" "" "Extension Attribute ID ${id}" "" "fail" "Missing name"
        return 1
    fi

    if [[ -z "$extensionType" ]]; then
        logMe "ERROR: Computer Extension Attribute ${extensionName} did not contain an input type."
        update_display_list "Update" "" "$extensionName" "" "fail" "Missing input type"
        return 1
    fi

    formattedExtensionName=$(make_apfs_safe "$extensionName")

    if [[ -z "$formattedExtensionName" ]]; then
        logMe "ERROR: Unable to create a valid filename for ${extensionName}."
        update_display_list "Update" "" "$extensionName" "" "fail" "Invalid filename"
        return 1
    fi

    case "$extensionType" in
        TEXT)
            fileDetails=$(
                printf 'Text field: %s' "$(extract_json_value "$jsonBlob" '.dataType // empty')")
            ;;

        SCRIPT)
            fileDetails=$(extract_json_value "$jsonBlob" '.scriptContents // empty')
            ;;

        POPUP)
            fileDetails=$(
                {
                    printf 'Pop-up Choices:\n\n'

                    extract_json_value \
                        "$jsonBlob" \
                        '.popupMenuChoices[]?'
                }
            )
            ;;

        DIRECTORY_SERVICE_ATTRIBUTE_MAPPING)
            fileDetails=$(printf 'AD Mapping: %s' "$(extract_json_value "$jsonBlob" '.ldapAttributeMapping // empty')")
            ;;

        *)
            logMe "ERROR: Unsupported Extension Attribute input type '${extensionType}' for ${extensionName}."
            update_display_list "Update" "" "$extensionName" "" "fail" "Unsupported input type"
            return 1
            ;;
    esac

    if [[ -z "$fileDetails" ]]; then
        update_display_list "Update" "" "$extensionName" "" "fail" "Not exported"
        logMe "ERROR: Computer Extension Attribute ${extensionName} was not exported because its contents were empty."
        printf 'Computer Extension Attribute: %s\n' "$formattedExtensionName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    update_display_list "Update" "" "$extensionName" "" "wait" "Working..."

    exportedFilename="${location_ComputerEA}/${formattedExtensionName}.sh"

    if ! printf '%s\n' "$fileDetails" > "$exportedFilename"; then
        logMe "ERROR: Unable to write Computer Extension Attribute ${extensionName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$extensionName" "" "fail" "Export failed"
        return 1
    fi

    if [[ ! -s "$exportedFilename" ]]; then
        logMe "ERROR: Exported Computer Extension Attribute was empty: ${extensionName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$extensionName" "" "fail" "Empty export"
        return 1
    fi
    logMe "Exporting Extension Attribute: ${extensionName}"
    update_display_list "Update" "" "$extensionName" "" "success" "Finished"
    return 0
}

###############################################
#
# Backup Configuration Profiles functions
#
###############################################

function backup_configuration_profiles ()
{
    local ProfileList=""
    local -a ProfileIDs=()
    local ProfileCount=0
    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""
    local JAMF_API_KEY="JSSResource/osxconfigurationprofiles"
    # PURPOSE: Backup all of the configuration profiles from JAMF
    logMe "Backing up configuration profiles"
    logMe "Destination: ${location_ConfigurationProfiles}"
    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi
    if ! ProfileList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve Configuration Profiles."
        return 1
    fi
    if ! print -r -- "$ProfileList" | jq -e '.os_x_configuration_profiles | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Configuration Profile list did not contain the expected array."
        return 1
    fi
    if ! create_listitem_list "The following configuration profiles are being downloaded from JAMF" "json" '.os_x_configuration_profiles[]?.name // empty' "$ProfileList" "SF=gear.circle.fill,color=brown"; then
        logMe "ERROR: Unable to create the Configuration Profile progress list."
        return 1
    fi

    ProfileIDs=("${(@f)$(print -r -- "$ProfileList" | jq -r '.os_x_configuration_profiles[]?.id // empty')}")
    ProfileCount=${#ProfileIDs[@]}

    if (( ProfileCount > 0 )); then
        execute_in_parallel "$BACKGROUND_TASKS" extract_profile_details "${ProfileIDs[@]}"
        parallelStatus=$?
    fi

    # Display how many Configuration Profile files were downloaded.
    DirectoryCount=$(find "$location_ConfigurationProfiles" -maxdepth 1 -type f -name '*.mobileconfig' 2>/dev/null | wc -l | xargs)

    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Configuration Profile exports failed. ${DirectoryCount} files are currently present on disk."
    elif (( ProfileCount != DirectoryCount )); then
        logMsg="WARNING: Expected ${ProfileCount} Configuration Profiles, but found ${DirectoryCount} files on disk."
    else
        logMsg="INFO: All ${ProfileCount} Configuration Profiles downloaded successfully."
    fi
	logMe "${logMsg}"
    logMsg="$DirectoryCount Configuration profiles were downloaded to $location_ConfigurationProfiles."
    logMe "${logMsg}" 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
    return "$parallelStatus"
}

function extract_profile_details ()
{
    # PURPOSE: extract the JSON string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF

    local profileName
    local id="${1:-}"
    local profileContents
    local formatted_profileName
    local exported_filename
    local JAMF_API_KEY="JSSResource/osxconfigurationprofiles"
    local jsonBlob=""
    

    [[ -z "$id" ]] && return 0

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Configuration Profile ID: ${id}"
        return 1
    fi

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "$JAMF_API_KEY/id/$id" "json"); then
        return 1
    fi

    profileName=$(extract_json_value "$jsonBlob" '.os_x_configuration_profile.general.name // empty')
    profileContents=$(extract_json_value "$jsonBlob" '.os_x_configuration_profile.general.payloads // empty')

    if [[ -z "$profileName" ]]; then
        logMe "ERROR: Configuration Profile ID ${id} did not contain a name."
        update_display_list "Update" "" "Profile ID ${id}" "" "fail" "Missing profile name"
        return 1
    fi

    formatted_profileName=$(make_apfs_safe "$profileName")

    if [[ -z "$formatted_profileName" ]]; then
        logMe "ERROR: Unable to create a valid filename for Configuration Profile ${profileName}."
        update_display_list "Update" "" "$profileName" "" "fail" "Invalid filename"
        return 1
    fi

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z "$profileContents" ]]; then
        update_display_list "Update" "" "$profileName" "" "fail" "Not exported"
        logMe "Configuration Profile ${profileName} was not exported because its payload is empty."
        printf 'Configuration Profile: %s\n' "$formatted_profileName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    update_display_list "Update" "" "$profileName" "" "wait" "Working..."
    exported_filename="${location_ConfigurationProfiles}/${formatted_profileName}.mobileconfig"

    if ! printf '%s\n' "$profileContents" > "$exported_filename"; then
        logMe "ERROR: Unable to write Configuration Profile ${profileName}."
        /bin/rm -f -- "$exported_filename"
        update_display_list "Update" "" "$profileName" "" "fail" "Export failed"
        return 1
    fi

    if [[ ! -s "$exported_filename" ]]; then
        logMe "ERROR: Configuration Profile export was empty for ${profileName}."
        /bin/rm -f -- "$exported_filename"
        update_display_list "Update" "" "$profileName" "" "fail" "Empty export"
        return 1
    fi

    logMe "Exporting Configuration Profile: ${profileName}"
    update_display_list "Update" "" "$profileName" "" "success" "Finished"
    return 0
}

###############################################
#
# Backup Computer Policy functions
#
###############################################

function backup_computer_policies ()
{
    # PURPOSE:
    #   Backup all Computer Policies from Jamf Pro as JSON.

    local PolicyList=""
    local -a PolicyIDs=()
    local PolicyCount=0
    local DirectoryCount=0
    local logMsg=""
    local parallelStatus=0

    logMe "Backing up Computer Policies"
    logMe "Destination: ${location_ComputerPolicies}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Retrieve the complete policy list as JSON.
    #

    if ! PolicyList=$(JAMF_retrieve_data_blob "JSSResource/policies" "json"); then
        logMe "ERROR: Unable to retrieve the Jamf Pro policy list."
        return 1
    fi

    #
    # Validate the expected JSON structure.
    #

    if ! print -r -- "$PolicyList" | jq -e '.policies | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Policy list did not contain a valid policies array."
        return 1
    fi

    #
    # Build the SwiftDialog list from the JSON response.
    #

    if ! create_listitem_list "The following Computer Policies are being downloaded from JAMF" "json" ".policies[]?.name // empty" "$PolicyList" "SF=apple.terminal.fill"; then
        logMe "ERROR: Unable to create the Computer Policy progress list."
        return 1
    fi

    #
    # Extract all Jamf Policy IDs.
    #

    PolicyIDs=("${(@f)$(print -r -- "$PolicyList" | jq -r '.policies[]?.id // empty')}")
    PolicyCount=${#PolicyIDs[@]}
    logMe "Found ${PolicyCount} Computer Policies to export."

    #
    # Export each policy in parallel.
    #

    if (( PolicyCount > 0 )); then
        execute_in_parallel "$BACKGROUND_TASKS" extract_computer_policies_details "${PolicyIDs[@]}"
        parallelStatus=$?
    fi

    #
    # Count the JSON files actually written to disk.
    #

    DirectoryCount=$(find "$location_ComputerPolicies" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | xargs)
    
    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Computer Policy exports failed. ${DirectoryCount} files are currently present on disk."
    elif (( PolicyCount != DirectoryCount )); then
        logMsg="WARNING: Expected ${PolicyCount} Computer Policies, but found ${DirectoryCount} files on disk."
    else
        logMsg="INFO: All ${PolicyCount} Computer Policies downloaded successfully."
    fi
    logMe "$logMsg"
    logMsg="${DirectoryCount} Computer Policies were downloaded to ${location_ComputerPolicies}."
    logMe "$logMsg"
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    return "$parallelStatus"
}

function extract_computer_policies_details ()
{
    # PURPOSE:
    #   Retrieve an individual Jamf Computer Policy as JSON and
    #   export the complete policy record to disk.
    #
    # PARAMETERS:
    #   $1 = Jamf Policy ID
    #
    # RETURNS:
    #   0 = Policy exported successfully
    #   1 = Retrieval, parsing, filename, or export failure

    local id="${1:-}"
    local jsonBlob=""
    local policyName=""
    local formattedPolicyName=""
    local exportedFilename=""

    [[ -z "$id" ]] && return 0

    #
    # Validate the incoming Jamf Policy ID.
    #

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf Policy ID: ${id}"
        return 1
    fi

    #
    # Retrieve the complete policy record as JSON.
    #

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "JSSResource/policies/id/${id}" "json"); then
        logMe "ERROR: Unable to retrieve Computer Policy ID ${id}."
        update_display_list "Update" "" "Policy ID ${id}" "" "fail" "Retrieval failed"
        return 1
    fi

    #
    # Verify that the response contains a valid policy object.
    #

    if ! print -r -- "$jsonBlob" | jq -e '.policy | objects' >/dev/null 2>&1; then
        logMe "ERROR: Invalid policy JSON returned for Policy ID ${id}."
        update_display_list "Update" "" "Policy ID ${id}" "" "fail" "Invalid JSON"
        return 1
    fi

    #
    # Extract the policy name.
    #

    policyName=$(print -r -- "$jsonBlob" | jq -r '.policy.general.name // empty')

    if [[ -z "$policyName" ]]; then
        logMe "ERROR: Computer Policy ID ${id} does not contain a valid policy name."
        update_display_list "Update" "" "Policy ID ${id}" "" "fail" "Missing policy name"
        return 1
    fi

    #
    # Create an APFS-safe filename.
    #

    formattedPolicyName=$(make_apfs_safe "$policyName")
    if [[ -z "$formattedPolicyName" ]]; then
        logMe "ERROR: Unable to create a valid filename for Computer Policy: ${policyName}"
        update_display_list "Update" "" "$policyName" "" "fail" "Invalid filename"
        return 1
    fi

    exportedFilename="${location_ComputerPolicies}/${formattedPolicyName}.json"

    update_display_list "Update" "" "$policyName" "" "wait" "Working..."
    logMe "Exporting Computer Policy: ${policyName}"

    #
    # Write formatted JSON directly to disk.
    #
    # Using jq here both formats the JSON and performs another
    # validation pass before the backup file is committed.
    #

    if ! print -r -- "$jsonBlob" | jq '.' > "$exportedFilename"; then
        logMe "ERROR: Failed to export Computer Policy: ${policyName}"

        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$policyName" "" "fail" "Not exported!"
        printf 'Computer Policy: %s\n' "$formattedPolicyName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    #
    # Confirm that a nonempty backup file was written.
    #

    if [[ ! -s "$exportedFilename" ]]; then
        logMe "ERROR: Computer Policy backup was empty: ${policyName}"

        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$policyName" "" "fail" "Empty export"
        printf 'Computer Policy: %s\n' "$formattedPolicyName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    update_display_list "Update" "" "$policyName" "" "success" "Finished"
    return 0
}

###############################################
#
# Compare Computer Policy functions
#
###############################################

function compare_profiles_menu ()
{
    local message=""
    local temp=""
    local returnCode=0
    local GroupList=""
    local array=""
    local JAMF_API_KEY="JSSResource/osxconfigurationprofiles"

    message="**Compare Configuration Profiles**<br><br>Please select two configuration profiles to compare.  This comparison only does the payload part of the profiles.<br><br>The comparison results will be displayed in a TextEdit window.  Any line with a '|' separator denotes a difference between the two files."

    if ! construct_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to create SwiftDialog header."
        return 1
    fi
    create_dropdown_message_body "" "" "first" || return 1
    # Read in the JAMF configuration profiles and create a dropdown list of them
    if ! GroupList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve Configuration Profiles for the Compare Profiles menu."
        return 1
    fi

    if ! print -r -- "$GroupList" | jq -e '.os_x_configuration_profiles | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Configuration Profile list returned for the Compare Profiles menu."
        return 1
    fi
    if ! array=$(construct_dropdown_list_items "$GroupList" '.os_x_configuration_profiles[]'); then
        logMe "ERROR: Unable to construct the Configuration Profile dropdown list."
        return 1
    fi
    if [[ -z "$array" ]]; then
        logMe "ERROR: No Configuration Profiles were available for selection."
        return 1
    fi
    create_dropdown_message_body "Select 1st Profile:" "$array" || return 1
    create_dropdown_message_body "Select 2nd Profile:" "$array" || return 1
    create_dropdown_message_body "" "" "last" || return 1
    close_dialog_json_object || return 1

	temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    returnCode=$?
    case "$returnCode" in
        0)
            ;;

        2)
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}."
            return 1
            ;;
    esac

    menu_compareFirstProfile=$(print -r -- "$temp" | jq -r '.["Select 1st Profile:"].selectedValue')
    menu_compareSecondProfile=$(print -r -- "$temp" | jq -r '.["Select 2nd Profile:"].selectedValue')
    menu_compareSave=$(print -r -- "$temp" | jq -r '.saveresults')
}

function compare_profiles ()
{
    # PURPOSE:
    #   Compare the payload contents of two Jamf configuration profiles.
    #
    #   Profile records are retrieved from the Classic API as JSON.
    #   The embedded XML payload is extracted with jq, normalized with
    #   xmllint, written to disk, and compared with diff.
    #
    # RETURNS:
    #   0 = Comparison completed successfully
    #   1 = Retrieval, parsing, formatting, or file-write failure

    local JAMF_API_KEY="JSSResource/osxconfigurationprofiles"

    local firstGroupID=""
    local firstGroupName=""
    local secondGroupID=""
    local secondGroupName=""

    local firstJSON=""
    local secondJSON=""

    local firstConfig=""
    local secondConfig=""

    local firstFile=""
    local secondFile=""
    local diffFile=""

    logMe "Comparing Configuration Profiles"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Parse the selected profile IDs and names.
    #

    firstGroupID="${menu_compareFirstProfile%% - *}"
    firstGroupName="${menu_compareFirstProfile#* - }"

    secondGroupID="${menu_compareSecondProfile%% - *}"
    secondGroupName="${menu_compareSecondProfile#* - }"


    #
    # Validate both Jamf profile IDs.
    #

    if [[ "$firstGroupID" != <-> ]]; then
        logMe "ERROR: Invalid first Configuration Profile ID: ${firstGroupID}"
        return 1
    fi

    if [[ "$secondGroupID" != <-> ]]; then
        logMe "ERROR: Invalid second Configuration Profile ID: ${secondGroupID}"
        return 1
    fi

    logMe "Comparing Configuration Profile: ${firstGroupName}"
    logMe "Against Configuration Profile: ${secondGroupName}"

    #
    # Create APFS-safe filenames.
    #

    firstGroupName=$(make_apfs_safe "$firstGroupName")
    secondGroupName=$(make_apfs_safe "$secondGroupName")

    if [[ -z "$firstGroupName" || -z "$secondGroupName" ]]; then
        logMe "ERROR: Unable to create valid Configuration Profile filenames."
        return 1
    fi

    firstFile="${location_CompareConfigFiles}/${firstGroupName}.txt"
    secondFile="${location_CompareConfigFiles}/${secondGroupName}.txt"
    diffFile="${location_CompareConfigFiles}/Diff Results.txt"

    #
    # Retrieve the first Configuration Profile as JSON.
    #

    if ! firstJSON=$(JAMF_retrieve_data_blob "${JAMF_API_KEY}/id/${firstGroupID}" "json"); then
        logMe "ERROR: Unable to retrieve Configuration Profile: ${firstGroupName}"
        return 1
    fi

    #
    # Retrieve the second Configuration Profile as JSON.
    #

    if ! secondJSON=$(JAMF_retrieve_data_blob "${JAMF_API_KEY}/id/${secondGroupID}" "json"); then
        logMe "ERROR: Unable to retrieve Configuration Profile: ${secondGroupName}"
        return 1
    fi

    #
    # Validate both responses.
    #

    if ! print -r -- "$firstJSON" | jq -e '.os_x_configuration_profile | objects' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Configuration Profile JSON returned for ID ${firstGroupID}."
        return 1
    fi

    if ! print -r -- "$secondJSON" | jq -e '.os_x_configuration_profile | objects' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Configuration Profile JSON returned for ID ${secondGroupID}."
        return 1
    fi

    #
    # Extract the embedded XML payload from each JSON response.
    #

    firstConfig=$(print -r -- "$firstJSON" | jq -r '.os_x_configuration_profile.general.payloads // empty')
    secondConfig=$(print -r -- "$secondJSON" | jq -r '.os_x_configuration_profile.general.payloads // empty')

    if [[ -z "$firstConfig" ]]; then
        logMe "ERROR: Configuration Profile '${firstGroupName}' contains no payload data."
        return 1
    fi

    if [[ -z "$secondConfig" ]]; then
        logMe "ERROR: Configuration Profile '${secondGroupName}' contains no payload data."
        return 1
    fi

    #
    # Normalize the embedded XML so formatting differences do not
    # create unnecessary differences in the comparison.
    #

    if ! firstConfig=$(print -r -- "$firstConfig" | xmllint --format - 2>/dev/null); then
        logMe "ERROR: Unable to format payload XML for '${firstGroupName}'."
        return 1
    fi

    if ! secondConfig=$(print -r -- "$secondConfig" | xmllint --format - 2>/dev/null); then
        logMe "ERROR: Unable to format payload XML for '${secondGroupName}'."
        return 1
    fi

    #
    # Write both normalized payloads to disk.
    #

    if ! printf '%s\n' "$firstConfig" > "$firstFile"; then
        logMe "ERROR: Unable to write comparison file: ${firstFile}"
        return 1
    fi

    if ! printf '%s\n' "$secondConfig" > "$secondFile"; then
        logMe "ERROR: Unable to write comparison file: ${secondFile}"
        return 1
    fi

    #
    # Compare the normalized profile payloads.
    #
    # diff returns:
    #   0 = identical
    #   1 = differences found
    #  >1 = actual error
    #

    diff -y "$firstFile" "$secondFile" > "$diffFile"
    local diffStatus=$?

    case "$diffStatus" in
        0)
            logMe "INFO: Configuration Profiles are identical."
            ;;

        1)
            logMe "INFO: Differences found between the Configuration Profiles."
            ;;

        *)
            logMe "ERROR: Unable to compare Configuration Profiles. diff returned ${diffStatus}."
            return 1
            ;;
    esac

    #
    # Open the comparison results.
    #

    if ! open "$diffFile"; then
        logMe "WARNING: Comparison completed, but the results file could not be opened."
    fi

    return 0
}

###############################################
#
# Create VCF Card functions
#
###############################################

function create_vcf_cards_menu ()
{
    # PURPOSE: Create the VCF Cards menu
    # RETURN: None
    # EXPECTED: None
    local JAMF_API_KEY="JSSResource/computergroups"
    local message=""
    local temp=""
    local returnCode=0
    local GroupList=""
    local array=""

    message="**Create VCF Cards Additional Options**<br><br>You have selected to create VCF cards from the JAMF server.  If you select a group, it will create a subfolder under the main contacts folder with all of the entries.<br><br>There are some additional items to select:"
    if ! construct_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct the VCF options dialog."
        return 1
    fi
    create_checkbox_message_body "Only users with managed systems" "onlyManaged" "" "true" "false" "first" || return 1
    create_checkbox_message_body "Create email recipient list" "csvfile" "" "true" "false" || return 1
    create_checkbox_message_body "Compose Email after completion" "compose" "" "true" "false" "last" || return 1
    append_dialog_json_separator || return 1

    create_dropdown_message_body "" "" "first" || return 1
    # Read in the JAMF groups and create a dropdown list of them
    if ! GroupList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve Computer Groups for the VCF menu."
        return 1
    fi

    if ! print -r -- "$GroupList" | jq -e '.computer_groups | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Computer Group list returned for the VCF menu."
        return 1
    fi
    if ! array=$(construct_dropdown_list_items "$GroupList" '.computer_groups[]'); then
        logMe "ERROR: Unable to construct the Computer Group dropdown list."
        return 1
    fi
    if [[ -z "$array" ]]; then
        logMe "ERROR: No Computer Groups were available for selection."
        return 1
    fi
    create_dropdown_message_body "Select Groups:" "$array" || return 1
    create_dropdown_message_body "" "" "last" || return 1
    close_dialog_json_object || return 1

	temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    returnCode=$?
    case "$returnCode" in
        0)
            ;;

        2)
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}."
            return 1
            ;;
    esac

    menu_onlyManagedUsers=$(print -r -- "$temp" | jq -r '.onlyManaged')
    menu_createCSV=$(print -r -- "$temp" | jq -r '.csvfile')
    menu_composeEmail=$(print -r -- "$temp" | jq -r '.compose')
    #menu_groupVCFExport=$(print -r -- "$temp" | jq -r '.SelectedOption')
    menu_groupVCFExport=$(print -r -- "$temp" | jq -r '.["Select Groups:"].selectedValue // empty')
}

function create_vcf_cards ()
{
    # PURPOSE:
    #   Create VCF cards from Jamf Pro user records using JSON.
    #
    #   When a Computer Group is selected:
    #     1. Retrieve the group as JSON.
    #     2. Retrieve USER_AND_LOCATION for each computer.
    #     3. Resolve the assigned email to a Jamf user.
    #     4. Deduplicate Jamf user IDs.
    #     5. Build the progress list using Jamf usernames.
    #     6. Export each user through extract_user_details.
    #
    #   When no Computer Group is selected:
    #     1. Retrieve all Jamf users.
    #     2. Build the progress list from the user names.
    #     3. Export each user through extract_user_details.
    #
    # RETURNS:
    #   0 = VCF export completed successfully
    #   1 = Retrieval, parsing, directory, dialog, or worker failure

    local GroupID=""
    local GroupName=""
    local formattedGroupName=""

    local computerList=""
    local inventoryData=""
    local userData=""
    local UserList=""

    local userEmail=""
    local encodedUserEmail=""
    local userID=""
    local userName=""
    local item=""

    local groupUsersJSON='{"users":[]}'

    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""

    local contactsRoot="$location_Contacts"
    local contactsDestination="$location_Contacts"
    local contactsFile=""

    local emailAddress=""
    local emailClean=""

    local -a ComputerIDs=()
    local -a UserIDs=()

    local -A SeenUserIDs=()
    local -A SeenEmails=()

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Normalize the selected Computer Group value.
    #

    menu_groupVCFExport=$(print -r -- "$menu_groupVCFExport" | xargs)

    #
    # Export users associated with a selected Computer Group.
    #

    if [[ -n "$menu_groupVCFExport" ]]; then

        #
        # The selected dropdown value is expected to use:
        #
        #   ID - Group Name
        #

        GroupID="${menu_groupVCFExport%% - *}"
        GroupName="${menu_groupVCFExport#* - }"

        GroupID=$(print -r -- "$GroupID" | xargs)
        GroupName=$(print -r -- "$GroupName" | xargs)

        if [[ "$GroupID" != <-> ]]; then
            logMe "ERROR: Invalid Computer Group ID selected for VCF export: ${GroupID}"
            return 1
        fi

        [[ -z "$GroupName" ]] && GroupName="Computer Group ${GroupID}"

        logMe "Creating VCF Cards from Jamf users in group: ${GroupName}"

        #
        # Create a group-specific destination directory.
        #

        formattedGroupName=$(make_apfs_safe "$GroupName")

        if [[ -z "$formattedGroupName" ]]; then
            logMe "ERROR: Unable to create a valid VCF directory name for ${GroupName}."
            return 1
        fi

        contactsDestination="${contactsRoot}/${formattedGroupName}"

        if [[ ! -d "$contactsDestination" ]]; then
            if ! /bin/mkdir -p "$contactsDestination"; then
                logMe "ERROR: Unable to create VCF export directory: ${contactsDestination}"
                return 1
            fi
        fi

        logMe "Destination: ${contactsDestination}"
        logMe "Retrieving Computer Group members for: ${GroupName}"

        #
        # Retrieve the selected Computer Group as JSON.
        #

        if ! computerList=$(JAMF_retrieve_data_blob "JSSResource/computergroups/id/${GroupID}" "json"); then
            logMe "ERROR: Unable to retrieve Computer Group ID ${GroupID}."
            return 1
        fi

        if ! print -r -- "$computerList" | jq -e '
                type == "object"
                and (.computer_group | type == "object")
                and (.computer_group.computers == null or (.computer_group.computers | type) == "array")' >/dev/null 2>&1; then
            logMe "ERROR: Invalid Computer Group JSON returned for ID ${GroupID}."
            return 1
        fi

        #
        # Extract clean numeric Jamf computer IDs.
        #

        ComputerIDs=("${(@f)$(print -r -- "$computerList" | jq -r '
                    .computer_group.computers[]?.id
                    | select(. != null)
                    | tostring
                    | select(test("^[0-9]+$"))')}")

        if (( ${#ComputerIDs[@]} == 0 )); then
            logMe "INFO: Computer Group '${GroupName}' has no members."

            "$SW_DIALOG" \
                --title "No Members in Group" \
                --message "The group ${GroupName} has no members, so no VCF cards will be created." \
                --button1text "OK" \
                --quitkey 0 \
                --icon "$SD_ICON_FILE"

            return 0
        fi

        logMe "Found ${#ComputerIDs[@]} computers in ${GroupName}."

        #
        # Resolve each group computer to an assigned email, then
        # resolve that email to a Jamf user.
        #
        # Do not create the progress dialog yet. The dialog must use
        # Jamf usernames because extract_user_details updates rows
        # using userShortName.
        #

        for item in "${ComputerIDs[@]}"; do

            if ! inventoryData=$(JAMF_get_inventory_record "USER_AND_LOCATION" "id=='${item}'"); then
                logMe "WARNING: Unable to retrieve USER_AND_LOCATION inventory for computer ID ${item}."
                continue
            fi

            userEmail=$(print -r -- "$inventoryData" | jq -r '.results[0].userAndLocation.email // empty')

            if [[ -z "$userEmail" || "$userEmail" == "null" ]]; then
                logMe "INFO: Computer ID ${item} does not have an assigned user email."
                continue
            fi

            #
            # Avoid resolving the same email address more than once.
            #

            if [[ -n "${SeenEmails[$userEmail]:-}" ]]; then
                continue
            fi

            SeenEmails[$userEmail]=1

            #
            # URL-encode the email before using it in the Classic API
            # endpoint.
            #

            encodedUserEmail=$(jq -nr --arg value "$userEmail" '$value | @uri')

            if [[ -z "$encodedUserEmail" ]]; then
                logMe "WARNING: Unable to encode user email: ${userEmail}"
                continue
            fi

            if ! userData=$(JAMF_retrieve_data_blob "JSSResource/users/email/${encodedUserEmail}" "json"); then
                logMe "WARNING: Unable to retrieve Jamf user for email ${userEmail}."
                continue
            fi

            if ! print -r -- "$userData" | jq -e 'type == "object" and (.users == null or (.users | type) == "array")' >/dev/null 2>&1; then
                logMe "WARNING: Invalid Jamf user lookup JSON returned for ${userEmail}."
                continue
            fi

            #
            # Capture both the user ID and the Jamf short name.
            #
            # The short name becomes the SwiftDialog row title so it
            # matches updates sent by extract_user_details.
            #

            while IFS=$'\t' read -r userID userName; do
                [[ "$userID" == <-> ]] || continue

                [[ -z "$userName" ]] && userName="User ID ${userID}"

                if [[ -n "${SeenUserIDs[$userID]:-}" ]]; then
                    continue
                fi

                SeenUserIDs[$userID]=1
                UserIDs+=("$userID")

                if ! groupUsersJSON=$(print -r -- "$groupUsersJSON" | jq -c --argjson id "$userID" --arg name "$userName" '.users += [{id: $id, name: $name}]'); then
                    logMe "ERROR: Unable to add Jamf user ID ${userID} to the VCF progress list."
                    return 1
                fi

            done < <(print -r -- "$userData" | jq -r '.users[]? |[(.id // empty),(.name // ("User ID " + ((.id // "") | tostring)))]| @tsv')
        done

        #
        # No resolved Jamf users is a successful empty result.
        #

        if (( ${#UserIDs[@]} == 0 )); then
            logMe "INFO: No Jamf users were resolved from Computer Group ${GroupName}."

            "$SW_DIALOG" \
                --title "No Users Found" \
                --message "No Jamf users with assigned email addresses were found for ${GroupName}." \
                --button1text "OK" \
                --quitkey 0 \
                --icon "$SD_ICON_FILE"

            return 0
        fi

        #
        # Verify the normalized progress-list JSON.
        #

        if ! print -r -- "$groupUsersJSON" | jq -e 'type == "object" and (.users | type == "array") and (.users | length > 0) ' >/dev/null 2>&1; then
            logMe "ERROR: Group VCF user processing produced invalid progress-list JSON."
            return 1
        fi

        #
        # Build the group progress list using Jamf usernames.
        #

        if ! create_listitem_list "The following VCF Cards are being created from the Jamf group:<br><br>**${GroupName}**" "json" '.users[]?.name // empty' "$groupUsersJSON" "SF=person.fill"; then
            logMe "ERROR: Unable to create the group VCF progress list."
            return 1
        fi

    #
    # Export every Jamf user.
    #

    else
        logMe "Creating VCF Cards from all Jamf users"
        logMe "Destination: ${contactsDestination}"

        if ! UserList=$(JAMF_retrieve_data_blob "JSSResource/users" "json"); then
            logMe "ERROR: Unable to retrieve the Jamf Pro user list."
            return 1
        fi

        if ! print -r -- "$UserList" | jq -e '.users | arrays' >/dev/null 2>&1; then
            logMe "ERROR: Jamf user list did not contain a valid users array."
            return 1
        fi

        UserIDs=("${(@f)$(print -r -- "$UserList" | jq -r '.users[]?.id | select(. != null) | tostring | select(test("^[0-9]+$")) ')}")

        if (( ${#UserIDs[@]} == 0 )); then
            logMe "INFO: No Jamf users were found for VCF export."
            return 0
        fi

        if ! create_listitem_list "The following VCF Cards are being created from the Jamf server" "json" '.users[]?.name // empty' "$UserList" "SF=person.fill"; then
            logMe "ERROR: Unable to create the VCF progress list."
            return 1
        fi
    fi

    #
    # Establish the final destination before the parallel workers
    # inherit the operation state.
    #

    if [[ -z "$contactsDestination" ]]; then
        logMe "ERROR: VCF destination is empty."
        return 1
    fi

    if [[ ! -d "$contactsDestination" ]]; then
        if ! /bin/mkdir -p "$contactsDestination"; then
            logMe "ERROR: Unable to create VCF destination: ${contactsDestination}"
            return 1
        fi
    fi

    location_Contacts="$contactsDestination"
    contactsFile="${location_Contacts}/contacts.txt"

    #
    # Remove recipient-list data and stale lock data from the
    # previous run.
    #

    /bin/rm -f -- "$contactsFile"
    /bin/rm -rf -- "${contactsFile}.lock"

    logMe "Found ${#UserIDs[@]} unique Jamf users to export."

    #
    # Export each user in parallel.
    #

    execute_in_parallel "$BACKGROUND_TASKS" extract_user_details "${UserIDs[@]}"

    parallelStatus=$?

    if (( parallelStatus != 0 )); then
        logMe "WARNING: One or more VCF export workers failed."
    fi

    #
    # Count the VCF files currently present.
    #

    DirectoryCount=$(find "$location_Contacts" -maxdepth 1 -type f -name '*.vcf' 2>/dev/null | wc -l | xargs)

    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more VCF exports failed. ${DirectoryCount} VCF files are currently present in ${location_Contacts}."
    else
        logMsg="INFO: VCF processing completed for ${#UserIDs[@]} Jamf users. ${DirectoryCount} VCF files are currently present in ${location_Contacts}."
    fi

    logMe "$logMsg"

    update_display_list "progress" "" "" "" "$logMsg" 100

    if [[ "$menu_composeEmail" == "true" ]]; then
        update_display_list "buttonchange" "Send Email"
    fi

    update_display_list "buttonenable"

    wait

    #
    # Open the selected email application with the exported addresses.
    #

    if [[ "$menu_composeEmail" == "true" ]]; then
        if [[ -s "$contactsFile" ]]; then
            emailAddress=$(<"$contactsFile")

            emailClean=$(print -r -- "$emailAddress" | tr -d '\r\n')

            if [[ -n "$emailClean" ]]; then
                if ! /usr/bin/open -b "$EMAIL_APP" "mailto:${emailClean}?subject=Subject&body=Type%20your%20message%20here"; then
                    logMe "WARNING: Unable to open the configured email application."
                fi
            fi
        else
            logMe "INFO: No email addresses were exported for email composition."
        fi
    fi
    location_Contacts="$contactsRoot"
    return "$parallelStatus"
}

function extract_user_details ()
{
    # PURPOSE:
    #   Retrieve one Jamf user as JSON and create a VCF card.
    #
    # PARAMETERS:
    #   $1 = Jamf user ID
    #
    # RETURNS:
    #   0 = VCF exported or user intentionally skipped
    #   1 = Retrieval, parsing, filename, or file-write failure

    local id="${1:-}"
    local jsonBlob=""
    local userShortName=""
    local userFullName=""
    local userEmail=""
    local userPosition=""
    local managed="true"
    local formattedUserName=""
    local userVCFBlob=""
    local exportedFilename=""
    local contactsFile=""

    [[ -z "$id" ]] && return 0

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf user ID passed to extract_user_details: ${id}"
        return 1
    fi

    #
    # Retrieve the complete Jamf user record as JSON.
    #

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "JSSResource/users/id/${id}" "json"); then
        logMe "ERROR: Unable to retrieve Jamf user ID ${id}."
        update_display_list "Update" "" "User ID ${id}" "" "fail" "Retrieval failed"
        return 1
    fi

    if ! print -r -- "$jsonBlob" | jq -e '.user | objects' >/dev/null 2>&1; then
        logMe "ERROR: Invalid user JSON returned for user ID ${id}."

        update_display_list "Update" "" "User ID ${id}" "" "fail" "Invalid JSON"
        return 1
    fi

    #
    # Extract the user fields.
    #

    userShortName=$(print -r -- "$jsonBlob" | jq -r '.user.name // empty')
    userFullName=$(print -r -- "$jsonBlob" | jq -r '.user.full_name // empty')
    userEmail=$(print -r -- "$jsonBlob" | jq -r '.user.email_address // empty')
    userPosition=$(print -r -- "$jsonBlob" | jq -r '.user.position // empty')

    [[ -z "$userShortName" ]] && userShortName="User ID ${id}"

    if [[ -z "$userFullName" ]]; then
        logMe "ERROR: User ${userShortName} was not exported because the full name is empty."
        update_display_list "Update" "" "$userShortName" "" "fail" "Missing full name"
        printf 'User VCF empty full name: %s\n' "$userShortName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    #
    # A VCF can technically omit an email address, but this utility
    # uses the exported addresses for CSV/email composition.
    #

    if [[ -z "$userEmail" ]]; then
        logMe "INFO: User ${userShortName} does not have an email address."

        update_display_list "Update" "" "$userShortName" "" "success" "No email address"
        return 0
    fi

    update_display_list "Update" "" "$userShortName" "" "wait" "Working..."

    #
    # Check whether the user has a managed computer when requested.
    #

    if [[ "$menu_onlyManagedUsers" == "true" ]]; then
        managed=$(extract_assigned_systems "$jsonBlob")

        if [[ "$managed" != "true" ]]; then
            update_display_list "Update" "" "$userShortName" "" "success" "No managed systems"
            return 0
        fi
    fi

    formattedUserName=$(make_apfs_safe "$userShortName")

    if [[ -z "$formattedUserName" ]]; then
        logMe "ERROR: Unable to create a valid VCF filename for ${userShortName}."

        update_display_list "Update" "" "$userShortName" "" "fail" "Invalid filename"
        return 1
    fi

    if ! userVCFBlob=$(export_vcf_file "$userFullName" "$userEmail" "$userPosition"); then
        logMe "ERROR: Unable to generate VCF content for ${userShortName}."
        update_display_list "Update" "" "$userShortName" "" "fail" "VCF generation failed"
        return 1
    fi

    exportedFilename="${location_Contacts}/${formattedUserName}.vcf"

    logMe "Exporting user ${userShortName} (${userFullName})"

    if ! printf '%s\n' "$userVCFBlob" > "$exportedFilename"; then
        logMe "ERROR: Unable to write VCF file for ${userShortName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$userShortName" "" "fail" "VCF export failed"
        return 1
    fi

    if [[ ! -s "$exportedFilename" ]]; then
        logMe "ERROR: VCF export was empty for ${userShortName}."
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$userShortName" "" "fail" "Empty VCF export"
        return 1
    fi

    #
    # Append the email address when CSV or email composition was selected.
    #
    # Since workers execute in parallel, use the same mkdir lock pattern
    # used for serialized command-file writes.
    #

    if [[ "$menu_composeEmail" == "true" ||
          "$menu_createCSV" == "true" ]]
    then
        contactsFile="${location_Contacts}/contacts.txt"

        local contactsLock="${contactsFile}.lock"
        local -i lockAttempts=0
        local -i maxLockAttempts=200

        while ! /bin/mkdir "$contactsLock" 2>/dev/null; do
            (( lockAttempts++ ))

            if (( lockAttempts >= maxLockAttempts )); then
                logMe "ERROR: Timed out waiting for the contacts-file lock."
                /bin/rm -rf -- "$contactsLock"
                update_display_list "Update" "" "$userShortName" "" "fail" "Recipient-list write failed"
                return 1
            fi
            /bin/sleep 0.05
        done

        if ! printf '%s;' "$userEmail" >> "$contactsFile"; then
            logMe "ERROR: Unable to append ${userEmail} to the recipient list."
            /bin/rm -rf -- "$contactsLock"
            update_display_list "Update" "" "$userShortName" "" "fail" "Recipient-list write failed"
            return 1
        fi

        /bin/rmdir "$contactsLock" 2>/dev/null || /bin/rm -rf -- "$contactsLock"
    fi

    update_display_list "Update" "" "$userShortName" "" "success" "Finished"
    return 0
}

function extract_assigned_systems ()
{
    # PURPOSE:
    #   Determine whether a Jamf user has at least one managed computer.
    #
    # PARAMETERS:
    #   $1 = Jamf user JSON
    #
    # OUTPUT:
    #   true or false

    local jsonBlob="${1:-}"
    local inventoryData=""
    local managedStatus="false"
    local id=""

    local -a ComputerIDs=()

    if [[ -z "$jsonBlob" ]]; then
        print -r -- "false"
        return 0
    fi

    if ! print -r -- "$jsonBlob" | jq -e '.user | objects' >/dev/null 2>&1; then
        print -r -- "false"
        return 0
    fi

    #
    # Normalize the common Classic API representations:
    #
    #   .user.links.computers
    #   .user.computers
    #
    # Each can be an array, a single object, or absent.
    #

    ComputerIDs=("${(@f)$(
        print -r -- "$jsonBlob" |
            jq -r '
                def as_array:
                    if . == null then
                        []
                    elif type == "array" then
                        .
                    elif type == "object" then
                        [.]
                    else
                        []
                    end;

                (
                    .user.links.computers
                    // .user.computers
                    // []
                    | as_array
                )[]?
                | .id
                | select(. != null)
                | tostring
                | select(test("^[0-9]+$"))
            '
    )}")

    if (( ${#ComputerIDs[@]} == 0 )); then
        print -r -- "false"
        return 0
    fi

    for id in "${ComputerIDs[@]}"; do
        if ! inventoryData=$(JAMF_get_inventory_record_byID "$id" "GENERAL"); then
            continue
        fi

        if ! print -r -- "$inventoryData" | jq -e 'type == "object"' >/dev/null 2>&1; then
            continue
        fi

        managedStatus=$(print -r -- "$inventoryData" | jq -r '.general.remoteManagement.managed // false')

        if [[ "$managedStatus" == "true" ]]; then
            print -r -- "true"
            return 0
        fi
    done

    print -r -- "false"
    return 0
}

function export_vcf_file ()
{
    # PURPOSE:
    #   Generate a version 3.0 VCF record.
    #
    # PARAMETERS:
    #   $1 = Full name
    #   $2 = Email address
    #   $3 = Position/title

    local fullName="${1:-}"
    local emailAddress="${2:-}"
    local position="${3:-}"

    [[ -z "$fullName" ]] && return 1

    #
    # Escape backslashes first, followed by VCF punctuation and
    # embedded line breaks.
    #

    fullName="${fullName//\\/\\\\}"
    fullName="${fullName//;/\\;}"
    fullName="${fullName//,/\\,}"
    fullName="${fullName//$'\r'/}"
    fullName="${fullName//$'\n'/\\n}"

    emailAddress="${emailAddress//\\/\\\\}"
    emailAddress="${emailAddress//;/\\;}"
    emailAddress="${emailAddress//,/\\,}"
    emailAddress="${emailAddress//$'\r'/}"
    emailAddress="${emailAddress//$'\n'/}"

    position="${position//\\/\\\\}"
    position="${position//;/\\;}"
    position="${position//,/\\,}"
    position="${position//$'\r'/}"
    position="${position//$'\n'/\\n}"

    printf '%s\n' \
        "BEGIN:VCARD" \
        "VERSION:3.0" \
        "FN:${fullName}" \
        "EMAIL:${emailAddress}" \
        "TITLE:${position}" \
        "END:VCARD"

    return 0
}

###############################################
#
# Create Smart Groups functions
#
###############################################

function export_computer_groups ()
{
    # PURPOSE:
    #   Export all Smart and Static Computer Groups from Jamf Pro
    #   using JSON for retrieval and processing.

    local JAMF_API_KEY="JSSResource/computergroups"
    local GroupList=""
    local -a GroupIDs=()
    local GroupCount=0
    local DirectoryCount=0
    local logMsg=""
    local parallelStatus=0
    

    logMe "Exporting Computer Groups from JAMF"
    logMe "Destination: ${location_backupSmartGroups}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Retrieve the complete Computer Group list as JSON.
    #

    if ! GroupList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve the Jamf Pro Computer Group list."
        return 1
    fi

    #
    # Validate the expected JSON structure.
    #

    if ! print -r -- "$GroupList" | jq -e '.computer_groups | arrays' >/dev/null 2>&1; then
        logMe "ERROR: Computer Group list did not contain a valid computer_groups array."
        return 1
    fi

    #
    # Populate the SwiftDialog list.
    #

    if ! create_listitem_list "The following Smart / Static groups are being exported from the JAMF server" "json" ".computer_groups[]?.name // empty" "$GroupList" "SF=person.3.fill"; then
        logMe "ERROR: Unable to create the Computer Group progress list."
        return 1
    fi

    #
    # Extract the Jamf Computer Group IDs.
    #

    GroupIDs=("${(@f)$(print -r -- "$GroupList" | jq -r '.computer_groups[]?.id // empty')}")
    GroupCount=${#GroupIDs[@]}
    logMe "Found ${GroupCount} Computer Groups to export."

    #
    # Export each Computer Group in parallel.
    #

    if (( GroupCount > 0 )); then
        execute_in_parallel "$BACKGROUND_TASKS" export_computer_group_details "${GroupIDs[@]}"
        parallelStatus=$?
    fi

    #
    # Count the group report files written to disk.
    #

    DirectoryCount=$(find "$location_backupSmartGroups" -type f -name '*.txt' 2>/dev/null | wc -l | xargs)
    
    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Computer Group exports failed. ${DirectoryCount} files are currently present on disk."
    elif (( GroupCount != DirectoryCount )); then
        logMsg="WARNING: Expected ${GroupCount} Computer Groups, but found ${DirectoryCount} files on disk."
    else
        logMsg="INFO: All ${GroupCount} Computer Groups downloaded successfully."
    fi

    logMe "$logMsg"
    logMsg="${DirectoryCount} Computer Groups were downloaded to ${location_backupSmartGroups}."
    logMe "$logMsg"

    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    return "$parallelStatus"
}

function export_computer_group_details ()
{
    # PURPOSE:
    #   Retrieve an individual Jamf Computer Group as JSON and export
    #   its Smart Group criteria or Static Group membership.
    #
    # PARAMETERS:
    #   $1 = Jamf Computer Group ID
    #
    # RETURNS:
    #   0 = Group exported successfully
    #   1 = Retrieval, parsing, filename, or export failure

    local id="${1:-}"
    local JAMF_API_KEY="JSSResource/computergroups"

    local jsonBlob=""
    local groupID=""
    local groupName=""
    local groupIsSmart="false"
    local groupType=""
    local groupCondition=""
    local formattedGroupName=""
    local exportedFilename=""

    [[ -z "$id" ]] && return 0

    #
    # Validate the incoming Jamf Computer Group ID.
    #

    if [[ "$id" != <-> ]]; then
        logMe "ERROR: Invalid Jamf Computer Group ID: ${id}"
        return 1
    fi

    #
    # Retrieve the complete Computer Group as JSON.
    #

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "${JAMF_API_KEY}/id/${id}" "json"); then
        logMe "ERROR: Unable to retrieve Computer Group ID ${id}."
        update_display_list "Update" "" "Group ID ${id}" "" "fail" "Retrieval failed"
        return 1
    fi

    #
    # Validate the JSON structure.
    #

    if ! print -r -- "$jsonBlob" | jq -e '.computer_group | objects' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Computer Group JSON returned for ID ${id}."
        update_display_list "Update" "" "Group ID ${id}" "" "fail" "Invalid JSON"
        return 1
    fi

    #
    # Extract the common group information.
    #

    groupID=$(print -r -- "$jsonBlob" | jq -r '.computer_group.id // empty')
    groupName=$(print -r -- "$jsonBlob" | jq -r '.computer_group.name // empty')
    groupIsSmart=$(print -r -- "$jsonBlob" | jq -r '.computer_group.is_smart // false')

    [[ -z "$groupID" ]] && groupID="$id"

    if [[ -z "$groupName" ]]; then
        logMe "ERROR: Computer Group ID ${id} does not contain a valid group name."
        update_display_list "Update" "" "Group ID ${id}" "" "fail" "Missing group name"
        printf 'Computer Group export: Group ID %s\n' "$id" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    #
    # Determine whether this is a Smart or Static Computer Group.
    #

    if [[ "$groupIsSmart" == "true" ]]; then
        groupType="Smart"
    else
        groupType="Static"
    fi

    #
    # Build the group report.
    #

    if [[ "$groupType" == "Smart" ]]; then

        #
        # Build each Smart Group criterion directly from its JSON
        # object instead of maintaining parallel arrays.
        #
        # \u0027 is used for the single quote character so the jq
        # program remains safely enclosed in shell single quotes.
        #

        if ! groupCondition=$(
            print -r -- "$jsonBlob" |
                jq -r '
                    .computer_group as $group
                    |
                    "Smart group (\($group.id // ""))",
                    "",
                    "Conditions:",
                    "",
                    (
                        $group.criteria[]?
                        |
                        (
                            if .opening_paren == true
                            then "("
                            else ""
                            end
                        )
                        +
                        "\u0027\(.name // "")\u0027 "
                        +
                        "\(.search_type // "") "
                        +
                        "\u0027\(.value // "")\u0027"
                        +
                        (
                            if .closing_paren == true
                            then ")"
                            else ""
                            end
                        )
                        +
                        (
                            if (.and_or // "") == ""
                            then ""
                            else " \(.and_or | ascii_upcase)"
                            end
                        )
                    )
                '
        )
        then
            logMe "ERROR: Unable to parse Smart Group criteria for ${groupName}."

            update_display_list "Update" "" "$groupName" "" "fail" "Criteria parsing failed"
            return 1
        fi

    else

        #
        # Build the Static Group member list directly from JSON.
        #

        if ! groupCondition=$(
            print -r -- "$jsonBlob" |
                jq -r '
                    .computer_group as $group
                    |
                    "Static group (\($group.id // ""))",
                    "",
                    "Members:",
                    "",
                    (
                        $group.computers[]?.name
                        // empty
                    )
                '
        )
        then
            logMe "ERROR: Unable to parse Static Group members for ${groupName}."

            update_display_list \
                "Update" "" "$groupName" "" \
                "fail" "Member parsing failed"

            return 1
        fi

    fi

    #
    # Make the group name safe for APFS.
    #

    formattedGroupName=$(make_apfs_safe "$groupName")

    if [[ -z "$formattedGroupName" ]]; then
        logMe "ERROR: Unable to create a valid filename for Computer Group: ${groupName}"
        update_display_list "Update" "" "$groupName" "" "fail" "Invalid filename"
        return 1
    fi

    #
    # Make sure the appropriate destination exists.
    #

    if [[ ! -d "${location_backupSmartGroups}/${groupType}" ]]; then
        if ! /bin/mkdir -p "${location_backupSmartGroups}/${groupType}"; then
            logMe "ERROR: Unable to create ${groupType} Computer Group backup directory."
            update_display_list "Update" "" "$groupName" "" "fail" "Directory creation failed"
            return 1
        fi
    fi

    exportedFilename="${location_backupSmartGroups}/${groupType}/${formattedGroupName}.txt"
    update_display_list "Update" "" "$groupName" "" "wait" "Working..."
    logMe "Exporting ${groupType} group: ${groupName}"

    #
    # Write the finished report.
    #

    if ! printf '%s\n' "$groupCondition" > "$exportedFilename"; then
        logMe "ERROR: Unable to export ${groupType} group: ${groupName}"
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$groupName" "" "fail" "Not exported"
        printf 'Computer Group export: %s\n' "$groupName" >> "$ERROR_LOG_LOCATION"
        return 1
    fi

    if [[ ! -s "$exportedFilename" ]]; then
        logMe "ERROR: Exported Computer Group report was empty: ${groupName}"
        /bin/rm -f -- "$exportedFilename"
        update_display_list "Update" "" "$groupName" "" "fail" "Empty export"
        return 1
    fi

    update_display_list "Update" "" "$groupName" "" "success" "Finished"
    return 0
}

###############################################
#
# Export Application Usage
#
###############################################

function export_usage_menu ()
{
    # PURPOSE: Export Application Usage for a users / group
    # RETURN: None
    # EXPECTED: None
    local JAMF_API_KEY="JSSResource/computergroups"
    local message=""
    local temp=""
    local returnCode=0
    local GroupList=""
    local array=""

    message="**Export Usage Additional Options**<br><br>You have selected to export Application Usage from the JAMF server.<br><br>There are some additional items to select:"
    if ! construct_header_settings "$message" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to construct the Application Usage options dialog."
        return 1
    fi
    create_textfield_message_body "StartDate" "Starting date for report:" "first" || return 1
    create_textfield_message_body "EndDate" "Enter Ending date:" "last" || return 1
    append_dialog_json_separator || return 1

    create_dropdown_message_body "" "" "first" || return 1
    # Read in the JAMF groups and create a dropdown list of them
    if ! GroupList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        logMe "ERROR: Unable to retrieve Computer Groups for the Application Usage menu."
        return 1
    fi

    if ! print -r -- "$GroupList" |
        jq -e '.computer_groups | arrays' >/dev/null 2>&1
    then
        logMe "ERROR: Invalid Computer Group list returned for the Application Usage menu."
        return 1
    fi

    if ! array=$(construct_dropdown_list_items "$GroupList" '.computer_groups[]'); then
        logMe "ERROR: Unable to construct the Computer Group dropdown list."
        return 1
    fi
    if [[ -z "$array" ]]; then
        logMe "ERROR: No Computer Groups were available for selection."
        return 1
    fi
    create_dropdown_message_body "Select Groups:" "$array" || return 1
    create_dropdown_message_body "" "" "last" || return 1
    close_dialog_json_object || return 1

	temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    returnCode=$?
    case "$returnCode" in
        0)
            ;;

        2)
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}."
            return 1
            ;;
    esac

    menu_startDateUsage=$(print -r -- "$temp" | jq -r '.StartDate')
    menu_endDateUsage=$(print -r -- "$temp" | jq -r '.EndDate')

    if ! menu_startDateUsage=$(/bin/date -j -f "%m/%d/%y" "$menu_startDateUsage" "+%Y-%m-%d" 2>/dev/null); then
        logMe "ERROR: Invalid Application Usage starting date."
        return 1
    fi

    if ! menu_endDateUsage=$(/bin/date -j -f "%m/%d/%y" "$menu_endDateUsage" "+%Y-%m-%d" 2>/dev/null); then
        logMe "ERROR: Invalid Application Usage ending date."
        return 1
    fi

    if [[ "$menu_startDateUsage" > "$menu_endDateUsage" ]]; then
        logMe "ERROR: Application Usage starting date occurs after the ending date."
        return 1
    fi

    #menu_groupAppUsage=$(print -r -- "$temp" | jq -r '.SelectedOption')
    menu_groupAppUsage=$(print -r -- "$temp" | jq -r '.["Select Groups:"].selectedValue // empty')
}

function export_usage ()
{
    # PURPOSE:
    #   Export application-usage reports for each computer in the
    #   selected Jamf Computer Group.
    #
    #   The group and application-usage records are retrieved and
    #   evaluated as JSON.
    #
    # RETURNS:
    #   0 = Export completed successfully or group contains no computers
    #   1 = Validation, retrieval, directory, dialog, or worker failure

    local JAMF_API_KEY="JSSResource/computergroups"

    local GroupID=""
    local GroupName=""
    local formattedGroupName=""
    local computerList=""
    local ComputerCount=0
    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""

    local -a ComputerRecords=()

    #
    # Parse the selected value:
    #
    #   ID - Group Name
    #

    GroupID="${menu_groupAppUsage%% - *}"
    GroupName="${menu_groupAppUsage#* - }"

    GroupID=$(print -r -- "$GroupID" | xargs)
    GroupName=$(print -r -- "$GroupName" | xargs)

    if [[ "$GroupID" != <-> ]]; then
        logMe "ERROR: Invalid Computer Group ID selected for Application Usage: ${GroupID}"
        return 1
    fi

    [[ -z "$GroupName" ]] && GroupName="Computer Group ${GroupID}"

    logMe "Exporting Application Usage for Computer Group: ${GroupName}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Create the group-specific report destination.
    #

    formattedGroupName=$(make_apfs_safe "$GroupName")

    if [[ -z "$formattedGroupName" ]]; then
        logMe "ERROR: Unable to create a valid Application Usage directory name for ${GroupName}."
        return 1
    fi

    formatted_ApplicationUsage_name="${location_ApplicationUsage}/${formattedGroupName}"

    if [[ ! -d "$formatted_ApplicationUsage_name" ]]; then
        if ! /bin/mkdir -p "$formatted_ApplicationUsage_name"; then
            logMe "ERROR: Unable to create Application Usage directory: ${formatted_ApplicationUsage_name}"
            return 1
        fi
    fi

    logMe "Destination: ${formatted_ApplicationUsage_name}"

    #
    # Retrieve the selected Computer Group as JSON.
    #

    if ! computerList=$(JAMF_retrieve_data_blob "${JAMF_API_KEY}/id/${GroupID}" "json"); then
        logMe "ERROR: Unable to retrieve Computer Group ID ${GroupID}."
        return 1
    fi

    #
    # Validate the expected group object and computers collection.
    #

    if ! print -r -- "$computerList" | jq -e 'type == "object" and (.computer_group | type == "object") and (.computer_group.computers == null or (.computer_group.computers | type) == "array")' >/dev/null 2>&1; then
        logMe "ERROR: Invalid Computer Group JSON returned for ID ${GroupID}."
        return 1
    fi

    #
    # Build one compact JSON object per computer:
    #
    #   {"id":123,"name":"MacBook Neo"}
    #
    # Each compact JSON object remains one quoted zsh array element.
    #

    ComputerRecords=("${(@f)$(print -r -- "$computerList" | jq -c '
                .computer_group.computers[]?
                |
                select(
                    (.id != null)
                    and
                    ((.id | tostring) | test("^[0-9]+$"))
                )
                |
                {
                    id: .id,
                    name: (
                        .name
                        // ("Computer ID " + (.id | tostring))
                    )
                }')}")

    ComputerCount=${#ComputerRecords[@]}

    if (( ComputerCount == 0 )); then
        logMe "INFO: Computer Group '${GroupName}' contains no computers."
        return 0
    fi

    logMe "Found ${ComputerCount} computers in ${GroupName}."

    #
    # Build and display the progress list through the hardened
    # SwiftDialog JSON helper.
    #

    if ! create_listitem_list "The following Usage reports will be generated from group:<br><br>**${GroupName}**" "json" '.computer_group.computers[]? | (.name // ("Computer ID " + (.id | tostring)))' "$computerList" "SF=desktopcomputer.and.macbook"
    then
        logMe "ERROR: Unable to create the Application Usage progress list."
        return 1
    fi

    #
    # Export usage for each computer.
    #

    execute_in_parallel "$BACKGROUND_TASKS" export_usage_details "${ComputerRecords[@]}"
    parallelStatus=$?
    #
    # Count only CSV reports generated by this operation.
    #
    # This count is not compared against ComputerCount because a
    # computer with no usage data legitimately creates no report.
    #
    DirectoryCount=$(find "$formatted_ApplicationUsage_name" -maxdepth 1 -type f -name '*.csv' 2>/dev/null | wc -l | xargs)
    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more Application Usage workers failed. ${DirectoryCount} reports are currently present on disk."
    else
        logMsg="INFO: Application Usage processing completed for ${ComputerCount} computers. ${DirectoryCount} reports were generated."
    fi

    logMe "$logMsg"
    logMsg="${DirectoryCount} Application Usage reports were downloaded to ${formatted_ApplicationUsage_name}."
    logMe "$logMsg"

    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    return "$parallelStatus"
}

function export_usage_details ()
{
    # PURPOSE:
    #   Retrieve one computer's application-usage data as JSON and
    #   export the results to a properly escaped CSV file.
    #
    # PARAMETERS:
    #   $1 = Compact JSON computer record:
    #
    #        {"id":123,"name":"MacBook Neo"}
    #
    # RETURNS:
    #   0 = Report exported or no usage data was available
    #   1 = Invalid input, retrieval, parsing, or file-write failure

    local computerRecord="${1:-}"
    local computerID=""
    local computerName=""
    local formattedComputerName=""
    local endpoint=""
    local jsonBlob=""
    local usageCount=0
    local filename=""

    [[ -z "$computerRecord" ]] && return 0

    #
    # Validate the compact worker JSON.
    #

    if ! print -r -- "$computerRecord" | jq -e 'type == "object" and (.id != null)' >/dev/null 2>&1; then
        logMe "ERROR: Invalid computer record passed to export_usage_details."
        return 1
    fi

    computerID=$(print -r -- "$computerRecord" | jq -r '.id // empty')
    computerName=$(print -r -- "$computerRecord" | jq -r '.name // ("Computer ID " + (.id | tostring))')

    if [[ "$computerID" != <-> ]]; then
        logMe "ERROR: Invalid Jamf computer ID passed to Application Usage worker: ${computerID}"
        update_display_list "Update" "" "$computerName" "" "fail" "Invalid computer ID"
        return 1
    fi

    [[ -z "$computerName" ]] && computerName="Computer ID ${computerID}"

    #
    # Use the stable Jamf computer ID instead of the computer name.
    #
    # This avoids malformed URLs caused by spaces, apostrophes,
    # percent signs, or other characters in computer names.
    #

    endpoint="JSSResource/computerapplicationusage/id/${computerID}/${menu_startDateUsage}_${menu_endDateUsage}"

    if ! jsonBlob=$(JAMF_retrieve_data_blob_global "$endpoint" "json"); then
        logMe "ERROR: Unable to retrieve Application Usage for ${computerName}."

        update_display_list "Update" "" "$computerName" "" "fail" "Retrieval failed"
        return 1
    fi

    #
    # Validate the response and normalize the usage collection.
    #

    if ! print -r -- "$jsonBlob" |
        jq -e '
            type == "object"
            and (
                .computer_application_usage == null
                or
                (.computer_application_usage | type) == "array"
                or
                (.computer_application_usage | type) == "object"
            )
        ' >/dev/null 2>&1
    then
        logMe "ERROR: Invalid Application Usage JSON returned for ${computerName}."
        update_display_list "Update" "" "$computerName" "" "fail" "Invalid JSON"
        return 1
    fi

    #
    # Count actual application records, not just usage-date objects.
    #
    # This handles both:
    #
    #   computer_application_usage = [...]
    #
    # and:
    #
    #   computer_application_usage = {...}
    #

    if ! usageCount=$(
        print -r -- "$jsonBlob" |
            jq -r '
                def as_array:
                    if . == null then
                        []
                    elif type == "array" then
                        .
                    elif type == "object" then
                        [.]
                    else
                        []
                    end;

                (
                    .computer_application_usage
                    | as_array
                )
                |
                map(
                    .apps
                    | as_array
                    | length
                )
                |
                add // 0
            '
    )
    then
        logMe "ERROR: Unable to count Application Usage records for ${computerName}."
        update_display_list "Update" "" "$computerName" "" "fail" "Parsing failed"
        return 1
    fi

    if [[ "$usageCount" != <-> ]]; then
        logMe "ERROR: Invalid Application Usage count for ${computerName}: ${usageCount}"
        update_display_list "Update" "" "$computerName" "" "fail" "Invalid usage count"
        return 1
    fi

    #
    # No usage data is an expected result, not a failed worker.
    #

    if (( usageCount == 0 )); then
        logMe "INFO: No Application Usage data found for ${computerName} between ${menu_startDateUsage} and ${menu_endDateUsage}."
        update_display_list "Update" "" "$computerName" "" "success" "No usage data"
        return 0
    fi

    formattedComputerName=$(make_apfs_safe "$computerName")

    if [[ -z "$formattedComputerName" ]]; then
        logMe "ERROR: Unable to create a valid Application Usage filename for ${computerName}."
        update_display_list "Update" "" "$computerName" "" "fail" "Invalid filename"
        return 1
    fi

    filename="${formatted_ApplicationUsage_name}/${formattedComputerName}.csv"
    update_display_list "Update" "" "$computerName" "" "wait" "Working..."
    logMe "Creating Application Usage report for ${computerName}: ${filename}"

    #
    # Generate the complete CSV with jq.
    #
    # @csv provides correct escaping for commas, quotation marks,
    # empty strings, and other CSV-sensitive values.
    #

    if ! {
        printf '"Computer Name","Date","Application Name","Total Hours","Version"\n'

        print -r -- "$jsonBlob" |
            jq -r \
                --arg computerName "$computerName" \
                '
                    def as_array:
                        if . == null then
                            []
                        elif type == "array" then
                            .
                        elif type == "object" then
                            [.]
                        else
                            []
                        end;

                    (
                        .computer_application_usage
                        | as_array
                    )[]? as $usage
                    |
                    (
                        $usage.apps
                        | as_array
                    )[]?
                    |
                    [
                        $computerName,
                        ($usage.date // "Unknown"),
                        (.name // "Unknown"),
                        (.foreground // 0),
                        (.version // "Unknown")
                    ]
                    |
                    @csv
                '
    } > "$filename"
    then
        logMe "ERROR: Unable to write Application Usage report for ${computerName}."
        /bin/rm -f -- "$filename"
        update_display_list "Update" "" "$computerName" "" "fail" "Export failed"
        return 1
    fi

    if [[ ! -s "$filename" ]]; then
        logMe "ERROR: Application Usage report was empty for ${computerName}."
        /bin/rm -f -- "$filename"
        update_display_list "Update" "" "$computerName" "" "fail" "Empty export"
        return 1
    fi

    update_display_list "Update" "" "$computerName" "" "success" "${usageCount} usage record(s)"

    return 0
}

###############################################
#
# Export User with multiple System
#
###############################################

function export_user_multiple ()
{
    # PURPOSE:
    #   Export reports for Jamf usernames assigned to multiple computers.
    #
    # RETURNS:
    #   0 = Export completed successfully or no duplicate users were found
    #   1 = Retrieval, JSON processing, dialog, directory, or worker failure

    local UserList=""
    local duplicateUsersJSON=""
    local UserCount=0
    local DirectoryCount=0
    local parallelStatus=0
    local logMsg=""

    local -a UserIDs=()

    logMe "Exporting Users with multiple systems"
    logMe "Destination: ${location_UsersMultipleSystems}"

    if ! JAMF_ensure_valid_token; then
        logMe "ERROR: Unable to obtain a valid Jamf Pro API token."
        return 1
    fi

    #
    # Ensure the report destination exists.
    #

    if [[ ! -d "$location_UsersMultipleSystems" ]]; then
        if ! /bin/mkdir -p "$location_UsersMultipleSystems"; then
            logMe "ERROR: Unable to create multiple-system user directory: ${location_UsersMultipleSystems}"
            return 1
        fi
    fi

    #
    # Retrieve USER_AND_LOCATION inventory data.
    #

    if ! UserList=$(JAMF_get_inventory_record "USER_AND_LOCATION"); then
        logMe "ERROR: Unable to retrieve USER_AND_LOCATION inventory records."
        return 1
    fi

    #
    # Validate the expected inventory structure.
    #

    if ! print -r -- "$UserList" | jq -e 'type == "object" and (.results | type == "array")' >/dev/null 2>&1; then
        logMe "ERROR: Invalid inventory JSON received while processing users with multiple systems."
        return 1
    fi

    #
    # Create a normalized JSON object containing usernames that occur
    # more than once:
    #
    #   {"users":["user1","user2"]}
    #
    # Keeping this as JSON lets the hardened dialog helper process it
    # without manual list-item construction.
    #

    if ! duplicateUsersJSON=$(
        print -r -- "$UserList" |
            jq -c '
                {
                    users: (
                        [
                            .results[]?
                            | .userAndLocation.username
                            // empty
                        ]
                        |
                        map(
                            select(
                                type == "string"
                                and length > 0
                            )
                        )
                        |
                        sort
                        |
                        group_by(.)
                        |
                        map(
                            select(length > 1)
                            | .[0]
                        )
                    )}'); then
        logMe "ERROR: Unable to identify users assigned to multiple systems."
        return 1
    fi

    if ! print -r -- "$duplicateUsersJSON" | jq -e ' type == "object" and (.users | type == "array")' >/dev/null 2>&1; then
        logMe "ERROR: Duplicate-user processing produced invalid JSON."
        return 1
    fi

    UserIDs=("${(@f)$(print -r -- "$duplicateUsersJSON" | jq -r '.users[]?')}")
    UserCount=${#UserIDs[@]}
    logMe "Found ${UserCount} users assigned to multiple systems."

    #
    # No duplicate usernames is a successful result.
    #
    # Do not create or update a SwiftDialog progress window when
    # there is no work to display.
    #

    if (( UserCount == 0 )); then
        logMe "INFO: No users assigned to multiple systems were found."
        return 0
    fi

    #
    # Build and display the progress list through the hardened
    # SwiftDialog JSON helper.
    #

    if ! create_listitem_list "Exporting list of users with multiple systems" "json" '.users[]?' "$duplicateUsersJSON" "SF=person.2.fill"; then
        logMe "ERROR: Unable to create the multiple-system user progress list."
        return 1
    fi

    #
    # Export one report per duplicate username.
    #

    execute_in_parallel "$BACKGROUND_TASKS" export_user_multiple_details "${UserIDs[@]}"
    parallelStatus=$?


    #
    # Count the generated CSV reports.
    #

    DirectoryCount=$(find "$location_UsersMultipleSystems" -maxdepth 1 -type f -name '*.csv' 2>/dev/null | wc -l | xargs)

    if (( parallelStatus != 0 )); then
        logMsg="WARNING: One or more multi-system user exports failed. ${DirectoryCount} files are currently present on disk."
    elif (( UserCount != DirectoryCount )); then
        logMsg="WARNING: Expected ${UserCount} multi-system user reports, but found ${DirectoryCount} files on disk."
    else
        logMsg="INFO: All ${DirectoryCount} multi-system user reports exported successfully."
    fi

    logMe "$logMsg"
    logMsg="${DirectoryCount} users with multiple systems were exported to ${location_UsersMultipleSystems}."
    logMe "$logMsg"

    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    return "$parallelStatus"
}

function export_user_multiple_details ()
{
    # PURPOSE:
    #   Export computer information for a user assigned to multiple systems.
    #
    # PARAMETERS:
    #   $1 = Jamf username

    local username="${1:-}"
    local UserList
    local filename
    local machineCount
    local -a machineList
    local -a managedList
    local -a machineLastContact
    local -i i

    [[ -z "$username" ]] && return 0

    if ! UserList=$(JAMF_get_inventory_record "GENERAL" "userAndLocation.username=='${username}'"); then
        logMe "ERROR: Unable to retrieve inventory records for user ${username}."
        update_display_list "Update" "" "$username" "" "fail" "Inventory lookup failed"
        return 1
    fi

    if ! print -r -- "$UserList" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: Invalid JSON returned for user ${username}."
        return 1
    fi


    machineList=("${(@f)$(print -r -- "$UserList" | jq -r '.results[].general.name // empty')}")
    managedList=("${(@f)$(print -r -- "$UserList" | jq -r '.results[].general.remoteManagement.managed // false')}")
    machineLastContact=("${(@f)$(print -r -- "$UserList" | jq -r '.results[].general.lastContactTime // "Unknown"')}")

    machineCount=$(print -r -- "$UserList" | jq -r '.totalCount // 0')

    update_display_list "Update" "" "$username" "" "wait" "Working..."

    local formatted_username

    formatted_username=$(make_apfs_safe "$username")

    if [[ -z "$formatted_username" ]]; then
        logMe "ERROR: Unable to create a valid filename for user ${username}."
        return 1
    fi
    filename="${location_UsersMultipleSystems}/${formatted_username}.csv"

    logMe "Creating Multi-user System report: for ${username}"
    if ! {
        printf '"Computer Name","Managed","Last Contact"\n'

        for (( i = 1; i <= ${#machineList[@]}; i++ )); do
            printf '"%s","%s","%s"\n' \
                "${machineList[i]//\"/\"\"}" \
                "${managedList[i]//\"/\"\"}" \
                "${machineLastContact[i]//\"/\"\"}"
        done
    } > "$filename"
    then
        logMe "ERROR: Unable to write multi-system report for ${username}."
        /bin/rm -f -- "$filename"
        update_display_list "Update" "" "$username" "" "fail" "Export failed"
        return 1
    fi
    update_display_list "Update" "" "$username" "" "success" "${machineCount} Systems"

    return 0
}

###############################################
#
# Application functions
#
###############################################

function extract_json_value ()
{
    # PURPOSE:
    #   Extract one or more values from JSON using a jq expression.
    #
    # PARAMETERS:
    #   $1 = JSON content
    #   $2 = jq expression
    #
    # RETURNS:
    #   0 = jq filter completed successfully
    #   1 = Missing input, invalid JSON, or jq failure
    #
    # OUTPUT:
    #   Raw jq output on stdout

    local jsonBlob="${1:-}"
    local jqFilter="${2:-}"

    if [[ -z "$jsonBlob" ]]; then
        logMe "ERROR: extract_json_value called without JSON content."
        return 1
    fi

    if [[ -z "$jqFilter" ]]; then
        logMe "ERROR: extract_json_value called without a jq filter."
        return 1
    fi

    if ! print -r -- "$jsonBlob" | jq -e . >/dev/null 2>&1; then
        logMe "ERROR: extract_json_value received invalid JSON."
        return 1
    fi

    if ! print -r -- "$jsonBlob" | jq -r "$jqFilter"; then
        logMe "ERROR: Unable to apply jq filter: ${jqFilter}"
        return 1
    fi

    return 0
}

function construct_header_settings ()
{
    # PURPOSE:
    #   Write the shared header for form and option dialogs.
    #
    # PARAMETERS:
    #   $1 = Dialog message
    #
    # OUTPUT:
    #   A partial JSON object on stdout.

    local message="${1:-}"
    local titleFont=""
    local headerJSON=""

    titleFont="shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"

    if ! headerJSON=$(
        jq -cn \
            --arg icon "$SD_ICON_FILE" \
            --arg message "$message" \
            --arg bannerImage "$SD_BANNER_IMAGE" \
            --arg bannerTitle "$SD_WINDOW_TITLE" \
            --arg subtitle "$BANNER_SUBTITLE" \
            --arg infoBox "$SD_INFO_BOX_MSG" \
            --arg titleFont "$titleFont" \
            '{
                icon: $icon,
                message: $message,
                bannerimage: $bannerImage,
                bannertitle: $bannerTitle,
                subtitle: $subtitle,
                infobox: $infoBox,
                titlefont: $titleFont,
                button1text: "OK",
                button2text: "Cancel",
                moveable: true,
                quitkey: "0",
                ontop: true,
                width: 800,
                height: 540,
                json: true,
                messagefont: "shadow=1",
                messageposition: "top"
            }'
    )
    then
        logMe "ERROR: Unable to construct SwiftDialog form header."
        return 1
    fi

    headerJSON="${headerJSON%?}"

    printf '%s\n' "${headerJSON},"

    return 0
}

function execute_in_parallel ()
{
    local max_jobs="${1:-1}"
    local task_function="${2:-}"
    local -i failed=0

    shift 2

    local -a items=("$@")
    local -a pids=()
    local item
    local pid

    if [[ "$max_jobs" != <-> ]] || (( max_jobs < 1 )); then
        logMe "ERROR: Invalid parallel job count: ${max_jobs}"
        return 1
    fi

    if [[ -z "$task_function" ]] || (( ! $+functions[$task_function] )); then
        logMe "ERROR: Invalid parallel function: ${task_function}"
        return 1
    fi

    for item in "${items[@]}"; do
        "$task_function" "$item" &
        pids+=("$!")

        if (( ${#pids[@]} >= max_jobs )); then
            for pid in "${pids[@]}"; do
                wait "$pid" || (( failed++ ))
            done

            pids=()
        fi
    done

    for pid in "${pids[@]}"; do
        wait "$pid" || (( failed++ ))
    done

    if (( failed > 0 )); then
        logMe "WARNING: ${failed} parallel task(s) failed while running ${task_function}."
        return 1
    fi

    return 0
}

function display_welcome_msg ()
{
    local message=""
    local temp=""
    local returnCode=0
    local -a MainDialogBody=()
    # PURPOSE: Display the welcome message to the user
    message="This set of utilities is designed to backup various items from your JAMF server.  Please select a destination folder location below:<br><br>##### + If chosen, additional screens will appear for the selected option."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --width 890
        --height 840
        --ignorednd
        --json
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
        --infotext "${jamfpro_url}"
        --checkboxstyle switch
        --helpmessage "This script will backup various items from your JAMF server.  Please select the items you wish to backup and the location to store them."
        --textfield "Select a storage location",fileselect,filetype=folder,required,name=StorageLocation
        --checkbox " ------- Computer Based Actions -------",disabled
        --checkbox "Backup Computer Policies (*.json)",checked,name=BackupComputerPolicy
        --checkbox "Backup Computer Extension Attributes (*.sh)",checked,name=BackupComputerExtensions
        --checkbox "Backup Configuration Profiles (*.mobileconfig)",checked,name=BackupConfigurationProfiles
        --checkbox "Backup Smart Groups & Static Groups (*.txt)",checked,name=BackupSmartGroups
        --checkbox "Export failed MDM commands (*.txt) +",checked,name=BackupFailedMDMCommands
        --checkbox "Compare two Configuration Profiles (*.txt) +",checked,name=CompareConfigProfiles
        --checkbox " ------- User Based Actions -------",disabled
        --checkbox "Create VCF cards or send emails from Groups (*.vcf) +",checked,name=createVCFcards
        --checkbox "Export Application Usage from Users / Groups (*.csv) +",checked,name=exportApplicationUsage
        --checkbox "Export Users with multiple systems (*.csv)",checked,name=exportUsersMultipleSystems
        --checkbox " ------- System Based Actions -------",disabled
        --checkbox "Backup Self Service Icons (*.png)",checked,name=BackupSSIcons
        --checkbox "Backup System Scripts (*.sh)",checked,name=BackupJAMFScripts
        )

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    case "$returnCode" in
        0)
            ;;

        2)
            cleanup_and_exit 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}."
            return 1
            ;;
    esac

    menu_backupSSIcons=$( print -r -- "$temp" | jq -r '.BackupSSIcons')
    menu_backupJAMFScripts=$( print -r -- "$temp" | jq -r '.BackupJAMFScripts' )
    menu_createVCFcards=$( print -r -- "$temp" | jq -r '.createVCFcards' )
    menu_storageLocation=$( print -r -- "$temp" | jq -r '.StorageLocation' )
    menu_computerea=$( print -r -- "$temp" | jq -r '.BackupComputerExtensions' )
    menu_configurationProfiles=$( print -r -- "$temp" | jq -r '.BackupConfigurationProfiles')
    menu_backupFailedMDM=$( print -r -- "$temp" | jq -r '.BackupFailedMDMCommands' )
    menu_backupSmartGroups=$( print -r -- "$temp" | jq -r '.BackupSmartGroups' )
    menu_exportApplicationUsage=$( print -r -- "$temp" | jq -r '.exportApplicationUsage' )
    menu_backupComputerPolicies=$( print -r -- "$temp" | jq -r '.BackupComputerPolicy' )
    menu_UsersMultipleSystems=$( print -r -- "$temp" | jq -r '.exportUsersMultipleSystems' )
    menu_CompareConfigProfiles=$( print -r -- "$temp" | jq -r '.CompareConfigProfiles')
    
    if [[ "$menu_backupFailedMDM" == "true" ]]; then
        export_failed_mdm_commands_menu || return 1
    fi

    if [[ "$menu_CompareConfigProfiles" == "true" ]]; then
        compare_profiles_menu || return 1
    fi

    if [[ "$menu_createVCFcards" == "true" ]]; then
        create_vcf_cards_menu || return 1
    fi

    if [[ "$menu_exportApplicationUsage" == "true" ]]; then
        export_usage_menu || return 1
    fi

    return 0

}

function show_backup_errors ()
{
    local initialMessage="${1:-}"
    local message=""
    local line=""
    local -a MainDialogBody=()
    message="${initialMessage}<br><br>"
     while IFS= read -r line; do
        # Process each line as needed, for example, print it
        message+="* $line<br>"
    done < "${ERROR_LOG_LOCATION}"

    message+="<br>This might be due to improper formatting in a script, or empty data contents.  You will need to investigate each issue manually.<br><br>The error log is located at:<br> ${ERROR_LOG_LOCATION}"

	MainDialogBody=(
        --message "$message"
        --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
        --subtitle "${BANNER_SUBTITLE}"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 900
        --height 660
        --ignorednd
        --quitkey 0
        --button1text "OK"
    )
	
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
}

function check_directories ()
{
    # PURPOSE:
    #   Define and create the directories required by the selected
    #   JAMF System Utilities operations.

    local make_directory=""

    location_SSIcons="${menu_storageLocation}/SSIcons"
    location_JAMFScripts="${menu_storageLocation}/SystemScripts"
    location_ComputerEA="${menu_storageLocation}/ComputerEA"
    location_Contacts="${menu_storageLocation}/Contacts"
    location_ConfigurationProfiles="${menu_storageLocation}/ConfigurationProfiles"
    location_FailedMDM="${menu_storageLocation}/FailedMDM"
    location_backupSmartGroups="${menu_storageLocation}/ComputerGroups"
    location_ApplicationUsage="${menu_storageLocation}/AppUsage"
    location_UsersMultipleSystems="${menu_storageLocation}/MultipleComputerUsers"
    location_ComputerPolicies="${menu_storageLocation}/ComputerPolicies"
    location_CompareConfigFiles="${menu_storageLocation}/CompareConfigFiles"

    for make_directory in \
        "$menu_storageLocation" \
        "$location_SSIcons" \
        "$location_JAMFScripts" \
        "$location_ComputerEA" \
        "$location_Contacts" \
        "$location_ConfigurationProfiles" \
        "$location_ComputerPolicies" \
        "$location_FailedMDM" \
        "$location_backupSmartGroups" \
        "$location_backupSmartGroups/Smart" \
        "$location_backupSmartGroups/Static" \
        "$location_ApplicationUsage" \
        "$location_CompareConfigFiles" \
        "$location_UsersMultipleSystems"
    do
        if [[ ! -d "$make_directory" ]]; then
            if ! /bin/mkdir -p "$make_directory"; then
                logMe "ERROR: Unable to create directory: ${make_directory}"
                return 1
            fi

            logMe "Created directory: ${make_directory}"
        fi
    done

    /usr/sbin/chown -R "$LOGGED_IN_USER" "$menu_storageLocation" ||
    {
        logMe "ERROR: Unable to set ownership on ${menu_storageLocation}."
        return 1
    }

    find "$menu_storageLocation" -type d -exec /bin/chmod 750 {} + ||
    {
        logMe "ERROR: Unable to secure directories under ${menu_storageLocation}."
        return 1
    }

    find "$menu_storageLocation" -type f -exec /bin/chmod 640 {} + ||
    {
        logMe "ERROR: Unable to secure files under ${menu_storageLocation}."
        return 1
    }

    ERROR_LOG_LOCATION="${menu_storageLocation}/JAMFErrors.txt"

    /bin/rm -f -- "$ERROR_LOG_LOCATION"

    if ! /usr/bin/touch "$ERROR_LOG_LOCATION"; then
        logMe "ERROR: Unable to create error log: ${ERROR_LOG_LOCATION}"
        return 1
    fi

    if ! /usr/sbin/chown "$LOGGED_IN_USER" "$ERROR_LOG_LOCATION"
    then
        logMe "ERROR: Unable to set error-log ownership."
        return 1
    fi

    if ! /bin/chmod 640 "$ERROR_LOG_LOCATION"; then
        logMe "ERROR: Unable to secure error log."
        return 1
    fi
    return 0
}

function fix_import_errors ()
{
    # PURPOSE:
    #   Extract the best available item name or API error message
    #   from a JSON response and record the export failure.
    #
    # PARAMETERS:
    #   $1 = JSON response
    #   $2 = Display and log message

    local jsonBlob="${1:-}"
    local displayMessage="${2:-Export failed}"
    local itemName="Unknown item"
    local apiError=""

    if [[ -n "$jsonBlob" ]] &&
       print -r -- "$jsonBlob" |
            jq -e . >/dev/null 2>&1
    then
        itemName=$(
            print -r -- "$jsonBlob" |
                jq -r '
                    .name
                    // .script.name
                    // .policy.general.name
                    // .computer_group.name
                    // .os_x_configuration_profile.general.name
                    // .user.name
                    // .errors[0].field
                    // "Unknown item"
                '
        )

        apiError=$(
            print -r -- "$jsonBlob" |
                jq -r '
                    .errors[0].description
                    // .errors[0].message
                    // .error_description
                    // .message
                    // .error
                    // empty
                '
        )
    fi

    if [[ -n "$apiError" ]]; then
        displayMessage="${displayMessage}: ${apiError}"
    fi

    update_display_list \
        "Update" "" "$itemName" "" \
        "error" "$displayMessage"

    logMe "Export error for ${itemName}: ${displayMessage}"

    printf 'Export error: %s: %s\n' \
        "$itemName" \
        "$displayMessage" \
        >> "$ERROR_LOG_LOCATION"

    return 0
}

function run_selected_operation ()
{
    local enabled="${1:-false}"
    local operation="${2:-}"

    [[ "$enabled" == "true" ]] || return 0

    if [[ -z "$operation" ]] || (( ! $+functions[$operation] )); then
        logMe "ERROR: Invalid operation: ${operation}"
        overallStatus=1
        return 1
    fi

    if ! "$operation"; then
        logMe "ERROR: Operation failed: ${operation}"
        overallStatus=1
        return 1
    fi

    return 0
}


####################################################################################################
#
# Main Script
#
####################################################################################################

typeset -gx api_token=""
typeset -g jamfpro_url=""
typeset -ga CURL_ARGS=()

typeset -g menu_backupJAMFScripts=""
typeset -g menu_backupSSIcons=""
typeset -g menu_createVCFcards=""
typeset -g menu_storageLocation=""
typeset -g menu_onlyManagedUsers=""
typeset -g menu_computerea=""
typeset -g menu_configurationProfiles=""
typeset -g menu_clearFailedMDM=""
typeset -g menu_backupFailedMDM=""
typeset -g menu_backupSmartGroups=""
typeset -g menu_groupVCFExport=""
typeset -g menu_createCSV=""
typeset -g menu_composeEmail=""
typeset -g menu_exportApplicationUsage=""
typeset -g menu_backupComputerPolicies=""
typeset -g menu_startDateUsage=""
typeset -g menu_endDateUsage=""
typeset -g menu_groupAppUsage=""
typeset -g menu_UsersMultipleSystems=""
typeset -g menu_CompareConfigProfiles=""

typeset -g location_SSIcons=""
typeset -g location_JAMFScripts=""
typeset -g location_ComputerEA=""
typeset -g location_Contacts=""
typeset -g location_ConfigurationProfiles=""
typeset -g location_FailedMDM=""
typeset -g location_UsersMultipleSystems=""
typeset -g location_ComputerPolicies=""
typeset -g location_CompareConfigFiles=""
typeset -g location_backupSmartGroups=""
typeset -g location_ApplicationUsage=""
typeset -g formatted_ApplicationUsage_name=""

integer overallStatus=0

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
make_temp_files || cleanup_and_exit 1
create_infobox_message

OVERLAY_ICON=$(JAMF_which_self_service)

display_welcome_msg || cleanup_and_exit 1
check_directories || cleanup_and_exit 1

run_selected_operation "$menu_backupComputerPolicies" backup_computer_policies
run_selected_operation "$menu_computerea" backup_computer_extensions
run_selected_operation "$menu_configurationProfiles" backup_configuration_profiles
run_selected_operation "$menu_backupSmartGroups" export_computer_groups
run_selected_operation "$menu_backupFailedMDM" export_failed_mdm_devices
run_selected_operation "$menu_CompareConfigProfiles" compare_profiles
run_selected_operation "$menu_createVCFcards" create_vcf_cards
run_selected_operation "$menu_exportApplicationUsage" export_usage
run_selected_operation "$menu_UsersMultipleSystems" export_user_multiple
run_selected_operation "$menu_backupSSIcons" backup_ss_icons
run_selected_operation "$menu_backupJAMFScripts" backup_jamf_scripts


if (( overallStatus == 0 )); then
    logMe "JAMF System Utilities completed successfully."
else
    logMe "WARNING: JAMF System Utilities completed with one or more failures."
fi

[[ -s "$ERROR_LOG_LOCATION" ]] && show_backup_errors "The following items could not be backed up or exported."

cleanup_and_exit "$overallStatus"
