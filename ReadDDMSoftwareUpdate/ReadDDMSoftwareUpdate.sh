#!/bin/zsh
#
# ReadDDMSoftwareSettings
#
# by: Scott Kendall
#
# Written: 01/27/2026
# Last updated: 01/27/2026
#
# Script Purpose: Read the DDM Software Update settings and show the info in a GUI window
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="ReadDDMSoftwareUpdate"
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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}DDM Software Update Settings"
SD_ICON_FILE="https://i0.wp.com/macmule.com/wp-content/uploads/2015/11/SoftwareUpdate.png?resize=256%2C256&ssl=1"
#OVERLAY_ICON="/System/Applications/App Store.app"
OVERLAY_ICON="computer"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"
PLIST_FILE="/var/db/softwareupdate/SoftwareUpdateDDMStatePersistence.plist"
##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"

####################################################################################################
#
# Functions
#
####################################################################################################

function admin_user ()
{
    [[ $UID -eq 0 ]] && return 0 || return 1
}

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
    if admin_user; then
        LOG_DIR=${LOG_FILE%/*}
        [[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
        /bin/chmod 755 "${LOG_DIR}"

        # If the log file does not exist - create it and set the permissions
        [[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
        /bin/chmod 644 "${LOG_FILE}"
    fi
}

function logMe () 
{
    # Basic two pronged logging function that will log like this:
    #
    # 20231204 12:00:00: Some message here
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    # if the user is an admin, it will write to the logfile, otherwise it will just echo to the screen
    #
    # RETURN: None
    if admin_user; then
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
    else
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"
    fi
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

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="{serialnumber}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
}

function check_for_sudo ()
{
	# Ensures that script is run as ROOT
    if ! admin_user; then
    	MainDialogBody=(
        --message "In order for this script to function properly, it must be run as an admin user!"
		--ontop
		--icon "$SD_ICON_FILE"
		--overlayicon warning
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
		--button1text "OK"
    )
    	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
		exit 1
	fi
}

function welcomemsg ()
{
    message="Here are the local DDM Settings for this Mac:<br><br>"$1

	MainDialogBody=(
        --message "$message"
        --messagefont size=16
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage "These are the Software Update Settings/Enforcement enforced on this mac at this time."
        --width 800
        --height 680
        --ignorednd
        --moveable
        --quitkey 0
        --button1text "OK"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

}

function extract_ddm_info ()
{
    local minorOS majorOS GlobalNotifications AutoInstallUpdates autoDownload adminRequired enableRSR enableRSRrollback systemUpdateDeferral message

    DDMArray=$(/usr/libexec/PlistBuddy -c "print" $PLIST_FILE)
    GlobalNotifications=$(echo $DDMArray| grep "enableGlobalNotifications" | awk '{print $3}')
    [[ $GlobalNotifications = "false" ]] && GlobalNotifications="No" || GlobalNotifications="Yes"

    adminRequired=$(echo $DDMArray| grep "adminInstallRequired" | awk '{print $3}')
    [[ $adminRequired = "0" ]] && adminRequired="No" || adminRequired="Yes"

    autoDownload=$(echo $DDMArray| grep "automaticallyDownload" | awk '{print $3}')
    [[ $autoDownload = "0" ]] && autoDownload="No" || autoDownload="Yes"    
    AutoInstallUpdates=$(echo $DDMArray| grep "automaticallyInstallSystemAndSecurityUpdates" | awk '{print $3}')
    [[ $AutoInstallUpdates = "0" ]] && AutoInstallUpdates="No" || AutoInstallUpdates="Yes"

    minorOS=$(echo $DDMArray| grep "minorOSDeferralPeriod" | awk '{print $3}')
    majorOS=$(echo $DDMArray| grep "majorOSDeferralPeriod" | awk '{print $3}')
    systemUpdateDeferral=$(echo $DDMArray| grep "systemUpdatesDeferralPeriod" | awk '{print $3}')

    enableRSR=$(echo $DDMArray| grep "enableRapidSecurityResponse " | awk '{print $3}')
    [[ $enableRSR = "true" ]] && enableRSR="Yes" || enableRSR="No"
    enableRSRrollback=$(echo $DDMArray| grep "enableRapidSecurityResponseRollback" | awk '{print $3}')
    [[ $enableRSRrollback = "true" ]] && enableRSRrollback="Yes" || enableRSRrollback="No"

    targetOSVersion=$(echo $DDMArray| grep "TargetOSVersion " | awk '{print $3}')
    targetOSDateTime=$(echo $DDMArray| grep "TargetLocalDateTime " | awk '{print $3}')

    retval="**Global Settings**<br><br>Admin Required to Install update: $adminRequired<br>Global Notifications: $GlobalNotifications<br><br>**Install Actions**<br><br>Auto Download: $autoDownload \
    <br>Auto Install updates: $AutoInstallUpdates<br><br>**Deferrals**<br><br>Major OS Deferral: $majorOS Day(s)<br>Minor OS Deferral: $minorOS Day(s)<br>Non System Updates: $systemUpdateDeferral Day(s) \
    <br><br>**Rapid Security Response**<br><br>Installation Allowed: $enableRSR<br>Removal Allowed: $enableRSRrollback"

    if [[ ! -z $targetOSVersion ]]; then
        retval+="<br><br>**OS Enforcement**<br><br>Target OS: $targetOSVersion<br>Target Install Date: $targetOSDateTime"
    fi
    echo $retval
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
message=$(extract_ddm_info)
welcomemsg $message
exit 0