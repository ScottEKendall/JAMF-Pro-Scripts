#!/bin/zsh --no-rcs
#
# ForcePlatformSSO.sh
#
# by: Scott Kendall
#
# Written: 10/02/2025
# Last updated: 01/29/2026
#
# Script Purpose: Deploys Platform Single Sign-on
#
# Contributions by: Howie Canterbury
#
#	1 - Installs Microsoft Company Portal
#	2 - Triggers install of Platform SSO for Microsoft Entra ID configuration profile by adding the Mac to 
#	    Platform Single Sign-on group
#	3 - Deploys password expiration check to alert users when their password is due to expire in 14 days or less
#   NOTE: If profile or Company Portal app are found to already be on the computer they are uninstalled and reinstalled.

######################
#
# Script Parameters:
#
#####################
#
#   Parameter 4: API client ID (Modern or Classic)
#   Parameter 5: API client secret
#   Parameter 6: MDM Profile Name
#   Parameter 7: JAMF Static Group name (for Platform SSO Users)
#
# 1.0 - Initial
# 1.1 - Made MDM profile and JAMF group name passed in variables vs hard coded
#       Make sure that all exit processes go thru the cleanup_and_exit function
#       Made the psso command run as current user (Thanks Adam N)
#       Perform a gatherAADInfo command after successful registration
# 1.2 - Put in the --silent flag for the curl commands to not clutter the log
#       changed logic in the detection of SS+...it was not returning expected value
#       Change the gatherAADInfo to RunAsUser vs root
# 1.3 - removed the app-sso -l command...wasn't really needed 
# 1.4 - Added feature to check for focus status and change the alert message accordingly
# 1.5 - Used modern JAMF API wherever possible
#       More logging of events
#       More error trapping of failures
#       Reworked Common section to be more inline with the rest of my apps
#       Fixed Typos

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="ForcePlatformSSO"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")
MAC_SERIAL=$(ioreg -l | grep IOPlatformSerialNumber | cut -d'"' -f4)

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

# Make some temp files

DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")
JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX")
chmod 666 $DIALOG_COMMAND_FILE
chmod 666 $JSON_DIALOG_BLOB
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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Register Platform Single Sign-on"
OVERLAY_ICON="${ICON_FILES}UserIcon.icns"
SD_ICON_FILE="${SUPPORT_DIR}/SupportFiles/sso.png"

# Provide the NAMES of the local profile and the JAMF group name to remove/add the users to
MDM_PROFILE="Apps | Microsoft | Platform SSO Extension"
JAMF_GROUP_NAME="Users | Microsoft | Platform SSO"

# Trigger installs for Images & icons

FOCUS_FILE="$USER_DIR/Library/DoNotDisturb/DB/Assertions.json"
SD_TIMER=300    #Length of time you want the message on the screen (300=5 mins)

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
PSSO_ICON_POLICY="install_psso_icon"
PORTAL_APP_POLICY="install_mscompanyportal"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID=${4}                               # user name for JAMF Pro
CLIENT_SECRET=${5}
MDM_PROFILE=${6}
JAMF_GROUP_NAME=${7}
RUN_JAMF_AAD=${8:-"NO"}

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF creentials we are using

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

	# If the log directory doesnt exist - create it and set the permissions (using zsh paramter expansion to get directory)
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
        [[  -z $SD_VERSION ]]; { logMe "SD Not reporting installed version!"; cleanup_and_exit 1; }
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
    [[ ! -e "${SD_ICON_FILE}" ]] && /usr/local/bin/jamf policy -trigger ${PSSO_ICON_POLICY}

}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
    JAMF_invalidate_token
	exit $1
}

function JAMF_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* || -z $retval ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    echo $retval
}

function JAMF_check_credentials ()
{
    # PURPOSE: Check to make sure the Client ID & Secret are passed correctly
    # RETURN: None
    # EXPECTED: None

    if [[ -z $CLIENT_ID ]] || [[ -z $CLIENT_SECRET ]]; then
        logMe "Client/Secret info is not valid"
        exit 1
    fi
    logMe "Valid credentials passed"
}

