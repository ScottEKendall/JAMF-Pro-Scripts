#!/bin/zsh
#
# BatteryInfo.sh
#
# Written by: Scott E. Kendall
#
# Created: 01/25/2025
# Last updated: 11/24/2026
#
# Script Purpose: Prompt user if battery needs service
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - fix the SD_ICON reference in the display prompt
# 1.3 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.4 - Changed the icon(s) and wording / Add Help Desk button if battery critical
# 1.5 - Swift dialog min requirements now 2.5.0 / Changed wording on critical message / New icons / Added display item for currently charging.
# 1.6 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
# 1.7 - Had to increase window height for Tahoe & SD v3.0
# 1.8 - Changed JAMF 'policy -trigger' to JAMF 'policy -event'
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and offset from defaults file
# 2.1 - Improved battery information retrieval and parsing
#       Improved detection of AC charger connection, wattage, and charging state
#       Added validation for the Jamf battery condition parameter
#       Improved SwiftDialog installation, version validation, and failure handling
#       Improved support file validation and error handling
#       Removed unused variables and dependencies
#       General code cleanup and reliability improvements

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="BatteryInfo"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

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

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

# Display items (banner / icon)

SD_WINDOW_TITLE="Battery Condition"
HELPDESK_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"


##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}" 
BATTERY_CONDITION=${4:-"info"}

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
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

function welcomemsg ()
{
    local buttonpress
    local messagebody
    local OVERLAY_ICON
    local -a MainDialogBody

    if [[ "${BATTERY_CONDITION:l}" == "info" ]]; then
        messagebody="$SD_DIALOG_GREETING, $SD_FIRST_NAME.  Here is the current state & charging information of your laptop battery:<br><br>"
        messagebody+="Condition: **${BatteryCondition}**<br>"
        messagebody+="Current # of Cycles: **${BatteryCycleCount}**<br>"
        messagebody+="Maximum Battery Capacity: **${BatteryCapacity}**<br>"
        messagebody+="Battery Current Charge: **${BatteryCurrentCharge}%**<br>"
        messagebody+="AC Charger Connected: **${ChargerConnected}**<br>"
        if [[ "$ChargerConnected" == "Yes" ]]; then
            [[ "$BatteryChargingWattage" != "Unknown" ]] && messagebody+="Charger Wattage: **${BatteryChargingWattage}W**<br>"
            messagebody+="Currently Charging: **${BatteryCharging}**<br>"
        fi
        OVERLAY_ICON="SF=battery.100percent.bolt,color=green,bgcolor=none,weight=bold,animation=pulse"
    else
        messagebody="$SD_DIALOG_GREETING, $SD_FIRST_NAME!  This is an automated message from JAMF "
        messagebody+="to let you know that the battery in your laptop is below acceptable"
        messagebody+=" limits declared by Apple.  The runtime while on battery and "
        messagebody+="performance may be severely affected. <br><br>Please raise a ticket with the "
        messagebody+="Help Desk to let them know that you received this message. They will"
        messagebody+=" review the battery condition and advise you on the appropriate next steps."
        OVERLAY_ICON="SF=battery.100percent.bolt,color=red,bgcolor=none,weight=bold,animation=pulse"
    fi

	MainDialogBody=(
        --message "${messagebody}"
        --icon computer
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
        --overlayicon "${OVERLAY_ICON}"
		--height 480
        --width 760
		--ontop
        --infobox "${SD_INFO_BOX_MSG}"
        --moveable
		--button1text 'OK'
		--buttonstyle center
    )
    if [[ "${BATTERY_CONDITION:l}" == "fail" ]] && MainDialogBody+=(--button2text "Help Desk Ticket")
    
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    if (( buttonpress == 2 )); then
        /usr/bin/open "$HELPDESK_URL"
        logMe "INFO: User chose to open a ticket...redirecting to URL and exiting script"
        cleanup_and_exit 0
    fi
}

function get_battery_information ()
{
    local battery_blob

    battery_blob=$(/usr/sbin/system_profiler SPPowerDataType 2>/dev/null)

    if [[ -z "$battery_blob" ]]; then
        logMe "ERROR: Unable to retrieve battery information."
        return 1
    fi

    BatteryCondition=$(print -r -- "$battery_blob" | awk -F': ' '/^[[:space:]]*Condition:/ {print $2; exit}')
    BatteryCycleCount=$(print -r -- "$battery_blob" | awk -F': ' '/^[[:space:]]*Cycle Count:/ {print $2; exit}')
    BatteryCapacity=$(print -r -- "$battery_blob" | awk -F': ' '/^[[:space:]]*Maximum Capacity:/ {print $2; exit}')
    BatteryCurrentCharge=$(print -r -- "$battery_blob" | awk -F': ' '/^[[:space:]]*State of Charge \(%\):/ {print $2; exit}')
    BatteryCharging=$(print -r -- "$battery_blob" | awk -F': ' '/^[[:space:]]*Charging:/ {print $2; exit}')

    ChargerConnected=$(print -r -- "$battery_blob" | awk '
                /AC Charger Information:/ { in_charger=1; next }
                in_charger && /Connected:/ {
                    sub(/^[[:space:]]*Connected:[[:space:]]*/, "")
                    print 
                    exit}')

    BatteryChargingWattage=$(print -r -- "$battery_blob" | awk '
                /AC Charger Information:/ { in_charger=1; next }
                in_charger && /Wattage \(W\):/ {
                    sub(/^[[:space:]]*Wattage \(W\):[[:space:]]*/, "")
                    print
                    exit}')

    BatteryCondition=${BatteryCondition:-"Unknown"}
    BatteryCycleCount=${BatteryCycleCount:-"Unknown"}
    BatteryCapacity=${BatteryCapacity:-"Unknown"}
    BatteryCurrentCharge=${BatteryCurrentCharge:-"Unknown"}
    BatteryCharging=${BatteryCharging:-"Unknown"}
    ChargerConnected=${ChargerConnected:-"No"}
    BatteryChargingWattage=${BatteryChargingWattage:-"Unknown"}

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

case "${BATTERY_CONDITION:l}" in
    info|fail)
        ;;
    *)
        logMe "WARNING: Invalid battery condition parameter '${BATTERY_CONDITION}'. Defaulting to 'info'."
        BATTERY_CONDITION="info"
        ;;
esac

check_swift_dialog_install || {
    logMe "ERROR: SwiftDialog requirements could not be satisfied."
    cleanup_and_exit 1
}

check_support_files || {
    logMe "ERROR: Required support files could not be verified."
    cleanup_and_exit 1
}

get_battery_information || cleanup_and_exit 1

create_infobox_message
welcomemsg

cleanup_and_exit 0