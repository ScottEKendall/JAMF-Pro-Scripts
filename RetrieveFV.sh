#!/bin/zsh
#
# RetrieveFV
#
# by: Scott Kendall
#
# Written: 12/20/2024
# Last updated: 02/13/2025
#
# Script Purpose: View Users Filevault Key
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistant with all apps

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
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_VERSION=$( sw_vers -productVersion | xargs)

SD_BANNER_IMAGE="/Library/Application Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="/Library/Application Support/GiantEagle/logs"
LOG_FILE="${LOG_DIR}/ViewFVKey.log"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="${ICON_FILES}FileVaultIcon.icns"

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
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}View FileVault Key"

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
          --icon "${OVERLAY_ICON}"
          --iconsize 100
          --message "Please enter the serial of the device you wish to see the FV Recovey Key for. \n\n You must also provide a reason for retreiving the Recovery Key."
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

     serial_num=$(echo $message | grep "Device" | awk -F '"Device" : "' '{print $2}' | awk -F '"' '{print $1}')
     reason=$(echo $message | grep "Reason" | awk -F '"Reason" : "' '{print $2}' | awk -F '"' '{print $1}') # Thanks to ons-mart https://github.com/ons-mart
}

function Get_JAMF_DeviceID ()
{
     ID=$(curl -s -H "Accept: text/xml" -H "Authorization: Bearer ${api_token}" ${jamfpro_url}/JSSResource/computers/serialnumber/"$serial_num" | xmllint --xpath '/computer/general/id/text()' -)
}

function Get_JamfPro_API_Token ()
{

     # This function uses Basic Authentication to get a new bearer token for API authentication.

     # Use user account's username and password credentials with Basic Authorization to request a bearer token.

     api_token=$(/usr/bin/curl -X POST --silent -u "${jamfpro_user}:${jamfpro_password}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)

}

function API_Token_Valid_Check () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")
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

function FileVault_Recovery_Key_Valid_Check () 
{
     # Verify that a FileVault recovery key is available by running an API command
     # which checks if there is a FileVault recovery key present.
     #
     # The API call will only return the HTTP status code.

     filevault_recovery_key_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/computers-inventory/$ID/filevault" --request GET --header "Authorization: Bearer ${api_token}")
}

function FileVault_Recovery_Key_Retrieval () 
{
     # Retrieves a FileVault recovery key from the computer inventory record.
     filevault_recovery_key_retrieved=$(/usr/bin/curl -sf --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/computers-inventory/$ID/filevault" -H "Accept: application/json" | plutil -extract personalRecoveryKey raw -)   
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
declare serial_num

autoload 'is-at-least'
# Get Jamf Pro API bearer token

jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
jamfpro_url=${jamfpro_url%%/}

create_log_directory
check_support_files
check_swift_dialog_install
display_welcome_message

Get_JamfPro_API_Token
Get_JAMF_DeviceID

if [[ "${ID}" == "" ]]; then
     dialogarray=(
          --bannerimage "${SD_BANNER_IMAGE}"
          --bannertitle "${SD_WINDOW_TITLE}"
          --icon "${OVERLAY_ICON}" 
          --iconsize 100
          --message "Device inventory not found. \nPlease make sure the device name or serial is correct."
          --messagefont "name=Arial,size=17"
          --ontop
          --moveable
     )
          
     $SW_DIALOG "${dialogarray[@]}" 2>/dev/null
     exit 1
fi


Check_And_Renew_API_Token
FileVault_Recovery_Key_Valid_Check
FileVault_Recovery_Key_Retrieval

# Show the result

dialogarray=(
     --bannerimage "${SD_BANNER_IMAGE}"
     --bannertitle "${SD_WINDOW_TITLE}"
     --icon "${OVERLAY_ICON}" 
     --iconsize 100
     --message "The Recovery Key for $serial_num is: <br>**$filevault_recovery_key_retrieved**<br><br>This key has also been put onto the clipboard"
     --messagefont "name=Arial,size=17"
     --width 900
     --ontop
     --moveable
)
echo $filevault_recovery_key_retrieved | xargs | pbcopy

$SW_DIALOG "${dialogarray[@]}" 2>/dev/null
exit 0