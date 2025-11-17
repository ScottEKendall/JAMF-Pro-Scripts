#!/bin/zsh

#
# ViewLogs
#
# Created by: Scott Kendall
#
# Created on: 01/29/25
# Last Modified: 11/17/2025
# 
# 1.0 - Initial Commit
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.2 - Made the variable EMAIL_APP to choose while mail app you want to use and automatically pasted the log contents into the body
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
#
#
# Expected Parameters
#
# Parm #4 - Full Path of Log to view
# Parm #5 - Window Title
# Parm #6 - Length of log to display or email (tail -n)
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="ViewLogs"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_SERIAL_NUMBER=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.serial_number' 'raw' -)
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

TMP_FILE_STORAGE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
chmod 666 $TMP_FILE_STORAGE

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

SD_ICON="${ICON_FILES}AllMyFiles.icns"
MAIL_ICON="${ICON_FILES}InternetLocation.icns"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}" 

LOG_TO_VIEW=${4:-"/var/log/system.log"}
LOG_WINDOW_TITLE=${5:-"System Log"}
LOG_LENGTH=${6:-100}

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}View ${LOG_WINDOW_TITLE}"

# Use the bundle identifier of your email app. you can find it by this command "osascript -e 'id of app "<appname>"' "
EMAIL_APP='com.microsoft.outlook'

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

function import_log_contents ()
{
    tail -${LOG_LENGTH} "${LOG_TO_VIEW}" > "${TMP_FILE_STORAGE}"

    log_body=""
    while IFS= read -r item; do
        log_body+="$item<br>"
    done < "${TMP_FILE_STORAGE}"
}

function mail_logs ()
{
	MainDialogBody=(
        --message "Please enter the email address you want to send this to.  The contents of the log file will be put into the message body.  "
        --messagefont "size=16"
		--ontop
		--icon "${MAIL_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--quitkey 0
        --titlefont shadow=1
        --json
        --textfield "Email Address:",value="<username>@company.com"
		--button1text "Send"
        --button2text "Cancel"
    )

	output=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)

    buttonpress=$?
    [[ ${buttonpress} -eq 2 ]] && return 0

    log_body=$(cat ${TMP_FILE_STORAGE})
    email_address=$(echo $output | awk '{print $NF}'| grep @ | xargs )
    
    /usr/bin/open -b ${EMAIL_APP} 'mailto:'${email_address}'?subject='${LOG_WINDOW_TITLE}' from '${MAC_SERIAL_NUMBER}'&body='${log_body}

}

function welcomemsg ()
{
	MainDialogBody=(
        --message "${log_body}"
        --messagefont "size=12"
		--ontop
		--icon "${SD_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --titlefont shadow=1
		--width 1000
        --height 600
		--quitkey 0
        --json
		--button1text "OK"
		--button2text "Send via Email"
    )
	# Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?
	[[ ${buttonpress} -eq 0 ]] && return 0
    mail_logs

}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare email_address
declare log_body

check_swift_dialog_install
create_infobox_message
check_support_files
import_log_contents
welcomemsg
cleanup_and_exit