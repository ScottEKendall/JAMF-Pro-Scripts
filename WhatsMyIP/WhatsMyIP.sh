#!/bin/zsh
#
# IP Test
#
# by: Scott Kendall
#
# Written: 9/20/2023
# Last updated: 08/13/2025
#
# Script Purpose: Display the IP address on all adapters as well as Cisco VPN if they are connected
#
# 1.0 - Initial rewrite using Swift Dialog prompts
# 1.1 - Code cleanup to be more consistant with all apps
# 1.2 - Reworked logic for all physical adapters to accomodate for older macs
# 1.3 - Included logic to display Wifi name if found
# 1.4 - Changed logic for Wi-Fi name to accomodate macOS 15.6 changes
#       Reworked top section for better idea of what can be modified

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

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

# Make some temp files for this app

JSON_OPTIONS=$(mktemp /var/tmp/NetworkIP.XXXXX)
/bin/chmod 666 $JSON_OPTIONS

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_FILE="${SUPPORT_DIR}/Logs/NetworkIP.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE=$BANNER_TEXT_PADDING"What's my IP?"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_WINDOW_ICON="${ICON_FILES}/GenericNetworkIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

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

typeset -a adapter
typeset -a ip_address

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

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

function get_nic_info
{

    declare sname
    declare sdev
    declare sip

    # Get ISP Info
    isp=$(curl -s https://ipecho.net/plain)
    adapter+="ISP"
    mylocation=_$( get_geolocation $isp )_
    ip_address+="**$isp** $mylocation"

    # Get all active intefaces

    while read -r line; do
        sname=$(echo "$line" | awk -F  "(, )|(: )|[)]" '{print $2}' | awk '{print $1}')
        sdev=$(echo "$line" | awk -F  "(, )|(: )|[)]" '{print $4}')
        currentip=$(ipconfig getifaddr $sdev)

        [[ -z $currentip ]] && continue
        adapter+="$sname"
        [[ $sname == *"Wi-Fi"* ]] && wifiName="_($( system_profiler SPAirPortDataType | awk '/Current Network Information:/ { getline; print substr($0, 13, (length($0) - 13)); exit }' ))_"      
        ip_address+="**$currentip** $wifiName"
    done <<< "$(networksetup -listnetworkserviceorder | grep 'Hardware Port')"

    # Section for VPN IP Collection

    if [[ "$( echo 'state' | /opt/cisco/anyconnect/bin/vpn -s | grep -m 1 ">> state:" )" == *'Connected' ]]; then
        ip_address+=**$(/opt/cisco/anyconnect/bin/vpn -s stats | grep 'Client Address (IPv4)' | awk -F ': ' '{ print $2 }' | xargs)**
        adapter+="VPN "
    fi
}

function get_geolocation ()
{
    myLocationInfo=$(/usr/bin/curl -s http://ip-api.com/xml/$1)
    mycity=$(echo $myLocationInfo | egrep -o '<city>.*</city>'| sed -e 's/^.*<city/<city/' | cut -f2 -d'>'| cut -f1 -d'<')
    myregionName=$(echo $myLocationInfo | egrep -o '<regionName>.*</regionName>'| sed -e 's/^.*<regionName/<regionName/' | cut -f2 -d'>'| cut -f1 -d'<')
    echo "($mycity, $myregionName)"
    return 0
}

function construct_dialog_header_settings()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
		"icon" : "'${SD_WINDOW_ICON}'",
		"message" : "'$1'",
		"bannerimage" : "'${SD_BANNER_IMAGE}'",
		"bannertitle" : "'${SD_WINDOW_TITLE}'",
		"titlefont" : "shadow=1",
		"button1text" : "OK",
		"height" : "375",
		"width" : "800",
		"moveable" : "true",
		"messageposition" : "top",'		
}

function display_welcome_message()
{
	# Display welcome message to user
    #
	# VARIABLES expected: JSON_OPTIONS & SD_WINDOW_TITLE must be set
	# PARMS Passed: None
    # RETURN: None

	WelcomeMsg="Listed below are the detected IP addresses on your Mac:<br><br>"

    for i in {1..$#adapter}; do
        WelcomeMsg+=" * $adapter[$i]: $ip_address[$i]<br>"
    done
    
	construct_dialog_header_settings "${WelcomeMsg}" > "${JSON_OPTIONS}"
	echo '}'>> "${JSON_OPTIONS}"

	${SW_DIALOG} --jsonfile "${JSON_OPTIONS}" 2>/dev/null
}

##############################
#
# Main Program
#
##############################
autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
get_nic_info
display_welcome_message
cleanup_and_exit