#!/bin/zsh
#
# JAMFSelfHeal.sh
#
# by: Scott Kendall
#
# Written: 03/06/2025
# Last updated: 05/28/2025
#
# Script Purpose: Redeploy the JAMF binary on a device
#   This script is a combination of documentation taken from here:
#       https://www.modtitan.com/2022/02/jamf-binary-self-heal-with-jamf-api.html
#   and here:
#       https://snelson.us/2022/08/jamf-binary-self-heal-via-terminal/

#
# 1.0 - Initial
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.3 - Made API changes for JAMF Pro 11.20 and higher

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
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

# Make some temp files for this app

JSON_OPTIONS=$(mktemp /var/tmp/AppDelete.XXXXX)
TMP_FILE_STORAGE=$(mktemp /var/tmp/AppDelete.XXXXX)
/bin/chmod 666 $JSON_OPTIONS
/bin/chmod 666 $TMP_FILE_STORAGE

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_FILE="${SUPPORT_DIR}/logs/JAMFSelfHeal.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}JAMF Binary Self Heal"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
SD_ICON="/Applications/Self Service.app"
OVERLAY_ICON="warning"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"
CURRENT_EPOCH=$(date +%s)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID=${4}                               # user name for JAMF Pro
CLIENT_SECRET=${5}                             

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


function JAMF_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path)
    [[ -z $retval ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    echo $retval
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
    #        $2 - Device name/serial # to search for

    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    ID=$(/usr/bin/curl -s --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computers-inventory?section=GENERAL&page=0&page-size=100&sort=general.name%3Aasc&filter=$type=='$2'"| jq -r '.results[].id')
    echo $ID
}

function JAMF_renew_binary ()
{
    # PURPOSE: Redeploy the JAMF binary on the device in question.
    # RETURN: redeploy_resonse
    redeploy_resonse=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "accept: application/json" "${jamfpro_url}"/api/v1/jamf-management-framework/redeploy/"${1}" -X POST )
    echo $redeploy_resonse
}

function display_welcome_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --titlefont shadow=1
        --iconsize 100
        --message "${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}.  Please enter the serial or hostname of the device you that you want to redploy the JAMF binary on."
        --messagefont name=Arial,size=17
        --textfield "Device,required"
        --textfield "Reason,required"
        --button1text "Continue"
        --button2text "Quit"
        --vieworder "dropdown,textfield"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --ontop
        --height 400
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0

    search_type=$(echo $message | plutil -extract "SelectedOption" 'raw' -)
    computer_id=$(echo $message | plutil -extract "Device" 'raw' -)
    reason=$(echo $message | plutil -extract "Reason" 'raw' -)

}

########################
#
# Start of Main Program
#
########################

declare api_token
declare api_authentication_check
declare jamfpro_url
declare ID
declare reason
declare search_type
declare computer_id
declare redeploy_resonse

autoload 'is-at-least'

create_log_directory
check_support_files
check_swift_dialog_install
display_welcome_message

SD_ICON=$(JAMF_which_self_service)
JAMF_check_connection
JAMF_get_server
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token
ID=$(JAMF_get_deviceID "${search_type}" ${computer_id})
logMe "Device ID #$ID"

if [[ "${ID}" == "" ]]; then
     dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --icon "${SD_ICON}" 
        --overlayicon ${OVERLAY_ICON}
        --alignment center
        --message "**Device inventory not found!** <br><br>Please make sure the device name or serial is correct."
        --messagefont "name=Arial,size=17"
        --ontop
        --moveable
     )

     $SW_DIALOG "${dialogarray[@]}" 2>/dev/null
     exit 1
fi

# confirm that the user wants to continue

dialogarray=(
    --bannerimage "${SD_BANNER_IMAGE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --icon "${SD_ICON}"
    --overlayicon ${OVERLAY_ICON}
    --titlefont shadow=1
    --message "Sending the command to repair the JAMF binary might enforce the enrollment process to run on system $computer_id.  Are you sure you want to continue?"
    --messagefont "name=Arial,size=17"
    --ontop
    --moveable
    --button1text "Continue"
    --button2text "Cancel"
)

$SW_DIALOG "${dialogarray[@]}" 2>/dev/null
buttonpress=$?

[[ $buttonpress = 2 ]] && exit 0 #exit if the user cancels

JAMF_renew_binary $ID
logMe "Binary redeploy comamnd send to #$ID"

# Show the result

dialogarray=(
    --bannerimage "${SD_BANNER_IMAGE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --icon "${SD_ICON}"
    --titlefont shadow=1
    --overlayicon "SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
    --message "The command to repair the JAMF binary for $computer_id has been sent.  This process might also enforce the enrollment process to run."
    --messagefont "name=Arial,size=17"
    --ontop
    --moveable
)

$SW_DIALOG "${dialogarray[@]}" 2>/dev/null
exit 0