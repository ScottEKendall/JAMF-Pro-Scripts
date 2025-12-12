#!/bin/zsh
#
# PPPCNudge
#
# by: Scott Kendall
#
# Written: 06/26/2025
# Last updated: 12/12/2025
#
# Script Purpose: check the PPPC Database to see if the requested item is turned off for a particular app, and prompt user if necessasry
#
# Derived from script written by: Brian Van Peski
# https://www.macosadventures.com/2023/03/07/screennudge-v1-7/
#
# 1.0 - Initial
# 1.1 - Put in logic to check User TCC first and then the System TCC
# 1.2 - Added check to make sure a user is logged in / Added more logging items / Removed the sudo command from the sql command
# 1.3 - Added support for multiple TCC checks (seperate each key with a space)
# 1.4 - Made the UserTCC keys a "static" array so that it can be checked against bundles better
# 1.5 - Code clean up and better determination of mode of TCC Key
# 1.6 - Check for existance of application before proceeding
# 1.7 - Added variable USER_UID to make sure that the RunAsUser runs with the correct ID / Reworked top section to be standard across all apps
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
# Global "Common" variables (do not change these!)
#
######################################################################################################

SCRIPT_NAME="PPPCNudge"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

DIALOG_COMMAND_FILE=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)
chmod 666 $DIALOG_COMMAND_FILE

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Privacy & Security Settings"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
HELPDESK_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"


# Trigger installs for Images & icons

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
JQ_INSTALL_POLICY="install_jq"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
APP_PATH="${4}"
TCC_KEY="${5}" #The TCC service(s) to modify.  If you pass in multiple items seperate each item with a space.
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
    [[ $(which jq) == *"not found"* ]] && /usr/local/bin/jamf policy -trigger ${JQ_INSTALL_POLICY}
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
        --message $1
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
    # PARAMETERS: $1 - TCC Key to search for

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

    Check_TCC ${1} ${bundleID}

    # Possiblities to check
    # 1.  Key is in the System TCC, but user is not allowed to approve
    # 2.  Key is in the System TCC, and user is allowed to approve
    # 3.  Key is pesent in the User TCC 
    # 4.  Key is NOT present in the user TCC

    # Check to see if this is in the User TCC first
    TCCresults="0"
    if [[ $tccKeyDB == "User" ]]; then
        if [[ -z $tccApproval ]]; then
            logMe "WARNING: $1 Service should be in User TCC, but not found.  App might need to be launched for the first time."
            TCCresults="1"
            return 1
        else
            if [[ $tccKeyStatus == "off" ]]; then
                logMe "INFO: $1 service found in User TCC, but is not approved for $APP_NAME"
            else
                logMe "INFO: $1 Service found in User TCC and has already been approved for $APP_NAME"
            fi
            return 0
        fi        
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
        logMe "INFO: ${prefScreen} has already been approved for $APP_NAME..."
        tccKeyStatus="on"
        return 0
    fi
    logMe "${prefScreen} has not been approved for $APP_NAME..."
    
    logMe "INFO: Valid application found, contining script"
}

function Check_TCC ()
{
    # PURPOSE: Check both the User TCC.db and the System TCC.db for the key and bundleID
    # EXPECTED: $USER_DIR:  Directory of user files
    # RETURNS: None
    # PARAMETERS: $1 - TCC Key to search for
    #             $2 - bundleID of application
    # ENVIRONMENT: tccApproval: Will contain the results of the bundleID if found for the TCC_KEY
    #              pppc_status: If the user is allowed to set the values for the TCC_KEY
    #
    # If this key is in the user TCC then check that first
    if [[ $tccKeyDB == "User" ]]; then
        logMe "Querying user TCC database for $1"

        tccKeyStatus=$(sqlite3 "$USER_DIR/Library/Application Support/com.apple.TCC/TCC.db" "SELECT * FROM access WHERE service like '$1'" | grep "$2" | awk -F "|" '{print $4}')
        tccApproval=$2
        # Test to see if Key was found in User TCC, and then if it is enabled or not (2 means on/enabled)
        if [[ $tccKeyStatus == "2" ]]; then # Key was found and turned on
            tccKeyStatus="on"
        elif [[ $tccKeyStatus == "0" ]]; then # Key was found but not turned on
            tccKeyStatus="off"
        else
            tccApproval="" # Key was not found
        fi

    else
        # Check to see if this app has been allowed via PPPC policy
        pppc_status=$(/usr/libexec/PlistBuddy -c 'print "'$2':'$1':Authorization"' "/Library/Application Support/com.apple.TCC/MDMOverrides.plist" 2>/dev/null)
        # and check the system TCC library
        logMe "Querying system TCC database for $1"
        tccApproval=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" 'SELECT client FROM access WHERE service like "'$1'" AND auth_value = '2'' | grep -o "$2")
        [[ ! -z $tccApproval ]] && tccKeyStatus="on"
    fi
}

function runAsUser () 
{  
    launchctl asuser "$USER_UID" sudo -u "$LOGGED_IN_USER" "$@"
}

