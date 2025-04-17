#!/bin/zsh
#
# by: Scott Kendall
#
# Written: 03/31/2025
# Last updated: 04/04/2025

# Script to view inventory detail of a JAMF record and show pertitent info in SwiftDialog
# 
# 1.0 - Initial code
#
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
MAC_MODEL=$(ioreg -l | awk '/product-name/ { split($0, line, "\""); printf("%s\n", line[4]); }')
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
TOTAL_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Total Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

MACOS_VERSION=$( sw_vers -productVersion | xargs)

MAC_LOCALNAME=$(scutil --get LocalHostName)
MAC_SHARENAME=$(scutil --get HostName)

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
#SD_BANNER_IMAGE="/Library/Application Support/GiantEagle/Enrollment/RedBackground.jpg"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/logs"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
JQ_FILE_INSTALL_POLICY="install_jq"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Device Information"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/ViewDeviceInventory.log"
SD_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"
JSON_OPTIONS=$(mktemp /var/tmp/ViewInventory.XXXXX)
chmod 666 ${JSON_OPTIONS}

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
CURRENT_EPOCH=$(date +%s)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID="$4"
CLIENT_SECRET="$5"
LOCK_CODE="$6"
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

	SD_INFO_BOX_MSG="## System Info ##\n"
    SD_INFO_BOX_MSG+="**${MAC_MODEL}**<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Free Space<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

function display_welcome_message ()
{
    local message
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --message none
        --iconsize 128
        --infobox "${SD_INFO_BOX_MSG}"
        --ontop
        --jsonfile "${JSON_OPTIONS}"
        --height 700
        --json
        --moveable
        --button1text "OK"
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && cleanup_and_exit

}

function display_status_message ()
{
    local msg=$1
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON}"
        --message "${msg}"
        --overlayicon SF="checkmark.circle.fill, color=green,weight=heavy"
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 420
        --json
        --moveable
    )
    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --message "Device ID ${computer_id} was not found.  Please try again."
        --icon "${SD_ICON}"
        --overlayicon warning
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 420
        --json
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
    invalidate_JAMF_Token
    cleanup_and_exit
}

function check_JSS_Connection()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None

    if ! /usr/local/bin/jamf -checkjssconnection -retry 5; then
        logMe "Error: JSS connection not active."
        exit 1
    fi
    logMe "JSS connection active!"
}

function get_JAMF_Server ()
{
    # PURPOSE: Retreive your JAMF server URL from the preferences file
    # RETURN: None
    # EXPECTED: None

    jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
    logMe "JAMF Pro server is: $jamfpro_url"
}

function get_JamfPro_Classic_API_Token ()
{
    # PURPOSE: Get a new bearer token for API authentication.  This is used if you are using a JAMF Pro ID & password to obtain the API (Bearer token)
    # PARMS: None
    # RETURN: api_token
    # EXPECTED: CLIENT_ID, CLIENT_SECRET, jamfpro_url

     api_token=$(/usr/bin/curl -X POST --silent -u "${CLIENT_ID}:${CLIENT_SECRET}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)

}

function get_JAMF_Access_Token()
{
    # PURPOSE: obtain an OAuth bearer token for API authentication.  This is used if you are using  Client ID & Secret credentials)
    # RETURN: connection stringe (either error code or valid data)
    # PARMS: None
    # EXPECTED: CLIENT_ID, CLIENT_SECRET, jamfpro_url

    returnval=$(curl --silent --location --request POST "${jamfpro_url}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${CLIENT_SECRET}")
    
    if [[ -z "$returnval" ]]; then
        logMe "Check Jamf URL"
        exit 1
    elif [[ "$returnval" == '{"error":"invalid_client"}' ]]; then
        logMe "Check the API Client credentials and permissions"
        exit 1
    fi
    
    api_token=$(echo "$returnval" | plutil -extract access_token raw -)
}

function get_JAMF_DeviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID (UDID) from the JAMF Pro server. (JAMF pro 11.5.1 or higher)
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - search identifier to use (Serial or Hostname)

    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"

    jamfID=$(/usr/bin/curl --silent --fail -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}/api/v1/computers-inventory?filter=${type}==${computer_id}" | /usr/bin/plutil -extract results.0.id raw -)

    # if ID is not found, display a message or something...
    [[ "$jamfID" == *"Could not extract value"* || "$jamfID" == *"null"* ]] && display_failure_message
    echo $jamfID
}

function invalidate_JAMF_Token()
{
    # PURPOSE: invalidate the JAMF Token to the server
    # RETURN: None
    # Expected jamfpro_url, ap_token

    returnval=$(/usr/bin/curl -w "%{http_code}" -H "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)

    if [[ $returnval == 204 ]]; then
        logMe "Token successfully invalidated"
    elif [[ $returnval == 401 ]]; then
        logMe "Token already invalid"
    else
        logMe "Unexpected response code: $returnval"
        exit 1  # Or handle it in a different way (e.g., retry or log the error)
    fi    
}

function get_JAMF_InventoryRecord ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/computers-inventory/$jamfID?section=$1") # 2>/dev/null)
    echo $retval | tr -d '\n'
}

