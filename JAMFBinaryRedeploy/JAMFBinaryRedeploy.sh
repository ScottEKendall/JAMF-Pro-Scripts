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
MAC_computer_idBER=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.computer_idber' 'raw' -)
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


###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_INFO_BOX_MSG=""
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}JAMF Binary Self Heal"

LOG_FILE="${LOG_DIR}/JAMFSelfHeal.log"

SD_ICON="/Applications/Self Service.app"
OVERLAY_ICON="warning"

JSON_OPTIONS=$(mktemp /var/tmp/ClearBrowserCache.XXXXX)

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
jamfpro_user=${4}                               # user name for JAMF Pro
jamfpro_password=${5}                             

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
    echo "${1}" 1>&2
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
    [[ -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
}

function display_welcome_message ()
{
     MainDialogBody=(
          --bannerimage "${SD_BANNER_IMAGE}"
          --bannertitle "${SD_WINDOW_TITLE}"
          --icon "${SD_ICON}"
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

function Get_JamfPro_API_Token ()
{
    # PURPOSE: Get a new bearer token for API authentication.
    # RETURN: api_token
    # EXPECTED: jamfpro_user, jamfpro_pasword, jamfpro_url

     api_token=$(/usr/bin/curl -X POST --silent -u "${jamfpro_user}:${jamfpro_password}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)

}

function Get_JAMF_DeviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID from the JAMF Pro server.
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - search identifier to use (serial or Hostname)

    [[ "$1" == "Hostname" ]] && type="name" || type="serialnumber"
    ID=$(curl -s -H "Accept: text/xml" -H "Authorization: Bearer ${api_token}" ${jamfpro_url}/JSSResource/computers/"${type}"/"${computer_id}" | xmllint --xpath '/computer/general/id/text()' -)
}

function Check_And_Renew_API_Token ()
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     API_Token_Valid_Check

     # If the api_authentication_check has a value of 200, that means that the current
     # bearer token is valid and can be used to authenticate an API call.

     if [[ ${api_authentication_check} == 200 ]]; then

     # If the current bearer token is valid, it is used to connect to the keep-alive endpoint. This will
     # trigger the issuing of a new bearer token and the invalidation of the previous one.

          api_token=$(/usr/bin/curl "${jamfpro_url}/api/v1/auth/keep-alive" --silent --request POST --header "Authorization: Bearer ${api_token}" | plutil -extract token raw -)

     else

          # If the current bearer token is not valid, this will trigger the issuing of a new bearer token
          # using Basic Authentication.

          Get_JamfPro_API_Token
     fi
}

function API_Token_Valid_Check () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")
}

function renew_jamf_binary ()
{
    # PURPOSE: Redeploy the JAMF binary on the device in question.
    # RETURN: redeploy_resonse
    redeploy_resonse=$(/usr/bin/curl -H "Authorization: Bearer ${api_token}" -H "accept: application/json" --fail-with-body "${jamfpro_url}"/api/v1/jamf-management-framework/redeploy/"${ID}" -X POST | plutil -extract commandUuid raw -)
}

########################
#
# Start of Main Program
#
########################

declare api_token
declare api_authentication_check
declare ID
declare reason
declare computer_id
declare redeploy_resonse

autoload 'is-at-least'

jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
jamfpro_url=${jamfpro_url%%/}

create_log_directory
check_support_files
check_swift_dialog_install
display_welcome_message

Get_JamfPro_API_Token
Get_JAMF_DeviceID ${search_type}

if [[ "${ID}" == "" ]]; then
     dialogarray=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
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


Check_And_Renew_API_Token

# confirm that the user wants to continue

dialogarray=(
    --bannerimage "${SD_BANNER_IMAGE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --icon "${SD_ICON}"
    --overlayicon ${OVERLAY_ICON}
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

renew_jamf_binary

# Show the result

dialogarray=(
    --bannerimage "${SD_BANNER_IMAGE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --icon "${SD_ICON}"
    --overlayicon "SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
    --message "The command to repair the JAMF binary for $computer_id has been sent.  This process might also enforce the enrollment process to run."
    --messagefont "name=Arial,size=17"
    --ontop
    --moveable
)

$SW_DIALOG "${dialogarray[@]}" 2>/dev/null
exit 0