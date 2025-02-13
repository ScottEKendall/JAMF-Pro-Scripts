#!/bin/zsh

# DeviceCompliance

# Written: 11/20/2024
# Last updated: 02/13/2025
# by: Scott Kendall
#
# If the user doesn't have the Workplace Join Key (WPJ) in their Keychain, it will prompt them to run the device compliance from SS
#
# 1.0 - Initial rewrite using Swift Dialog prompts
# 1.1 - Merge updated global library functions into app

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
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

SUPPORT_DIR="/Library/Application Support/GiantEagle"
OVERLAY_ICON="/Applications/Self Service.app"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"

LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/DeviceCompliance.log"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

JSON_OPTIONS=$(mktemp /var/tmp/DeviceCompliance.XXXXX)
BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_INFO_BOX_MSG=""
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Device Compliance Registration"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

TSD_TICKET='https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d'

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"              # Passed in by JAMF automatically
ENROLL_POLICY_ID=$4                                         # Policy # to run for registration

#PassedParameterDefault="${4:-"<set default vaulue"}"

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

	SD_INFO_BOX_MSG="## System Info ##\n"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function welcomemsg ()
{
    
    message="Please finish setting up your computer by running the Device Compliance Registration policy in Self Service. \
    <br><br>This step is critial to make sure that you are stil able to get to applications and be able to print.  If you are having problems with the registration, please click on 'Create ticket' to submit a ticket to the TSD.\
    <br><br>Click OK to get started."

    
    icon="https://d8p1x3h4xd5gq.cloudfront.net/59822132ca753d719145cc4c/public/601ee87d92b87d67659ff2f2.png"

	MainDialogBody=(
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. ${message}"
		--ontop
		--icon "${icon}"
		--overlayicon "${OVERLAY_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --helpmessage "Device Compliance is necessary to ensure that your device meets specific security standards and protocols, helping protect and maintain the integrity of your data."
		--width 920
		--quitkey 0
		--button1text "OK"
        --button2text "Create Ticket"
    )

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    returnCode=$?

}

####################################################################################################
#
# Main Script
#
####################################################################################################

declare returnCode

autoload 'is-at-least'

check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg

case ${returnCode} in 
    
    0) logMe "${JAMF_LOGGED_IN_USER} clicked OK. Launch Self service Poicy to Enroll"
        /usr/local/bin/jamf policy -id ${ENROLL_POLICY_ID}
        ;;
    2) logMe "${JAMF_LOGGED_IN_USER} clicked Create Ticket. Creating Ticket "
        open ${TSD_TICKET}
       ;;
    4) logMe "${JAMF_LOGGED_IN_USER} allowed timer to expire"
        ;;
    *) logMe "Something else happened; swiftDialog Return Code: ${returnCode};"
        ;;
    
esac
exit 0
