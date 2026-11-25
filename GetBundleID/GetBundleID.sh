#!/bin/zsh
#
# GetBundleID
#
# by: Scott Kendall
#
# Written: 07/11/2025
# Last updated: 11/25/2026
#
# Script Purpose: Extract the Bundle ID and Team ID of applications found in a selected directory
#
# 1.0 - Initial
# 1.1 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 1.2 - Fixed window layout for Tahoe & SD v3.0
# 1.3 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Now includes Team ID in the listing as well
#       Changed the order of the items in the welcome screen
# 2.1 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.2 - Improved application discovery and support for application paths containing spaces
#       Improved Bundle ID and Team ID retrieval with handling for missing values
#       Updated SwiftDialog list-item construction to use jq for safer JSON generation
#       Added error handling and return-code validation throughout the application workflow
#       Added notification when no applications are found in the selected directory
#       Enhanced exported results to include application name, path, Bundle ID, and Team ID
#       Improved SwiftDialog process management, command updates, and error handling
#       Improved temporary file handling and cleanup
#       General code cleanup and reliability improvements


######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="GetBundleID"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)
chmod 644 "$JSON_DIALOG_BLOB"
chmod 644 "$DIALOG_COMMAND_FILE"

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

SD_WINDOW_TITLE="Extract Bundle ID"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/System/Applications/App Store.app"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"


##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

####################################################################################################
#
# Common Library Functions
#
####################################################################################################

function admin_user ()
{
    (( UID == 0 ))
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

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM

    [[ -n "${JSON_DIALOG_BLOB:-}" ]] && /bin/rm -f -- "$JSON_DIALOG_BLOB"
    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && /bin/rm -f -- "$DIALOG_COMMAND_FILE"

    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

####################################################################################################
#
# Script Specific Functions
#
####################################################################################################


function welcomemsg ()
{
    message="This script is designed to display the Bundle IDs and Team IDs of the applications found in a selected directory, with an option to export a list of found applications and their associated Bundle IDs & Team IDs.<br><br>Please enter a location to get started."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --infobox "${SD_INFO_BOX_MSG}"
        --vieworder "textfield, checkbox"
        --textfield "Select a file location to scan",fileselect,filetype=folder,required,name=fileLocation
        --checkbox "Export list",name=ExportList
        --height 480
        --ignorednd
        --json
        --quitkey 0
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
            logMe "ERROR: SwiftDialog exited unexpectedly with code: ${returnCode}"
            cleanup_and_exit "$returnCode"
            ;;
    esac

    fileLocation=$(echo "$temp" | /usr/bin/plutil -extract "fileLocation" raw -)
    exportList=$(echo "$temp" | /usr/bin/plutil -extract "ExportList" raw -)

}

function build_file_list_array ()
{
    FILES_LIST=()

    while IFS= read -r app_path; do
        [[ -n "$app_path" ]] && FILES_LIST+=("$app_path")
    done < <(/usr/bin/find "$fileLocation" -maxdepth 1 -type d -iname '*.app' -print 2>/dev/null | /usr/bin/sort -f)
}

function construct_dialog_header_settings ()
{
    # Construct the basic SwiftDialog screen information that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "message" : "'$1'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : "true",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "subtitle" : "'${BANNER_SUBTITLE}'",
        "titlefont" : "shadow=1, color='${BANNER_TEXT_COLOR}', offset='${BANNER_TEXT_PADDING}'",
        "button1text" : "OK",
        "moveable" : "true",
        "width" : "1100",
        "height" : "800",
        "json" : "true", 
        "quitkey" : "0",
        "messageposition" : "top",'
}

function update_display_list ()
{
    # PURPOSE:
    #   Update the active SwiftDialog window using the command file.
    #
    # PARAMETERS:
    #   $1 - Action
    #        add
    #        buttonenable
    #        buttonchange
    #        change
    #        subtitle
    #
    #   $2 - Item title / button text
    #   $3 - Status / subtitle
    #   $4 - Status text
    #   $5 - Progress text
    #   $6 - Progress value
    #
    # RETURN:
    #   0 - Command written successfully
    #   1 - Invalid action or command file unavailable

    local action="${1:l}"
    local item="${2:-}"
    local display_status="${3:-}"
    local status_text="${4:-}"
    local progress_text="${5:-}"
    local progress_value="${6:-}"

    if [[ -z "${DIALOG_COMMAND_FILE:-}" || ! -e "$DIALOG_COMMAND_FILE" ]]; then
        logMe "ERROR: SwiftDialog command file is unavailable."
        return 1
    fi

    case "$action" in

        "add")
            /bin/echo "listitem: add, title: ${item}, status: ${display_status}, statustext: ${status_text}" >> "$DIALOG_COMMAND_FILE"
            ;;

        "buttonenable")
            /bin/echo "button1: enable" >> "$DIALOG_COMMAND_FILE"
            ;;

        "buttonchange")
            /bin/echo "button1text: ${item}" >> "$DIALOG_COMMAND_FILE"
            ;;

        "change")
            /bin/echo "listitem: title: ${item}, status: ${display_status}, statustext: ${status_text}" >> "$DIALOG_COMMAND_FILE"

            [[ -n "$progress_text" ]] && /bin/echo "progresstext: ${progress_text}" >> "$DIALOG_COMMAND_FILE"
            [[ -n "$progress_value" ]] && /bin/echo "progress: ${progress_value}" >> "$DIALOG_COMMAND_FILE"
            ;;

        "subtitle")
            /bin/echo "listitem: title: ${item}, subtitle: ${display_status}" >> "$DIALOG_COMMAND_FILE"
            ;;

        *)
            logMe "ERROR: Invalid SwiftDialog update action: ${1}"
            return 1
            ;;

    esac
    return 0
}

