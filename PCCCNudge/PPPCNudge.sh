#!/bin/zsh
#
# PPPCNudge
#
# by: Scott Kendall
#
# Written: 06/26/2025
# Last updated: 06/26/2025
#
# Script Purpose: check the PPPC Database to see if the requested item is turned off for a particular app, and prompt user if necessasry
#
# Derived from script written by: Brian Van Peski
# https://www.macosadventures.com/2023/03/07/screennudge-v1-7/
#
# 1.0 - Initial
#
# Here is a list of the System Settings Prefpanes that can be opened from terminal
#
# Privacy_AppleIntelligenceReport
# Privacy_DevTools
# Privacy_Automation
# Privacy_NudityDetection
# Privacy_Location
# Privacy_LocationServices
# Privacy_SystemServices
# Privacy_ScreenCapture
# Privacy_AudioCapture
# Privacy_Advertising
# Privacy_Analytics
# Privacy_FilesAndFolders
# Privacy_DesktopFolder
# Privacy_DocumentsFolder
# Privacy_DownloadsFolder
# Privacy_NetworkVolume
# Privacy_RemovableVolume
# Privacy_Accessibility
# Privacy_Microphone
# Privacy_Calendars
# Privacy_Pasteboard
# Privacy_Camera
# Privacy_Photos

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

OS_PLATFORM=$(/usr/bin/uname -p)

