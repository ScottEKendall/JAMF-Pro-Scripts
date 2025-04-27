#!/bin/zsh
#
# Main Library
#
# by: Scott Kendall
#
# Written: 04/27/2025
# Last updated: 04/27/2025
#
# Script Purpose:  Purpose: Completely remove MS Office Products from users mac
#
# 1.0 - Initial
# 1.1 - Code optimization

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

#JSON_OPTIONS=$(mktemp /var/tmp/ClearBrowserCache.XXXXX)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Remove Microsoft Office"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/RemoveOffice.log"
SD_ICON_FILE="/Applications/Microsoft Word.app"
TSD_TICKET="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"
OVERLAY_ICON="SF=trash.fill,color=black,weight=light"
ContainersPath="${USER_DIR}/Library/Containers/"
GroupContainersPath="${USER_DIR}/Library/Group Containers/"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
LOG_TO_VIEW=${4:-"/var/log/system.log"} 

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

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

function display_welcome_msg ()
{
    messagebody="This script is designed to completely remove the below listed applications in\n"
    messagebody+="case you are having issues launching any\n"
    messagebody+="of the office products.\n"
    messagebody+="* Microsoft Word\n"
    messagebody+="* Microsoft Excel\n"
    messagebody+="* Microsoft Outlook\n"
    messagebody+="* Microsoft Powerpoint\n\n"
    messagebody+="The entire suite can be reinstalled from Self Service."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $messagebody"
		--ontop
		--icon "${SD_ICON_FILE}"
		--overlayicon "${OVERLAY_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --ignorednd
		--quitkey 0
        --height 500
		--button1text "OK"
        --button2text "Cancel"
        --infobutton
        --moveable
        --infobuttontext "Get Help" 
        --infobuttonaction "$TSD_TICKET" 
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

    [[ ${buttonpress} -eq 0 ]] && delete_files
}

function delete_files ()
{
	for CleanUp_Path (
        "/Applications/Microsoft Word.app"
        "/Applications/Microsoft Powerpoint.app"
        "/Applications/Microsoft Excel.app"
        "/Applications/Microsoft Outlook.app"
        "${ContainersPath}com.microsoft.excel"
        "${ContainersPath}com.microsoft.Outlook"
        "${ContainersPath}com.microsoft.Outlook.CalendarWidget"
        "${ContainersPath}com.microsoft.Powerpoint"
        "${ContainersPath}com.microsoft.Word"
        "${ContainersPath}Microsoft Error Reporting"
		"${ContainersPath}Microsoft Excel"
		"${ContainersPath}Microsoft Outlook"
		"${ContainersPath}Microsoft Powerpoint"
        "${ContainersPath}Microsoft Word"
		"${ContainersPath}com.microsoft.netlib.shipassertprocess"
		"${ContainersPath}com.microsoft.Office365ServiceV2"
		"${ContainersPath}com.microsoft.RMS-XPCService"
		"${GroupContainersPath}UBF8T346G9.ms"
		"${GroupContainersPath}UBF8T346G9.Office"
		"${GroupContainersPath}UBF8T346G9.OfficeOsfWebHost"
	) { [[ -e "${CleanUp_Path}" ]] && { logMe "Cleaning up: ${CleanUp_Path}" ; /bin/rm -rf "${CleanUp_Path}" ; }}

}

############################
#
# Start of Main Script
#
#############################

autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
display_welcome_msg
cleanup_and_exit
