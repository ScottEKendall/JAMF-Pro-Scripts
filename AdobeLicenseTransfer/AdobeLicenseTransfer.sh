#!/bin/zsh
#
# by: Scott Kendall
#
# Written: 04/16/2025
# Last updated: 05/28/2025

# Script for store users to request an Adobe license transfer 
#
# 1.0 - Initial code
# 1.1 - more concise model name ("2023 Macbook Pro") vs ("MacBook Pro (14-inch, Nov 2023)")
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.3 - Code cleanup / Added feature to read in defaults file / removed unnecessary variables.
#
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="AdobeLicenseTransfer"
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
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
fi

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Title Header
BANNER_TEXT_PADDING="      " #5 spaces to accommodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Adobe License Transfer"
SD_INFO_BOX_MSG=""
OVERLAY_ICON="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
SD_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

TSD_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID="$4"
CLIENT_SECRET="$5"
LOCK_CODE="$6"

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
    [[ $(which jq) == *"not found"* ]] && /usr/local/bin/jamf policy -trigger ${JQ_INSTALL_POLICY}

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

function display_welcome_message ()
{

     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --titlefont shadow=1
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, Please fill out this form to have your Adobe license transferred from one store to another."
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Previous Store # to transfer from",required,prompt="4 Digit Store Code",name="OldStoreID",regex="\d{4}",regexerror="Old Store Code must be a four digit number"
        --textfield "Previous Store Artist Name",required,prompt="First.Last name",name="OldStoreUser"
        --textfield "New Store # to transfer to",required,prompt="4 Digit Store Code",name="NewStoreID",regex="\d{4}",regexerror="New Store Code must be a four digit number"
        --textfield "New Store Artist Name",required,prompt="First.Last Name",name="NewStoreUser",value=$LOGGED_IN_USER
        --button1text "Continue"
        --button2text "Quit"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --ontop
        --height 460
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && cleanup_and_exit

}

function TSD_Ticket_message ()
{

     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --overlayicon "${OVERLAY_ICON}"
        --titlefont shadow=1
        --message "The following message has been created and put onto the clipboard:<br><br>**$1**<br><br>Click on the 'Create Ticket' button to put in the ticket to the TSD and make sure to paste (Option-V or Edit > Paste) this message into the _Description_ field"
        --button1text "Create Ticket"
        --button1action $TSD_URL
        --infobox "${SD_INFO_BOX_MSG}"
        --ontop
        --height 460
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && cleanup_and_exit
    

}
####################################################################################################
#
# Main Script
#
####################################################################################################

declare message
autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
display_welcome_message

oldstore=$(echo $message | plutil -extract "OldStoreID" raw -)
newstore=$(echo $message | plutil -extract "NewStoreID" raw -)
OldStoreUser=$(echo $message | plutil -extract "OldStoreUser" raw -)
NewStoreUser=$(echo $message | plutil -extract "NewStoreUser" raw -)
TicketMessage="Please transfer the Adobe License from $OldStoreUser (Store #$oldstore) to $NewStoreUser (Store #$newstore)"

echo $TicketMessage | pbcopy
TSD_Ticket_message $TicketMessage


