#!/bin/zsh
#
# AppDelete
# Purpose: Allow end users to delete apps / folders using Swift Dialog
#
# Written: 8/3/2022
# Last updated: 11/24/2026
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
#       Added a conservative installed-package receipt removal workflow
#       Excludes Apple receipts, user data, protected system locations, shared paths, and unsafe entries
#       Removes exact files and symlinks before empty-directory cleanup
#       Forgets the receipt only after all approved removals succeed
#       Writes a JSON removal manifest to the AppDelete log directory
#       Promoted receipt-owned application bundles under approved application roots
#       Collapses internal bundle files into one validated .app removal target
#       Adds application bundles to the preflight preview and JSON manifest
#       Added protected package-prefix support for package receipt removal
#       com.apple and com.jamf receipts are hidden and revalidated before preflight/forget


######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="AppDelete"
SCRIPT_VERSION="3.0"
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

# Package-receipt removal safety settings.
# Apple receipts and anything installed beneath these roots are never offered for removal.
# Package identifiers matching these prefixes can never be removed by AppDelete.
PROTECTED_PACKAGE_PREFIXES=(
    "com.apple"
    "com.jamf"
)
RECEIPT_PREVIEW_LIMIT=100

# These directories and paths are never removed by AppDelete, even if they are listed in a package receipt.
RECEIPT_PROTECTED_PREFIXES=(
    "/System"
    "/bin"
    "/sbin"
    "/usr/bin"
    "/usr/lib"
    "/usr/libexec"
    "/usr/sbin"
    "/Users"
    "/private/var"
)
# These exact paths are never removed by AppDelete, even if they are listed in a package receipt.
RECEIPT_PROTECTED_EXACT_PATHS=(
    "/"
    "/Applications"
    "/Library"
    "/usr"
    "/usr/local"
    "/opt"
    "/private"
    "/var"
    "/tmp"
)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
WORKFLOW_PARAMETER="${4:-applications}"         #Workflow option to allow (applications|receipts|choose) to be passed in as a parameter.  Default is applications
 
####################################################################################################
#
# Global / Shared Functions
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
    if [[ -n "${RECEIPT_WORK_DIR:-}" && -d "$RECEIPT_WORK_DIR" && "$RECEIPT_WORK_DIR" == "/var/tmp/${SCRIPT_NAME}.receipt."* ]]; then
        /bin/rm -rf -- "$RECEIPT_WORK_DIR"
    fi

    exit "$exit_code"
}

####################################################################################################
#
# Application Removal Workflow
#
####################################################################################################

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
        --arg infotext "V ${SCRIPT_VERSION}" \
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
            buttonstyle: "right",
            infotext: $infotext,
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

function run_application_workflow ()
{
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
}

####################################################################################################
#
# Installed Package Receipt Removal Workflow
#
####################################################################################################


function receipt_is_protected ()
{
    local package_id="$1"
    local protected_prefix

    [[ -n "$package_id" ]] || return 0

    for protected_prefix in "${PROTECTED_PACKAGE_PREFIXES[@]}"; do
        [[ -n "$protected_prefix" ]] || continue

        if [[ "$package_id" == "$protected_prefix" ||
              "$package_id" == "${protected_prefix}."* ]]; then
            return 0
        fi
    done

    return 1
}