function JAMF_check_connection ()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None

    if ! /usr/local/bin/jamf -checkjssconnection -retry 5; then
        logMe "Error: JSS connection not active."
        exit 1
    fi
    logMe "JSS connection active!"
}

function JAMF_get_server ()
{
    # PURPOSE: Retreive your JAMF server URL from the preferences file
    # RETURN: None
    # EXPECTED: None

    jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
    logMe "JAMF Pro server is: $jamfpro_url"
}

function JAMF_get_classic_api_token ()
{
    # PURPOSE: Get a new bearer token for API authentication.  This is used if you are using a JAMF Pro ID & password to obtain the API (Bearer token)
    # PARMS: None
    # RETURN: api_token
    # EXPECTED: CLIENT_ID, CLIENT_SECRET, jamfpro_url

     api_token=$(/usr/bin/curl -X POST --silent -u "${CLIENT_ID}:${CLIENT_SECRET}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)
     if [[ "$api_token" == *"Could not extract value"* ]]; then
         logMe "Error: Unable to obtain API token. Check your credentials and JAMF Pro URL."
         exit 1
     else 
        logMe "Classic API token successfully obtained."
    fi

}

function JAMF_validate_token () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")
}

function JAMF_get_access_token ()
{
    # PURPOSE: obtain an OAuth bearer token for API authentication.  This is used if you are using  Client ID & Secret credentials)
    # RETURN: connection stringe (either error code or valid data)
    # PARMS: None
    # EXPECTED: CLIENT_ID, CLIENT_SECRET, jamfpro_url

    returnval=$(curl --silent --location --request POST "${jamfpro_url}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${CLIENT_SECRET}")
    
    if [[ -z "$returnval" ]]; then
        logMe "Check Jamf URL"
        exit 1
    elif [[ "$returnval" == '{"error":"invalid_client"}' ]]; then
        logMe "Check the API Client credentials and permissions"
        exit 1
    else
        logMe "API token successfully obtained."
    fi
    
    api_token=$(echo "$returnval" | plutil -extract access_token raw -)
}

function JAMF_check_and_renew_api_token ()
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     JAMF_validate_token

     # If the api_authentication_check has a value of 200, that means that the current
     # bearer token is valid and can be used to authenticate an API call.

     if [[ ${api_authentication_check} == 200 ]]; then

     # If the current bearer token is valid, it is used to connect to the keep-alive endpoint. This will
     # trigger the issuing of a new bearer token and the invalidation of the previous one.

          api_token=$(/usr/bin/curl "${jamfpro_url}/api/v1/auth/keep-alive" --silent --request POST -H "Authorization: Bearer ${api_token}" | plutil -extract token raw -)

     else

          # If the current bearer token is not valid, this will trigger the issuing of a new bearer token
          # using Basic Authentication.

          JAMF_get_classic_api_token
     fi
}

function JAMF_invalidate_token ()
{
    # PURPOSE: invalidate the JAMF Token to the server
    # RETURN: None
    # Expected jamfpro_url, ap_token

    returnval=$(/usr/bin/curl -w "%{http_code}" -H "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)

    if [[ $returnval == 204 ]]; then
        logMe "Token successfully invalidated"
    elif [[ $returnval == 401 ]]; then
        logMe "Token already invalid"
    else
        logMe "Unexpected response code: $returnval"
        exit 1  # Or handle it in a different way (e.g., retry or log the error)
    fi    
}

function JAMF_get_deviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID from the JAMF Pro server.
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - search identifier to use (serial or Hostname)
    #        $2 - Conputer ID (serial/hostname)
    local type retval ID
    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v3/computers-inventory?filter=${type}=='${2}'") || {
        display_failure_message "Failed to contact Jamf Pro"
        echo "ERR"
        return 1
    }

    # Basic JSON validity check
    if ! jq -e . >/dev/null 2>&1 <<<"$retval"; then
        display_failure_message "Invalid JSON response from Jamf Pro"
        echo "ERR"
        return 1
    fi

    if [[ $retval == *"PRIVILEGE"* ]]; then
        display_failure_message "Invalid Privilege to read inventory"
        echo "PRIVILEGE"
        return 1
    fi

    total=$(jq '.totalCount' <<<"$retval")
    if [[ $total -eq 0 ]]; then
        display_failure_message "Inventory Record '${2}' not found"
        echo "NOT FOUND"
        return 1
    fi

    id=$(printf "%s" $retval | tr -d '[:cntrl:]' | jq -r '.results[].id')
    if [[ -z $id || $id == "null" ]]; then
        display_failure_message "$retval"
        echo "ERR"
        return 1
    fi
    printf '%s\n' "$id"
    return 0
}