[[ "$OS_PLATFORM" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

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

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Privacy & Security Settings"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/PPCNudge.log"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/Applications/Self Service.app"
JSON_OPTIONS=$(mktemp /var/tmp/PPPCNudge.XXXXX)

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
HELPDESK_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
APP_PATH="${4}"
TCCC_KEY="${5}" #The TCC service to modify
MAX_ATTEMPTS="${6}" #How many attempts at prompting the user before giving up.
SLEEP_TIME="${7}" #How many seconds to wait between user prompts. 
DISPLAY_TYPE=${8:-"MINI"}

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

function cleanup_and_exit ()
{
    exitcode=$1
    [[ -z $exitcode ]] && exitcode=0
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $exitcode
}

function welcomemsg ()
{
	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $1"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage "This setting needs to be set for this particular app so it will work properly"
        --ignorednd
        --ontop
        --width 680
        --moveable
        --quitkey 0
        --button1text "OK"
        --button2text "Helpdesk Ticket"
    )
    [[ "${DISPLAY_TYPE:l}" == "mini" ]] && MainDialogBody+=(--mini)
    
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$?
    if [[ $buttonpress = 2 ]]; then
        open $HELPDESK_URL
        logMe "INFO: User choose to open a ticket...redirecting to URL and exiting script"
        cleanup_and_exit 0
    fi
}

#######################################################################################################
# 
# Functions for system & user level TCCC Database
#
#######################################################################################################

function configure_system_tccdb ()
{
    local values=$1
    local dbPath="/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sudo sqlite3 "$dbPath" "$sqlQuery"
}

function configure_user_tccdb () 
{
    local values=$1
    local dbPath="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sqlite3 "$dbPath" "$sqlQuery"
}

function get_app_details ()
{
    # FUNCTION: Do some quick santity checks on the, app has to exist, valid bundleID found and then see if it has already been approved.
    # RETURNS: None
    # PARAMETERS: None

    # check to see if the app exists
    if [[ ! -e "${APP_PATH}" ]]; then
        logMe "WARNING: Could not find $APP_NAME installed at $APP_PATH."
        cleanup_and_exit 0
    fi
    
    # Check to make sure that the bundleID is valid
    if ! [[ $bundleID =~ ^[a-zA-Z0-9]+[-.](.*) ]]; then
	    logMe "WARNING: Could not find valid bundleID for $APP_NAME at $APP_PATH!"
	    cleanup_and_exit 1
	fi

    Check_TCC

    # Quick check to see if our search results match the bundleID from the app
    if [[ $tccApprovalSystem == "$bundleID" ]]; then
        logMe "${prefScreen} has already been approved for $APP_NAME..."
        cleanup_and_exit 0
    else
        logMe "${prefScreen} has not been approved for $APP_NAME..."
        return 0
    fi

    if [[ $pppc_status != "AllowStandardUserToSetSystemService" ]]; then
        logMe "WARNING: Could not find valid PPPC Profile for $APP_NAME allowing Standard User to Approve."
        cleanup_and_exit 1
    fi
    logMe "INFO: Valid application found, contining script"
}

function Check_TCC ()
{
    pppc_status=$(/usr/libexec/PlistBuddy -c 'print "'$bundleID':'$TCCC_KEY':Authorization"' "/Library/Application Support/com.apple.TCC/MDMOverrides.plist")
    # Check the system TCC library first
    tccApprovalSystem=$(sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" 'SELECT client FROM access WHERE service like "'$TCCC_KEY'" AND auth_value = '2'' | grep -o "$bundleID")
    [[ ! -z $tccApprovalSystem ]] && return 0
    tccApprovalUser=$(sudo sqlite3 "$USER_DIR/Library/Application Support/com.apple.TCC/TCC.db" 'SELECT client FROM access WHERE service like "'$TCCC_KEY'" AND auth_value = '2'' | grep -o "$bundleID")
}

function runAsUser () 
{  
  if [ "$LOGGED_IN_USER" != "loginwindow" ]; then
    launchctl asuser "$UID" sudo -u "$LOGGED_IN_USER" "$@"
  else
    echo "no user logged in"
    # uncomment the exit command to make the function exit with an error when no user is logged in
    # exit 1
  fi
}

function extract_keys_from_json ()
{
    # PURPOSE: Extract a specific key from the JSON array
    # RETURN: extracted value
    # PARMS: $1 - Key to search for
    #        $2 - JSON element to return
    # EXPECTED: None

    retval=$(echo $1 | jq -r '.applications[] | select(.name == "'$2'") | '$3'')
    echo $retval
}

####################################################################################################
#
# Main Script
#
####################################################################################################
declare tccApprovalSystem
declare bundleID
declare iconPath
declare tccJSONarray
declare $TCCC_KEY
declare pppc_status

autoload 'is-at-least'

# Make sure that the passed app has the .app extension
[[ ! "$APP_PATH" == *".app" ]] && APP_PATH+=".app"
# extract just the app name from the path that was passed in
APP_NAME="${APP_PATH:t:r}"
SD_ICON_FILE=$APP_PATH

# the JSON blob contains the TCCKey, the system setitngs pane to open, and a verbal description of what you want to display to the user
tccJSONarray='{
    "applications": [
        {"name": "kTCCServiceScreenCapture",       "menu": "Privacy_ScreenCapture",   "descrip" : "Please approve the *Screen & Audio Recordings* for **'$APP_NAME'**.  This is so that others can view your screen or you can record screens."},
        {"name": "kTCCServiceSystemPolicyAllFiles","menu": "Privacy_FilesAndFolders", "descrip" : "Please approve the *Files & Folders* for **'$APP_NAME'**.  This is so that you can access files from various locations."},
        {"name": "kTCCServiceAccessibility"       ,"menu": "Privacy_Accessibility",   "descrip" : "Please allow the *Accessibility* for **'$APP_NAME'**.  This is so that various automation actions can be used with the application."} ]}'



#extract the BundleID from the application
bundleID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
#extract the preferences pane to use and the message to display
prefScreen=$(extract_keys_from_json $tccJSONarray $TCCC_KEY ".menu")
messageBlurb=$(extract_keys_from_json $tccJSONarray $TCCC_KEY ".descrip")
# strip out the Markdown Characters if using the mini mode
[[ "${DISPLAY_TYPE:l}" == "mini" ]] && messageBlurb=$(echo $messageBlurb | tr -d '*')

create_log_directory
check_swift_dialog_install
check_support_files
get_app_details

# start the loop and continue until either the user approves the request or max attempts have been reached.
dialogAttempts=0
until [[ $tccApprovalSystem = $bundleID ]]; do
    if (( $dialogAttempts >= $MAX_ATTEMPTS )); then
        logMe "Prompts have been ignored after $MAX_ATTEMPTS attempts. Giving up..."
        cleanup_and_exit 1
    fi
    logMe "Requesting user to manually approve ${prefScreen} for $APP_NAME..."
    runAsUser open "x-apple.systempreferences:com.apple.preference.security?"$prefScreen
    # show the welcome mesasge appropriate to the key that we are trying change/fix
    welcomemsg "${messageBlurb}"
    sleep $SLEEP_TIME
    ((dialogAttempts++))
    logMe "Checking for approval of ${prefScreen} for $APP_NAME..."
    Check_TCC
done
logMe "INFO: Screen Recording for $APP_NAME has been approved! Exiting..."
runAsUser /usr/bin/osascript -e 'quit app "System Preferences"'
cleanup_and_exit 0
