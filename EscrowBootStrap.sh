#!/bin/zsh
#
# EscrowBootStrap.sh
#
# by: Scott Kendall
#
# Written: 02/18/2025
# Last updated:
#
# Script Purpose: Escrow a users bootstrap token to the server if it isn't already.
#
# 1.0 - Initial

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

JSON_OPTIONS=$(mktemp /var/tmp/ClearBrowserCache.XXXXX)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Escrow Bootstrap Token"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/EscrowBootstrap.log"
SD_ICON_FILE=${ICON_FILES}"LockedIcon.icns"
OVERLAY_ICON="${ICON_FILES}FileVaultIcon.icns"
SUPPORT_INFO="TSD_Mac_Support@gianteagle.com"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

LOGGED_IN_USER_UUID=$(dscl . -read /Users/$LOGGED_IN_USER/ GeneratedUID | awk '{print $2}')

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

# Banner image for message
banner="${4:-"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcTRgKEFxRXAMU_VCzaaGvHKkckwfjmgGncVjA&usqp=CAU"}"
# More Information Button shown in message
infotext="${5:-"More Information"}"
infolink="${6:-"https://support.apple.com/guide/deployment/use-secure-and-bootstrap-tokens-dep24dbdcf9e/web"}"
# Swift Dialog icon to be displayed in message
icon="${7:-"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/LockedIcon.icns"}"
supportInformation="${8:-"support@organization.com"}"

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

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function display_msg ()
{
    # Expected Parms
    #
    # Parm $1 - Message to display
    # Parm $2 - Type of dialog (message, input, password)
    # Parm $3 - Button text
    # Parm $4 - Overlay Icon to display
    # Parm $5 - Welcome message (Yes/No)

    [[ "$2" == "welcome" ]] && message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. $1" || message="$1"

	MainDialogBody=(
        --message "${message}"
		--ontop
		--icon "$SD_ICON_FILE"
		--overlayicon "$4"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --position "center"
        --height 450
		--width 760
		--quitkey 0
        --moveable
		--button1text "$3"
    )

    # Add items to the array depending on what info was passed

    [[ "$2" == "password" ]] && MainDialogBody+=(--textfield "Enter Password",secure,required)
    [[ "$3" == "OK" ]] && MainDialogBody+=(--button2text Cancel)

	returnval=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ $returnCode == 2 || $returnCode == 10 ]] && cleanup_and_exit

    # retrieve the password

    [[ "$2" == "password" ]] && userPass=$(echo $returnval | grep "Enter Password" | awk -F " : " '{print $NF}')
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare userPass

# Set some local variables here

BootStrapSupportedYes="supported on server: YES"
BootStrapSupportedNo="supported on server: NO"
BootStrapEscrowedYes="escrowed to server: YES"
BootStrapEscrowedNo="escrowed to server: NO"

## Counter for Attempts
try=0
maxTry=3

check_swift_dialog_install
check_support_files
create_infobox_message

## This first user check sees if the logged in account is already authorized with FileVault 2
userCheck=$(fdesetup list | awk -F "," '{print $1}')
if [[ "${userCheck}" != *"${LOGGED_IN_USER}"* ]]; then
	logMe "This user is not a FileVault 2 enabled user."
	display_msg "It doesn't appear that your account has the correct permissions to create a Bootstrap Token. Please contact support @ $SUPPORT_INFO."  "welcome" "Done" "warning" "No"
    cleanup_and_exit 1
fi


## Check to see if the bootstrap token is already escrowed
BootstrapToken=$(profiles status -type bootstraptoken 2>/dev/null)

if [[ "$BootstrapToken" == *"$BootStrapSupportedYes"* ]] && [[ "$BootstrapToken" == *"$BootStrapEscrowedYes"* ]]; then
	logMe "The bootstrap token is already escrowed."
	display_msg "Your Bootstrap token has been successfully stored on the JAMF server!" "welcome" "Done" "SF=checkmark.circle.fill, color=green,weight=heavy" "No"
	cleanup_and_exit 0
fi

# Display a prompt for the user to enter their password

display_msg "## Bootstrap token\n\nYour Bootstrap token is not currently stored on the JAMF server. This token is used to help keep your Mac account secure.\n\n Please enter your Mac password to store your Bootstrap token." "password" "OK" "caution"

until /usr/bin/dscl /Search -authonly "$LOGGED_IN_USER" "${userPass}" &>/dev/null; do
	(( TRY++ ))
    display_msg "## Bootstrap token\n\nYour Bootstrap token is not currently stored on the JAMF server. This token is used to help keep your Mac account secure.\n\n ### Password Incorrect please try again:" "password" "OK" "caution"
	if (( TRY >= $maxTry )); then
        logMe "Stopping after failed attempts for password entry"
        display_msg "## Please check your password and try again.\n\nIf issue persists, please contact support @ $SUPPORT_INFO."  "message" "Done" "warning" "No"
		cleanup_and_exit 1
	fi
done

logMe "Escrowing bootstrap token"

# This process uses an EXPECT file to deal with interactive portion of bootstrap tokens
# Do not change anything in the follow lines

result=$(expect -c "
spawn profiles install -type bootstraptoken
expect \"Enter the admin user name:\"
send \"${LOGGED_IN_USER}\r\"
expect \"Enter the password for user '${LOGGED_IN_USER}':\"
send \"${userPass}\r\"
expect eof
")

# Log the results
logMe $result

# Check to ensure token was escrowed
BootstrapToken=$(profiles status -type bootstraptoken 2>/dev/null)
if [[ "$BootstrapToken" == *"$BootStrapSupportedYes"* ]] && [[ "$BootstrapToken" == *"$BootStrapEscrowedYes"* ]]; then
	logMe "Bootstrap token escrowed for $LOGGED_IN_USER"
    display_msg "Your Bootstrap token has been successfully stored on the JAMF server!" "message" "Done" "SF=checkmark.circle.fill, color=green,weight=heavy" "No"
	cleanup_and_exit 0
fi
