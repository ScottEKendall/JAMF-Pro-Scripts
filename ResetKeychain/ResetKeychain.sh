#!/bin/zsh
#
# ResetKeychain
#
# by: Scott Kendall
#
# Written: 02/03/2025
# Last updated: 12/15/2025
#
# Script Purpose: Backup the keychain file and delete the current keychain file(s)
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       Change the restart command to use AppleScript...much safer than the shutdown command
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
# 1.4 - Removed dependencies of using systemprofiler command and use sysctl instead
#       Changed create_infobox_message to use new OS & version variables

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="ResetKeychain"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$( /usr/bin/sw_vers -productName )
MACOS_VERSION=$( /usr/bin/sw_vers -productVersion )
MAC_RAM=$( /usr/sbin/sysctl -n hw.memsize 2>/dev/null | /usr/bin/awk '{printf "%.0f GB", $1/1024/1024/1024}' )
MAC_CPU=$( /usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null )
# Fallback to uname if sysctl fails
[[ -z "$MAC_CPU" ]] && [[ "$(/usr/bin/uname -m)" == "arm64" ]] && MAC_CPU="Apple Silicon" || MAC_CPU="Intel"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files for this app

JSON_OPTIONS=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
/bin/chmod 666 "${JSON_OPTIONS}"

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Reset Login Keychain"

# Define the target directory
KEYCHAIN_DIR="$USER_DIR/Library/Keychains"
KEYCHAIN_BACKUP_DIR="$USER_DIR/Library/Keychains Copy"
RESTART_TIMER=30

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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
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
    # Parm $2 - Button text
    # Parm $3 - Overlay Icon to display
    # Parm $4 - Welcome message (Yes/No)
    [[ "${4}" == "Yes" ]] && message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. $1" || message="$1"

    icon="/System/Applications/Utilities/Keychain access.app"
    if is-at-least "15" "$(sw_vers -productVersion | xargs)"; then    #File location change in Sequoia and higher
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
        --titlefont shadow=1
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
        osascript -e 'tell app "System Events" to restart'
    else
        display_msg "Errors have occurred while trying to reset your keychain!" "OK" "stop"
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
