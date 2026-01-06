#!/bin/zsh
#
# RetrieveFV
#
# by: Scott Kendall
#
# Written: 12/20/2024
# Last updated: 01/06/2025
#
# Script Purpose: View Users Filevault Key
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - Use new JAMF API calls / Add more info in dialog screens
# 1.3 - Change welcome dialog to have a more friendly greeting
# 1.4 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.5 - dialog text changes / fix PBCOPY issue / Added overlay icon / Add title shadow
# 2.0 - Fixed tons of typos
#       You can now use JAMF classic & modern credentials
#       Added feature to read in defaults file
#       Add verification of JAMF credentials and error trapping if ID doesn't have rights
#       Compatible with JAMF 11.21 and higher using the new APIs

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="GetBundleID"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

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

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e "${DEFAULTS_DIR}" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "${DEFAULTS_DIR}" "SupportFiles")
    SD_BANNER_IMAGE=$(defaults read "${DEFAULTS_DIR}" "BannerImage")
    spacing=$(defaults read "${DEFAULTS_DIR}" "BannerPadding")
    SD_BANNER_IMAGE="${SUPPORT_DIR}${SD_BANNER_IMAGE}"
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}View FileVault Key"
LOG_FILE="${SUPPORT_DIR}/logs/ViewFileVaultKey.log"
SD_ICON="${ICON_FILES}FileVaultIcon.icns"
OVERLAY_ICON="SF=key.fill,color=black,bgcolor=none"
JAMF_API_KEY="api/v2/computers-inventory"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID=${4}                               # user name for JAMF Pro
CLIENT_SECRET=${5}
[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF credentials we are using                      

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
	exit 0
}

###########################
#
# JAMF functions
#
###########################

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

function JAMF_get_deviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID from the JAMF Pro server. (JAMF pro 11.5.1 or higher)
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - search identifier to use (serial or Hostname)

    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    ID=$(/usr/bin/curl -sf --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/computers-inventory?filter=${type}==${computer_id}" -H "Accept: application/json" | /usr/bin/plutil -extract results.0.id raw -)

    # if ID is not found, display a message or something...
    [[ "$ID" == *"Could not extract value"* || "$ID" == *"empty data"* ]] && invalid_device_message
    echo $ID
}

###########################
#
# Application Specific functions
#
###########################

function display_welcome_message ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 100
        --titlefont shadow=1
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you wish to see the FV Recovery Key for. \n\n You must also provide a reason for retrieving the Recovery Key."
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --textfield "Reason,required"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 400
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0

    search_type=$(echo $message | plutil -extract 'SelectedOption' 'raw' -)
    computer_id=$(echo $message | plutil -extract 'Device' 'raw' -)
    reason=$(echo $message | plutil -extract 'Reason' 'raw' -)
}

function display_status_message ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}" 
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon SF="checkmark.circle.fill, color=green,weight=heavy"
        --message "The Recovery Key for $computer_id is: <br>**$filevault_recovery_key_retrieved**<br><br>This key has also been put onto the clipboard"
        --messagefont "name=Arial,size=17"
        --titlefont shadow=1
        --width 900
        --height 420
        --ontop
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    cleanup_and_exit
}

function invalid_device_message ()
{
    dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}" 
        --overlayicon warning
        --infobox "${SD_INFO_BOX_MSG}"
        --message "Device inventory not found for $computer_id. \nPlease make sure the device name or serial is correct."
        --messagefont "name=Arial,size=17"
        --ontop
        --height 420
        --titlefont shadow=1
        --moveable
    )
        
    $SW_DIALOG "${dialogarray[@]}" 2>/dev/null
    cleanup_and_exit
}

function FileVault_Recovery_Key_Valid_Check () 
{
     # Verify that a FileVault recovery key is available by running an API command
     # which checks if there is a FileVault recovery key present.
     #
     # The API call will only return the HTTP status code.

     filevault_recovery_key_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}${JAMF_API_KEY}/$ID/filevault" --request GET --header "Authorization: Bearer ${api_token}")
}

function FileVault_Recovery_Key_Retrieval () 
{
     # Retrieves a FileVault recovery key from the computer inventory record.

     temp=$(/usr/bin/curl --header "Authorization: Bearer ${api_token}" "${jamfpro_url}${JAMF_API_KEY}/$ID/filevault" -H "accept: application/json")
     if [[ "$temp" == *"Forbidden"* ]]; then
        logMe "Insufficient JAMF privileges"
        exit 1
     fi   
     filevault_recovery_key_retrieved=$(echo $temp | plutil -extract personalRecoveryKey raw -)
}


function display_status_message ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}" 
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon SF="checkmark.circle.fill, color=green,weight=heavy"
        --message "The Recovery Key for $computer_id is: <br>**$filevault_recovery_key_retrieved**<br><br>This key has also been put onto the clipboard"
        --messagefont "name=Arial,size=17"
        --titlefont shadow=1
        --width 900
        --height 420
        --ontop
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    echo $filevault_recovery_key_retrieved | pbcopy
    cleanup_and_exit
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
declare computer_id

autoload 'is-at-least'

create_log_directory
check_support_files
check_swift_dialog_install
create_infobox_message
JAMF_check_credentials
JAMF_get_server
display_welcome_message

# Perform JAMF API calls to locate device and retrieve the FV key

[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token
ID=$(JAMF_get_deviceID ${search_type})

logMe "JAMF ID: $ID"
[[ -z $ID ]] && invalid_device_message

JAMF_check_and_renew_api_token
FileVault_Recovery_Key_Valid_Check
FileVault_Recovery_Key_Retrieval
JAMF_invalidate_token
display_status_message
exit 0