#!/bin/zsh

# EntraIDRegistration
#
# by: Scott Kendall
#
# Written: 02/03/2025
# Last updated: 01/26/2026
#
# Script Purpose: Backup the keychain file and delete the current keychain file(s)
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
#
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

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
MIN_SD_REQUIRED_VERSION="2.5.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}EntraID Registration"
OVERLAY_ICON="/Applications/Company Portal.app"
SD_WPJ_IMAGE="${SUPPORT_DIR}/SupportFiles/WPJKeychain.png"

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

REGISTRATION_POLICY=9
SD_INFO_BOX_MSG=""
inTuneStatus=""

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
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
  [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
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
check_logged_in_user
create_infobox_message
if ! check_display_sleep; then
  cleanup_and_exit 1
fi
check_inTune_Registration
construct_welcomemsg
welcomemsg
cleanup_and_exit 0