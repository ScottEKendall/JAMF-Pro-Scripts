#!/bin/zsh
#
# AppDelete
# Purpose: Allow end users to delete apps / folders using Swift Dialog
#
# Written: 8/3/2022
# Last updated: 04/01/2026
#
# 1.0 - Initial Release
# 1.1 - Major code cleanup & documentation
#		Structured code to be more inline / consistent across all apps
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 2.0 - Bumped Swift Dialog min version to 2.5.0
#		NEW: Added option to allow folders to be deleted (ALLOWED_FOLDERS)
#		Put shadows in the banner text
# 		Reordered sections to better show what can be modified
# 2.1 - Added option to sort array (case insensitive) after the application scan & folders added 
# 2.2 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 2.3 - Add logic in the delete_files section to not continue processing if name is blank
#		Fixed issue with reading in the defaults file and setting the variables.
# 2.4	Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.5 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 3.0 - Rebuilt selection handling using valid JSON and jq
#       Added support for multiple application search locations
#       Added exact-path tracking for discovered applications and approved folders
#       Added exact-name validation before deletion
#       Added protected-application revalidation
#       Added symlink and path-boundary protection
#       Added verified deletion results
#       Added secure temporary-file creation and cleanup
#       Added explicit handling for empty selections and dialog errors
#       Improved prerequisite and error propagation

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="AppDelete"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files for this app

JSON_OPTIONS=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.dialog.XXXXXX") || {
    print -u2 -r -- "ERROR: Unable to create SwiftDialog JSON file."
    exit 1
}

TMP_FILE_STORAGE=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.output.XXXXXX") || {
    print -u2 -r -- "ERROR: Unable to create SwiftDialog output file."
    /bin/rm -f -- "$JSON_OPTIONS"
    exit 1
}

if ! /bin/chmod 644 "$JSON_OPTIONS"; then
    print -u2 -r -- "ERROR: Unable to set permissions on ${JSON_OPTIONS}."
    /bin/rm -f -- "$JSON_OPTIONS" "$TMP_FILE_STORAGE"
    exit 1
fi

if ! /bin/chmod 600 "$TMP_FILE_STORAGE"; then
    print -u2 -r -- "ERROR: Unable to secure ${TMP_FILE_STORAGE}."
    /bin/rm -f -- "$JSON_OPTIONS" "$TMP_FILE_STORAGE"
    exit 1
fi

trap 'cleanup_and_exit $?' EXIT
trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

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

SD_WINDOW_TITLE="Delete Applications"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE="SF=trash.fill, color=black, weight=light"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

# Locations to search for removable applications
APPLICATION_SEARCH_PATHS=(
    "/Applications"
    "${USER_DIR}/Applications"
)

# The follow array lists the apps that the users are not allowed to remove.  
#If the apps show up in the list, they do not appear in the list of apps that can be deleted
NOT_ALLOWED_APPS=(
    "Company Portal" 
	"Falcon"
    "Jamf Connect"
	"Self Service"
	"Self Service+"
    "ZScaler")

# This list contains approved folders that users are allowed to delete.
# Some applications install into subfolders beneath an application search location.
# Include only the folder name, not the full path.
ALLOWED_FOLDERS=(
	"Zscaler Copy"
	"Utilities copy"
	"Cisco copy")

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

####################################################################################################
#
# Global Functions
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

    trap - EXIT INT TERM

    [[ -n "${JSON_OPTIONS:-}" ]] && /bin/rm -f -- "$JSON_OPTIONS"
    [[ -n "${TMP_FILE_STORAGE:-}" ]] && /bin/rm -f -- "$TMP_FILE_STORAGE"

    exit "$exit_code"
}


####################################################################################################
#
# Functions
#
####################################################################################################

