#!/bin/zsh
#
# FixProfileOwner
#
# by: Scott Kendall
#
# Written: 9/20/2023
# Last updated: 11/25/2026
#
# Script Purpose: Identify regular files in the logged-in user's home
# directory that are owned by another account and restore ownership
# to the logged-in user.
#
# 1.0 - Initial rewrite using Swift Dialog prompts
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - Changed logic in get_incorrect_file_count function to use find | wc (much faster)
# 1.3 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.4 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
# 1.5 - Had to fix some dialog logic for Tahoe & SD v3.0
# 1.6 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated minimum Swift Dialog version requirement to 3.1.0
#       Added configurable banner subtitle, text color, and padding
#       Added validation for the logged-in user and home directory
#       Changed the scan to identify only incorrectly owned regular files
#       Added a null-delimited ownership manifest for filename safety
#       Changed the ownership workflow to scan the user profile only once
#       Added file revalidation before changing ownership
#       Added corrected, skipped, and failed file totals
#       Added failure handling and nonzero exit results
#       Updated Swift Dialog command-file handling

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
SCRIPT_NAME="FixProfileOwner"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Create the Swift Dialog command file.
DIALOG_COMMAND_FILE=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_dialog.XXXXX")

if [[ -z "$DIALOG_COMMAND_FILE" || ! -f "$DIALOG_COMMAND_FILE" ]]; then
    print -u2 -r -- "ERROR: Unable to create the Swift Dialog command file."
    exit 1
fi

if ! /bin/chmod 666 "$DIALOG_COMMAND_FILE"; then
    print -u2 -r -- "ERROR: Unable to set permissions on the Swift Dialog command file."
    /bin/rm -f -- "$DIALOG_COMMAND_FILE"
    exit 1
fi

# Create the null-delimited ownership manifest.
INCORRECT_OWNER_FILE_LIST=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_files.XXXXX")

if [[ -z "$INCORRECT_OWNER_FILE_LIST" || ! -f "$INCORRECT_OWNER_FILE_LIST" ]]; then
    print -u2 -r -- "ERROR: Unable to create the ownership manifest."
    /bin/rm -f -- "$DIALOG_COMMAND_FILE"
    exit 1
fi

if ! /bin/chmod 600 "$INCORRECT_OWNER_FILE_LIST"; then
    print -u2 -r -- "ERROR: Unable to secure the ownership manifest."
    /bin/rm -f -- "$DIALOG_COMMAND_FILE" "$INCORRECT_OWNER_FILE_LIST"
    exit 1
fi

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
SD_WINDOW_TITLE="Fix Profile Ownership"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

USER_SCAN_START_DIR="${USER_DIR}"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

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
    return 0
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM

    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && /bin/rm -f -- "$DIALOG_COMMAND_FILE"
    [[ -n "${INCORRECT_OWNER_FILE_LIST:-}" ]] && /bin/rm -f -- "$INCORRECT_OWNER_FILE_LIST"

    exit "$exit_code"
}

function update_display_list ()
{
    # Purpose:
    #   Update the active Swift Dialog window using the command file.
    #
    # Parameters:
    #   $1 - Action
    #   $2 - Message text
    #   $5 - Progress text
    #   $6 - Progress value
    #
    # Supported actions:
    #   clear
    #   destroy
    #   progress
  
    #
    # Return:
    #   0 = Command processed
    #   1 = Invalid action or command file unavailable

    local action="${1:l}"

    # Most actions require an existing Swift Dialog command file.
    if [[ ! -f "$DIALOG_COMMAND_FILE" ]]; then
        logMe "ERROR: Swift Dialog command file is unavailable: ${DIALOG_COMMAND_FILE}"
        return 1
    fi

    case "$action" in

        "clear" )
            # Clear the list and optionally update the message.
            /bin/echo "list: clear" >> "$DIALOG_COMMAND_FILE"

            [[ -n "$2" ]] && \
                /bin/echo "message: ${2}" >> "$DIALOG_COMMAND_FILE"
            ;;

        "destroy" )
            # Close the Swift Dialog window.
            /bin/echo "quit:" >> "$DIALOG_COMMAND_FILE"
            ;;

        "progress" )
            # Update progress value and progress text.
            /bin/echo "progress: ${6}" >> "$DIALOG_COMMAND_FILE"
            /bin/echo "progresstext: ${5}" >> "$DIALOG_COMMAND_FILE"
            ;;

        * )
            logMe "ERROR: Invalid update_display_list action: ${1}"
            return 1
            ;;

    esac

    return 0
}

####################################################################################################
#
# Local Functions
#
####################################################################################################

function show_welcome_message ()
{
    # Purpose: Display dialog message to user 
    # Return: None

    MainDialogBody=(
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. Please wait while determining which files to analyze...<br><br>Starting the scan at folder: ${USER_SCAN_START_DIR}"
        --icon computer
        --iconsize 128
        --overlayicon "${SD_ICON_FILE}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "color=${BANNER_TEXT_COLOR}, shadow=1, offset=${BANNER_TEXT_PADDING}"
        --messagefont size=18
        --width 770
        --height 350
        --button1disabled
        --commandfile "${DIALOG_COMMAND_FILE}"
        --button1text "none"
        --moveable
        --progress
        --ontop
    )

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null & sleep 0.5

}

