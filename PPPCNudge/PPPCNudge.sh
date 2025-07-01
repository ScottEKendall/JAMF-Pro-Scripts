#!/bin/zsh
#
# PPPCNudge
#
# by: Scott Kendall
#
# Written: 06/26/2025
# Last updated: 06/30/2025
#
# Script Purpose: check the PPPC Database to see if the requested item is turned off for a particular app, and prompt user if necessasry
#
# Derived from script written by: Brian Van Peski
# https://www.macosadventures.com/2023/03/07/screennudge-v1-7/
#
# 1.0 - Initial
# 1.1 - Put in logic to check User TCC first and then the System TCC
# 1.2 - Added check to make sure a user is logged in / Added more logging items / Removed the sudo command from the sql command
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
TCC_KEY="${5}" #The TCC service to modify
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
    # PURPOSE: change the TCC.db database in the system location with hardcoded vaiues
    # EXPECTED: None
    # RETURNS: None
    # PARAMETERS: $1 - values to set
    local values=$1
    local dbPath="/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($1);"
    sudo sqlite3 "$dbPath" "$sqlQuery"
}

function configure_user_tccdb () 
{
    # PURPOSE: change the TCC.db database in the user location with hardcoded vaiues
    # EXPECTED: None
    # RETURNS: None
    # PARAMETERS: $1 - values to set
    local values=$1
    local dbPath="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($1);"
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

    # Possiblities to check
    # 1.  Key is in the System TCC, but user is not allowed to approve
    # 2.  Key is in the System TCC, and user is allowed to approve
    # 3.  Key is in the User TCC 

    # Check to see if this is in the User TCC first
    if [[ $tccKeyDB == "User" ]]; then
        if [[ ! -z $tccApproval ]]; then
            logMe "INFO: Service found in User TCC and has already been approved for $APP_NAME"
            cleanup_and_exit 0
        fi
        logMe "INFO: Service found in User TCC, but has not been approved for $APP_NAME"
        return 0
    fi

    # It wasn't found in the User TCC so work on the System TCC
    # Verify that the PPPC profile has been pushed to their system
    if [[ $pppc_status != "AllowStandardUserToSetSystemService" ]]; then
        logMe "WARNING: Could not find valid PPPC Profile for $APP_NAME allowing Standard User to Approve."
        cleanup_and_exit 1
    fi    
    logMe "INFO: found valid PPPC Profile for $APP_NAME allowing Standard User to Approve."

    # Quick check to see if our search results match the bundleID from the app
    if [[ $tccApproval == "$bundleID" ]]; then
        logMe "${prefScreen} has already been approved for $APP_NAME..."
        cleanup_and_exit 0
    fi
    logMe "${prefScreen} has not been approved for $APP_NAME..."
    
    logMe "INFO: Valid application found, contining script"
}

function Check_TCC ()
{
    # PURPOSE: Check both the User TCC.db and the System TCC.db for the key and bundleID
    # EXPECTED: $USER_DIR:  Directory of user files
    #           $TCC_KEY:   The TCC Service to search for
    #           $BundleID:  Applicaiton bundleID
    # ENVIRONMENT: tccApproval: Will contain the results of the BundleID was found for the TCC_KEY
    #              pppc_status: If the user is allowed to set the values for the TCC_KEY
    # RETURNS: None
    # PARAMETERS: None
    #
    # If this key is in the user TCC then check that first
    if [[ $tccKeyDB == "User" ]]; then
        logMe "INFO: Querying user TCC database"
        tccApproval=$(sqlite3 "$USER_DIR/Library/Application Support/com.apple.TCC/TCC.db" "SELECT client FROM access WHERE service like '$TCC_KEY' AND auth_value = '2'" | grep -o "$bundleID")
    else
        # Check to see if this app has been allowed via PPPC policy
        pppc_status=$(/usr/libexec/PlistBuddy -c 'print "'$bundleID':'$TCC_KEY':Authorization"' "/Library/Application Support/com.apple.TCC/MDMOverrides.plist" 2>/dev/null)
        # and check the system TCC library
        logMe "INFO: Querying system TCC database"
        tccApproval=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" 'SELECT client FROM access WHERE service like "'$TCC_KEY'" AND auth_value = '2'' | grep -o "$bundleID")
    fi
}

function runAsUser () 
{  
    launchctl asuser "$UID" sudo -u "$LOGGED_IN_USER" "$@"
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

declare bundleID
declare iconPath
declare tccJSONarray
declare pppc_status
declare userTCCServices
declare tccApproval
declare tccKeyDB && tccKeyDB="System"

autoload 'is-at-least'


if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
    logMe "INFO: No user logged in"
    cleanup_and_exit 0
fi

# Make sure that the passed app has the .app extension
# eand xtract just the app name from the path that was passed in
[[ ! "$APP_PATH" == *".app" ]] && APP_PATH+=".app"
APP_NAME="${APP_PATH:t:r}"
SD_ICON_FILE=$APP_PATH

# the JSON blob contains the TCCKey, the system setitngs pane to open, and a verbal description of what you want to display to the user
tccJSONarray='{
    "applications": [
        {"name": "kTCCServiceScreenCapture",       "menu": "Privacy_ScreenCapture",   "descrip" : "Please approve the *Screen & Audio Recordings* for **'$APP_NAME'**.  This is so that others can view your screen or you can record screens."},
        {"name": "kTCCServiceSystemPolicyAllFiles","menu": "Privacy_FilesAndFolders", "descrip" : "Please approve the *Files & Folders* for **'$APP_NAME'**.  This is so that you can access files from various locations."},
        {"name": "kTCCServiceAccessibility"       ,"menu": "Privacy_Accessibility",   "descrip" : "Please allow the *Accessibility* for **'$APP_NAME'**.  This is so that various automation actions can be used with the application."},
        {"name": "kTCCServiceMicrophone"          ,"menu": "Privacy_Microphone",      "descrip" : "Please allow the *Microphone* for **'$APP_NAME'**.  This is so others can hear you during meetings."} ]}'

# Store the User TCC Keys into an array so we can search on it later
# if the TCC_KEY is found in the user TCC then mark it as User
userTCCServices=$(sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "SELECT * FROM access;" | awk -F "|" '{print $1}' | sort | uniq)
[[ $(echo $userTCCServices | grep $TCC_KEY) ]] && tccKeyDB="User"

#extract the BundleID from the application
bundleID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")

#extract the preferences pane to use and the message to display
prefScreen=$(extract_keys_from_json $tccJSONarray $TCC_KEY ".menu")
messageBlurb=$(extract_keys_from_json $tccJSONarray $TCC_KEY ".descrip")

# strip out the Markdown Characters if using the mini mode
[[ "${DISPLAY_TYPE:l}" == "mini" ]] && messageBlurb=$(echo $messageBlurb | tr -d '*')

create_log_directory
check_swift_dialog_install
check_support_files
get_app_details

# start the loop and continue until either the user approves the request or max attempts have been reached.
dialogAttempts=0
until [[ $tccApproval = $bundleID ]]; do
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