function get_nic_info ()
{

    declare sname
    declare sdev
    declare sip

    # Get all active intefaces, its name & ip address

    while read -r line; do
        sname=$(echo "$line" | awk -F  "(, )|(: )|[)]" '{print $2}' | awk '{print $1}')
        sdev=$(echo "$line" | awk -F  "(, )|(: )|[)]" '{print $4}')
        sip=$(ipconfig getifaddr $sdev)

        [[ -z $sip ]] && continue
        currentIPAddress+="$(ipconfig getifaddr $sdev) | "
        adapter+="$sname | " 
    done <<< "$(networksetup -listnetworkserviceorder | grep 'Hardware Port')"

    adapter=${adapter::-3}
    currentIPAddress=${currentIPAddress::-3}
    wifiName=$(sudo wdutil info | grep "SSID" | head -1 | awk -F ":" '{print $2}' | xargs)

}

function mdm_check ()
{
    [[ ! -x /usr/local/jamf/bin/jamf ]] && { echo "JAMF Not installed"; exit 0;}
    mdm=$(sudo profiles list | grep 'com.jamfsoftware.tcc.management' | awk '{print $4}' | sed -e 's#com.##' -e 's#.tcc.management##')
    [[ $mdm == jamfsoftware ]] && retval="JAMF MDM Installed" || retval="No JAMF MDM profile found"
    echo $retval
}

function get_filevault_status ()
{
    FV=$(fdesetup list | grep $LOGGED_IN_USER)
    if [[ ! -z $FV ]]; then
        echo "FV Enabled"
    else
        [[ $(fdesetup status | grep On) ]] && echo "FV Enabled but not for current user" || echo "FV Not eanbled"
    fi
}

function create_mdm_message_body ()
{
    # PURPOSE: Construct the message body of the dialog box
    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - JSON array to pull data from 
    #        $2 - Field to extract
    #        $3 - Display message
    message+="$3: **$(echo $1 | plutil -extract $2 'raw' -)**<br>"
}

function create_message_body ()
{
    declare line && line=""
    # PURPOSE: Construct the message body of the dialog box
    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title 
    #        $2 - icon
    #        $3 - listitem
    #        $4 - first or last - construct appropriate listitem heders / footers
    [[ "$4:l" == "first" ]] && line+='{"listitem" : ['
    line+='{"title" : "'$1':", "icon" : "'$2'", "statustext" : "'$3'"},'
    [[ "$4:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_OPTIONS}
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
####################################################################################################
#
# Main Script
#
####################################################################################################
declare jamfpro_url
declare api_token
declare jamfID
declare search_type
declare recordGeneral
declare recordExtensions
declare message && message=""
declare wifiName
declare currentIPAddress

search_type="serial"
computer_id=$MAC_SERIAL_NUMBER

autoload 'is-at-least'
autoload 'calendar_scandate'

DiskFreeSpace=$((100*$FREE_DISK_SPACE / $TOTAL_DISK_SPACE))

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
get_nic_info

# Perform JAMF API calls to locate device retrieve device info

check_JSS_Connection
get_JAMF_Server
get_JamfPro_Classic_API_Token
jamfID=$(get_JAMF_DeviceID ${search_type})

recordGeneral=$(get_JAMF_InventoryRecord "GENERAL")
recordExtensions=$(get_JAMF_InventoryRecord "EXTENSION_ATTRIBUTES")

# Construct the info necessary for the display
filevaultStatus=$(get_filevault_status)
mdmprofile=$(mdm_check)

# These variables are specific to JAMF EA fields
userPassword=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Password Change Date") | .values[]' )
userPassword=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" $userPassword +"%Y-%m-%d")

days=$(duration_in_days $userPassword $(date))

create_message_body "Device Name" "${ICON_FILES}HomeFolderIcon.icns" "$MAC_LOCALNAME" "first"
create_message_body "Serial Number" "https://www.iconshock.com/image/RealVista/Accounting/serial_number" "$MAC_SERIAL_NUMBER"
create_message_body "User Logged In" "${ICON_FILES}UserIcon.icns" "$LOGGED_IN_USER"
create_message_body "Password Last Changed" "https://www.iconarchive.com/download/i42977/oxygen-icons.org/oxygen/Apps-preferences-desktop-user-password.ico" "$userPassword ($days days old)"
create_message_body "Current Network" "${ICON_FILES}GenericNetworkIcon.icns" "$wifiName"
create_message_body "Active Connections" "${ICON_FILES}AirDrop.icns" "$adapter"
create_message_body "Current IP" "https://www.iconarchive.com/download/i91394/icons8/windows-8/Network-Ip-Address.ico" "$currentIPAddress"
create_message_body "FV Status" "${ICON_FILES}FileVaultIcon.icns" "$filevaultStatus"
create_message_body "Free Disk Space"  "https://ics.services.jamfcloud.com/icon/hash_522d1d726357cda2b122810601899663e468a065db3d66046778ceecb6e81c2b" "${FREE_DISK_SPACE}Gb $DiskFreeSpace% Free" 
create_message_body "MDM Profile Status" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" "$mdmprofile" "last"

display_welcome_message
exit 0

