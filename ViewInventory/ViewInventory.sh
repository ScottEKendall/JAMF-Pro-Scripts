#!/bin/zsh
#
# by: Scott Kendall
#
# Written: 03/31/2025
# Last updated: 04/04/2025

# Script to view inventory detail of a JAMF record and show pertitent info in SwiftDialog
# 
# 1.0 - Initial code
# 1.1 - Added addition logic for Mac mini...it isn't formatted the same as regular model names
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
MAC_MODEL=$(ioreg -l | grep "product-name" | awk -F ' = ' '{print $2}' | tr -d '<>"')
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
TOTAL_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Total Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

MACOS_VERSION=$( sw_vers -productVersion | xargs)
MAC_LOCALNAME=$(scutil --get LocalHostName)

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
INVENTORY_MODE=${6:-"local"}
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

function display_device_entry_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --icon "${SD_ICON}"
        --iconsize 128
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you want to view the inventory of"
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --textfield "Device,required"
        --button1text "Continue"
        --button2text "Quit"
        --infobox "${SD_INFO_BOX_MSG}"
        --ontop
        --height 420
        --json
        --moveable
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0

    search_type=$(echo $message | jq -r ".SelectedOption" )
    computer_id=$(echo $message | jq -r ".Device" )
}

function display_device_info ()
{
    local message
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --icon "${SD_ICON}"
        --message none
        --iconsize 128
        --infobox "${SD_INFO_BOX_MSG}"
        --ontop
        --jsonfile "${JSON_OPTIONS}"
        --height 790
        --width 920
        --json
        --moveable
        --button1text "OK"
        --infobutton 
        --infobuttontext "Get Help" 
        --infobuttonaction "https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d" 
        --helpmessage "Free Disk Space must be above 50GB available.\n\n SMART Status must return 'Verified'.\n\n Last Jamf Checkin must be within 7 days.\n\n Last Reboot must be within 14 days.\n\n Battery Condition must return 'Normal'.\n\n Battery Cycle Count must be below 1000. \n\n Encryption status must return 'Filevault is on'.\n\n Crowdstrike Falcon must be connected.\n\n macOS must be on version $macOSversion2 or $macOSversion1" 

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
        --titlefont shadow=1
        --icon "${SD_ICON}"
        --message "${msg}"
        --overlayicon "SF=checkmark.circle.fill,color=green,weight=heavy"
        --infobox "${SD_INFO_BOX_MSG}"
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 460
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
        --titlefont shadow=1
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

function format_mac_model ()
{
    # PURPOSE: format the device model correctly showing just "Model (year)"...use parameter expansion to extract the numbers within parentheses
    # RETURN: properly formatted model name
    # PARAMS: $1 = Model name to convert

    declare year
    declare name
    name=$(echo $1 | sed 's/\[[^][]*\]//g' | xargs)
    name="${(C)name}"
    [[ ${name} == *"Mini"* ]] && year="${name##*\(}" || year="${name##*, }"
    year="${year%%\)*}"
    name=$(echo $name | awk -F '(' '{print $1}' | xargs)
    echo "$name ($year)"
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
declare search_type
declare computer_id
declare jamfID
declare search_type
declare recordGeneral
declare recordExtensions
declare message && message=""
declare wifiName
declare currentIPAddress

autoload 'is-at-least'
autoload 'calendar_scandate'

create_log_directory
check_swift_dialog_install
check_support_files

if [[ ${INVENTORY_MODE} == "local" ]]; then
    search_type="serial"
    computer_id=$MAC_SERIAL_NUMBER
else
    display_device_entry_message
fi

# Perform JAMF API calls to locate device retrieve device info

check_JSS_Connection
get_JAMF_Server
get_JamfPro_Classic_API_Token
jamfID=$(get_JAMF_DeviceID ${search_type})

recordGeneral=$(get_JAMF_InventoryRecord "GENERAL")
recordExtensions=$(get_JAMF_InventoryRecord "EXTENSION_ATTRIBUTES")
recordHardware=$(get_JAMF_InventoryRecord "HARDWARE")
recordStorage=$(get_JAMF_InventoryRecord "STORAGE")
recordOperatingSystem=$(get_JAMF_InventoryRecord "OPERATING_SYSTEM")

invalidate_JAMF_Token

if [[ ${INVENTORY_MODE} == "local" ]]; then

    # Information to show if we are viewing local machine info
    SD_WINDOW_TITLE+=" (Local)"
    get_nic_info

    SYSTEM_PROFILER_BATTERY_BLOB=$( /usr/sbin/system_profiler 'SPPowerDataType')
    BatteryCondition=$(echo $SYSTEM_PROFILER_BATTERY_BLOB | grep "Condition" | awk '{print $2}')
    BatteryCycleCount=$(echo $SYSTEM_PROFILER_BATTERY_BLOB | grep "Cycle Count" | awk '{print $3}')
    BatteryCondition+=" ($BatteryCycleCount Cycles)"

    filevaultStatus=$(get_filevault_status)
    mdmprofile=$(mdm_check)

    deviceName=$MAC_LOCALNAME
    deviceModel=$(format_mac_model $MAC_MODEL)
    deviceSerialNumber=$MAC_SERIAL_NUMBER
    deviceLastLoggedInUser=$LOGGED_IN_USER
    deviceStorage=$FREE_DISK_SPACE
    deviceTotalStorage=$TOTAL_DISK_SPACE
    deviceCPU=$MAC_CPU
    macOSVersion=$MACOS_VERSION

    JAMFLastCheckinTime=$(grep "Checking for policies triggered by \"recurring check-in\"" "/private/var/log/jamf.log" | tail -n 1 | awk '{ print $2,$3,$4 }')
    JAMFLastCheckinTime=$(date -j -f "%b %d %H:%M:%S" $JAMFLastCheckinTime +"%Y-%m-%d %H:%M:%S")


    # Last Reboot
    boottime=$(sysctl kern.boottime | awk '{print $5}' | tr -d ,) # produces EPOCH time
    formattedTime=$(date -jf %s "$boottime" +%F) #formats to a readable time
    lastRebootFormatted=$(date -j -f "%Y-%m-%d" "$formattedTime" +"%Y-%d-%m")

    ####### Crowdstrike Falcon Connection Status
    falcon_connect_status=$(sudo /Applications/Falcon.app/Contents/Resources/falconctl stats | grep "State:" | awk '{print $2}')

else
    # Users is viewing remote info, so create the information based on their JAMF record    
    # Some of the JAMF EA field are specific to our environment: "Password Plist Entry" & "Wi-Fi SSID"

    SD_WINDOW_TITLE+=" (Remote)"
    adapter="Wi-Fi"
    create_infobox_message

    macOSVersion=$(echo $recordOperatingSystem | jq -r '.operatingSystem.version')
    deviceCPU=$(echo $recordHardware | jq -r '.hardware.processorType')
    deviceName=$(echo $recordGeneral | jq -r '.general.name')
    deviceModel=$(echo $recordHardware | jq -r '.hardware.model')
    falcon_connect_status=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Crowdstrike Status") | .values[]' )
    zScaler_status=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "ZScaler Info") | .values[]' )
    
    deviceModel=$(format_mac_model $deviceModel)
    
    deviceSerialNumber=$(echo $recordHardware | jq -r '.hardware.serialNumber')
    deviceLastLoggedInUser=$(echo $recordGeneral | jq -r '.general.lastLoggedInUsernameBinary')

    # JAMF Connection info
    JAMFLastCheckinTime=$(echo $recordGeneral | jq -r '.general.lastContactTime')
    JAMFLastCheckinTime=${JAMFLastCheckinTime:: -5}
    JAMFLastCheckinTime=$(date -j -f "%Y-%m-%dT%H:%M:%S" $JAMFLastCheckinTime +"%Y-%m-%d %H:%M:%S")

    lastRebootFormatted=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Last Restart") | .values[]' )
    lastRebootFormatted=$(date -j -f "%b %d" "$lastRebootFormatted" +"%Y-%m-%d")

    days=$(duration_in_days $lastRebootFormatted $(date))
    lastRebootFormatted+=" ($days day ago)"
    BatteryCondition=$(echo $recordHardware | jq -r '.hardware.extensionAttributes[] | select(.name == "Battery Condition") | .values[]' )

    # Get Wi-Fi and IP address info
    wifiName=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Wi-Fi SSID") | .values[]' )
    currentIPAddress=$(echo $recordGeneral | jq -r '.general.lastReportedIp')

    # FileVault status & Storage space
    
    deviceStorage=$(echo $recordStorage | jq -r '.storage.disks[].partitions[] | select(.name == "Data")' )
    filevaultStatus=$(echo $deviceStorage | grep "fileVault2State" | awk -F ":" '{print $2}' | xargs | tr -d ",")
    [[ $filevaultStatus == "ENCRYPTED" ]] && filevaultStatus="FV Enabled" || filevaultStatus="FV Not eanbled"

    deviceTotalStorage=$(($(echo $deviceStorage | grep "sizeMegabytes" | awk -F ":" '{print $2}' | xargs | tr -d ",") / 1024 ))
    deviceStorage=$(($(echo $deviceStorage | grep "availableMegabytes" | awk -F ":" '{print $2}' | xargs | tr -d ",") / 1024 ))

fi

# Disk Space calculation
DiskFreeSpace=$((100 * $deviceStorage / $deviceTotalStorage ))

# Password age calculation
# These variables are specific to our JAMF EA field "Password Plist Entry"

userPassword=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Password Plist Entry") | .values[]' )
userPassword=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" $userPassword +"%Y-%m-%d")
days=$(duration_in_days $userPassword $(date))

# determine falcon status
if [[ $falcon_connect_status == "connected" ]]; then
    falcon_connect_icon="success"
    falcon_connect_status="Connected"
else
    falcon_connect_icon="error"
    falcon_connect_status="Not Connected"
fi
# determine zScaler status
if [[ $zScaler_status == *"Logged In"* ]]; then
    zScaler_status="Logged In"
elif [[ $zScaler_status == *"Tunnel Bypassed"* ]]; then
    zScaler_status="Bypassed"
else
    zScaler_status="Unknown"
fi 

create_message_body "Device Name" "${ICON_FILES}HomeFolderIcon.icns" "$deviceName" "first"
create_message_body "maCOS Version" "${ICON_FILES}FinderIcon.icns" "macOS "$macOSVersion
create_message_body "User Logged In" "${ICON_FILES}UserIcon.icns" "$deviceLastLoggedInUser"
create_message_body "Password Last Changed" "https://www.iconarchive.com/download/i42977/oxygen-icons.org/oxygen/Apps-preferences-desktop-user-password.ico" "$userPassword ($days days ago)"
create_message_body "Model" "SF=apple.logo color=black" "$deviceModel"
create_message_body "CPU Type" "SF=cpu.fill color=black" "$deviceCPU"
create_message_body "Crowdstrike Falcon" "/Applications/Falcon.app/Contents/Resources/AppIcon.icns" "$falcon_connect_status"
create_message_body "zScaler" "/Applications/ZScaler/Zscaler.app/Contents/Resources/AppIcon.icns" "$zScaler_status"
create_message_body "Battery Condition" "SF=batteryblock.fill color=green" "${BatteryCondition}"
create_message_body "Last Reboot" "https://use2.ics.services.jamfcloud.com/icon/hash_5d46c28310a0730f80d84afbfc5889bc4af8a590704bb9c41b87fc09679d3ebd" $lastRebootFormatted
create_message_body "Serial Number" "https://www.iconshock.com/image/RealVista/Accounting/serial_number" "$deviceSerialNumber"
create_message_body "Current Network" "${ICON_FILES}GenericNetworkIcon.icns" "$wifiName"
create_message_body "Active Connections" "${ICON_FILES}AirDrop.icns" "$adapter"
create_message_body "Current IP" "https://www.iconarchive.com/download/i91394/icons8/windows-8/Network-Ip-Address.ico" "$currentIPAddress"
create_message_body "FileVault Status" "${ICON_FILES}FileVaultIcon.icns" "$filevaultStatus"
create_message_body "Free Disk Space"  "https://ics.services.jamfcloud.com/icon/hash_522d1d726357cda2b122810601899663e468a065db3d66046778ceecb6e81c2b" "${deviceStorage}Gb ($DiskFreeSpace% Free)"
create_message_body "JAMF ID #" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" $jamfID
create_message_body "Last Jamf Checkin:" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" "$JAMFLastCheckinTime"
create_message_body "MDM Profile Status" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" "$mdmprofile" "last"

display_device_info
exit 0
