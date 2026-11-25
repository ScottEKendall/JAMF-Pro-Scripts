#!/bin/zsh
#
# UpTime
#
# Scott Kendall
#
# Created on: 02/10/25
# Last Modified: 11/25/2026
# 
# 1.0 - Initial Commit
# 1.1 - Added more logging details
# 1.2 - Added shutdown -r now command in case the applescript method fails
# 1.3 - Add logic to not display restart option if already on day 0...this addresses an issue in JAMF that this policy might be run before inventory gets accurate info
# 1.4 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.5 - Add additional logging
#       set the default JAMF_LOGGED_IN_USER to current logged in user if not called from JAMF
#       Put in logic to install the icon if it doesn't already existing in specified location
#       Bumped min version of Swift Dialog to v2.5.0
# 1.6 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 1.7 - Optimized global common variables routines
#       Fixed issue of ICON_FILES contents not installed properly
# 1.8 - Fixed issue of Free Space amount not showing
#       Swift dialog version wasn't being displayed properly
# 1.9 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Replaced human-readable uptime parsing with kern.boottime calculation
#       Added local uptime validation to prevent notifications after a recent restart
#       Added configurable uptime-threshold enforcement
#       Added validation for uptime and restart-timer parameters
#       Added root-execution validation
#       Improved SwiftDialog installation and version checks
#       Improved support-file installation and verification
#       Added explicit SwiftDialog return-code handling
#       Removed the unused jq dependency
#       Improved logging and restart fallback handling

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="UpTime"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

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

SD_WINDOW_TITLE="System Uptime Reminder"
OVERLAY_ICON="${SUPPORT_DIR}/SupportFiles/Uptime.png"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_ICON_TRIGGER="install_uptimeicon"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JAMF_BINARY="/usr/local/bin/jamf"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}" 
UPTIME_DAYS="${4:-"30"}"
RESTART_TIMER="${5:-"10"}"

####################################################################################################
#
# Functions
#
####################################################################################################

function check_for_sudo ()
{
    if ! admin_user; then
        print -u2 -r -- "ERROR: This script must be run as root."
        return 1
    fi

    return 0
}

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

    if [[ ! -x "$JAMF_BINARY" ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install SwiftDialog."
        return 1
    fi

    "$JAMF_BINARY" policy -event "$DIALOG_INSTALL_POLICY"
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

        if [[ -x "$JAMF_BINARY" ]]; then
            logMe "Running support-file installation policy."

            if ! "$JAMF_BINARY" policy -event "$SUPPORT_FILE_INSTALL_POLICY"; then
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

    if [[ ! -f "$OVERLAY_ICON" ]]; then
        logMe "Uptime icon not found: ${OVERLAY_ICON}"

        if [[ -x "$JAMF_BINARY" ]]; then
            logMe "Running uptime icon installation policy."

            if ! "$JAMF_BINARY" policy -event "$DIALOG_ICON_TRIGGER"; then
                logMe "WARNING: Uptime icon installation policy failed."
            fi
        else
            logMe "WARNING: The local Jamf binary is unavailable. The uptime icon cannot be installed."
        fi

        if [[ -f "$OVERLAY_ICON" ]]; then
            logMe "Uptime icon successfully installed: ${OVERLAY_ICON}"
        else
            logMe "WARNING: Uptime icon remains unavailable: ${OVERLAY_ICON}"
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

    exit "$exit_code"
}

function welcomemsg ()
{
    local messagebody
    local buttonpress
    local -a MainDialogBody

    messagebody="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  This is an automated message to let "
    messagebody+="you know that your Mac has been running for ${uptimeDays} days without a restart.  <br><br>"
    messagebody+="It is highly recommended that you restart your "
    messagebody+="Mac at least once every ${UPTIME_DAYS} days to keep your system running as smoothly as possible.<br><br>"
    messagebody+="You can choose Restart Now to start a ${RESTART_TIMER}-minute countdown "
    messagebody+="before the system restarts.<br><br>If you do not restart soon, "
    messagebody+="you will get a friendly reminder next week."

    MainDialogBody=(
        --message "${messagebody}"
        --icon "${OVERLAY_ICON}"
        --overlayicon --computer
        --height 480
        --ontop
        --bannerimage "${SD_BANNER_IMAGE}"
        --subtitle "${BANNER_SUBTITLE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
        --moveable
        --button2text "OK"
        --button1text "Restart Now"
        --buttonstyle center
    )

    # Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    case "$buttonpress" in
        0)
            logMe "INFO: User chose to restart the system."
            display_restart_timer
            ;;
        2)
            logMe "INFO: User chose to defer at this time."
            ;;
        *)
            logMe "INFO: Dialog exited with return code ${buttonpress}."
            ;;
    esac
}

function display_restart_timer ()
{
    local messagebody
    local -a MainDialogBody
    messagebody="Your Mac will restart after the countdown finishes, or you "
    messagebody+="can choose to restart immediately. Please take this time to save your work."
    
    MainDialogBody=(
    --message "${messagebody}"
    --icon "${OVERLAY_ICON}"
    --height 300
    --ontop
    --bannerimage "${SD_BANNER_IMAGE}"
    --subtitle "${BANNER_SUBTITLE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --titlefont shadow=1,color="${BANNER_TEXT_COLOR}",offset="${BANNER_TEXT_PADDING}"
    --moveable
    --timer $((RESTART_TIMER*60))
    --button1text "Restart Now"
    )

    logMe "INFO: Starting the ${RESTART_TIMER}-minute restart countdown."
    
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null

    if ! /usr/bin/osascript -e 'tell application "System Events" to restart'; then
        logMe "WARNING: AppleScript restart failed. Falling back to shutdown."
        /sbin/shutdown -r now
    fi
}

####################################################################################################
#
# Main Program
#
####################################################################################################

declare uptimeDays

autoload 'is-at-least'

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1

if [[ "$UPTIME_DAYS" != <-> ]] || (( UPTIME_DAYS < 1 )); then
    logMe "ERROR: Invalid uptime threshold: ${UPTIME_DAYS}"
    cleanup_and_exit 1
fi

if [[ "$RESTART_TIMER" != <-> ]] || (( RESTART_TIMER < 1 )); then
    logMe "ERROR: Invalid restart timer: ${RESTART_TIMER}"
    cleanup_and_exit 1
fi



BOOT_TIME=$(sysctl -n kern.boottime | awk -F'[ ,}]+' '{print $4}')
CURRENT_TIME=$(date +%s)

if [[ -z "$BOOT_TIME" || "$BOOT_TIME" != <-> ]]; then
    logMe "ERROR: Unable to determine system boot time."
    cleanup_and_exit 1
fi

uptimeDays=$(( (CURRENT_TIME - BOOT_TIME) / 86400 ))

logMe "System uptime is ${uptimeDays} days."
if (( uptimeDays < UPTIME_DAYS )); then
    logMe "System uptime is below the ${UPTIME_DAYS}-day notification threshold. No notification is required."
    cleanup_and_exit 0
fi

check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1
create_infobox_message
welcomemsg
cleanup_and_exit 0
