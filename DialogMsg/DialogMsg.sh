#!/bin/zsh
#
# DialogMsg
# 
# Written by: Scott Kendall
#
# Created Date: 01/227/2025
# Last modified: 01/27/2026
#
# Script Purpose: Display a generic SWifDialog notification to JAMF users.  Pass in variables to customize display
#
# 1.0 - Initial script
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - the JAMF_LOGGED_IN_USER will default to LOGGED_IN_USER if there is no name present
#      - Added -ignorednd to make sure that the message is displayed regardless of focus setting
#      - Will display the inbox items if you can the function first
#      - Minimum version of SwiftDialog is now 2.5.0
# 1.3 - Changed variable declarations around for better readability
# 1.4 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 1.5 - Fixed typos
#       Optimized "Common" section for better performance
#       Fixed Swift Dialog not reporting properly
# 2.0 - Add functions to check for a logged in user and that the system is awake (message will only display if system is awake and a user is logged in)
#       Added more logged in sleep status, message button status
#
# Expected Parameters: 
# #4 - Title
# #5 - Full formatted message to display
# #6 - Alternate language to display (formatted as <2 Digit Lang code> | <message>)
# #7 - Button1 Text
# #8 - Image to display
# #9 - JAMF policy to load image if it doesn't exist
# #10 - Notification icon name
# #11 - Timer (in seconds) to wait until dismissal

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="DialogMsg"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles)
    SD_BANNER_IMAGE="${SUPPORT_DIR}$(defaults read "$DEFAULTS_DIR" BannerImage)"
    SPACING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
BANNER_TEXT_PADDING="${(j::)${(l:$SPACING:: :)}}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_IMAGE_TO_DISPLAY="${SUPPORT_DIR}/SupportFiles/PasswordChange.png"
SD_OVERLAY_ICON="computer"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

SD_DEFAULT_LANGUAGE="EN" # Change your default language here!
DISPLAY_MESSAGE=""

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}$4"
SD_WELCOME_MSG="${5:-"Information Message"}"
SD_WELCOME_MSG_ALT="${6:-""}"
SD_BUTTON1_PROMPT="${7:-"OK"}"
SD_IMAGE_TO_DISPLAY="${8:-""}"
SD_IMAGE_POLICY="${9:-""}"
SD_ICON_PRIMARY="${10:-"AlertNoteIcon.icns"}"
SD_TIMER="${11-120}"
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
    fi
    SD_VERSION=$( ${SW_DIALOG} --version)  
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
    [[ ! -e "${SD_IMAGE_TO_DISPLAY}" ]] && /usr/local/bin/jamf policy -trigger ${SD_IMAGE_POLICY}
}

function check_logged_in_user ()
{
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in, exiting"
        cleanup_and_exit 0
    else
        logMe "INFO: User $LOGGED_IN_USER is logged in"
    fi
}

function check_display_sleep ()
{
    local sleepval
    local retval=0
    logMe "INFO: Checking sleep status"
    sleepval=$(pmset -g systemstate | tail -1 | awk '{print $4}')
    if [[ $sleepval -eq 4 ]]; then
        logMe "INFO: System appears to be awake"
    else
        logMe "INFO: System appears to be asleep, will pause notifications"
        retval=1
    fi
    return $retval
}

function display_msg ()
{
    MainDialogBody=(
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  ${DISPLAY_MESSAGE}"
        --ontop
        --icon "${SD_ICON_PRIMARY}"
        --titlefont shadow=1
        --overlayicon "${SD_OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --ignorednd
        --moveable
        --helpmsg ""
        --quitkey 0
        --timer "${SD_TIMER}"
        --button1text "${SD_BUTTON1_PROMPT}"
        )
        [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

    # Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    returnCode=$?
    [[ $returnCode = 4 ]] && logMe "Timer Expired"
    [[ $returnCode = 0 ]] && logMe "User Click $SD_BUTTON1_PROMPT"
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

function check_language_support ()
{

    declare -a languageArray
    declare preferredLanguage && preferredLanguage=${LANG[1,2]:u}

    # if there is no 2nd language line, the just return the 1st line
    
    if [[ -z "${SD_WELCOME_MSG_ALT}" ]]; then
        echo "${SD_WELCOME_MSG}"
        return 0
    fi

    languageArray+=(${SD_WELCOME_MSG})
    languageArray+=(${SD_WELCOME_MSG_ALT})

    # get the system(s) default language

    # Loop through the array and print the message for the preferred language
    for entry in "${languageArray[@]}"; do
        langCode=$(echo $entry | awk -F "|" '{print $1}' | xargs)
        message=$(echo $entry | awk -F "|" '{print $2}'| xargs)
        if [[ "$preferredLanguage" == "$langCode" ]]; then
            echo "${message}"
            return 0
        fi
    done

    # If no match was found, print the message for the default language
    for entry in "${languageArray[@]}"; do
        langCode=$(echo $entry | awk -F "|" '{print $1}'| xargs)
        message=$(echo $entry | awk -F "|" '{print $2}' | xargs)

        if [[ "$SD_DEFAULT_LANGUAGE" == "$langCode" ]]; then
            echo "${message}"
            return 0
        fi
    done
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_swift_dialog_install
check_support_files
# Check and make sure there is a user logged in and system is awake
check_logged_in_user
if ! check_display_sleep; then    
    exit 1
fi
create_infobox_message
DISPLAY_MESSAGE=$(check_language_support)
logMe "Displaying Message"
display_msg
exit 0