function construct_display_list ()
{
    # PURPOSE:
    #   Construct the SwiftDialog JSON containing all discovered applications.
    #
    # PARMS: None
    # EXPECTED: FILES_LIST contains full application paths
    # RETURN:
    #   0 - Dialog JSON successfully constructed
    #   1 - Unable to construct dialog JSON

    local app_path
    local app_name

    if ! construct_dialog_header_settings "Below are the discovered applications and their Bundle IDs and Team IDs" > "$JSON_DIALOG_BLOB"; then

        logMe "ERROR: Unable to create SwiftDialog JSON header."
        return 1
    fi

    if ! create_listitem_message_body "" "" "" "" "" "first"; then
        logMe "ERROR: Unable to create SwiftDialog list header."
        return 1
    fi

    for app_path in "${FILES_LIST[@]}"; do
        app_name="${app_path:t:r}"
        if ! create_listitem_message_body "$app_name" "File Info" "$app_path" "Working" "working"; then
            logMe "ERROR: Unable to create SwiftDialog list item for: ${app_name}"
            return 1
        fi

    done

    if ! create_listitem_message_body "" "" "" "" "" "last"; then
        logMe "ERROR: Unable to create SwiftDialog list footer."
        return 1
    fi

    if ! /bin/chmod 644 "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to set permissions on SwiftDialog JSON file."
        return 1
    fi

    return 0
}

function create_listitem_message_body ()
{
    # PURPOSE:
    #   Construct SwiftDialog list item JSON and append it to the
    #   existing dialog JSON file.
    #
    # PARAMETERS:
    #   $1 - Item title
    #   $2 - Item subtitle
    #   $3 - Item icon
    #   $4 - Status text
    #   $5 - Status
    #   $6 - Position: first, last, or blank
    #
    # RETURN:
    #   0 - JSON successfully written
    #   1 - Unable to construct or write JSON

    local item_title="${1:-}"
    local item_subtitle="${2:-}"
    local item_icon="${3:-}"
    local status_text="${4:-}"
    local item_status="${5:-}"
    local position="${6:l}"
    local json_line=""

    case "$position" in

        "first")
            json_line='"button1disabled": true, "listitem": ['

            if ! /bin/echo "$json_line" >> "$JSON_DIALOG_BLOB"; then
                logMe "ERROR: Unable to write list header to SwiftDialog JSON file."
                return 1
            fi
            ;;

        "last")
            if ! /bin/echo ']}' >> "$JSON_DIALOG_BLOB"; then
                logMe "ERROR: Unable to write list footer to SwiftDialog JSON file."
                return 1
            fi
            ;;

        *)
            if [[ -z "$item_title" ]]; then
                logMe "ERROR: Unable to create SwiftDialog list item without a title."
                return 1
            fi

            json_line=$(
                /usr/bin/jq -cn \
                    --arg title "$item_title" \
                    --arg subtitle "$item_subtitle" \
                    --arg icon "$item_icon" \
                    --arg status "$item_status" \
                    --arg statustext "$status_text" \
                    '{
                        title: $title,
                        subtitle: $subtitle,
                        icon: $icon,
                        status: $status,
                        statustext: $statustext
                    }'
            ) || {
                logMe "ERROR: Unable to construct SwiftDialog list item JSON for: ${item_title}"
                return 1
            }

            if ! /bin/echo "${json_line}," >> "$JSON_DIALOG_BLOB"; then
                logMe "ERROR: Unable to write SwiftDialog list item: ${item_title}"
                return 1
            fi
            ;;

    esac

    return 0
}

