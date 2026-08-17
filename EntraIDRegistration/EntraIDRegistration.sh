#!/bin/zsh

# EntraIDRegistration
#
# by: Scott Kendall
#
# Written: 02/03/2025
# Last updated: 04/01/2026
#
# Script Purpose: Check if the user is registered for EntraID and display status.  If not registered, provide option to register via JAMF policy.
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - Fixed issue of Register button not running the JAMF policy
# 1.3 - Removed debug code and fix incorrect message on failure dialog
# 1.4 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.5 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
# 1.6 - Optimized Common section
#       Added options to check for logged in user and system awake
# 1.7 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
#
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
set -x
SCRIPT_NAME="EntraIDRegistration"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
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
MIN_SD_REQUIRED_VERSION="3.1.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
chmod 666 "$JSON_DIALOG_BLOB"
chmod 666 "$DIALOG_COMMAND_FILE"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_PLIST="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_PLIST" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_PLIST" SupportFiles 2>/dev/null)
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_PLIST" BannerImage 2>/dev/null)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_PLIST" BannerPadding 2>/dev/null)
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_PLIST" BannerSubtitle 2>/dev/null)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_PLIST" TitleFontColor 2>/dev/null)
fi
[[ -z "$SUPPORT_DIR" ]] && SUPPORT_DIR="/Library/Application Support/GiantEagle"
[[ -z "$SD_BANNER_IMAGE" ]] && SD_BANNER_IMAGE="GE_SD_BannerImage.png"
[[ -z "$BANNER_TEXT_PADDING" ]] && BANNER_TEXT_PADDING=10
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="EntraID Registration"
SD_ICON="/Applications/Company Portal.app"
OVERLAY_ICON="computer"
SD_WPJ_IMAGE="${SUPPORT_DIR}/SupportFiles/WPJKeychain.png"
HELPDESK_TICKET_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

REGISTRATION_POLICY=9
SD_INFO_BOX_MSG=""

##################################################
#
# Passed in variables
# 
#################################################
JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

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

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
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

	/usr/local/bin/jamf policy -event ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && [[ "${SD_BANNER_IMAGE}" =~ \.(jpg|png|heic)$ ]] && /usr/local/bin/jamf policy -event ${SUPPORT_FILE_INSTALL_POLICY}
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

function check_logged_in_user ()
{    
    # PURPOSE: Make sure there is a logged in user
    # RETURN: None
    # EXPECTED: $LOGGED_IN_USER
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in, exiting"
        cleanup_and_exit 0
    else
        logMe "INFO: User $LOGGED_IN_USER is logged in"
    fi
}

function check_display_sleep ()
{
    # PURPOSE: Determine if the mac is asleep or awake.
    # RETURN: will return 0 if awake, otherwise will return 1
    # EXPECTED: None
    local sleepval=$(pmset -g systemstate | tail -1 | awk '{print $4}')
    local retval=0
    logMe "INFO: Checking sleep status"
    [[ $sleepval -eq 4 ]] && logMe "INFO: System appears to be awake" || { logMe "INFO: System appears to be asleep, will pause notifications"; retval=1; }
    return $retval
}