function JAMF_retrieve_static_groupID ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID # of static group
    # EXPECTED: jamppro_url, api_token
    # PARMATERS: $1 = JAMF Static group name
    local tmp
    tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computer-groups/static-groups?sort=id%3Aasc") || {
        display_failure_message "Failed to contact Jamf Pro"
        echo "ERR"
        return 1
    }

    # Basic JSON validity check
    if ! jq -e . >/dev/null 2>&1 <<<"$tmp"; then
        display_failure_message "Invalid JSON response from Jamf Pro"
        echo "ERR"
        return 1
    fi

    if [[ $tmp == *"PRIVILEGE"* ]]; then
        display_failure_message "Invalid Privilege to read groups"
        echo "PRIVILEGE"
        return 1
    fi

    total=$(jq '.totalCount' <<<"$tmp")
    if [[ $total -eq 0 ]]; then
        display_failure_message "Inventory Record '${2}' not found"
        echo "NOT FOUND"
        return 1
    fi
    id=$(printf "%s" $tmp | tr -d '[:cntrl:]' | jq -r --arg name "$1" '.results[] | select(.name == $name) | .id')
    if [[ -z $id || $id == "null" ]]; then
        display_failure_message "$tmp"
        echo "ERR"
        return 1
    fi
    printf '%s\n' "$id"
    return 0
}

function JAMF_static_group_action ()
{
	# PURPOSE: Remove record from JAMF static group
    # RETURN: None
    # EXPECTED: jamfpro_url, api_token
    # PARMATERS: $1 = JAMF Static group id
    #            $2 - Serial # of device
    #            $3 = Acton to take "Add/Remove"
    declare apiData
    local groupID="$1" serial="$2" action="$3"
    local action_lower=${action:l}

    # Validate action
    [[ "$action_lower" != (add|remove) ]] && {echo "ERROR: Action must be 'add' or 'remove'" >&2; return 1; }
     # Validate groupID is numeric
    [[ ! "$groupID" =~ '^[0-9]+$' ]] && { echo "ERROR: Group ID must be numeric" >&2; return 1; }
    # Generate XML payload
    if [[ $action_lower == "remove" ]]; then
        api_data='<computer_group><computer_deletions><computer><serial_number>'${serial}'</serial_number></computer></computer_deletions></computer_group>'
    else
        api_data='<computer_group><computer_additions><computer><serial_number>'${serial}'</serial_number></computer></computer_additions></computer_group>'
    fi
    ## curl call to the API to add the computer to the provided group ID
    retval=$(curl -w "%{http_code}" -s -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/xml" "${jamfpro_url}JSSResource/computergroups/id/${groupID}" --request PUT --data "$api_data" -o /dev/null)
    case "$retval" in
        200|201) return 0 ;;  # Success
        409) echo "ERROR: Computer not in group" >&2; return 1 ;;
        401) echo "ERROR: API token invalid/expired" >&2; return 1 ;;
        404) echo "ERROR: Group ID $groupID not found" >&2; return 1 ;;
        *) echo "ERROR: HTTP $retval" >&2; return 1 ;;
    esac
}

