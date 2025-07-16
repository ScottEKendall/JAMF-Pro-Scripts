#!/bin/zsh
#
# UpTime
#
# Created by: Scott Kendall
# Created on: 02/10/25
# Last Modified: 07/16/2025
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
# 
######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

OS_PLATFORM=$(/usr/bin/uname -p)

[[ "$OS_PLATFORM" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.5.0"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/SystemUptime.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}System Uptime Reminder"
SD_INFO_BOX_MSG=""
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
OVERLAY_ICON="${SUPPORT_DIR}/SupportFiles/Uptime.png"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_ICON_TRIGGER="install_uptimeicon"

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

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions
	[[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
	/bin/chmod 755 "${LOG_DIR}"

	# If the log file does not exist - create it and set the permissions
	[[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
	/bin/chmod 644 "${LOG_FILE}"
}

function logMe () 
{
    # Basic two pronged logging function that will log like this:
    #
    # 20231204 12:00:00: Some message here
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    #
    # RETURN: None
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
}

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None

    logMe "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$( ${SW_DIALOG} --version)        
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else    
        logMe "Swift Dialog is currently running: ${SD_VERSION}"
    fi
}

function install_swift_dialog ()
{
    # Install Swift dialog From JAMF
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
    #
    # RETURN: None

    /usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
    [[ ! -e "${OVERLAY_ICON}" ]] && /usr/local/bin/jamf policy -trigger ${DIALOG_ICON_TRIGGER}
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
    [[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
    [[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
    exit 0
}

function welcomemsg ()
{
    
    messagebody="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  This is an automated message from JAMF to let "
    messagebody+="you know that it has been over ${uptimeDays:-0} days since your system was<br>"
    messagebody+="last restarted.  It is highly recommended that you restart your<br>"
    messagebody+="Mac at least once every ${UPTIME_DAYS} days to keep your system running as smoothly as possible.<br><br>"
    messagebody+="You can choose Restart Now, and it will start a $RESTART_TIMER minute count down "
    messagebody+="timer before the system restarts.<br><br>If you do not restart very soon, "
    messagebody+="you will get a friendly reminder next week."

    MainDialogBody=(
        --message "${messagebody}"
        --icon "${OVERLAY_ICON}"
        --overlayicon --computer
        --height 480
        --ontop
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --titlefont shadow=1
        --moveable
        --button2text "OK"
        --button1text "Restart Now"
        --buttonstyle center
    )

    # Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    # User wants to continue, so retart the computer

    [[ ${buttonpress} -eq 0 ]] && display_restart_timer
    logMe "INFO: User chose to defer at this time."
}

function display_restart_timer ()
{
    messagebody="You Mac will restart after the timer has finished its count down, or you "
    messagebody+="can choose to restart immediately.  Please take this time to save your work."
    
    MainDialogBody=(
    --message "${messagebody}"
    --icon "${OVERLAY_ICON}"
    --height 300
    --ontop
    --bannerimage "${SD_BANNER_IMAGE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --titlefont shadow=1
    --moveable
    --timer $((RESTART_TIMER*60))
    --button1text "Restart Now"
    )

    logMe "INFO: User chose to restart now...starting $RESTART_TIMER timer"
    
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null

    osascript -e 'tell app "System Events" to restart'
    if [[ $? -ne 0 ]]; then
        logMe "Performing restart of system at this time."
        sudo shutdown -r now
    fi
}

####################################################################################################
#
# Main Program
#
####################################################################################################

declare uptimeDays

autoload 'is-at-least'

# Special condition for JAMF...if the user restart, but the jamf recon hasn't been run yet, then JAMF still thinks the computer needs resarted
uptimeOutput=$(uptime)
[[ "${uptimeOutput/day/}" != "${uptimeOutput}" ]] && uptimeDays=$(echo $uptimeOutput | awk -F "up | day" '{print $2}') || exit 0

check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg
exit 0
