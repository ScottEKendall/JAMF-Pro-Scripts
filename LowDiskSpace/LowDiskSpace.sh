#!/bin/zsh
#
# LowDiskSpace.sh
#
# by: Scott Kendall
#
# Written: 01/03/2025
# Last updated: 11/24/2026
#
# Script Purpose: Display user friendly dialog to users about their disk space
#
# 1.0 - Initial 
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       Fixed Show Files option to call correct trigger
#       removed unnecessary variables.
#       Fixed typos
# 1.4 - Fixed window layout for Tahoe & SD v3.0
# 1.5 - Changed JAMF 'policy -trigger' to JAMF 'policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Updated disk usage calculation to use the APFS Data volume
#       Added available disk space to the user notification
#       Updated dialog messaging and button layout
#       Added "Not Now" option and made "Show Files" the primary action
#       Improved Jamf policy execution and error handling
#       Added root and SwiftDialog prerequisite validation
#       Improved logging and general code cleanup

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="LowDiskSpace"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

DISK_INFO=$( /bin/df -Pk /System/Volumes/Data | /usr/bin/awk 'END { gsub(/%/, "", $5); printf "%s %s", $5, $4 }' )
DISK_USAGE="${DISK_INFO%% *}"
FREE_DISK_BLOCKS="${DISK_INFO##* }"
FREE_DISK_SPACE=$(( FREE_DISK_BLOCKS / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
SHOW_DISK_USAGE="ShowDiskUsage"

# Make some temp files for this app

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles)
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="GE_SD_BannerImage.png"
    BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
    BANNER_SUBTITLE=""
fi
[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Low Disk Space"
OVERLAY_ICON="${SUPPORT_DIR}/SupportFiles/DiskSpace.png"

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
    [[ -n "${DIALOG_COMMAND_FILE:-}" ]] && /bin/rm -rf -- "${DIALOG_COMMAND_FILE}.lock"

    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

function welcomemsg ()
{
    local messagebody
    local buttonpress

    # Determine current disk utilization and available space

    messagebody="Your Mac is running low on storage space.\\n\\n"
    messagebody+="**${DISK_USAGE}% of the disk is currently in use, leaving approximately ${FREE_DISK_SPACE} GB available.**\\n\\n"
    messagebody+="Low disk space can prevent macOS and application updates from installing successfully "
    messagebody+="and may affect system performance.\\n\\n"
    messagebody+="Select **Show Files** to review the largest files on your Mac. "
    messagebody+="Remove files you no longer need and remember to empty the Trash afterward."

    MainDialogBody=(
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. ${messagebody}"
        --icon "${OVERLAY_ICON}"
        --height 560
        --width 850
        --ontop
        --bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
        --moveable
        --button1text "Show Files"
        --button2text "Not Now"
        --buttonstyle right
    )

    # Show the dialog screen and evaluate the user's selection
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    case "$buttonpress" in
        0)
            logMe "User selected Show Files."
            if ! show_disk_usage; then
                logMe "ERROR: Unable to launch the disk usage workflow."
                return 1
            fi
            ;;
        2)
            logMe "User selected Not Now."
            ;;
        *)
            logMe "Dialog closed with exit code: ${buttonpress}"
            ;;
    esac

    return 0
}

function show_disk_usage ()
{
    local jamf_exit=0

    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot run disk usage workflow."
        return 1
    fi

    logMe "Running disk usage workflow."

    /usr/local/bin/jamf policy -event "${SHOW_DISK_USAGE}"
    jamf_exit=$?

    if (( jamf_exit != 0 )); then
        logMe "ERROR: Disk usage workflow failed. Exit code: ${jamf_exit}"
        return 1
    fi

    return 0
}

####################################################################################################
#
# Main Program
#
####################################################################################################

autoload 'is-at-least'

check_for_sudo || exit 1
create_log_directory || exit 1
check_swift_dialog_install || exit 1
check_support_files
create_infobox_message
welcomemsg

exit 0