function cleanup_and_exit ()
{
  [[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${JSON_DIALOG_BLOB} ]] && /bin/rm -rf ${JSON_DIALOG_BLOB}
  [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function runAsUser() 
{
    sudo -H -u "$LOGGED_IN_USER" "$@"
}

####################################################################################################
#
# Script Specific Functions
#
####################################################################################################

function check_for_profile ()
{
  # PURPOSE: Check to see if a profile is installed
  # RETURN: Profile Installed (Yes/No)
  # EXPECTED: None
  # PARAMETERS: $1 = Profile name to search for
  logMe "Checking if ${1} is installed..."
  check_installed=$(/usr/bin/profiles -C -v | /usr/bin/awk -F: '/attribute: name/{print $NF}' | /usr/bin/grep "${1}" | xargs)

  # Confirm installed
  if [[ "$check_installed" == *"$1"* ]]; then
    logMe "${1} profile is installed"
    helpmessage="**Profile installed:** $1<br>"
    profileInstalled=true
  else
    logMe " ${1} profile is not installed"
    helpmessage="**Profile not installed:** ${1}<br>"
    profileInstalled=false
  fi
}

function check_Apple_Registration ()
{
  # PURPOSE: Check if the user is registered for EntraID via Intune
  # RETURN: Registration status
  # EXPECTED: None
  # Check both the Apple Platform SSO and the JamfAAD registration status to determine if the user is registered for EntraID

  if [[ "${appSSOStatus}" != "true" ]]; then
    helpmessage+="**Apple SSO**: Not Registered<br>"
    appleSSOStatus=2
    appleSSOStatusVerbose="Registration Not Completed"
    logMe "Apple SSO Status: ${appleSSOStatusVerbose}"
    return 0
  fi
  # Apple shows registered, so lets see what state it is in
  case "$appSSOState" in
    "POUserStateNormal (0)")
      # Meaning: The user is successfully registered with the Identity Provider (IdP).
      # Status: Healthy. Authentication tokens are active, and no further user action is required.
      appleSSOStatus=0
      appleSSOStatusVerbose="Fully Registered (0)"
      ;;
    "POUserStateNeedsNewKeys (1)")
      # Meaning: The user's secure authentication keys are missing, expired, or out of sync.
      # Status: Action required. The user will typically see a prompt or menu bar notification to sign in again to regenerate their Secure Enclave keys.
      appleSSOStatus=1
      appleSSOStatusVerbose="Issue with secure auth keys (1)"
      ;;
    "POUserStateNeedsRegistration (2)")
      # Meaning: The device is managed, but this specific local user has not yet gone through the registration process.
      # Status: Action required. The user must click the registration banner or notification to link their local account with their cloud IdP credentials
      appleSSOStatus=2
      appleSSOStatusVerbose="User token not granted (2)"
      ;;
  esac
  helpmessage+="**Apple SSO**: $appleSSOStatusVerbose<br>"
  logMe "Apple SSO Status: ${appSSOState}"
}

function check_jamf_azure_token ()
{
  # PURPOSE: Check if the user has a valid Jamf Azure Token
  # RETURN: Registration status
  # EXPECTED: None
  local AAD_ID=$(/usr/bin/defaults read  "$USER_DIR/Library/Preferences/com.jamf.management.jamfAAD.plist" have_an_Azure_id)
  if [[ $AAD_ID -ne "1" ]]; then
    #jamfAAD ID does not exist
    helpmessage+="**Jamf Azure Token**: Not Acquired<br>"
    jamfAzureToken=false
    logMe "Jamf Azure Token not acquired for user home: $USER_DIR"
    return 0
  fi
  helpmessage+="**Jamf Azure Token**: Acquired<br>"
  jamfAzureToken=true
  logMe "Jamf Azure Token acquired for user home: $USER_DIR"
}