function reinstall_companyportal ()
{
    # PURPOSE: Reinstall the MS Company Portal app if found
    # RETURN: None
    # PARAMETERS: None
    # EXPECTED: None
    company_portal_app="/Applications/Company Portal.app"

    # Uninstall Company Portal if found to ensure the latest version will be installed
    if [[ -d "$company_portal_app" ]]; then
        logMe "Company Portal found; uninstalling..."
        rm -rf "$company_portal_app"
    else
        logMe "Company Portal not found; continuing..."
    fi

    # Install Microsoft Company Portal
    logMe "Installing Microsoft Company Portal..."
    /usr/local/jamf/bin/jamf policy -trigger "$PORTAL_APP_POLICY" --forceNoRecon

    # Check that Company Portal app is installed
    if [[ -d "$company_portal_app" ]]; then
        logMe "Company Portal App is installed. Ready to install PSSO profile."
    else
        logMe "Company Portal app did not install. Exiting with error..."
        exit 1
    fi
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --message "**Problems retrieving JAMF Info**<br><br>Error Message: $1"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

}

function check_for_profile ()
{
    # PURPOSE: Check to see if a profile is installed
    # RETURN: Profile Installed (Yes/No)
    # EXPECTED: None
    # PARAMETERS: $1 = Profile name to search for
    LogMe "Checking if Platform Single Sign-on profile is installed..."
	check_installed=$(/usr/bin/profiles -C -v | /usr/bin/awk -F: '/attribute: name/{print $NF}' | /usr/bin/grep "${1}" | xargs)
	
	# Confirm installed
	if [[ "$check_installed" == "$1" ]]; then
		LogMe "Platform SSO for Microsoft Entra ID profile is installed"
		echo "Yes"
	else
		LogMe "Platform SSO for Microsoft Entra ID profile is not installed"
		echo "No"
	fi
}

function displaymsg ()
{
	message="When you see this macOS notification appear, please click the register button within the prompt, and go through the registration process."
    if [[ $focus_status = "On" ]] && message+="<br><br>**Since your focus mode is turned on, you will need to click in the notification center to see this prompt**"
	MainDialogBody=(
        --message "<br>$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1 size=24
        --appearance light
        --ontop
        --moveable
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
		--commandfile "${DIALOG_COMMAND_FILE}"
		--image "${SUPPORT_DIR}/SupportFiles/pSSO_Notification.png"
        --helpmessage "Contact the TSD or put in a ticket if you are having problems registering your device."
        --width 740
        --height 450
        --ignorednd
        --timer 300
        --quitkey 0
        --button1text "Dismiss"
    )

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null &
}

function getValueOf ()
{
	echo $2 | grep "$1" | awk -F ":" '{print $2}' | tr -d "," | xargs
}

function get_sso_status()
{
	ssoStatus=$(runAsUser app-sso platform -s)
}

function kill_sso_agent()
{
	pkill AppSSOAgent
	sleep 1
}

function runAsUser () 
{  
    launchctl asuser "$USER_ID" sudo -u "$LOGGED_IN_USER" "$@"
}

function check_focus_status ()
{
    # PURPOSE: Check to see if the user is in focus mode
    # RETURN: in focus mode (Off/On)
    # EXPECTED: FOCUS_FILE is the location of FocusMode settings
    # PARAMETERS: None

    results="Off"
    if [[ -e $FOCUS_FILE ]]; then
        retval=$(grep -c '"storeAssertionRecords"' "$FOCUS_FILE" 2>/dev/null)
        [[ $retval == 1 ]] && results="On"
    fi
    echo $results
}

####################################################################################################
#
# Main Script
#
####################################################################################################

declare api_token
declare jamfpro_url
declare ssoStatus
declare focus_status

autoload 'is-at-least'

# Make sure the MDM profile and Group name are passed in
if [[ -z $MDM_PROFILE ]] || [[ -z $JAMF_GROUP_NAME ]]; then
    logMe "ERROR: Missing Group name or MDM profile name"
    cleanup_and_exit 1