function check_logged_in_user ()
{
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in"
        cleanup_and_exit 0
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

declare bundleID
declare iconPath
declare tccJSONarray
declare pppc_status
declare userTCCServices
declare tccApproval
declare tccKeyDB
declare TCCresults
declare tccKeyStatus

autoload 'is-at-least'

check_logged_in_user
create_log_directory
check_swift_dialog_install
check_support_files

# Extract each key into an array eleement so we can loop over each item
TCC_KEY_ARRAY=($(echo $TCC_KEY))

# Make sure that the passed app has the .app extension
# and extract just the app name from the path that was passed in
[[ ! "$APP_PATH" == *".app" ]] && APP_PATH+=".app"

# See if the application has been installed...if not then exit gracefully 
if [[ ! -e "${APP_PATH}" ]]; then
    logMe "INFO: The Application $APP_PATH is not installed"
    cleanup_and_exit 0
fi
APP_NAME="${APP_PATH:t:r}"
SD_ICON_FILE=$APP_PATH

# Store the User TCC Keys into an array so we can search on it later
userTCCServices=(kTCCServiceAddressBook
kTCCServiceAppleEvents
kTCCServiceBluetoothAlways
kTCCServiceCalendar
kTCCServiceCamera
kTCCServiceFileProviderDomain
kTCCServiceLiverpool
kTCCServiceMicrophone
kTCCServicePhotos
kTCCServiceReminders
kTCCServiceSystemPolicyAppBundles
kTCCServiceSystemPolicyAppData
kTCCServiceSystemPolicyDesktopFolder
kTCCServiceSystemPolicyDocumentsFolder
kTCCServiceSystemPolicyDownloadsFolder
kTCCServiceSystemPolicyNetworkVolumes
kTCCServiceSystemPolicyRemovableVolumes
kTCCServiceUbiquity
kTCCServiceWebBrowserPublicKeyCredential)

# the JSON blob contains the TCCKey, the system setitngs pane to open, and a verbal description of what you want to display to the user
tccJSONarray='{
    "applications": [
        {"name": "kTCCServiceScreenCapture",       "menu": "Privacy_ScreenCapture",   "descrip" : "Please approve the **Screen & Audio Recordings** for *'$APP_NAME'*.  This is so that others can view your screen or you can record screens."},
        {"name": "kTCCServiceSystemPolicyAllFiles","menu": "Privacy_FilesAndFolders", "descrip" : "Please approve the **Files & Folders** for *'$APP_NAME'*.  This is so that you can access files from various locations."},
        {"name": "kTCCServiceAccessibility"       ,"menu": "Privacy_Accessibility",   "descrip" : "Please allow the **Accessibility** for *'$APP_NAME'*.  This is so that various automation actions can be used with the application."},
        {"name": "kTCCServiceBluetoothAlways"     ,"menu": "Privacy_Bluetooth",       "descrip" : "Please allow the **Bluetooth** for *'$APP_NAME'*.  This is so that you can use a bluetooth device for speaker or microphone."},
        {"name": "kTCCServiceCamera"              ,"menu": "Privacy_Camera",          "descrip" : "Please allow the **Camera** for *'$APP_NAME'*.  This is so that others can see you."},
        {"name": "kTCCServiceMicrophone"          ,"menu": "Privacy_Microphone",      "descrip" : "Please allow the **Microphone** for *'$APP_NAME'*.  This is so others can hear you during meetings."} ]}'

#extract the BundleID from the application
bundleID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
logMe "Bundle ID for $APP_NAME is $bundleID"

for ((i=1; i<=${#TCC_KEY_ARRAY[@]}; i++)); do
    # if the TCC_KEY is found in the user TCC then mark it as User

    [[ ! -z $(echo $userTCCServices | grep $TCC_KEY_ARRAY[i]) ]] && tccKeyDB="User" || tccKeyDB="System"
    #extract the preferences pane to use and the message to display
    prefScreen=$(extract_keys_from_json $tccJSONarray $TCC_KEY_ARRAY[i] ".menu")
    messageBlurb=$(extract_keys_from_json $tccJSONarray $TCC_KEY_ARRAY[i] ".descrip")

    # strip out the Markdown Characters if using the mini mode
    [[ "${DISPLAY_TYPE:l}" == "mini" ]] && messageBlurb=$(echo $messageBlurb | tr -d '*')
    get_app_details "$TCC_KEY_ARRAY[i]"
    # This condition should only happen if testing on the User TCC and there is no entry, which probably means that the app hasn't been launched for the first time
    if [[ $TCCresults == "1" ]]; then
        logMe "Skipping $TCC_KEY_ARRAY[i]. Continuing..."
        continue
    fi

    # start the loop and continue until either the user approves the request or max attempts have been reached.
    dialogAttempts=0
    until [[ $tccApproval = $bundleID && $tccKeyStatus = "on" ]]; do
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
        Check_TCC $TCC_KEY_ARRAY[i] $bundleID
    done
    logMe "INFO: ${TCC_KEY_ARRAY[i]} for $APP_NAME has been approved!..."
done
runAsUser /usr/bin/osascript -e 'quit app "System Preferences"'
cleanup_and_exit 0
