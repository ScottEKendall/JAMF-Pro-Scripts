#!/bin/zsh
#
# DiskUsage
#
# by: Scott Kendall
#
# Written: 10/2/2022
# Last updated: 02/22/2025
#
# Script Purpose: 
#
# 1.0 - Initial
# 1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps
# 1.2 - Fix issued with Grand Perpective option not showning correctly

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

OS_PLATFORM=$(/usr/bin/uname -p)

[[ "$OS_PLATFORM" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_SERIAL_NUMBER=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.serial_number' 'raw' -)
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_VERSION=$( sw_vers -productVersion | xargs)

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/logs"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Disk Usage Scanner"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/DiskUsage.log"
SD_ICON="/System/Applications/Utilities/Disk Utility.app"
GRAND_PERSPECTIVE_APP="/Applications/GrandPerspective.app"
DU_OUTPUT=$(mktemp /var/tmp/DiskUsage.XXXXX)
SCAN_DIR="${USER_DIR}"
SCAN_DEPTH=50

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

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
    echo "${1}" 1>&2
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
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##\n"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function display_welcome_message ()
{

    WelcomeMsg="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  This script analyzes the ${SCAN_DEPTH} largest files and/or directories from your home "
    WelcomeMsg+="directory, and stores the results in a text file on your desktop (and on the screen).  "
    WelcomeMsg+="Please be patient as execution time can take several minutes."

	MainDialogBody=(
        --message "${WelcomeMsg}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --moveable
        --overlayicon "${SD_ICON}"
        --icon computer
        --quitkey 0
        --titlefont shadow=1, size=24
        --messagefont size=18
        --checkbox "Directories only"
        --infobox "${SD_INFO_BOX_MSG}"
        --width 900
        --height 480
        --button1text "Ok"
        --button2text "Cancel"
        --ontop
        )

        [[ -x "${GRAND_PERSPECTIVE_APP}" ]] && MainDialogBody+=(--infobuttontext "Grand Perspective")
        temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
        returnCode=$?

        [[ $returnCode = 2 ]] && cleanup_and_exit
        [[ $returnCode = 3 ]] && open_grand_perspective
    
        INCLUDE_DIRECTORIES=$(echo $temp | awk -F " : " '{print $NF}' | tr -d '"')
}

function open_grand_perspective ()
{
    open "${GRAND_PERSPECTIVE_APP}"
    cleanup_and_exit
}

function analyze_disk_usage ()
{
    # Perform either a directory scan or a files scan

    if [[ "${INCLUDE_DIRECTORIES}" == "true" ]]; then
        /usr/bin/du -xargh --si "${SCAN_DIR}" 2>/dev/null | sort -hr | head -n ${SCAN_DEPTH} > ${DU_OUTPUT}
    else
        find "${SCAN_DIR}" -type f -exec du -ah {} + 2>/dev/null | sort -hr |  head -n ${SCAN_DEPTH} > ${DU_OUTPUT}
    fi
}

function show_results ()
{
    tempmsg=""
    while IFS= read -r item; do
        space=$(echo "${item}" | /usr/bin/awk -F " " '{print $1}' )
        dir=$( echo "${item}" | /usr/bin/cut  -f 2- )
        tempmsg+="$space  -  $dir<br>"
    done < "${DU_OUTPUT}"

	MainDialogBody=(
        --message "${tempmsg}"
        --messagefont size=12
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --moveable
        --quitkey 0
        --titlefont shadow=1, size=24
        --width 1000
        --height 800
        --button1text "Ok"
        --ontop
        )

        "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
        returnCode=$?
}

############################
#
# Start of Main Script
#
############################

autoload 'is-at-least'

check_support_files
check_swift_dialog_install
check_support_files
create_infobox_message
display_welcome_message
analyze_disk_usage
show_results
cp ${DU_OUTPUT} "${USER_DIR}/Desktop/DiskUsage_Output.txt"
chown ${LOGGED_IN_USER} "${USER_DIR}/Desktop/DiskUsage_Output.txt"
cleanup_and_exit