function check_JAMF_registration ()
{
  # PURPOSE: Check if the user is registered for EntraID via JAMF Conditional Access
  # RETURN: Registration status
  # EXPECTED: None
  # Check if registered via PSSO/SSOe first
  local AADInfoResults=$(runAsUser "$jamfCA" gatherAADInfo)
  local JAMFssoStatus=$(echo $JAMFssoStatus | tr -d '()[]"' | sed -E 's/, /\n/g')

  if [[ $JAMFssoStatus == *"primary_registration_metadata_device_id"* ]]; then
      
      JAMFssoStatus=$(echo $JAMFssoStatus  | sed -E 's/(extraDeviceInformation |AnyHashable|primary_registration_metadata_)//g')

      # jamfAAD ID exists, and shows registered, so lets get the UPN and device ID from the jamfAAD command
      field_upn=$(printf '%s\n' "$JAMFssoStatus" | /usr/bin/awk -F "upn: " 'NF>1{print $2}')
      upn=$(printf '%s\n' "$field_upn" | /usr/bin/grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'| /usr/bin/head -1)

      # the UPN from the jamfAAD Command could be blank, so lets grab this from the Apple SSO command and construct it
      if [[ -z $upn ]]; then
          local raw_upn=$(app-sso platform -s | grep '"upn"'| sed -E 's/.*"upn"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
          raw_upn=${raw_upn//\\@/@}           # unescape \@
          local email=${raw_upn/\\*}          # keep everything up to first '@'
          local domain_part=${raw_upn#*@}     # everything after first '@'
          upn="$email@${domain_part%@*}"      # append domain up to second '@'
      fi

      field_device=$(printf '%s\n' "$JAMFssoStatus" | /usr/bin/awk -F "device_id: " 'NF>1{print $2; exit}')
      device_id=$(printf '%s\n' "$field_device" | /usr/bin/grep -Eo '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'| /usr/bin/head -1)
      isSSOExtensionInFullMode=$(printf '%s\n' "$JAMFssoStatus"| awk -F "isSSOExtensionInFullMode: " 'NF>1{print $2; exit}')

      case "${AADstatus}" in
          0 ) joinmethod="pSSO Not Enabled (0)" ;jamfAADStatus=0;;
          1 ) joinmethod="pSSO Enabled not registered (1)" ;jamfAADStatus=1;;
          2 ) joinmethod="pSSO Enabled and registered (2)" ;jamfAADStatus=2;;
          3 ) joinmethod="unkown pSSO status (3)" ;jamfAADStatus=3;;
      esac
      JAMFSSOStatusVerbose=$joinmethod
      helpmessage+="**JAMF SSO**: $JAMFSSOStatusVerbose<br><br>-- Registration Info --<br><br>**UPN:** ${upn:-NoUPNFound}<br>**Azure Device ID:** ${device_id:-NoDeviceIDFound}<br>**SSO Extension in Full Mode:** ${isSSOExtensionInFullMode:-NoInfoFound}<br>**User Home:** $USER_DIR<br>"
      logMe "JAMF SSO Status: $JAMFSSOStatusVerbose"
      logMe "INFO: Registration Info - UPN: ${upn:-NoUPNFound}"
      logMe "INFO: Registration Info - Azure Device ID: ${device_id:-NoDeviceIDFound}"
      logMe "INFO: Registration Info - SSO Extension in Full Mode: ${isSSOExtensionInFullMode:-NoInfoFound}"
      logMe "INFO: Registration Info - User Home: $USER_DIR"
      return 0
    fi
    # SSOe/PSSO secure enclave registered but not jamfAAD registered
    helpmessage+="WPJ Key is in Secure Enclave, but AAD ID not acquired for user home: $USER_DIR<br>"
    return 0
}

function check_intune_Registration ()
{
  # PURPOSE: Check if the user is registered for EntraID via Intune
  # RETURN: Registration status
  # EXPECTED: None
  local intuneStatus=$(echo $JAMFssoStatus | tr -d '()[]"' | sed -E 's/, /\n/g')

  if [[ $intuneStatus == *"primary_registration_metadata_device_id"* ]]; then
      helpmessage+="**Intune**: Registered with valid device ID<br>"
      return 0
  fi

  helpmessage+="**Intune**: Not Registered<br>"
  return 0
}

function construct_dialog_header_settings ()
{
  # Construct the basic Swift Dialog screen info that is used on all messages
  #
  # RETURN: None
  # VARIABLES expected: All of the Widow variables should be set
  # PARMS Passed: $1 is message to be displayed on the window

	echo '{
    "icon" : "'${SD_ICON}'",
    "message" : "'$1'",
    "bannerimage" : "'${SD_BANNER_IMAGE}'",
    "subtitle" : "'${BANNER_SUBTITLE}'",
    "infobox" : "'${SD_INFO_BOX_MSG}'",
    "overlayicon" : "'${OVERLAY_ICON}'",
    "helpmessage" : "'${helpmessage}'",
    "ontop" : "true",
    "bannertitle" : "'${SD_WINDOW_TITLE}'",
    "titlefont" : "shadow=1,color='${BANNER_TEXT_COLOR}',offset='${BANNER_TEXT_PADDING}'",
    "button1text" : "OK",
    "width" : "750",
    "height" : "480",
    "resizable" : "false",
    "moveable" : "true",
    "json" : "true",
    "quitkey" : "0",
    "messageposition" : "top"}'
}

