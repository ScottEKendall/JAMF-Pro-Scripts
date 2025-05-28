#!/bin/zsh

# EntraIDRegistration
#
# by: Scott Kendall
#
# Written: 02/03/2025
# Last updated: 05/28/2025
#
# Script Purpose: Backup the keychain file and delete the current keychain file(s)
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistant with all apps
# 1.2 - Fixed issue of Register button not running the JAMF policy
# 1.3 - Removed debug code and fix incorrect message on failure dialog
# 1.4 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
#
######################################################################################################
#
# Gobal "Common" variables (do not change these!)
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

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

OVERLAY_ICON="/Applications/Company Portal.app"
SD_WPJ_IMAGE="${SUPPORT_DIR}/SupportFiles/WPJKeychain.png"

LOG_FILE="${LOG_DIR}/AppDelete.log"

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}EntraID Registration"
REGISTRATION_POLICY=9
SD_INFO_BOX_MSG=""
inTuneStatus=""

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
    [[ ! -e "${SD_WPJ_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
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

function check_inTune_Registration ()
{
  #check if registered via PSSO

  platformStatus=$( su $LOGGED_IN_USER -c "app-sso platform -s" | grep 'registration' | /usr/bin/awk '{ print $3 }' | sed 's/,//' )
  if [[ "${platformStatus}" == "true" ]]; then
  
    #and then check if jamfAAD registered too
  
    psso_AAD_ID=$(defaults read  "$USER_DIR/Library/Preferences/com.jamf.management.jamfAAD.plist" have_an_Azure_id 2>/dev/null)
    if [[ $psso_AAD_ID -eq "1" ]]; then
      #jamfAAD ID exists
      inTuneStatus="Registered with Platform SSO"
      return 0
    fi
    #PSSO registered but not jamfAAD registered

    inTuneStatus="Platform SSO registered but AAD ID not acquired"
    return 0
  fi

  #check if wpj private key is present
  WPJKey=$(security dump "$USER_DIR/Library/Keychains/login.keychain-db" | grep MS-ORGANIZATION-ACCESS)
  if [[ -z "$WPJKey" ]]; then
    inTuneStatus="Not Registered for user home"
    return 0
  fi

  #WPJ key is present, so check if jamfAAD plist exists
    plist="$USER_DIR/Library/Preferences/com.jamf.management.jamfAAD.plist"
    if [ ! -f "$plist" ]; then
      #plist doesn't exist
        inTuneStatus="WPJ Key present, JamfAAD PLIST missing"
        return 0
    fi

    #PLIST exists. Check if jamfAAD has acquired AAD ID
    AAD_ID=$(defaults read  "$USER_DIR/Library/Preferences/com.jamf.management.jamfAAD.plist" have_an_Azure_id)
    if [[ $AAD_ID -eq "1" ]]; then
      #jamfAAD ID exists
      inTuneStatus="Registered"
      return 0
    fi

    #WPJ is present but no AAD ID acquired:
    inTuneStatus="WPJ Key Present. AAD ID not acquired"
    return 0

  #no wpj key
  inTuneStatus="$USER_DIR"
}

function construct_welcomemsg ()
{
    # For testing purposes only
  
  [[ ! -z "${errorcode}" ]] && inTuneStatus="${errorcode}"

  messagebody="**${inTuneStatus}**<br><br>"
  messageimage=""
  showRegisterButton=''

  case "${inTuneStatus}" in

    "Registered with Platform SSO" | "Registered" )
      
      messagebody+="Congratulations!  Your mac has the WPJ certificate in the keychain, and Jamf has successfully "
      messagebody+="obtained your Entra ID."
      messageimage="${SD_WPJ_IMAGE}"
      messageimagecpation="Remember, if you get a prompt similar to this, type in your password and click on \"Always Allow\""
      ;;
    
    "Platform SSO registered but AAD ID not acquired" | "WPJ Key Present. AAD ID not acquired" )

      messagebody+="There is a problem.  You have the WPJ certificate in your keychain,"
      messagebody+=" but JAMF has not successfully obtained your EntraID.  Your system"
      messagebody+=" will try again within the next two hours, or you can manually do it"
      messagebody+=" by clicking on the 'Register' button."
      showRegisterButton='Register'
      ;;
    
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

  MainDialogBody=(
    --message "${messagebody}"
		--icon computer
    --overlayicon "${OVERLAY_ICON}"
		--height 520
		--ontop
    --image "${messageimage}"
    --imagecaption "${messageimagecpation}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
    --infobox "${SD_INFO_BOX_MSG}"
    --titlefont shadow=1
    --alignment center
    --moveable
		--button1text "OK"
    --button2text "${showRegisterButton}"
		--buttonstyle center
  )

	# Show the dialog screen and allow the user to choose

		"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    button=$?
    [[ $button == 2 && "${showRegisterButton}" == "Register" ]] && /usr/local/bin/jamf policy -id $REGISTRATION_POLICY
}

####################################################################################################
#
# Main Program
#
####################################################################################################

autoload 'is-at-least'

check_swift_dialog_install
check_support_files
create_infobox_message
check_inTune_Registration
construct_welcomemsg
welcomemsg
exit 0