function validate_selected_items ()
{
    local selected_name
    local approved_path

    APPROVED_DELETE_PATHS=()

    for selected_name in "${SELECTED_ITEMS[@]}"; do
        approved_path=""

        if approved_path=$(resolve_approved_delete_path "$selected_name"); then
            APPROVED_DELETE_PATHS+=("$approved_path")
        else
            logMe "ERROR: Selection validation failed: ${selected_name}"
        fi
    done

    if (( ${#APPROVED_DELETE_PATHS[@]} == 0 )); then
        logMe "ERROR: No approved deletion paths remain after validation."
        return 1
    fi

    if (( ${#APPROVED_DELETE_PATHS[@]} != ${#SELECTED_ITEMS[@]} )); then
        logMe "ERROR: One or more selected items failed validation."
        return 1
    fi

    return 0
}

function build_file_list_array ()
{
    local search_path
    local app_path
    local app_name
    local folder_name
    local folder_path
    local -a discovered_items

    discovered_items=()
    FILES_LIST=()
    ITEM_PATHS=()

    for search_path in "${APPLICATION_SEARCH_PATHS[@]}"; do

        # Skip search locations that do not exist.
        if [[ ! -d "$search_path" ]]; then
            logMe "Application search path not found: ${search_path}"
            continue
        fi

        logMe "Searching for applications in: ${search_path}"

        for app_path in "${search_path}"/*.app(N/); do
            app_name="${app_path:t:r}"

            if array_contains "$app_name" "${NOT_ALLOWED_APPS[@]}"; then
                logMe "Protected application excluded: ${app_name}"
                continue
            fi

            if [[ -L "$app_path" ]]; then
                logMe "Symbolic link excluded: ${app_path}"
                continue
            fi

            # Avoid duplicate display names.
            if [[ -n "${ITEM_PATHS[$app_name]:-}" ]]; then
                logMe "Duplicate application name excluded: ${app_name} (${app_path})"
                continue
            fi

            discovered_items+=("$app_name")
            ITEM_PATHS[$app_name]="$app_path"
        done

        for folder_name in "${ALLOWED_FOLDERS[@]}"; do
            folder_path="${search_path}/${folder_name}"

            if [[ -d "$folder_path" && ! -L "$folder_path" ]]; then

                if [[ -n "${ITEM_PATHS[$folder_name]:-}" ]]; then
                    logMe "Duplicate folder name excluded: ${folder_name} (${folder_path})"
                    continue
                fi

                discovered_items+=("$folder_name")
                ITEM_PATHS[$folder_name]="$folder_path"
            fi
        done

    done

    if (( ${#discovered_items[@]} == 0 )); then
        logMe "No removable applications or approved folders were found."
        return 1
    fi

    FILES_LIST=("${(@on)discovered_items}")

    return 0
}

function construct_display_list ()
{
    local item
    local item_icon
    local item_json
    local checkbox_json=""

    local -a checkbox_items

    checkbox_items=()

    for item in "${FILES_LIST[@]}"; do
		item_icon=""

		if [[ -z "${ITEM_PATHS[$item]:-}" ]]; then
			logMe "WARNING: No approved path exists for item: ${item}"
			continue
		fi

		if [[ "${ITEM_PATHS[$item]}" == *.app ]]; then
			item_icon="${ITEM_PATHS[$item]}"
		elif array_contains "$item" "${ALLOWED_FOLDERS[@]}"; then
			item_icon="${ICON_FILES}/ApplicationsFolderIcon.icns"
		else
			logMe "WARNING: Skipping unavailable or unapproved item: ${item}"
			continue
		fi

        item_json=$(jq -n \
                --arg label "$item" \
                --arg icon "$item_icon" \
                '{
                    label: $label,
                    checked: false,
                    disabled: false,
                    icon: $icon
                }') || {
            logMe "ERROR: Unable to build JSON for ${item}"
            return 1
        }

        checkbox_items+=("$item_json")
    done

    if (( ${#checkbox_items[@]} == 0 )); then
        logMe "ERROR: No valid checkbox entries were generated."
        return 1
    fi

    checkbox_json=$(printf '%s\n' "${checkbox_items[@]}" | jq -s '.') || {
        logMe "ERROR: Unable to combine checkbox JSON."
        return 1
    }

    jq -n \
        --arg message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. Please choose the application(s) and/or approved folder(s) that you want to remove. Applications can be installed again from Self Service." \
        --arg bannertitle "$SD_WINDOW_TITLE" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}" \
        --arg icon "$SD_ICON_FILE" \
        --arg overlayicon "$OVERLAY_ICON" \
        --arg bannerimage "$SD_BANNER_IMAGE" \
        --arg helpmessage "Choose the applications or approved folders you want to remove.<br>Applications can be installed again from Self Service." \
        --arg infobox "$SD_INFO_BOX_MSG" \
        --argjson checkbox "$checkbox_json" \
        '{
            message: $message,
            messageposition: "top",
            bannertitle: $bannertitle,
            subtitle: $subtitle,
            titlefont: $titlefont,
            icon: $icon,
            overlayicon: $overlayicon,
            bannerimage: $bannerimage,
            helpmessage: $helpmessage,
            width: 920,
            height: 750,
            moveable: true,
            ontop: true,
            buttonstyle: "center",
            infobox: $infobox,
            quitkey: "0",
            button1text: "Next",
            button2text: "Cancel",
            checkboxstyle: {
                style: "switch",
                size: "regular"
            },
            checkbox: $checkbox
        }' > "$JSON_OPTIONS" || {
            logMe "ERROR: Unable to write SwiftDialog JSON."
            return 1
        }

    if ! jq empty "$JSON_OPTIONS" >/dev/null 2>&1; then
        logMe "ERROR: Generated SwiftDialog JSON failed validation."
        return 1
    fi

    return 0
}

function choose_files_to_delete ()
{
    local dialog_output=""
    local dialog_error=""
    local dialog_error_file=""
    local return_code=0
    local selected_name

    SELECTED_ITEMS=()

    dialog_error_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.dialog-error.XXXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog error file."
        return 1
    }

    dialog_output=$("$SW_DIALOG" --jsonfile "$JSON_OPTIONS" --json 2>"$dialog_error_file")
    return_code=$?

    dialog_error=$(<"$dialog_error_file")
    /bin/rm -f -- "$dialog_error_file"

    case "$return_code" in
        0)
            ;;

        2|10)
            logMe "User cancelled application selection."
            return 2
            ;;

        *)
            logMe "ERROR: Selection dialog exited with code ${return_code}."

            if [[ -n "$dialog_error" ]]; then
                logMe "SwiftDialog error: ${dialog_error}"
            fi

            return 1
            ;;
    esac

    print -r -- "$dialog_output" > "$TMP_FILE_STORAGE"

    if ! jq empty "$TMP_FILE_STORAGE" >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog returned invalid JSON."
        logMe "SwiftDialog output: ${dialog_output}"
        return 1
    fi

    while IFS= read -r selected_name; do
        [[ -n "$selected_name" ]] &&
            SELECTED_ITEMS+=("$selected_name")
    done < <(jq -r 'to_entries[]| select(.value == true) | .key' "$TMP_FILE_STORAGE")

    if (( ${#SELECTED_ITEMS[@]} == 0 )); then
        logMe "No applications or folders were selected."
        return 3
    fi

    logMe "User selected ${#SELECTED_ITEMS[@]} item(s)."

    return 0
}

function build_confirmation_message ()
{
    local path

    CONFIRMATION_MESSAGE="The following items will be permanently removed:<br><br>"

    for path in "${APPROVED_DELETE_PATHS[@]}"; do
        CONFIRMATION_MESSAGE+="* ${path}<br>"
    done

    CONFIRMATION_MESSAGE+="<br>This action cannot be undone."
    return 0
}

function path_is_within_search_locations ()
{
    local candidate_path="$1"
    local search_path

    [[ -n "$candidate_path" ]] || return 1

    for search_path in "${APPLICATION_SEARCH_PATHS[@]}"; do
        search_path="${search_path%/}"

        if [[ "$candidate_path" == "${search_path}/"* ]]; then
            return 0
        fi
    done

    return 1
}

function delete_files ()
{
    local delete_path

    DELETED_ITEMS=()
    FAILED_ITEMS=()

    for delete_path in "${APPROVED_DELETE_PATHS[@]}"; do

        [[ -n "$delete_path" ]] || continue

        # Validate that the path is beneath one of our approved search roots.
        if ! path_is_within_search_locations "$delete_path"; then
            logMe "ERROR: Rejected deletion path outside approved application locations: ${delete_path}"
            FAILED_ITEMS+=("$delete_path")
            continue
        fi

        # Never allow one of the search roots itself to be deleted.
        if array_contains "${delete_path%/}" "${APPLICATION_SEARCH_PATHS[@]}"; then
            logMe "ERROR: Refusing to remove application search directory: ${delete_path}"
            FAILED_ITEMS+=("$delete_path")
            continue
        fi

        if [[ -L "$delete_path" ]]; then
            logMe "ERROR: Refusing to remove symbolic link: ${delete_path}"
            FAILED_ITEMS+=("$delete_path")
            continue
        fi

        if [[ ! -e "$delete_path" ]]; then
            logMe "ERROR: Selected path no longer exists: ${delete_path}"
            FAILED_ITEMS+=("$delete_path")
            continue
        fi

        logMe "Attempting removal: ${delete_path}"

        if /bin/rm -rf -- "$delete_path"; then

            if [[ ! -e "$delete_path" ]]; then
                DELETED_ITEMS+=("$delete_path")
                logMe "Removal verified: ${delete_path}"
            else
                FAILED_ITEMS+=("$delete_path")
                logMe "ERROR: Path remains after removal: ${delete_path}"
            fi

        else
            FAILED_ITEMS+=("$delete_path")
            logMe "ERROR: Removal failed: ${delete_path}"
        fi

    done

    (( ${#FAILED_ITEMS[@]} == 0 ))
}

function show_final_delete_prompt ()
{
    local return_code=0
    local -a main_dialog_body

    main_dialog_body=(
        --message "$CONFIRMATION_MESSAGE"
        --icon "$SD_ICON_FILE"
        --overlayicon warning
        --width 920
        --height 520
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --subtitle "$BANNER_SUBTITLE"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
        --button1text "Delete"
        --button2text "Cancel"
        --buttonstyle center
        --ontop
        --quitkey 0
    )

    "$SW_DIALOG" "${main_dialog_body[@]}" 2>/dev/null
    return_code=$?

    case "$return_code" in
        0)
            logMe "User confirmed deletion."
            return 0
            ;;
        2|10)
            logMe "User cancelled deletion."
            return 2
            ;;
        *)
            logMe "ERROR: Confirmation dialog exited with code ${return_code}."
            return 1
            ;;
    esac
}

function build_completion_message ()
{
    local path

    COMPLETION_MESSAGE=""

    if (( ${#DELETED_ITEMS[@]} > 0 )); then
        COMPLETION_MESSAGE+="## Successfully removed<br><br>"

        for path in "${DELETED_ITEMS[@]}"; do
            COMPLETION_MESSAGE+="* ${path}<br>"
        done
    fi

    if (( ${#FAILED_ITEMS[@]} > 0 )); then
        COMPLETION_MESSAGE+="<br>## Could not remove<br><br>"

        for path in "${FAILED_ITEMS[@]}"; do
            COMPLETION_MESSAGE+="* ${path}<br>"
        done

        COMPLETION_MESSAGE+="<br>Review ${LOG_FILE} for additional details."
    fi

    return 0
}

function show_completed_prompt ()
{
    local return_code=0
    local completion_icon=""
    local -a main_dialog_body

    if (( ${#FAILED_ITEMS[@]} == 0 )); then
        completion_icon="SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
    else
        completion_icon="SF=exclamationmark.triangle.fill,color=orange,weight=light,bgcolor=none"
    fi

    main_dialog_body=(
        --message "$COMPLETION_MESSAGE"
        --ontop
        --icon "$SD_ICON_FILE"
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --subtitle "$BANNER_SUBTITLE"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
        --overlayicon "$completion_icon"
        --width 920
        --height 560
        --quitkey 0
        --buttonstyle center
        --button1text "OK"
        --button2text "Run Again"
    )

    "$SW_DIALOG" "${main_dialog_body[@]}" 2>/dev/null
    return_code=$?

    case "$return_code" in
        0|10)
            return 0
            ;;
        2)
            return 2
            ;;
        *)
            logMe "ERROR: Completion dialog exited with code ${return_code}."
            return 1
            ;;
    esac
}

function array_contains ()
{
    local needle="$1"
    shift

    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done

    return 1
}

function resolve_approved_delete_path ()
{
    local name="$1"
    local path=""

    [[ -n "$name" ]] || return 1

    if ! array_contains "$name" "${FILES_LIST[@]}"; then
        logMe "ERROR: Rejected unapproved selection: ${name}"
        return 1
    fi

    if array_contains "$name" "${NOT_ALLOWED_APPS[@]}"; then
        logMe "ERROR: Rejected protected application: ${name}"
        return 1
    fi

    path="${ITEM_PATHS[$name]:-}"

    if [[ -z "$path" ]]; then
        logMe "ERROR: No approved deletion path for: ${name}"
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        logMe "ERROR: Approved deletion path no longer exists: ${path}"
        return 1
    fi

    if [[ -L "$path" ]]; then
        logMe "ERROR: Refusing symbolic link: ${path}"
        return 1
    fi

    print -r -- "$path"
}

#############################
#
# Start of Main Script
#
#############################

autoload 'is-at-least'

typeset -a FILES_LIST
typeset -A ITEM_PATHS
typeset -a SELECTED_ITEMS
typeset -a DELETED_ITEMS
typeset -a FAILED_ITEMS
typeset CONFIRMATION_MESSAGE=""
typeset -a APPROVED_DELETE_PATHS


if ! check_for_sudo; then
    exit 1
fi

if ! create_log_directory; then
    print -u2 -r -- "ERROR: Unable to initialize logging."
    exit 1
fi

if ! check_swift_dialog_install; then
    logMe "ERROR: Unable to continue without a supported SwiftDialog installation."
    exit 1
fi

if ! check_support_files; then
    logMe "ERROR: Required support files or utilities are unavailable."
    exit 1
fi
create_infobox_message

while true; do
    FILES_LIST=()
    ITEM_PATHS=()
    SELECTED_ITEMS=()
    APPROVED_DELETE_PATHS=()
    DELETED_ITEMS=()
    FAILED_ITEMS=()
    CONFIRMATION_MESSAGE=""

    if ! build_file_list_array; then
        logMe "No removable applications or approved folders are available."
        cleanup_and_exit 0
    fi

    if ! construct_display_list; then
        logMe "ERROR: Unable to construct the item selection list."
        cleanup_and_exit 1
    fi

    choose_files_to_delete
    selection_status=$?

    case "$selection_status" in
        0)
            ;;
        2)
            cleanup_and_exit 0
            ;;
        3)
            logMe "Redisplaying selection because no items were selected."
            continue
            ;;
        *)
            cleanup_and_exit 1
            ;;
    esac

    if ! validate_selected_items; then
        logMe "ERROR: Selected-item validation failed."
        cleanup_and_exit 1
    fi

    build_confirmation_message

    show_final_delete_prompt
    confirmation_status=$?

    case "$confirmation_status" in
        0)
            ;;
        2)
            logMe "Returning to the selection screen."
            continue
            ;;
        *)
            cleanup_and_exit 1
            ;;
    esac

    delete_files
    deletion_status=$?

    build_completion_message

    show_completed_prompt
    completion_status=$?

    case "$completion_status" in
        0)
            if (( deletion_status == 0 )); then
                cleanup_and_exit 0
            else
                cleanup_and_exit 1
            fi
            ;;
        2)
            logMe "User selected Run Again."
            continue
            ;;
        *)
            cleanup_and_exit 1
            ;;
    esac
done
cleanup_and_exit
