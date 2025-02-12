#!/bin/zsh

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

SW_DIALOG="/usr/local/bin/dialog"
SUPPORT_DIR="/Library/Application Support/GiantEagle"
ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
OVERLAY_ICON="${SUPPORT_DIR}/DiskSpace.png"
SD_WINDOW_ICON="${ICON_FILES}/GenericNetworkIcon.icns"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/GiantEagle/logs"
LOG_FILE="${LOG_DIR}/NetworkIP.log"
JSON_DIALOG_BLOB=$(mktemp /var/tmp/NetworkIP.XXXXX)
chmod 777 $JSON_DIALOG_BLOB
SD_WINDOW_TITLE="     What's my IP?"

# Swift Dialog version requirements

[[ -e "/usr/local/bin/dialog" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

typeset -a adapter
typeset -a ip_address

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions
	if [[ ! -d "${LOG_DIR}" ]]; then
		/bin/mkdir -p "${LOG_DIR}"
		/bin/chmod 755 "${LOG_DIR}"
	fi

	# If the log file does not exist - create it and set the permissions
	if [[ ! -f "${LOG_FILE}" ]]; then
		/usr/bin/touch "${LOG_FILE}"
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
    #
    # RETURN: None
    echo "${1}" 1>&2
    echo "$(/bin/date '+%Y%m%d %H:%M:%S'): ${1}\n" >> "${LOG_FILE}"
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
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
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy # from JAMF
    #
    # RETURN: None

	/usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

function alltrim ()
{
    echo "${1}" | /usr/bin/xargs
}

function get_nic_info
{
    typeset -a nic_interfaces && nic_interfaces=( ${(f)"$( networksetup -listnetworkserviceorder | grep "Device:" | awk '{print $3, $NF}' )"} )

    # Get ISP Info
    isp=$(curl -s https://ipecho.net/plain)
    adapter+="ISP"
    mylocation=_$( get_geolocation $isp )_

    ip_address+="**$isp** $mylocation"

    for i ($nic_interfaces); do
        if [[ ${i} != *"bridge"* ]]; then
            adapter+=$( echo $i | awk '{print $1}' | tr -d ',' )
            interface=$( echo $i | awk '{print $2}')
            ip=**$(ifconfig ${interface::-1} | grep "inet " | awk '{print $2}')**
            [[ ${i} == *"Wi-Fi"* ]] && ip="$ip _($(/usr/bin/wdutil info | grep "SSID                 :" | tr -s ' ' | cut -d ' ' -f4 -f4-))_"
            ip_address+=$ip
        fi
    done
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

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
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
		"width" : "720",
		"moveable" : "true",
		"messageposition" : "top",'		
}

function display_welcome_message()
{
	# Display welcome message to user
    #
	# VARIABLES expected: JSON_DIALOG_BLOB & SD_WINDOW_TITLE must be set
	# PARMS Passed: None
    # RETURN: None

	WelcomeMsg="Listed below are the detected IP addresses on your Mac:<br><br>"

    for i in {1..$#adapter}; do
        WelcomeMsg+=" * $adapter[$i] address: $ip_address[$i]<br>"
    done
    
	construct_dialog_header_settings "${WelcomeMsg}" > "${JSON_DIALOG_BLOB}"
	echo '}'>> "${JSON_DIALOG_BLOB}"

	${SW_DIALOG} --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null
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