#!/bin/zsh
#
# by: Scott Kendall
#
# Written: 03/31/2025
# Last updated: 05/28/2025

# Script to Set/Remove Recovery Lock on Apple Silicon Macs using the Jamf API.
# Works based on the 'lockMode' variable (Set/Remove) to configure Recovery Lock.
# 
# Key Functionalities:
# - Retrieves the Mac's serial number.
# - Uses JAMF API Roles and Clients
# - Sets the recovery password to one of your choosing
# - Uses Jamf Pro API to:
#   - Obtain access token
#   - Fetch the computer's management ID
#   - Send the Set Recovery Lock MDM command based on 'lockMode'
# - If 'lockMode' is "Set", it enables Recovery Lock with a generated password.
# - If 'lockMode' is "Remove", it clears the Recovery Lock.
# - Finally, invalidates the API token for security.
# 
# Requirements:
# - A Mac with Apple Silicon running macOS 11.5 or later.
# - Jamf Pro API permissions: 
#   - Send Set Recovery Lock Command
#   - View MDM Command Information
#   - Read Computers
#   - View Recovery Lock
#
# Usage:
# - Provide 'Set' or 'Remove' as parameter 6 in a Jamf policy.
# - For details, refer: 
#   https://learn.jamf.com/en-US/bundle/technical-articles/page/Recovery_Lock_Enablement_in_macOS_Using_the_Jamf_Pro_API.html
# 
#  Karthikeyan Marappan / Scott Kendall
# 
# 1.0 - Initial code
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
#
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
JQ_FILE_INSTALL_POLICY="install_jq"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Set/Clear Recovery Lock"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/JAMF_RecoveryLock.log"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
SD_ICON="/Applications/Self Service.app"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
CURRENT_EPOCH=$(date +%s)


##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
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
	exit 0
}

function display_welcome_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --iconsize 128
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you want to set or clear the recovery lock on.  Please Note: This only works on Apple Silicon Macs."
        --messagefont name=Arial,size=17
        --textfield "Device,required"
        --button1text "Continue"
        --button2text "Quit"
        --infobox "${SD_INFO_BOX_MSG}"
        --vieworder "dropdown,textfield"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
		--selecttitle "Recovery,required"
		--selectvalues "Set, Clear"
		--selectdefault "Set"
        --ontop
        --height 420
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0

    search_type=$(echo $message | jq -r ".Serial.selectedValue")
    computer_id=$(echo $message | jq -r ".Device")
    lockMode=$(echo $message | jq -r ".Recovery.selectedValue")
}

function display_status_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --overlayicon SF="checkmark.circle.fill, color=green,weight=heavy"
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 420
        --json
        --moveable
    )

    if [[ $lockMode == "Set" ]]; then
        MainDialogBody+=(--message "Recovery lock ${lockMode} with '$LOCK_CODE' for ${computer_id}.  You will need to update the inventory record for the changes to reflect on your JAMF server.")
    else
        MainDialogBody+=(--message "Recovery lock ${lockMode}ed for ${computer_id}.  You will need to update the inventory record for the changes to reflect on your JAMF server.")
    fi

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --message "Device ID ${computer_id} was not found.  Please try again."
        --icon "${SD_ICON}"
        --overlayicon warning
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 420
        --json
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
    invalidate_JAMF_Token
    cleanup_and_exit
}

function check_JSS_Connection()
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

function get_JAMF_Server ()
{
    # PURPOSE: Retreive your JAMF server URL from the preferences file
    # RETURN: None
    # EXPECTED: None

    jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
    logMe "JAMF Pro server is: $jamfpro_url"
}

function get_JamfPro_Classic_API_Token ()
{
    # PURPOSE: Get a new bearer token for API authentication.  This is used if you are using a JAMF Pro ID & password to obtain the API (Bearer token)
    # PARMS: None
    # RETURN: api_token
    # EXPECTED: jamfpro_user, jamfpro_pasword, jamfpro_url

     api_token=$(/usr/bin/curl -X POST --silent -u "${CLIENT_ID}:${CLIENT_SECRET}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)

}

function get_JAMF_Access_Token()
{
    # PURPOSE: obtain an OAuth bearer token for API authentication.  This is used if you are using  Client ID & Secret credentials)
    # RETURN: connection stringe (either error code or valid data)
    # PARMS: None
    # EXPECTED: client_ID, client_secret, jamfpro_url

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
    fi
    
    api_token=$(echo "$returnval" | plutil -extract access_token raw -)
    token_expires_in=$(echo "$returnval" | plutil -extract expires_in raw -)
    token_expiration_epoch=$((CURRENT_EPOCH + token_expires_in - 1))
}

function get_JAMF_DeviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID (UDID) from the JAMF Pro server. (JAMF pro 11.5.1 or higher)
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - search identifier to use (Serial or Hostname)

    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"

    ID=$(/usr/bin/curl -sf --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/computers-inventory?filter=${type}==${computer_id}" -H "Accept: application/json" | jq -r '.results[0].general.managementId')

    # if ID is not found, display a message or something...
    [[ "$ID" == *"Could not extract value"* || "$ID" == *"null"* ]] && display_failure_message
    logMe "Device ID #$ID"
}

function invalidate_JAMF_Token()
{
    # PURPOSE: invalidate the JAMF Token to the server
    # RETURN: None
    # Expected jamfpro_url, ap_token

    returnval=$(curl -w "%{http_code}" -H "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)

    if [[ $returnval == 204 ]]; then
        logMe "Token successfully invalidated"
    elif [[ $returnval == 401 ]]; then
        logMe "Token already invalid"
    else
        logMe "Unexpected response code: $returnval"
        exit 1  # Or handle it in a different way (e.g., retry or log the error)
    fi    
}

function sendRecoveryLockCommand()
{
    # PURPOSE: send the command to clear or remove the Recovery Lock 
    # RETURN: None
    # PARMS: $1 = Lock code to set (pass blank to clear)
    # Expected jamfpro_url, ap_token, ID
	local newPassword="$1"
	
	returnval=$(curl -w "%{http_code}" "$jamfpro_url/api/v2/mdm/commands" \
		-H "accept: application/json" \
		-H "Authorization: Bearer ${api_token}"  \
		-H "Content-Type: application/json" \
		-X POST -s -o /dev/null \
		-d @- <<EOF
		{
			"clientData": [{ "managementId": "$ID", "clientType": "COMPUTER" }],
			"commandData": { "commandType": "SET_RECOVERY_LOCK", "newPassword": "$newPassword" }
		}
EOF
	)
	logMe "Recovery Lock ${lockMode} for ${computer_id}"
}

####################################################################################################
#
# Main Script
#
####################################################################################################
declare jamfpro_url
declare api_token
declare api_authentication_check
declare ID
declare reason

declare token_expires_in
declare token_expiration_epoch
declare search_type
declare computer_id
declare redeploy_resonse

autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
display_welcome_message

# Perform JAMF API calls to locate device and clear MDM failures

check_JSS_Connection
get_JAMF_Server
get_JamfPro_Classic_API_Token
get_JAMF_DeviceID ${search_type}	
[[ $lockMode == "Set" ]] && sendRecoveryLockCommand "$LOCK_CODE" || sendRecoveryLockCommand ""
display_status_message
invalidate_JAMF_Token
exit 0
