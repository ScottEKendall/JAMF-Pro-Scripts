#!/bin/zsh
#
# DiskUsage
#
# by: Scott Kendall
#
# Written: 10/2/2022
# Last updated: 11/25/2026
#
# Script Purpose: Show disk usage info for the logged in user and optionally open Grand Perspective if installed.
#
# 1.0 - Initial
# 1.1 - Major code cleanup & documentation / Structured code to be more inline / consistent across all apps
# 1.2 - Fix issued with Grand Perspective option not showing correctly
# 1.3 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.4 - Code cleanup
#       Add verbiage in the window if Grand Perspective is installed.
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 1.5 - Had to fix some dialog logic for  Tahoe & SD v3.0
# 1.6 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Improved disk scanning performance and result handling
#       Reworked file scanning to use find/stat with numeric size sorting
#       Reworked directory scanning to return directory-only results
#       Added human-readable size formatting for displayed and exported results
#       Added scan validation and improved error handling
#       Added formatted Desktop results export
#       Improved temporary-file cleanup

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="DiskUsage"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files for this app

DU_OUTPUT=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.XXXXX") || exit 1

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

SD_WINDOW_TITLE="Disk Usage Scanner"
SD_INFO_BOX_MSG=""
SD_ICON="/System/Applications/Utilities/Disk Utility.app"
GRAND_PERSPECTIVE_APP="/Applications/GrandPerspective.app"

SCAN_DIR="${USER_DIR}"
SCAN_DEPTH=50

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

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="{computername}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="{osname} {osversion}<br>"
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM

    [[ -n "${DU_OUTPUT:-}" && -f "$DU_OUTPUT" ]] && /bin/rm -f -- "$DU_OUTPUT"

    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

function display_welcome_message ()
{
    local WelcomeMsg=""
    local temp=""
    local returnCode=0
    local -a MainDialogBody

    WelcomeMsg="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  This script analyzes the ${SCAN_DEPTH} largest files and/or directories from your home "
    WelcomeMsg+="directory, and stores the results in a text file on your desktop (and on the screen).  "
    WelcomeMsg+="Please be patient as execution time can take several minutes."
    [[ -d "${GRAND_PERSPECTIVE_APP}" ]] && WelcomeMsg+="<br><br>Since you have Grand Perspective installed, you can launch that application to show disk usage with more details."

	MainDialogBody=(
        --message "${WelcomeMsg}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --overlayicon "${SD_ICON}"
        --icon computer
        --quitkey 0
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"
        --messagefont size=18
        --checkbox "Directories only"
        --infobox "${SD_INFO_BOX_MSG}"
        --width 900
        --height 480
        --button1text "Ok"
        --button2text "Cancel"
        )

        [[ -d "${GRAND_PERSPECTIVE_APP}" ]] && MainDialogBody+=(--infobuttontext "Grand Perspective")
        MainDialogBody+=(--moveable --ontop)
        temp=$("$SW_DIALOG" "${MainDialogBody[@]}")
        returnCode=$?

        [[ $returnCode = 2 ]] && cleanup_and_exit
        [[ $returnCode = 3 ]] && open_grand_perspective
    
        INCLUDE_DIRECTORIES=$(printf '%s\n' "$temp" | awk -F " : " '{print $NF}' | tr -d '"')
}

function open_grand_perspective ()
{
    /usr/bin/open "${GRAND_PERSPECTIVE_APP}"
    cleanup_and_exit
}

