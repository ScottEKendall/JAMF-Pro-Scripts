#!/bin/zsh
#
# ResetKeychain
#
# by: Scott Kendall
#
# Written: 02/03/2025
# Last updated: 05/28/2025
#
# Script Purpose: Backup the keychain file and delete the current keychain file(s)
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistant with all apps
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...

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
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_VERSION=$( sw_vers -productVersion | xargs)

SD_BANNER_IMAGE="/Library/Application Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="/Library/Application Support/GiantEagle/logs"
LOG_FILE="${LOG_DIR}/ResetKeychain.log"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

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

JSON_OPTIONS=$(mktemp /var/tmp/ResetKeychain.XXXXX)
BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_INFO_BOX_MSG=""
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Reset Login Keychain"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Define the target directory
KEYCHAIN_DIR="$USER_DIR/Library/Keychains"
KEYCHAIN_BACKUP_DIR="$USER_DIR/Library/Keychains Copy"
RESTART_TIMER=30

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

function create_infobox_message ()
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

function display_msg ()
{
    # Expected Parms
    #
    # Parm $1 - Message to display
    # Parm $2 - Button text
    # Parm $3 - Overlay Icon to display
    # Parm $4 - Welcome message (Yes/No)
    [[ "${4}" == "Yes" ]] && message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. $1" || message="$1"

    icon="/System/Applications/Utilities/Keychain access.app"
    if is-at-least "15" "${MACOS_VERSION}"; then    #File location change in Sequoia and higher
        icon="/System/Library/CoreServices/Applications/Keychain Access.app"
    fi

	MainDialogBody=(
        --message "${message}"
		--ontop
		--icon "$icon"
		--overlayicon "$3"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
		--width 760
        --height 480
        --ignorednd
		--quitkey 0
		--button1text "$2"
    )

    # Add items to the array depending on what info was passed

    [[ "${2}" == "OK" ]] && { MainDialogBody+='--button2text' ; MainDialogBody+='Cancel' ; }
    [[ "${2}" == "Restart" ]] && { MainDialogBody+="--timer" ;  MainDialogBody+=$RESTART_TIMER ; }

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    returnCode=$?

    [[ $returnCode == 2 || $returnCode == 10 ]] && cleanup_and_exit

}

function perform_reset ()
{

    typeset -i success_count && success_count=0
    typeset -i fail_count && fail_count=0

    # Close the Keychain Access app

    logMe "Closing Keychain Access application."
    pkill -x "Keychain Access"

    # Check if the target directory exists
    if [[ ! -d "$KEYCHAIN_DIR" ]]; then
        display_msg "Your personal Keychain does not exist in the expected directory!" "OK" "stop"
        logMe "Target directory does not exist. No actions were taken."
        exit 0
    fi

    logMe "Creating a backup of User Keychain Files"
    mkdir -p "${KEYCHAIN_BACKUP_DIR}"
    cp -rf "${KEYCHAIN_DIR}" "${KEYCHAIN_BACKUP_DIR}"
    logMe "Starting cleanup of directories in $KEYCHAIN_DIR"


    # Find all directories within the target directory and delete them, logging each action
    find "$KEYCHAIN_DIR" -mindepth 1 -print0 | while IFS= read -r -d $'\0' dir; do
       rm -rf "$dir"
        if [[ $? -eq 0 ]]; then
            logMe "Successfully deleted file / directory: $dir"
            ((success_count++))
        else
            logMe "Failed to delete file / directory: $dir"
            ((fail_count++))
        fi
    done

    if [[ $fail_count -eq 0 ]]; then
        display_msg "The keychain reset was successful.  Your system must be restarted to finish this process.  Restart will occur in $RESTART_TIMER seconds.  After it restarts, you will need to run the 'Register with EntraID' from Self Service." "Restart" "computer"

        logMe "Initiating forced restart with $RESTART_TIMER second delay."
        shutdown -r now "Script-initiated forced restart."
    else
        display_msg "Errors have occured while trying to reset your keychian!" "OK" "stop"
        logMe "Cleanup completed with $fail_count failures. Restart aborted."
    fi
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_swift_dialog_install
check_support_files
create_infobox_message
display_msg "If you are experiencing issues with items in your keychain, this utility will backup your current keychain and then reset it.  <br><br>You will need to restart your computer after running this process." "OK" "caution" "Yes"
perform_reset
cleanup_and_exit