function receipt_path_is_protected ()
{
    local candidate="${1%/}"
    local protected
    [[ -n "$candidate" && "$candidate" == /* ]] || return 0
    [[ "$candidate" != *'/../'* && "$candidate" != '/..' && "$candidate" != *'/..' ]] || return 0
    for protected in "${RECEIPT_PROTECTED_EXACT_PATHS[@]}"; do
        [[ "$candidate" == "${protected%/}" ]] && return 0
    done
    for protected in "${RECEIPT_PROTECTED_PREFIXES[@]}"; do
        protected="${protected%/}"
        [[ "$candidate" == "$protected" || "$candidate" == "$protected/"* ]] && return 0
    done
    return 1
}

function receipt_root_from_metadata ()
{
    local package_id="$1"
    local plist_file="$2"
    local volume install_location root
    /usr/sbin/pkgutil --pkg-info-plist "$package_id" > "$plist_file" 2>/dev/null || return 1
    volume=$(/usr/bin/plutil -extract volume raw -o - "$plist_file" 2>/dev/null) || volume="/"
    install_location=$(/usr/bin/plutil -extract install-location raw -o - "$plist_file" 2>/dev/null) || install_location="/"
    [[ "$volume" == /* ]] || return 1
    volume="${volume%/}"
    install_location="/${install_location#/}"
    root="${volume}${install_location}"
    root="${root%/}"
    [[ -n "$root" ]] || root="/"
    print -r -- "$root"
}

function path_has_symlink_ancestor ()
{
    local candidate="$1" current="/" component
    local -a components
    components=("${(@s:/:)${candidate#/}}")
    for component in "${components[@]:0:${#components[@]}-1}"; do
        [[ -n "$component" ]] || continue
        current="${current%/}/${component}"
        [[ -L "$current" ]] && return 0
    done
    return 1
}

function get_receipt_app_bundle ()
{
    local candidate="$1"
    local search_root=""
    local relative_path=""
    local app_component=""
    local app_bundle=""

    [[ -n "$candidate" ]] || return 1

    for search_root in "${APPLICATION_SEARCH_PATHS[@]}"; do

        search_root="${search_root%/}"

        [[ "$candidate" == "${search_root}/"* ]] || continue

        relative_path="${candidate#${search_root}/}"

        #
        # Find the first *.app component beneath the approved
        # application search root.
        #
        app_component="${relative_path%%/*}"

        [[ "$app_component" == *.app ]] || continue

        app_bundle="${search_root}/${app_component}"

        #
        # The application itself must currently exist and may
        # not be a symbolic link.
        #
        [[ -d "$app_bundle" ]] || continue
        [[ ! -L "$app_bundle" ]] || continue

        print -r -- "$app_bundle"
        return 0
    done

    return 1
}

function construct_receipt_list ()
{
    local label item_json checkbox_json
    local -a checkbox_items
    checkbox_items=()
    for label in "${RECEIPT_LABELS[@]}"; do
        item_json=$(jq -n --arg label "$label" '{label:$label,checked:false,disabled:false,icon:"SF=shippingbox.fill,color=auto"}') || return 1
        checkbox_items+=("$item_json")
    done
    checkbox_json=$(printf '%s\n' "${checkbox_items[@]}" | jq -s '.') || return 1
    jq -n \
        --arg message "Select exactly one eligible installer receipt. Protected package prefixes are excluded. AppDelete will perform a safety preflight before removing anything." \
        --arg bannertitle "Remove Installed Package" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}" \
        --arg icon "SF=shippingbox.fill,color=auto" \
        --arg bannerimage "$SD_BANNER_IMAGE" \
        --arg helpmessage "Package receipts are not vendor uninstallers. Protected, shared, missing, and unsafe paths are excluded. The receipt is forgotten only after approved removals succeed." \
        --arg infotext "V ${SCRIPT_VERSION}" \
        --argjson checkbox "$checkbox_json" \
        '{message:$message,messageposition:"top",bannertitle:$bannertitle,subtitle:$subtitle,titlefont:$titlefont,icon:$icon,bannerimage:$bannerimage,helpmessage:$helpmessage,width:1040,height:760,moveable:true,ontop:true,buttonstyle:"right",infotext:$infotext,quitkey:"0",button1text:"Preflight",button2text:"Back",checkboxstyle:{style:"switch",size:"regular"},checkbox:$checkbox}' > "$JSON_OPTIONS" || return 1
    jq empty "$JSON_OPTIONS" >/dev/null 2>&1
}

function preflight_receipt ()
{
    local package_id="$SELECTED_RECEIPT_ID"

    if receipt_is_protected "$package_id"; then
        logMe "ERROR: Protected package receipt reached preflight: ${package_id}"
        return 1
    fi
    local metadata_file="${RECEIPT_WORK_DIR}/selected.plist"
    local entry candidate app_bundle

    RECEIPT_APPROVED_APP_BUNDLES=()
    RECEIPT_APPROVED_FILES=()
    RECEIPT_APPROVED_DIRS=()
    RECEIPT_SHARED_PATHS=()
    RECEIPT_PROTECTED_PATHS=()
    RECEIPT_MISSING_PATHS=()
    RECEIPT_UNSAFE_PATHS=()
    RECEIPT_MANIFEST_PATH=""

    RECEIPT_ROOT=$(receipt_root_from_metadata "$package_id" "$metadata_file") || {
        logMe "ERROR: Unable to read metadata for receipt: ${package_id}"
        return 1
    }

    RECEIPT_VERSION=$(/usr/bin/plutil -extract pkg-version raw -o - "$metadata_file" 2>/dev/null) || RECEIPT_VERSION="unknown"

    logMe "Scanning selected receipt only: ${package_id}"
    logMe "Receipt install root: ${RECEIPT_ROOT}"

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue

        candidate=$(resolve_receipt_entry "$RECEIPT_ROOT" "$entry") || {
            RECEIPT_UNSAFE_PATHS+=("$entry")
            continue
        }

        if receipt_path_is_protected "$candidate" || path_has_symlink_ancestor "$candidate"; then
            RECEIPT_PROTECTED_PATHS+=("$candidate")
            continue
        fi

        if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
            RECEIPT_MISSING_PATHS+=("$candidate")
            continue
        fi

        app_bundle=""
        if app_bundle=$(get_receipt_app_bundle "$candidate"); then
            RECEIPT_APPROVED_APP_BUNDLES+=("$app_bundle")
            continue
        fi

        if [[ -d "$candidate" && ! -L "$candidate" ]]; then
            RECEIPT_APPROVED_DIRS+=("$candidate")
        elif [[ -f "$candidate" || -L "$candidate" ]]; then
            RECEIPT_APPROVED_FILES+=("$candidate")
        else
            RECEIPT_UNSAFE_PATHS+=("$candidate")
        fi
    done < <(/usr/sbin/pkgutil --files "$package_id" 2>/dev/null)

    RECEIPT_APPROVED_APP_BUNDLES=("${(@u)RECEIPT_APPROVED_APP_BUNDLES}")
    RECEIPT_APPROVED_FILES=("${(@u)RECEIPT_APPROVED_FILES}")
    RECEIPT_APPROVED_DIRS=("${(@u)RECEIPT_APPROVED_DIRS}")
    RECEIPT_PROTECTED_PATHS=("${(@u)RECEIPT_PROTECTED_PATHS}")
    RECEIPT_MISSING_PATHS=("${(@u)RECEIPT_MISSING_PATHS}")
    RECEIPT_UNSAFE_PATHS=("${(@u)RECEIPT_UNSAFE_PATHS}")
    RECEIPT_APPROVED_DIRS=("${(Oa)RECEIPT_APPROVED_DIRS}")

    logMe "Selected receipt preflight complete: ${#RECEIPT_APPROVED_APP_BUNDLES[@]} application bundle(s), ${#RECEIPT_APPROVED_FILES[@]} file(s)/link(s), ${#RECEIPT_APPROVED_DIRS[@]} directorie(s), ${#RECEIPT_PROTECTED_PATHS[@]} protected, ${#RECEIPT_MISSING_PATHS[@]} missing, ${#RECEIPT_UNSAFE_PATHS[@]} unsafe."

    write_receipt_manifest false
}

function resolve_receipt_entry ()
{
    local root="${1%/}"
    local entry="$2"
    local candidate
    [[ -n "$entry" ]] || return 1
    [[ "$entry" != /* ]] || return 1
    [[ "$entry" != '..' && "$entry" != ../* && "$entry" != *'/../'* && "$entry" != *'/..' ]] || return 1
    [[ "$entry" != '.' && "$entry" != './'* ]] || return 1
    [[ -n "$root" ]] || root="/"
    if [[ "$root" == "/" ]]; then
        candidate="/${entry#/}"
    else
        candidate="${root}/${entry#/}"
    fi
    print -r -- "$candidate"
}

function build_receipt_list ()
{
    local package_id plist_file version install_location label
    local -a discovered
    RECEIPT_LABELS=()
    RECEIPT_IDS=()
    discovered=()
    plist_file="${RECEIPT_WORK_DIR}/receipt-info.plist"
    while IFS= read -r package_id; do
        [[ -n "$package_id" ]] || continue
        if receipt_is_protected "$package_id"; then
            logMe "Protected package receipt excluded: ${package_id}"
            continue
        fi
        /usr/sbin/pkgutil --pkg-info-plist "$package_id" > "$plist_file" 2>/dev/null || continue
        version=$(/usr/bin/plutil -extract pkg-version raw -o - "$plist_file" 2>/dev/null) || version="unknown"
        install_location=$(/usr/bin/plutil -extract install-location raw -o - "$plist_file" 2>/dev/null) || install_location="/"
        label="${package_id} | ${version} | ${install_location}"
        discovered+=("$label")
        RECEIPT_IDS[$label]="$package_id"
    done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null)
    (( ${#discovered[@]} > 0 )) || return 1
    RECEIPT_LABELS=("${(@on)discovered}")
}

function choose_receipt ()
{
    local output return_code selected_label
    local -a selections
    selections=()
    output=$("$SW_DIALOG" --jsonfile "$JSON_OPTIONS" --json 2>/dev/null)
    return_code=$?
    case "$return_code" in 0) ;; 2|10) return 2 ;; *) return 1 ;; esac
    while IFS= read -r selected_label; do
        [[ -n "$selected_label" ]] && selections+=("$selected_label")
    done < <(print -r -- "$output" | jq -r 'to_entries[] | select(.value == true) | .key')
    (( ${#selections[@]} == 1 )) || { logMe "Select exactly one package receipt."; return 3; }
    selected_label="${selections[1]}"
    SELECTED_RECEIPT_ID="${RECEIPT_IDS[$selected_label]:-}"
    [[ -n "$SELECTED_RECEIPT_ID" ]] || return 1
    if receipt_is_protected "$SELECTED_RECEIPT_ID"; then
        logMe "ERROR: Refusing protected package receipt: ${SELECTED_RECEIPT_ID}"
        SELECTED_RECEIPT_ID=""
        return 1
    fi
}

function write_receipt_manifest ()
{
    local forgotten="${1:-false}"
    local manifest_tmp="${RECEIPT_WORK_DIR}/manifest.json"
    local apps_file="${RECEIPT_WORK_DIR}/applications.txt"
    local approved_file="${RECEIPT_WORK_DIR}/approved.txt"
    local dirs_file="${RECEIPT_WORK_DIR}/directories.txt"
    local shared_file="${RECEIPT_WORK_DIR}/shared.txt"
    local protected_file="${RECEIPT_WORK_DIR}/protected.txt"
    local missing_file="${RECEIPT_WORK_DIR}/missing.txt"
    local unsafe_file="${RECEIPT_WORK_DIR}/unsafe.txt"
    local removed_file="${RECEIPT_WORK_DIR}/removed.txt"
    local failed_file="${RECEIPT_WORK_DIR}/failed.txt"

    printf '%s\n' "${RECEIPT_APPROVED_APP_BUNDLES[@]}" > "$apps_file" || return 1
    printf '%s\n' "${RECEIPT_APPROVED_FILES[@]}" > "$approved_file" || return 1
    printf '%s\n' "${RECEIPT_APPROVED_DIRS[@]}" > "$dirs_file" || return 1
    printf '%s\n' "${RECEIPT_SHARED_PATHS[@]}" > "$shared_file" || return 1
    printf '%s\n' "${RECEIPT_PROTECTED_PATHS[@]}" > "$protected_file" || return 1
    printf '%s\n' "${RECEIPT_MISSING_PATHS[@]}" > "$missing_file" || return 1
    printf '%s\n' "${RECEIPT_UNSAFE_PATHS[@]}" > "$unsafe_file" || return 1
    printf '%s\n' "${DELETED_ITEMS[@]}" > "$removed_file" || return 1
    printf '%s\n' "${FAILED_ITEMS[@]}" > "$failed_file" || return 1

    if ! jq -n \
        --arg packageID "$SELECTED_RECEIPT_ID" \
        --arg version "$RECEIPT_VERSION" \
        --arg root "$RECEIPT_ROOT" \
        --argjson receiptForgotten "$forgotten" \
        --rawfile approvedApplications "$apps_file" \
        --rawfile approvedFiles "$approved_file" \
        --rawfile approvedDirectories "$dirs_file" \
        --rawfile sharedPaths "$shared_file" \
        --rawfile protectedPaths "$protected_file" \
        --rawfile missingPaths "$missing_file" \
        --rawfile unsafePaths "$unsafe_file" \
        --rawfile removedPaths "$removed_file" \
        --rawfile failedPaths "$failed_file" \
        '
        def lines:
            split("\n")
            | map(select(length > 0));

        {
            packageID: $packageID,
            version: $version,
            installRoot: $root,
            receiptForgotten: $receiptForgotten,
            approvedApplications: ($approvedApplications | lines),
            approvedFiles: ($approvedFiles | lines),
            approvedDirectories: ($approvedDirectories | lines),
            sharedPaths: ($sharedPaths | lines),
            protectedPaths: ($protectedPaths | lines),
            missingPaths: ($missingPaths | lines),
            unsafePaths: ($unsafePaths | lines),
            removedPaths: ($removedPaths | lines),
            failedPaths: ($failedPaths | lines)
        }
        ' > "$manifest_tmp"
    then
        logMe "ERROR: Unable to create receipt removal manifest."
        return 1
    fi

    if [[ -z "$RECEIPT_MANIFEST_PATH" ]]; then
        RECEIPT_MANIFEST_PATH="${LOG_FILE:h}/${SCRIPT_NAME}-${SELECTED_RECEIPT_ID//[^A-Za-z0-9._-]/_}-$EPOCHSECONDS.json"
    fi

    if ! /bin/cp -f -- "$manifest_tmp" "$RECEIPT_MANIFEST_PATH"; then
        logMe "ERROR: Unable to save receipt removal manifest."
        return 1
    fi

    if ! /bin/chmod 600 "$RECEIPT_MANIFEST_PATH"; then
        logMe "ERROR: Unable to secure receipt removal manifest."
        return 1
    fi

    return 0
}

function build_receipt_confirmation ()
{
    local path
    local count=0
    local remaining=0
    local preview_limit="${RECEIPT_PREVIEW_LIMIT:-100}"

    [[ "$preview_limit" == <-> ]] || preview_limit=100
    (( preview_limit > 0 )) || preview_limit=100

    CONFIRMATION_MESSAGE="## Installed Package Removal Preflight<br><br>"

    CONFIRMATION_MESSAGE+="**Package ID:** ${SELECTED_RECEIPT_ID}<br>"
    CONFIRMATION_MESSAGE+="**Version:** ${RECEIPT_VERSION}<br>"
    CONFIRMATION_MESSAGE+="**Install Root:** ${RECEIPT_ROOT}<br><br>"

    CONFIRMATION_MESSAGE+="### Preflight Summary<br><br>"
    CONFIRMATION_MESSAGE+="Applications to remove: ${#RECEIPT_APPROVED_APP_BUNDLES[@]}<br>"
    CONFIRMATION_MESSAGE+="Files and links to remove: ${#RECEIPT_APPROVED_FILES[@]}<br>"
    CONFIRMATION_MESSAGE+="Directories eligible for empty-only cleanup: ${#RECEIPT_APPROVED_DIRS[@]}<br>"
    CONFIRMATION_MESSAGE+="Protected paths excluded: ${#RECEIPT_PROTECTED_PATHS[@]}<br>"
    CONFIRMATION_MESSAGE+="Missing paths: ${#RECEIPT_MISSING_PATHS[@]}<br>"
    CONFIRMATION_MESSAGE+="Unsafe entries excluded: ${#RECEIPT_UNSAFE_PATHS[@]}<br><br>"

    if (( ${#RECEIPT_APPROVED_APP_BUNDLES[@]} > 0 )); then
        CONFIRMATION_MESSAGE+="### Applications to Remove<br><br>"
        for path in "${RECEIPT_APPROVED_APP_BUNDLES[@]}"; do
            CONFIRMATION_MESSAGE+="• ${path}<br>"
        done
        CONFIRMATION_MESSAGE+="<br>"
    fi

    if (( ${#RECEIPT_APPROVED_FILES[@]} > 0 )); then
        CONFIRMATION_MESSAGE+="### Files and Links to Remove<br><br>"
        count=0

        for path in "${RECEIPT_APPROVED_FILES[@]}"; do
            (( count >= preview_limit )) && break
            CONFIRMATION_MESSAGE+="• ${path}<br>"
            (( count++ ))
        done

        remaining=$(( ${#RECEIPT_APPROVED_FILES[@]} - count ))

        if (( remaining > 0 )); then
            CONFIRMATION_MESSAGE+="<br>...and ${remaining} additional files or links.<br>"
            CONFIRMATION_MESSAGE+="See the removal manifest for the complete list.<br>"
        fi

        CONFIRMATION_MESSAGE+="<br>"
    fi

    if (( ${#RECEIPT_APPROVED_DIRS[@]} > 0 )); then
        CONFIRMATION_MESSAGE+="### Directories Eligible for Empty-Only Cleanup<br><br>"
        count=0

        for path in "${RECEIPT_APPROVED_DIRS[@]}"; do
            (( count >= preview_limit )) && break
            CONFIRMATION_MESSAGE+="• ${path}<br>"
            (( count++ ))
        done

        remaining=$(( ${#RECEIPT_APPROVED_DIRS[@]} - count ))

        if (( remaining > 0 )); then
            CONFIRMATION_MESSAGE+="<br>...and ${remaining} additional directories.<br>"
            CONFIRMATION_MESSAGE+="See the removal manifest for the complete list.<br>"
        fi

        CONFIRMATION_MESSAGE+="<br>"
    fi

    CONFIRMATION_MESSAGE+="AppDelete will remove the application bundles, files, and links listed above, then attempt to remove the listed directories only when they are empty.<br><br>"
    CONFIRMATION_MESSAGE+="The package receipt will be forgotten only if all approved removals succeed.<br><br>"
    CONFIRMATION_MESSAGE+="**Manifest:** ${RECEIPT_MANIFEST_PATH}<br><br>"
    CONFIRMATION_MESSAGE+="**This action cannot be undone.**"

    return 0
}

function remove_receipt_content ()
{
    local path app_name

    DELETED_ITEMS=()
    FAILED_ITEMS=()

    for path in "${RECEIPT_APPROVED_APP_BUNDLES[@]}"; do
        [[ -n "$path" ]] || continue
        app_name="${path:t:r}"

        if ! path_is_within_search_locations "$path"; then
            logMe "ERROR: Receipt application is outside approved application locations: ${path}"
            FAILED_ITEMS+=("$path")
            continue
        fi

        if array_contains "$app_name" "${NOT_ALLOWED_APPS[@]}"; then
            logMe "ERROR: Refusing to remove protected application bundle: ${path}"
            FAILED_ITEMS+=("$path")
            continue
        fi

        if [[ -L "$path" || ! -d "$path" || "$path" != *.app ]]; then
            logMe "ERROR: Receipt application failed final validation: ${path}"
            FAILED_ITEMS+=("$path")
            continue
        fi

        logMe "Removing receipt-owned application bundle: ${path}"
        if /bin/rm -rf -- "$path" && [[ ! -e "$path" ]]; then
            DELETED_ITEMS+=("$path")
            logMe "Application bundle removal verified: ${path}"
        else
            FAILED_ITEMS+=("$path")
            logMe "ERROR: Application bundle removal failed or path remains: ${path}"
        fi
    done

    for path in "${RECEIPT_APPROVED_FILES[@]}"; do
        if receipt_path_is_protected "$path" || path_has_symlink_ancestor "$path" || [[ ! -e "$path" && ! -L "$path" ]]; then
            FAILED_ITEMS+=("$path")
            logMe "ERROR: Receipt path failed final validation: ${path}"
            continue
        fi

        /bin/rm -f -- "$path"

        if [[ ! -e "$path" && ! -L "$path" ]]; then
            DELETED_ITEMS+=("$path")
        else
            FAILED_ITEMS+=("$path")
        fi
    done

    for path in "${RECEIPT_APPROVED_DIRS[@]}"; do
        receipt_path_is_protected "$path" && continue
        [[ -d "$path" && ! -L "$path" ]] || continue
        /bin/rmdir -- "$path" 2>/dev/null && DELETED_ITEMS+=("$path")
    done

    (( ${#FAILED_ITEMS[@]} == 0 ))
}

function forget_selected_receipt ()
{
    local output

    if receipt_is_protected "$SELECTED_RECEIPT_ID"; then
        logMe "ERROR: Refusing to forget protected package receipt: ${SELECTED_RECEIPT_ID}"
        return 1
    fi
    output=$(/usr/sbin/pkgutil --forget "$SELECTED_RECEIPT_ID" 2>&1) || { logMe "ERROR: pkgutil --forget failed: ${output}"; return 1; }
    if /usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -Fqx -- "$SELECTED_RECEIPT_ID"; then
        logMe "ERROR: Receipt remains registered: ${SELECTED_RECEIPT_ID}"
        return 1
    fi
    logMe "Receipt successfully forgotten: ${SELECTED_RECEIPT_ID}"
}

function run_receipt_workflow ()
{
    local pkgStatus=0
    local confirmation_status=0
    local completion_status=0

    RECEIPT_WORK_DIR=$(/usr/bin/mktemp -d "/var/tmp/${SCRIPT_NAME}.receipt.XXXXXX") || return 1

    if ! build_receipt_list; then
        logMe "No eligible package receipts were found."
        return 2
    fi

    while true; do
        construct_receipt_list || return 1

        choose_receipt
        pkgStatus=$?

        case "$pkgStatus" in
            0)
                break
                ;;
            2)
                return 2
                ;;
            3)
                continue
                ;;
            *)
                return 1
                ;;
        esac
    done

    logMe "Preflighting receipt: ${SELECTED_RECEIPT_ID}"

    if ! preflight_receipt; then
        logMe "ERROR: Receipt preflight failed: ${SELECTED_RECEIPT_ID}"
        return 1
    fi

    # A receipt with no remaining approved files/directories can be stale.
    # Forget it only when the receipt contains missing paths and there are no
    # protected or unsafe paths preventing us from proving that its content is gone.
    if (( ${#RECEIPT_APPROVED_APP_BUNDLES[@]} == 0 &&
          ${#RECEIPT_APPROVED_FILES[@]} == 0 &&
          ${#RECEIPT_APPROVED_DIRS[@]} == 0 )); then

        if (( ${#RECEIPT_MISSING_PATHS[@]} > 0 &&
              ${#RECEIPT_PROTECTED_PATHS[@]} == 0 &&
              ${#RECEIPT_UNSAFE_PATHS[@]} == 0 )); then

            logMe "All receipt-owned content is already absent from the system."
            logMe "The stale package receipt can be forgotten: ${SELECTED_RECEIPT_ID}"

            DELETED_ITEMS=()
            FAILED_ITEMS=()

            CONFIRMATION_MESSAGE="## Stale package receipt detected<br><br>"
            CONFIRMATION_MESSAGE+="Package ID: ${SELECTED_RECEIPT_ID}<br>"
            CONFIRMATION_MESSAGE+="Version: ${RECEIPT_VERSION}<br>"
            CONFIRMATION_MESSAGE+="Install root: ${RECEIPT_ROOT}<br>"
            CONFIRMATION_MESSAGE+="Missing receipt paths: ${#RECEIPT_MISSING_PATHS[@]}<br><br>"
            CONFIRMATION_MESSAGE+="No installed files or directories recorded by this receipt remain on the system.<br><br>"
            CONFIRMATION_MESSAGE+="No files will be deleted. Only the stale package receipt will be forgotten.<br><br>"
            CONFIRMATION_MESSAGE+="Manifest: ${RECEIPT_MANIFEST_PATH}"

            show_final_delete_prompt
            confirmation_status=$?

            case "$confirmation_status" in
                0)
                    if forget_selected_receipt; then
                        DELETED_ITEMS+=("Receipt forgotten: ${SELECTED_RECEIPT_ID}")
                        write_receipt_manifest true
                        build_completion_message
                        show_completed_prompt
                        completion_status=$?
                        case "$completion_status" in
                            0) return 0 ;;
                            2)
                                logMe "User selected Run Again after stale receipt removal."
                                return 2
                                ;;
                            *) return 1 ;;
                        esac
                    fi

                    FAILED_ITEMS+=("Receipt not forgotten: ${SELECTED_RECEIPT_ID}")
                    write_receipt_manifest false
                    build_completion_message
                    show_completed_prompt
                    completion_status=$?
                    case "$completion_status" in
                        2)
                            logMe "User selected Run Again after stale receipt removal failure."
                            return 2
                            ;;
                        *) return 1 ;;
                    esac
                    ;;
                2)
                    logMe "Stale receipt removal cancelled."
                    return 2
                    ;;
                *)
                    logMe "ERROR: Stale receipt confirmation dialog exited with code ${confirmation_status}."
                    return 1
                    ;;
            esac
        fi

        logMe "No removable content was found, but protected or unsafe receipt paths remain."
        logMe "Receipt will not be forgotten automatically: ${SELECTED_RECEIPT_ID}"
        return 1
    fi

    build_receipt_confirmation

    show_final_delete_prompt
    confirmation_status=$?

    case "$confirmation_status" in
        0)
            ;;
        2)
            logMe "Package removal cancelled."
            return 2
            ;;
        *)
            logMe "ERROR: Package removal confirmation dialog exited with code ${confirmation_status}."
            return 1
            ;;
    esac

    remove_receipt_content
    pkgStatus=$?

    if (( pkgStatus == 0 )); then
        if forget_selected_receipt; then
            DELETED_ITEMS+=("Receipt forgotten: ${SELECTED_RECEIPT_ID}")
            write_receipt_manifest true
        else
            FAILED_ITEMS+=("Receipt not forgotten: ${SELECTED_RECEIPT_ID}")
            pkgStatus=1
            write_receipt_manifest false
        fi
    else
        logMe "Receipt retained because one or more approved removals failed."
        FAILED_ITEMS+=("Receipt retained: ${SELECTED_RECEIPT_ID}")
        write_receipt_manifest false
    fi

    build_completion_message
    show_completed_prompt
    completion_status=$?

    case "$completion_status" in
        0) return "$pkgStatus" ;;
        2)
            logMe "User selected Run Again after package removal."
            return 2
            ;;
        *) return 1 ;;
    esac
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

####################################################################################################
#
# Common functions
#
####################################################################################################

function choose_workflow_mode ()
{
    local requested_workflow="${WORKFLOW_PARAMETER:l}"
    local dialog_output=""
    local return_code=0
    local selected_workflow=""

    WORKFLOW_MODE=""

    #
    # Parameter-controlled workflows do not display the selector.
    #
    case "$requested_workflow" in
        applications|application|apps|app)
            WORKFLOW_MODE="applications"
            logMe "Workflow selected by parameter: Applications"
            return 0
            ;;

        receipts|receipt|packages|package)
            WORKFLOW_MODE="receipts"
            logMe "Workflow selected by parameter: Installed Package"
            return 0
            ;;

        choose|select|prompt)
            logMe "Workflow parameter requests interactive selection."
            ;;

        *)
            logMe "WARNING: Invalid workflow parameter: ${WORKFLOW_PARAMETER}"
            logMe "Defaulting to the Applications workflow."

            WORKFLOW_MODE="applications"
            return 0
            ;;
    esac

    #
    # Build workflow-selection dialog.
    #
    if ! jq -n \
        --arg message "Choose the AppDelete workflow you want to run." \
        --arg icon "$SD_ICON_FILE" \
        --arg bannerimage "$SD_BANNER_IMAGE" \
        --arg bannertitle "$SD_WINDOW_TITLE" \
        --arg subtitle "$BANNER_SUBTITLE" \
        --arg titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}" \
        --arg infotext "V${SCRIPT_VERSION}" \
        '
        {
            message: $message,
            messageposition: "top",
            icon: $icon,
            bannerimage: $bannerimage,
            bannertitle: $bannertitle,
            subtitle: $subtitle,
            titlefont: $titlefont,
            width: 820,
            height: 500,
            moveable: true,
            ontop: true,
            quitkey: "0",
            buttonstyle: "right",
            infotext: $infotext,
            button1text: "Continue",
            button2text: "Quit",

            selectitems: [
                {
                    title: "Workflow",
                    name: "Workflow",
                    values: [
                        "Applications",
                        "Installed Package"
                    ],
                    default: "Applications",
                    style: "radio"
                }
            ]
        }
        ' > "$JSON_OPTIONS"
    then
        logMe "ERROR: Unable to construct workflow selection JSON."
        return 1
    fi

    if ! jq empty "$JSON_OPTIONS" >/dev/null 2>&1; then
        logMe "ERROR: Workflow selection JSON is invalid."
        return 1
    fi

    dialog_output=$("$SW_DIALOG" --jsonfile "$JSON_OPTIONS" --json 2>/dev/null)

    return_code=$?

    case "$return_code" in
        0)
            ;;

        2|10)
            logMe "User elected to quit AppDelete."
            return 2
            ;;

        *)
            logMe "ERROR: Workflow dialog exited with code ${return_code}."
            return 1
            ;;
    esac

    #
    # Validate returned JSON.
    #
    if ! print -r -- "$dialog_output" |
        jq empty >/dev/null 2>&1
    then
        logMe "ERROR: Workflow dialog returned invalid JSON."
        return 1
    fi

    #
    # Read the named Workflow radio control.
    #
    selected_workflow=$(
        print -r -- "$dialog_output" |
            jq -r '."Workflow".selectedValue // empty'
    )

    case "$selected_workflow" in
        "Applications")
            WORKFLOW_MODE="applications"
            ;;

        "Installed Package")
            WORKFLOW_MODE="receipts"
            ;;

        *)
            logMe "ERROR: Invalid workflow selection: ${selected_workflow}"
            return 1
            ;;
    esac

    logMe "Selected workflow: ${selected_workflow}"

    return 0
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

function show_final_delete_prompt ()
{
    local return_code=0
    local -a main_dialog_body

    main_dialog_body=(
        --message "$CONFIRMATION_MESSAGE"
        --icon "$SD_ICON_FILE"
        --overlayicon warning
        --width 920
        --height 750
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --subtitle "$BANNER_SUBTITLE"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
        --button1text "Delete"
        --button2text "Cancel"
        --buttonstyle right
        --infotext "V ${SCRIPT_VERSION}"
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
        --buttonstyle right
        --infotext "V ${SCRIPT_VERSION}"
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

####################################################################################################
#
# Main
#
####################################################################################################

autoload 'is-at-least'

#
# Global application state
#
typeset -a FILES_LIST
typeset -A ITEM_PATHS
typeset -a SELECTED_ITEMS
typeset -a APPROVED_DELETE_PATHS

#
# Global result state
#
typeset -a DELETED_ITEMS
typeset -a FAILED_ITEMS
typeset CONFIRMATION_MESSAGE=""

#
# Workflow state
#
typeset WORKFLOW_MODE=""

#
# Package receipt state
#
typeset RECEIPT_WORK_DIR=""
typeset SELECTED_RECEIPT_ID=""
typeset RECEIPT_ROOT=""
typeset RECEIPT_VERSION=""
typeset RECEIPT_MANIFEST_PATH=""

typeset -a RECEIPT_LABELS
typeset -a RECEIPT_APPROVED_APP_BUNDLES
typeset -a RECEIPT_APPROVED_FILES
typeset -a RECEIPT_APPROVED_DIRS
typeset -a RECEIPT_SHARED_PATHS
typeset -a RECEIPT_PROTECTED_PATHS
typeset -a RECEIPT_MISSING_PATHS
typeset -a RECEIPT_UNSAFE_PATHS

typeset -A RECEIPT_IDS


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

    choose_workflow_mode
    workflow_status=$?

    case "$workflow_status" in
        0)
            ;;
        2)
            cleanup_and_exit 0
            ;;
        *)
            cleanup_and_exit 1
            ;;
    esac

    case "$WORKFLOW_MODE" in
        applications)
            run_application_workflow
            ;;

        receipts)
            run_receipt_workflow
            ;;

        *)
            logMe "ERROR: Unknown workflow mode: ${WORKFLOW_MODE}"
            cleanup_and_exit 1
            ;;
    esac

    workflow_status=$?

    case "$workflow_status" in
        0)
            cleanup_and_exit 0
            ;;

        2)
            continue
            ;;

        *)
            cleanup_and_exit 1
            ;;
    esac

done