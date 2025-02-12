#!/bin/zsh
#
# Written by: Scott E. Kendall
#
# Created Date: 01/227/2025
# Last modified: 01/27/2025
#
# v1.0 - Inital script
#
# Expected Paramaters: 
# #4 - Title
# #5 - Full formatted message to display
# #6 - Button1 Text
# #7 - Image to display
# #8 - JAMF policy to load image if it doeesn't exist
# #9 - Notification icon name
# #10 - Timer (in seconds) to wait until dismissal

######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

SUPPORT_DIR="/Library/Application Support/GiantEagle"
OVERLAY_ICON="${SUPPORT_DIR}/SupportFiles/DiskSpace.png"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"


LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/DialogNotify.log"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

JSONOptions=$(mktemp /var/tmp/ClearBrowserCache.XXXXX)
BANNER_TEXT_PADDING="      "
SD_INFO_BOX_MSG=""
SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}$4"
SD_WELCOME_MSG="${5:-"Information Message"}"
SD_BUTTON1_PROMPT="${6:-"OK"}"
SD_IMAGE_TO_DISPLAY="${7:-""}"
SD_IMAGE_POLCIY="${8:-""}"
SD_ICON_PRIMARY="${9:-"AlertNoteIcon.icns"}"
SD_TIMER="${10-120}"
SD_ICON_PRIMARY="${ICON_FILES}${SD_ICON_PRIMARY}"


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
    if [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]]; then
        [[ ! -e "${SD_IMAGE_TO_DISPLAY}" ]] && /usr/local/bin/jamf policy -trigger ${SD_IMAGE_POLCIY}     
    fi   
    # Make sure it is readable by everyone
    chmod +r "${SD_IMAGE_TO_DISPLAY}"
}

function display_msg ()
{
	MainDialogBody=(
		--message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  ${SD_WELCOME_MSG}"
		--ontop
		--icon "${SD_ICON_PRIMARY}"
		--overlayicon computer
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--quitkey 0
        --timer "${SD_TIMER}"
		--button1text "${SD_BUTTON1_PROMPT}"
    )
        [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	# Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    returnCode=$?
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


autoload 'is-at-least'

check_swift_dialog_install
check_support_files
create_infobox_message
display_msg
exit 0