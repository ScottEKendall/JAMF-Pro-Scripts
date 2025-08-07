#!/bin/zsh
#
# Written by: Scott E. Kendall
#
# Purpose: Provide user notifications of a password expiration.
#
# Created: 04/18/2024
# Last updated: 08/07/2025
#
# v1.0 - Initial Release
# v1.1 - Major code cleanup & documentation
#		 Structred code to be more inline / consistent across all apps
# v1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# v1.3 - Fixed pasword age calculation
# 		 Add support for 'on demand' viewing of password
# v1.4 - Changed variable declarations around for better readability
#
# Expected Paramaters: 
# $4 - Password Expiration in Days
# $5 - Show "on demand" viewing (Yes) or script processing (No)

######################################################################################################
#
# Gobal "Common" variables (do not change these!)
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
MACOS_VERSION=$( sw_vers -productVersion | xargs)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

JSS_FILE="/Library/Managed Preferences/com.gianteagle.jss.plist"
SD_TIMER="240"

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_FILE="${SUPPORT_DIR}/PasswordExpireNotice.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Password Expiration Notice"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
SD_IMAGE_TO_DISPLAY="${SUPPORT_DIR}/SupportFiles/PasswordChange.png"
OVERLAY_ICON="/Applications/Self Service.app"
SD_ICON_FILE=${ICON_FILES}"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SD_IMAGE_POLICY="install_passwordSS"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}   # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
PASSWORD_EXPIRE_IN_DAYS=$4
PASSWORD_CHECK=${5:-"NO"}

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
    [[ ! -e "${SD_IMAGE_TO_DISPLAY}" ]] && /usr/local/bin/jamf policy -trigger ${SD_IMAGE_POLICY}  
    # Make sure it is readable by everyone
    chmod +r "${SD_IMAGE_TO_DISPLAY}"
}

function display_msg ()
{
    SD_ICON_PRIMARY="/System/Applications/Utilities/Keychain access.app"
    if is-at-least "15" "${MACOS_VERSION}"; then    #File location change in Sequoia and higher
        SD_ICON_PRIMARY="/System/Applications/Passwords.app"
    fi
	MainDialogBody=(
		--message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  ${SD_WELCOME_MSG}"
		--ontop
		--overlayicon "${SD_ICON_PRIMARY}"
		--icon "SF=person.circle.fill,weight=heavy,bgcolor=none,colour=blue,colour2=purple"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
		--quitkey 0
        --timer "${SD_TIMER}"
		--button1text "OK"
    )
        [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 540 --image "${SD_IMAGE_TO_DISPLAY}")

	# Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    returnCode=$?
}

function display_notification ()
{
    MainDialogBody=(
        --notification
        --title "Password Notification" 
        --message "${SD_WELCOME_MSG}" 
        --button1text "Change Now" 
        --button1action "https://account.activedirectory.windowsazure.com/ChangePassword.aspx"
    )
	# Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
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

function duration_in_days ()
{
    # PURPOSE: Calculate the difference between two dates
    # RETURN: days elapsed
    # EXPECTED: 
    # PARMS: $1 - oldest date 
    #        $2 - newest date
    local start end
    calendar_scandate $1        
    start=$REPLY        
    calendar_scandate $2        
    end=$REPLY        
    echo $(( ( end - start ) / ( 24 * 60 * 60 ) ))
}

function get_password_info()
{
    # PURPOSE: Retrieve the age of the user password either by reading in the plilst key or getting it from the local login password last changed date
    # EXPECTED: JSS_File - path of the plist file to read from
    # RETURN: Password age (in days)
    declare passwordExpireDate
    declare curUser
    declare passwordAge

    passwordExpireDate=$(/usr/libexec/plistbuddy -c "print PasswordLastChanged" $JSS_FILE 2>&1)

    if [[ $passwordExpireDate == *"Does Not Exist"* || -z $passwordExpireDate ]]; then
        # Not populated yet, so fall back to the local login password change
        passwordAge=$(expr $(expr $(date +%s) - $(dscl . read /Users/${LOGGED_IN_USER} | grep -A1 passwordLastSetTime | grep real | awk -F'real>|</real' '{print $2}' | awk -F'.' '{print $1}')) / 86400)
    else
        #found the key, so determine the days based off of that
        passwordAge=$(duration_in_days $passwordExpireDate $(date))
    fi
    passwordAge=$(($PASSWORD_EXPIRE_IN_DAYS - $passwordAge))
    echo ${passwordAge}
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'calendar_scandate'
autoload 'is-at-least'

check_swift_dialog_install
check_support_files
create_infobox_message

# Retrieve the users password ago and display he appropriate dialog box
passwordAge=$(get_password_info)
logMe "INFO: Users passsword age is: "$passwordAge

if [[ ${passwordAge} -le 8 && ${PASSWORD_CHECK:l} == "no" ]]; then
    SD_WELCOME_MSG="Your are receiving this notice because your password is about to expire within the next ${passwordAge} days.  You can click on the 'Unlock / Reset Network Password...' option in **JAMF Connect** to change your password.  You will receive further notices when your password is about to expire within the next 7 days."
	logMe "INFO: Display prompt for user that password will expire in ${passwordAge} days"
	display_msg
else
    SD_WELCOME_MSG="Your password will expire in ${passwordAge} days."
    logMe "INFO: Display notification for user that password will expire in ${passwordAge} days"

    display_notification
fi
exit 0