function get_bundleID ()
{
    # PURPOSE: Extract the Bundle IDs and Team IDs from each application
    #          in the FILES_LIST array and update SwiftDialog.
    #
    # PARMS: None
    # EXPECTED: FILES_LIST contains full application paths
    # RETURN:
    #   0 - Application information successfully processed
    #   1 - Unable to update SwiftDialog
    
    local app_path
    local app_name
    local bundleID
    local teamID

    logMe "Extracting Bundle IDs and Team IDs from: ${fileLocation}"
    for app_path in "${FILES_LIST[@]}"; do
        app_name="${app_path:t:r}"
        bundleID=$(/usr/bin/plutil -extract CFBundleIdentifier raw "${app_path}/Contents/Info.plist" 2>/dev/null)
        [[ -z "$bundleID" ]] && bundleID="Not Found"

        teamID=$(/usr/bin/codesign -dv "${app_path}" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')
        [[ -z "$teamID" ]] && teamID="Not Found"

        if ! update_display_list "subtitle" "$app_name" "Team ID - $teamID | Bundle ID - $bundleID"; then
            logMe "ERROR: Unable to update Bundle ID and Team ID for: ${app_name}"
            return 1
        fi

        if ! update_display_list "change" "$app_name" "success" "Done"; then
            logMe "ERROR: Unable to update completion status for: ${app_name}"
            return 1
        fi
    done
    return 0
}

function export_bundleID_list ()
{
    # PURPOSE: Export the Bundle IDs and Team IDs from each application
    #          in the array to a file on the Desktop.
    #
    # PARMS: None
    # EXPECTED: FILES_LIST contains full application paths
    # RETURN: 0 on success, 1 on failure

    local export_file="${USER_DIR}/Desktop/BundleIDlist.txt"
    local app_name
    local app_path
    local bundleID
    local teamID

    : > "$export_file" || {
        logMe "ERROR: Unable to create export file: ${export_file}"
        return 1
    }

    for app_path in "${FILES_LIST[@]}"; do

        app_name="${app_path:t:r}"

        bundleID=$(/usr/bin/plutil -extract CFBundleIdentifier raw "${app_path}/Contents/Info.plist" 2>/dev/null)
        [[ -z "$bundleID" ]] && bundleID="Not Found"

        teamID=$(/usr/bin/codesign -dv "${app_path}" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')
        [[ -z "$teamID" ]] && teamID="Not Found"

        if ! {
            echo "Application: ${app_name}"
            echo "Path: ${app_path}"
            echo "Bundle ID: ${bundleID}"
            echo "Team ID: ${teamID}"
            echo
        } >> "$export_file"; then

            logMe "ERROR: Unable to write application information to: ${export_file}"
            return 1
        fi

    done

    logMe "Exported application information to: ${export_file}"
    return 0
}


####################################################################################################
#
# Main Script
#
####################################################################################################
declare fileLocation
declare exportList
typeset -a FILES_LIST

autoload 'is-at-least'

create_log_directory || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
create_infobox_message
welcomemsg
if [[ ! -d "$fileLocation" ]]; then
    logMe "ERROR: Selected scan location is invalid: ${fileLocation}"
    cleanup_and_exit 1
fi

build_file_list_array

if (( ${#FILES_LIST[@]} == 0 )); then
    logMe "No applications found in: ${fileLocation}"
    "$SW_DIALOG" --title "$SD_WINDOW_TITLE" --message "No applications were found in the selected directory." --icon "$SD_ICON_FILE" --button1text "OK"
    cleanup_and_exit 0
fi

construct_display_list || cleanup_and_exit 1

"$SW_DIALOG" --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" &
dialog_pid=$!

get_bundleID || cleanup_and_exit 1

if [[ "$exportList" == "true" ]]; then
    update_display_list "buttonchange" "Export" || cleanup_and_exit 1
fi

update_display_list "buttonenable" || cleanup_and_exit 1
wait "$dialog_pid"

if [[ "$exportList" == "true" ]]; then
    if ! export_bundleID_list; then
        logMe "ERROR: Failed to export application information."
        cleanup_and_exit 1
    fi
fi

cleanup_and_exit 0