function construct_messagebody ()
{
  messagebody=""
  messageimage="caution"
  
  appleSSOStatus=1
  jamfAADStatus=1

  # Check if the required profile is installed.  If not, display a message and exit.
  if [[ "$profileInstalled" == false ]]; then
    messagebody+="Problem Encountered!  The required profile (**${MDM_PROFILE}**) is not installed!<br><br>Please contact your IT department for assistance."
    action="profile"
    messageimage="warning"
    return 0
  fi

  messagebody+="**Apple SSO:** $appleSSOStatusVerbose<br>**Jamf AAD**: $JAMFSSOStatusVerbose<br><br>"
  case "${appleSSOStatus}:${jamfAADStatus}" in

    0:2 )
      # Condition: User shows as regisgtered with Apple SSO and Jamf has successfully obtained the Entra ID
      messagebody+="Congratulations!  Your mac is registered with EntraID and Jamf has successfully obtained your Entra ID."      
      messageimage="SF=checkmark.seal.fill,weight=bold,color=green,bgcolor=none"
      action="none"
      ;;
    0:1 )
      # Condition: User shows as registered with Apple SSO, but Jamf has not successfully obtained the Entra ID
      messagebody+="Problem Encountered!  You are registered with EntraID, but Jamf has not successfully obtained your Entra ID.  Your system will try again within the next two hours, or you can manually do it by clicking on the 'Register' button."
      action="AAD Repair"
      ;;

    0:0 )
      # Condition: User shows as registered with Apple SSO, but Jamf has not successfully obtained the Entra ID
      messagebody+="Problem Encountered!  The server doesn't have valid registration information.  Please click on the 'Register' button to reregister your system with Intune"
      action="JAMF Register"
      ;;
    1:* )
      messagebody+="Problem with SSO!  It appears that you are not properly registered with the Apple SSO. <br><br>When the next window appears, click on 'Edit...' next to the 'Network Account Server' section and then click on 'Register (or Repair) buton to re-register. <br><br>Please click on the 'Register with SSO' below to start."
      messageimage="warning"
      action="registerSSO"
      ;;
    2:0 ) ;;
    2:1 )
      messagebody+="Problem with SSO!  It appears that you are not properly registered with the Apple SSO. <br><br>When the next window appears, click on 'Edit...' next to the 'Network Account Server' section and then click on 'Register (or Repair) buton to re-register. <br><br>Please click on the 'Register with SSO' below to start."
      messageimage="warning"
      action="registerSSO"
      ;;
      
    2:2 ) ;;

    "WPJ Key present, JamfAAD PLIST missing" )
      messagebody+="There is a problem.  You have a WPJ certificate in your keychain, and the Company Portal application was probably run, but \"Register with EntraID\" "
      messagebody+="has not. Please click on the \"Register\" below."
      showRegisterButton='Register'
      ;;

    "Not Registered for user home" )
      messagebody+="There is a problem.  You do not have a WPJ certificate in your Keychain.  You will probably have issues "
      messagebody+="accessing your Microsoft applications. Please click on \"Register\" to fix this issue."
      showRegisterButton='Register'

  esac

}