fi

create_log_directory
check_swift_dialog_install
check_support_files
JAMF_check_connection
JAMF_get_server
focus_status=$(check_focus_status)

# Check if the JAMF Pro server is using the new API or the classic API
# If the client ID is longer than 30 characters, then it is using the new API
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token   

# See if the portal is installed.  If you do not need to remove the app, then comment the following line
#reinstall_companyportal

# Check to see if the profile is installed
installed=(check_for_profile $MDM_PROFILE)

# retrieve the JAMF ID # of the static group name
groupID=$(JAMF_retrieve_static_groupID $JAMF_GROUP_NAME)
[[ $groupID == *"ERR"* ]] && cleanup_and_exit 1
[[ $groupID == *"NOT FOUND"* || $groupID == *"PRIVILEGE"* ]] && cleanup_and_exit 1

deviceID=$(JAMF_get_deviceID "Serials" $MAC_SERIAL)
[[ $deviceID == *"ERR"* ]] && cleanup_and_exit 1
[[ $deviceID == *"NOT FOUND"* || $deviceID == *"PRIVILEGE"* ]] && cleanup_and_exit 1

logMe "Group ID is: $groupID"
logMe "Device ID is: $deviceID"

# If the profile is not installed, then install it
if [[ "$installed" == "No" ]]; then
    retval=$(JAMF_static_group_action $groupID $MAC_SERIAL "add")
    [[ -z $retval ]] && logMe "Successfull addition" || {logMe $retval; cleanup_and_exit 1; }
else
    # System was found, so lets remove it first and then re-add it to force the prompt to appear
    logMe "Platform SSO for Microsoft Entra ID profile is already installed. Uninstalling and reinstalling..."
    logMe "Removing $MAC_SERIAL from $JAMF_GROUP_NAME ($groupID)"
    retval=$(JAMF_static_group_action $groupID $MAC_SERIAL "remove")
    [[ -z $retval ]] && logMe "Successfull removal" || {logMe $retval; cleanup_and_exit 1; }
    sleep 5
    logMe "Adding $MAC_SERIAL to $JAMF_GROUP_NAME ($groupID)"
    retval=$(JAMF_static_group_action $groupID $MAC_SERIAL "add")
    [[ -z $retval ]] && logMe "Successfull addition" || {logMe $retval; cleanup_and_exit 1; }
fi

# Prompt the user to register if needed
get_sso_status
if [[ $(getValueOf registrationCompleted "$ssoStatus") == true ]]; then
    logMe "User already registered"
    exit 0
fi

logMe "Prompting user to register device"
displaymsg
echo "activate:" > ${DIALOG_COMMAND_FILE}
# Force the registration dialog to appear
logMe "Stopping pSSO agent"
kill_sso_agent
# Wait until registation is complete
interval=10     # seconds
max_wait=300    # total seconds before timeout (e.g., 5 minutes)
start_ts=$(date +%s)

until [[ $(getValueOf registrationCompleted "$ssoStatus") == true ]]; do
    sleep "$interval"
    logMe "Device has not been registered yet."
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= max_wait )); then
        logMe "ERROR: Timed out after ${max_wait}s waiting for User Registration."
        cleanup_and_exit 1
    fi
    sleep $interval
    get_sso_status
done
logMe "INFO: Registration Finished Successfully"
if [[ $RUN_JAMF_AAD == "YES" ]]; then
    logMe "INFO: Sleeping for 20 secs and then running the gatherAADInfo command"
    ${SW_DIALOG} --notification --identifier "registration" --title "Doing some Platform SSO registration" --message "Please be patient" --button1text "Dismiss"
    sleep 20
    runAsUser /usr/local/jamf/bin/jamfAAD gatherAADInfo
    ${SW_DIALOG} --notification --identifier "registration" --remove
fi
echo "quit:" > ${DIALOG_COMMAND_FILE}
cleanup_and_exit 0