function analyze_disk_usage ()
{
    local scan_status=0
    local temp_output=""

    logMe "Scanning disk usage under: ${SCAN_DIR}"

    : > "$DU_OUTPUT"

    if [[ "${INCLUDE_DIRECTORIES}" == "true" ]]; then
        logMe "Scanning directories..."

        temp_output=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_directories.XXXXX") || {
            logMe "ERROR: Unable to create temporary directory scan file."
            return 1
        }

        /usr/bin/du -x -k "$SCAN_DIR" 2>/dev/null | /usr/bin/awk -F '\t' -v root="$SCAN_DIR" '$2 != root' | /usr/bin/sort -nr | /usr/bin/head -n "$SCAN_DEPTH" > "$temp_output"
        scan_status=${pipestatus[1]}

        if (( scan_status == 0 )); then
            /usr/bin/awk -F '\t' '{
                size=$1 * 1024
                $1=""
                sub(/^[[:space:]]*/, "")
                printf "%.0f\t%s\n", size, $0}' "$temp_output" > "$DU_OUTPUT"
        fi

        /bin/rm -f "$temp_output"
    else
        logMe "Scanning files..."

        /usr/bin/find "$SCAN_DIR" -xdev -type f -print0 2>/dev/null | /usr/bin/xargs -0 /usr/bin/stat -f '%z	%N' 2>/dev/null | /usr/bin/sort -nr | /usr/bin/head -n "$SCAN_DEPTH" > "$DU_OUTPUT"
        scan_status=${pipestatus[1]}
    fi

    if (( scan_status != 0 )); then
        logMe "WARNING: Disk usage scan reported exit code: ${scan_status}"
    fi

    if [[ ! -s "$DU_OUTPUT" ]]; then
        logMe "ERROR: Disk usage scan did not return any results."
        return 1
    fi

    logMe "Disk usage scan completed."
    return 0
}

function format_bytes ()
{
    local bytes="$1"

    if (( bytes >= 1099511627776 )); then
        printf "%.2f TB" "$(( bytes / 1099511627776.0 ))"
    elif (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$(( bytes / 1073741824.0 ))"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" "$(( bytes / 1048576.0 ))"
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" "$(( bytes / 1024.0 ))"
    else
        printf "%d bytes" "$bytes"
    fi
}

function show_results ()
{
    local tempmsg=""
    local bytes
    local size
    local item_path
    local returnCode=0
    local -a MainDialogBody

    while IFS=$'\t' read -r bytes item_path; do
        [[ -z "$bytes" || -z "$item_path" ]] && continue

        size=$(format_bytes "$bytes")
        tempmsg+="${size}  -  ${item_path}<br>"
    done < "$DU_OUTPUT"

    if [[ -z "$tempmsg" ]]; then
        logMe "ERROR: No disk usage results available for display."
        return 1
    fi

    MainDialogBody=(
        --message "$tempmsg"
        --messagefont size=12
        --bannerimage "$SD_BANNER_IMAGE"
        --bannertitle "$SD_WINDOW_TITLE"
        --subtitle "$BANNER_SUBTITLE"
        --quitkey 0
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"
        --width 1000
        --height 800
        --button1text "Ok"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}"
    returnCode=$?

    return "$returnCode"
}

function export_results ()
{
    local output_file="${USER_DIR}/Desktop/DiskUsage_Output.txt"
    local bytes
    local size
    local item_path

    : > "$output_file" || {
        logMe "ERROR: Unable to create output file: ${output_file}"
        return 1
    }

    while IFS=$'\t' read -r bytes item_path; do
        [[ -z "$bytes" || -z "$item_path" ]] && continue

        size=$(format_bytes "$bytes")
        printf "%-10s - %s\n" "$size" "$item_path" >> "$output_file"
    done < "$DU_OUTPUT"

    if [[ ! -s "$output_file" ]]; then
        logMe "ERROR: Disk usage output file is empty: ${output_file}"
        return 1
    fi

    if ! /usr/sbin/chown "$LOGGED_IN_USER" "$output_file"; then
        logMe "ERROR: Unable to set ownership on: ${output_file}"
        return 1
    fi

    logMe "Disk usage results saved to: ${output_file}"
    return 0
}

############################
#
# Start of Main Script
#
############################

autoload 'is-at-least'

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
create_infobox_message
display_welcome_message

analyze_disk_usage || cleanup_and_exit 1
show_results || {
    logMe "WARNING: Unable to display disk usage results."
}

export_results || cleanup_and_exit 1
cleanup_and_exit 0