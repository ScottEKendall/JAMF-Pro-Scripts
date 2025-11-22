#!/bin/zsh
#
# RemoveOffice
#
# by: Scott Kendall
#
# Written: 04/27/2025
# Last updated: 11/18/2025
#
# Script Purpose:  Purpose: Completely remove MS Office Products from users mac
#
# 1.0 - Initial
# 1.1 - Code optimization
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
# 1.4	Add removal for Teams

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="RemoveOffice"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files for this app

ContainersPath="${USER_DIR}/Library/Containers/"
GroupContainersPath="${USER_DIR}/Library/Group Containers/"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
    SD_BANNER_IMAGE=$SUPPORT_DIR$(defaults read $DEFAULTS_DIR "BannerImage")
    spacing=$(defaults read $DEFAULTS_DIR "BannerPadding")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Remove Microsoft Office"
SD_ICON_FILE="https://upload.wikimedia.org/wikipedia/commons/thumb/0/0e/Microsoft_365_%282022%29.svg/512px-Microsoft_365_%282022%29.svg.png?20231004051714"
TSD_TICKET="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"
OVERLAY_ICON="SF=trash.fill,color=black"

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

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
	LOG_DIR=${LOG_FILE%/*}
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
	exit $1
}

function display_welcome_msg ()
{
    messagebody="This script is designed to completely remove the below listed applications in\n"
    messagebody+="case you are having issues launching any\n"
    messagebody+="of the office products.\n"
    messagebody+="* Microsoft Word<br>"
    messagebody+="* Microsoft Excel<br>"
    messagebody+="* Microsoft Outlook<br>"
    messagebody+="* Microsoft Powerpoint<br>"
    messagebody+="* Microsoft Teams<br><br>"
    messagebody+="The entire suite can be reinstalled from Self Service."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $messagebody"
        --titlefont shadow=1
		--ontop
		--icon "${SD_ICON_FILE}"
        --iconsize 256
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
        "/Applications/Microsoft Teams.app"
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
        "${USER_DIR}/Library/Caches/com.microsoft.teams"
        "${USER_DIR}/Library/Caches/com.microsoft.teams.shipit"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/Application Cache/Cache"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/blob_storage"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/Cache"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/databases"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/GPUCache"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/IndexedDB"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/Local Storage"
        "${USER_DIR}/Library/Application Support/Microsoft/Teams/tmp"
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
