#!/bin/zsh
#
# AdobeMultiVersionDetect.sh
#
# by: Scott Kendall
#
# Written: 11/25/2025
# Last updated: 11/25/2025
#
# Script Purpose: Detect if there a multiple versions of Adobe apps on a users system and display a friendly reminder to clean up the old version
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="AdobeMultiVersionDetect"
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

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)
chmod 666 $JSON_DIALOG_BLOB
chmod 666 $DIALOG_COMMAND_FILE

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
    SD_BANNER_IMAGE=$SUPPORT_DIR$(defaults read $DEFAULTS_DIR "BannerImage")
    spacing=$(defaults read $DEFAULTS_DIR "BannerPadding")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Adobe Multiple Version Detector"
SD_ICON="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
OVERLAY_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
ADOBE_CLEANUP="AdobeCleanup"
TSD_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

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
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}" 1>&2
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

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function detect_adobe_apps ()
{
    # PURPOSE: scan for multiple version of Adobe apps
    # PARAMETERS: None
    # RETURN: Array of # of duplicates found
    # EXPECTED: None

    declare -a results
    declare logResults
    declare -a app_names    
    apps=$(find /Applications -name "Adobe*" -type d -maxdepth 1 | sed 's|^/Applications/Adobe||'| grep -v "^Adobe Creative Cloud$" | grep -v "Adobe Acrobat*" | grep -v "^Adobe Experience Manager*" |  grep -v "^Adobe Digital Editions*" |  grep -v "^Adobe XD"  | sort)
    apps_array=("${(@f)apps}")
    for app in "${apps_array[@]}"; do
        # Extract the app name by removing the last digit part
        name_without_version="${app% *}"
        app_names+=("$name_without_version")
    done
    # Count the occurrences of each app name
    print -l "${app_names[@]}" | sort | uniq -c | while read count name; do
        if (( count > 1 )); then
            results+=("* $name has $count version(s)<br>")
            logResults+="$name has $count version(s) "
        fi
    done
    logMe $logResults
    echo $results
}

function welcomemsg ()
{
    message="Multiple versions of Adobe applications have been detected "
    message+="on your system.  It is recommended that you remove the older versions "
    message+="from your computer.  Not only will this save valuable disk space, "
    message+="but it makes sure you are always opening the correct version of the "
    message+="Adobe application.<br><br>$adobeDuplicates<br><br>"
    message+="Please click on 'Cleanup' to start the Adobe Removal Utility"

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button."
        --width 920
        --height 480
        --infobuttontext "Get Help"
        --infobuttonaction "$TSD_URL"
        --ignorednd
        --quitkey 0
        --button1text "Cleanup"
        --button2text "OK"
    )

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ $returnCode == 0 ]] && {logMe "User clicked Cleanup";/usr/local/bin/jamf policy -trigger ${ADOBE_CLEANUP};}
    [[ $returnCode == 2 ]] && logMe "User dismissed the message"
    
}

####################################################################################################
#
# Main Script
#
####################################################################################################

declare -a adobeDuplicates

autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message

adobeDuplicates=$(detect_adobe_apps)
[[ ! -z "${adobeDuplicates}" ]] && welcomemsg || logMe "No Duplicates found"
cleanup_and_exit 0