function get_incorrect_file_count ()
{
    # Purpose:
    #   Create a null-delimited manifest of regular files that are not
    #   owned by the logged-in user.
    #
    # Return:
    #   0 = Scan completed successfully
    #   1 = Scan failed

    update_display_list "progress" "" "" "" "Scanning for files with incorrect ownership..." 0

    if [[ ! -d "$USER_SCAN_START_DIR" ]]; then
        logMe "ERROR: User scan directory does not exist: ${USER_SCAN_START_DIR}"
        return 1
    fi

    : > "$INCORRECT_OWNER_FILE_LIST" || {
        logMe "ERROR: Unable to initialize the ownership manifest."
        return 1
    }

    if ! /usr/bin/find "$USER_SCAN_START_DIR" -type f ! -user "$LOGGED_IN_USER" -print0 > "$INCORRECT_OWNER_FILE_LIST"; then
        logMe "ERROR: Unable to complete the ownership scan."
        return 1
    fi

    incorrect_file_count=$(LC_ALL=C /usr/bin/tr -cd '\000' < "$INCORRECT_OWNER_FILE_LIST" | /usr/bin/wc -c | /usr/bin/tr -d '[:space:]')

    if [[ ! "$incorrect_file_count" == <-> ]]; then
        logMe "ERROR: Ownership scan returned an invalid file count."
        return 1
    fi

    if (( incorrect_file_count == 0 )); then
        logMe "No incorrectly owned files were found in ${USER_SCAN_START_DIR}."
    else
        logMe "Found ${incorrect_file_count} incorrectly owned file(s) in ${USER_SCAN_START_DIR}."
    fi

    return 0
}

function change_ownership ()
{
    # Purpose:
    #   Correct ownership of files recorded in the ownership manifest.
    #
    # Return:
    #   0 = Completed successfully
    #   1 = One or more ownership changes failed

    typeset -i processed_file_count=0
    typeset -i failed_count=0
    typeset -i skipped_count=0
    typeset -i progress_percentage=0
    typeset -i corrected_count=0
    local file
    local current_owner

    update_display_list "clear" "Correcting incorrectly owned files in: ${USER_SCAN_START_DIR}"

    if (( incorrect_file_count == 0 )); then
        update_display_list "progress" "" "" "" "All files are already owned by ${LOGGED_IN_USER}." 100
        logMe "No ownership corrections are required."
        return 0
    fi

    while IFS= read -r -d '' file; do
        (( processed_file_count++ ))

        if [[ ! -e "$file" ]]; then
            logMe "WARNING: File no longer exists: ${file}"
            (( skipped_count++ ))

        elif ! current_owner=$(/usr/bin/stat -f '%Su' "$file" 2>/dev/null); then
            logMe "WARNING: Unable to determine current owner: ${file}"
            (( failed_count++ ))

        elif [[ "$current_owner" == "$LOGGED_IN_USER" ]]; then
            logMe "File ownership was already corrected: ${file}"
            (( skipped_count++ ))

        elif /usr/sbin/chown "$LOGGED_IN_USER" "$file"; then
            logMe "Corrected ownership: ${file}"
            (( corrected_count++ ))

        else
            logMe "WARNING: Unable to change ownership: ${file}"
            (( failed_count++ ))
        fi

        progress_percentage=$(( processed_file_count * 100 / incorrect_file_count ))

        update_display_list "progress" "" "" "" "Correcting ownership: ${processed_file_count} of ${incorrect_file_count} files" "$progress_percentage"

    done < "$INCORRECT_OWNER_FILE_LIST"

    if (( failed_count > 0 )); then
        logMe "WARNING: Ownership correction completed with ${failed_count} failure(s) and ${skipped_count} skipped file(s)."
        return 1
    fi

    logMe "Ownership correction completed. Processed: ${processed_file_count}; corrected: ${corrected_count}; skipped: ${skipped_count}; failed: ${failed_count}."

    return 0
}

function validate_logged_in_user ()
{
    if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "loginwindow" || "$LOGGED_IN_USER" == "root" ]]; then
        logMe "ERROR: No eligible logged-in user was detected."
        return 1
    fi

    if [[ -z "$USER_DIR" || "$USER_DIR" == "/" || ! -d "$USER_DIR" ]]; then
        logMe "ERROR: Unable to determine a valid home directory for ${LOGGED_IN_USER}."
        return 1
    fi

    if [[ "$USER_SCAN_START_DIR" != "$USER_DIR" ]]; then
        logMe "ERROR: Scan directory does not match the detected user home directory."
        return 1
    fi

    logMe "Detected logged-in user: ${LOGGED_IN_USER}"
    logMe "Validated user home directory: ${USER_DIR}"

    return 0
}

#############################
#
# Start of Main Script
#
#############################

typeset -i incorrect_file_count=0

autoload 'is-at-least'

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
validate_logged_in_user || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1

show_welcome_message

if ! get_incorrect_file_count; then
    update_display_list "Destroy"
    cleanup_and_exit 1
fi

sleep 4

if ! change_ownership; then
    sleep 4
    update_display_list "Destroy"
    cleanup_and_exit 1
fi

sleep 4

update_display_list "Destroy"
cleanup_and_exit 0