function welcomemsg ()
{
  # PURPOSE: Display the main Swift Dialog window with the status of the EntraID registration
  # RETURN: None
  # EXPECTED: None
  construct_messagebody
  construct_dialog_header_settings "$messagebody" > "$JSON_DIALOG_BLOB"
  logMe "INFO: Action to be taken: $action"
  logMe "INFO: Displaying Swift Dialog window with status of EntraID registration"
  "$SW_DIALOG" --jsonfile "$JSON_DIALOG_BLOB" --commandfile "${DIALOG_COMMAND_FILE}" & sleep .2
  echo "overlayicon: $messageimage" >> "${DIALOG_COMMAND_FILE}"
  case "$action" in
    "profile" )
      echo "button1text: Create Ticket" >> "${DIALOG_COMMAND_FILE}"
      ;;
    "AAD Repair" )
      echo "button1text: Register" >> "${DIALOG_COMMAND_FILE}"
      ;;
    "JAMF Register" )
      echo "button1text: Register" >> "${DIALOG_COMMAND_FILE}"
      ;;
    "registerSSO" )
      echo "button1text: Register with SSO" >> "${DIALOG_COMMAND_FILE}"
      ;;


  esac

  # Wait for the user to click on a button and then take the appropriate action
  wait

  case "$action" in
    "profile" )
      logMe "INFO: User clicked on 'Create Ticket' button"
      logMe "Redirecting user to put in a ticket"
      echo "Creating ticket for IT support..."
      open "$HELPDESK_TICKET_URL"
      ;;
    "AAD Repair" )
      logMe "INFO: User clicked on 'Re-register' button"
      logMe "INFO: Running the JAMF gatherAADInfo command"
      runAsUser "$jamfCA" gatherAADInfo
      ;;
    "JAMF Register" )
      logMe "INFO: Running the JAMF CA registerWithIntune"
      runAsUser "$jamfCA" registerWithIntune
      ;;
    "registerSSO" )
      open "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"  
      ;;
    * )
      # No action required
  esac
}

function JAMF_Repair ()
{
  # PURPOSE: Run the JAMF Repair policy to re-register the user for EntraID
  # RETURN: None
  # EXPECTED: None
  # Terminate the shared web credentials daemon
  logMe "INFO: Running JAMF Repair policy to re-register the user for EntraID"
  logMe "Terminating the shared web credentials daemon..."
  pkill -9 swcd

  # Reset the shared web credentials utility cache
  logMe "Resetting the shared web credentials utility cache..."
  swcutil reset

  # Terminate the AppSSO agent to force a restart of the extension
  logMe "Terminating the AppSSO agent..."
  pkill -9 AppSSOAgent
}

####################################################################################################
#
# Main Program
#
####################################################################################################
autoload 'is-at-least'

local MDM_PROFILE='Apps | Microsoft | Platform SSO' 
local profileInstalled
local appleSSOStatus
local appleSSOStatusVerbose
local jamfAzureToken
local jamfAADStatus
local JAMFSSOStatusVerbose
local messagebody
local action
local ShowRegisterButton
local messageimage
local helpmessage
local jamfCA="/Library/Application Support/JAMF/Jamf.app/Contents/MacOS/Jamf Conditional Access.app/Contents/MacOS/JAMF Conditional Access"
local appSSOStatus=$( su $LOGGED_IN_USER -c "app-sso platform -s" | grep 'registration' | /usr/bin/awk '{ print $3 }' | sed 's/,//' )
local appSSOState=$( su $LOGGED_IN_USER -c "app-sso platform -s" |  awk -F'"' '/"state"/ {print $4}')
local JAMFssoStatus=$(runAsUser "$jamfCA" getPSSOStatus)
# If the getPSSOStatus command times out, it will return a warning message. In that case, we will wait 5 seconds and try to get the device ID again.
if [[ $JAMFssoStatus == *"Warning:Timedout"* ]]; then
    sleep 5
    JAMFssoStatus=$(runAsUser "$jamfCA" getPSSOStatus)
fi
AADstatus=$(echo $JAMFssoStatus | /usr/bin/head -n1) 

check_swift_dialog_install
check_support_files
check_logged_in_user
create_infobox_message
if ! check_display_sleep; then
  cleanup_and_exit 1
fi

check_for_profile $MDM_PROFILE
check_intune_Registration
check_jamf_azure_token
check_Apple_Registration
check_JAMF_registration
welcomemsg
cleanup_and_exit 0