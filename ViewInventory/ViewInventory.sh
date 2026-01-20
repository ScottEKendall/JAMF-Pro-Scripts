#!/bin/zsh
#
# ViewInventory
# by: Scott Kendall
#
# Written: 03/31/2025
# Last updated: 11/15/2025

# Script to view inventory detail of a JAMF record and show pertinent info in SwiftDialog
# 
# 1.0 - Initial code
# 1.1 - Added addition logic for Mac mini...it isn't formatted the same as regular model names
# 1.2 - Added feature for compliance reporting, removed unnecessary functions
# 1.3 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 1.4 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Bumped min version of SD to 2.5.0
#       Fixed typos
#
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

#set -x 
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="ViewInventory"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.6"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX")
chmod 666 $JSON_DIALOG_BLOB

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
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Device Information"
SD_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"

HELP_DESK_TICKET="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID="$4"
CLIENT_SECRET="$5"
INVENTORY_MODE=${6:-"local"}
MIN_OS_VERSION="${7:-"14.4"}" # Minimum version for macOS N
MIN_HD_SPACE="${8:-"50"}" # Minimum amount of storage available in gigabytes
JAMF_CHECKIN_DELTA="${9:-"7"}" #Threshold days since last jamf check-in
LAST_REBOOT_DELTA="${10:-"14"}" # Threshold days since last reboot

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF credentials we are using

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

function cleanup_and_exit ()
{
	[[ -f ${JSON_DIALOG_BLOB} ]] && /bin/rm -rf ${JSON_DIALOG_BLOB}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
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
        --message "Compliance information symbols are displayed next to the required item(s).  To see the reason for any failures, please click the 'Compliance' button for details."
        --iconsize 128
        --infobox "${SD_INFO_BOX_MSG}"
        --ontop
        --jsonfile "${JSON_DIALOG_BLOB}"
        --height 790
        --width 920
        --json
        --moveable
        --button1text "OK"
        --button2text "Compliance"
        --infobutton 
        --infobuttontext "Get Help" 
        --infobuttonaction "${HELP_DESK_TICKET}" 
     )
	
     message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

     buttonpress=$?
    [[ $buttonpress = 2 ]] && display_compliance_info

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

###########################
#
# JAMF functions
#
###########################

function JAMF_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path)
    [[ -z $retval ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    echo $retval
}

function JAMF_check_connection ()
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

function JAMF_get_server ()
{
    # PURPOSE: Retreive your JAMF server URL from the preferences file
    # RETURN: None
    # EXPECTED: None

    jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
    logMe "JAMF Pro server is: $jamfpro_url"
}

function JAMF_check_credentials ()
{
    # PURPOSE: Check to make sure the Client ID & Secret are passed correctly
    # RETURN: None
    # EXPECTED: None

    if [[ -z $CLIENT_ID ]] || [[ -z $CLIENT_SECRET ]]; then
        logMe "Client/Secret info is not valid"
        exit 1
    fi
    logMe "Valid credentials passed"
}

function JAMF_get_classic_api_token ()
{
    # PURPOSE: Get a new bearer token for API authentication.  This is used if you are using a JAMF Pro ID & password to obtain the API (Bearer token)
    # PARMS: None
    # RETURN: api_token
    # EXPECTED: CLIENT_ID, CLIENT_SECRET, jamfpro_url

     api_token=$(/usr/bin/curl -X POST --silent -u "${CLIENT_ID}:${CLIENT_SECRET}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)
     if [[ "$api_token" == *"Could not extract value"* ]]; then
         logMe "Error: Unable to obtain API token. Check your credentials and JAMF Pro URL."
         exit 1
     else 
        logMe "Classic API token successfully obtained."
    fi

}

function JAMF_validate_token () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")
}

function JAMF_get_access_token ()
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
    else
        logMe "API token successfully obtained."
    fi
    
    api_token=$(echo "$returnval" | plutil -extract access_token raw -)
}

function JAMF_check_and_renew_api_token ()
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     JAMF_validate_token

     # If the api_authentication_check has a value of 200, that means that the current
     # bearer token is valid and can be used to authenticate an API call.

     if [[ ${api_authentication_check} == 200 ]]; then

     # If the current bearer token is valid, it is used to connect to the keep-alive endpoint. This will
     # trigger the issuing of a new bearer token and the invalidation of the previous one.

          api_token=$(/usr/bin/curl "${jamfpro_url}/api/v1/auth/keep-alive" --silent --request POST -H "Authorization: Bearer ${api_token}" | plutil -extract token raw -)

     else

          # If the current bearer token is not valid, this will trigger the issuing of a new bearer token
          # using Basic Authentication.

          JAMF_get_classic_api_token
     fi
}

function JAMF_invalidate_token ()
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
    wirelessInterface=$( networksetup -listnetworkserviceorder | sed -En 's/^\(Hardware Port: (Wi-Fi|AirPort), Device: (en.)\)$/\2/p' )
    ipconfig setverbose 1
    wifiName=$( ipconfig getsummary "${wirelessInterface}" | awk -F ' SSID : ' '/ SSID : / {print $2}')
    ipconfig setverbose 0
    [[ -z "${wifiName}" ]] && wifiName="Not connected"


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
        [[ $(fdesetup status | grep On) ]] && echo "FV Enabled but not for current user" || echo "FV Not enabled"
    fi
}

function create_message_body ()
{
    # PURPOSE: Construct the message body of the dialog box
    #"listitem" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title 
    #        $2 - icon
    #        $3 - listitem
    #        $4 - status
    #        $5 - first or last - construct appropriate listitem heders / footers
    declare line && line=""

    [[ "$5:l" == "first" ]] && line+='{"listitem" : ['
    if [[ -z $4 ]]; then
        line+='{"title" : "'$1':", "icon" : "'$2'", "statustext" : "'$3'"},'
    else
        line+='{"title" : "'$1':", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    fi
    [[ "$5:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
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

function display_compliance_info ()
{
    # PURPOSE: go thru each compliance item and show the reason(s) for any failures
    # RETURN: None
    # EXPECTED: None
    # 
    declare message
    message="The following issues have been found on your system:<br><br>"

    [[ $os_status_icon == "fail" ]] && message+="- The minimum OS required is macOS $MIN_OS_VERSION.  You are running macOS $macOSVersion.<br>"
    [[ $falcon_connect_icon == "fail" ]] && message+="- Crowdstrike Falcon is not running on your computer.<br>"
    [[ ! $zScaler_status_icon == "success" ]] && message+="- zScaler is not running, or not protecting your computer.<br>"
    [[ $filevaultStatus_icon == "fail" ]] && message+="- FileVault is not currently encrypting your system.<br>"
    [[ $hd_status_icon == "fail" ]] && message+="- You need to have at least ${MIN_HD_SPACE}Gb of free space on your hard drive.<br>"
    [[ $JAMF_checkin_icon == "fail" ]] && message+="- Your system hasn't checked into JAMF for over ${JAMF_CHECKIN_DELTA} days.<br>"
    [[ $reboot_icon = "fail" ]] && message+="- Your system needs to be restarted at least once every $LAST_REBOOT_DELTA days.<br>"

     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --icon "${SD_ICON}"
        --message "${message}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "Quit"
        --ontop
        --height 460
        --json
        --moveable
    )
    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    cleanup_and_exit
}

function get_zscaler_info () 
{
    # PURPOSE: Check to see if the zScaler tunnel is running
    # RETURN: None
    # EXPECTED: None
 
    tunnel=$( pgrep -i ZscalerTunnel )

    keychainKey="" #$(su - $LOGGED_IN_USER -c "security find-generic-password -l 'com.zscaler.tray'")

    # If the keychain entry is not found, they haven't logged in
    [[ ! -z $keychainKey ]] && zStatus="Logged In" || zStatus="Not Logged In"
    [[ -z $tunnel ]] && zStatus="Tunnel Bypassed"

    # if the http test doesn't resolve to zscaler, then the tunnel has been bypassed
    orgsite=$(curl -fs https://ipinfo.io/json | grep org | awk -F ":" '{print $2}' | tr -d ",")
    [[ $orgsite == *"ZSCALER"* && ! -z $keychainKey ]] && RESULT="Protected" || RESULT="No Active Tunnel"
    
    #report results
    echo $zStatus
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

    # Users is viewing local info, so pull all the data from current system  

    SD_WINDOW_TITLE+=" (Local)"
    get_nic_info
    zScaler_status=$(get_zscaler_info)

    deviceName=$MAC_LOCALNAME
    deviceModel=$(format_mac_model $MAC_MODEL)
    deviceSerialNumber=$MAC_SERIAL_NUMBER
    deviceLastLoggedInUser=$LOGGED_IN_USER
    deviceAvailStorage=$FREE_DISK_SPACE
    deviceTotalStorage=$TOTAL_DISK_SPACE
    deviceCPU=$MAC_CPU
    macOSVersion=$MACOS_VERSION

    # Battery Info
    SYSTEM_PROFILER_BATTERY_BLOB=$( /usr/sbin/system_profiler 'SPPowerDataType')
    BatteryCondition=$(echo $SYSTEM_PROFILER_BATTERY_BLOB | grep "Condition" | awk '{print $2}')
    BatteryCycleCount=$(echo $SYSTEM_PROFILER_BATTERY_BLOB | grep "Cycle Count" | awk '{print $3}')
    BatteryCondition+=" ($BatteryCycleCount Cycles)"

    # FileVault status
    filevaultStatus=$(get_filevault_status)
    mdmprofile=$(mdm_check)

    # JAMF Info
    JAMFLastCheckinTime=$(grep "Checking for policies triggered by \"recurring check-in\"" "/private/var/log/jamf.log" | tail -n 1 | awk '{ print $2,$3,$4 }')
    JAMFLastCheckinTime=$(date -j -f "%b %d %H:%M:%S" $JAMFLastCheckinTime +"%Y-%m-%d %H:%M:%S")

    # Last Reboot
    boottime=$(sysctl kern.boottime | awk '{print $5}' | tr -d ,) # produces EPOCH time
    formattedTime=$(date -jf %s "$boottime" +%F) #formats to a readable time
    lastRebootFormatted=$(date -j -f "%Y-%m-%d" "$formattedTime" +"%Y-%m-%d %H:%M:%S")

    # Crowdstrike Falcon Connection Status
    falcon_connect_status=$(sudo /Applications/Falcon.app/Contents/Resources/falconctl stats | grep "State:" | awk '{print $2}' | head -n 1)

    # Last Password Update
    userPassword=$(/usr/libexec/plistbuddy -c "print PasswordLastChanged" $JSS_FILE 2>&1)

else

    # Users is viewing remote info, so create the information based on their JAMF record    
    # Some of the JAMF EA field are specific to our environment: "Password Plist Entry" & "Wi-Fi SSID"
    # Perform JAMF API calls to locate device info

    create_infobox_message
    display_device_entry_message
    check_JSS_Connection
    JAMF_get_server
    [[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token 
    jamfID=$(get_JAMF_DeviceID ${search_type})

    recordGeneral=$(get_JAMF_InventoryRecord "GENERAL")
    recordExtensions=$(get_JAMF_InventoryRecord "EXTENSION_ATTRIBUTES")
    recordHardware=$(get_JAMF_InventoryRecord "HARDWARE")
    recordStorage=$(get_JAMF_InventoryRecord "STORAGE")
    recordOperatingSystem=$(get_JAMF_InventoryRecord "OPERATING_SYSTEM")
    JAMF_invalidate_token

    SD_WINDOW_TITLE+=" (Remote)"
    adapter="Wi-Fi"

    deviceName=$(echo $recordGeneral | jq -r '.general.name')
    deviceModel=$(echo $recordHardware | jq -r '.hardware.model')
    deviceModel=$(format_mac_model $deviceModel)
    deviceSerialNumber=$(echo $recordHardware | jq -r '.hardware.serialNumber')
    deviceLastLoggedInUser=$(echo $recordGeneral | jq -r '.general.lastLoggedInUsernameBinary')

    deviceAvailStorage=$(echo $recordStorage | jq -r '.storage.disks[].partitions[] | select(.name == "Data")' )
    deviceTotalStorage=$(($(echo $deviceAvailStorage | grep "sizeMegabytes" | awk -F ":" '{print $2}' | tr -d " ,") / 1024 ))
    deviceAvailStorage=$(($(echo $deviceAvailStorage | grep "availableMegabytes" | awk -F ":" '{print $2}' | tr -d " ,") / 1024 ))

    deviceCPU=$(echo $recordHardware | jq -r '.hardware.processorType')
    macOSVersion=$(echo $recordOperatingSystem | jq -r '.operatingSystem.version')
    BatteryCondition=$(echo $recordHardware | jq -r '.hardware.extensionAttributes[] | select(.name == "Battery Condition") | .values[]' )

    # FileVault status & Storage space
    
    tempFVStoage=$(echo $recordStorage | jq -r '.storage.disks[].partitions[] | select(.name == "Data")' )
    filevaultStatus=$(echo $tempFVStoage | grep "fileVault2State" | awk -F ":" '{print $2}' | xargs | tr -d ",")

    [[ $filevaultStatus == "ENCRYPTED" ]] && filevaultStatus="FV Enabled" || filevaultStatus="FV Not eanbled"

    falcon_connect_status=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Crowdstrike Status") | .values[]' )
    zScaler_status=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "ZScaler Info") | .values[]' )

    # JAMF Connection info
    JAMFLastCheckinTime=$(echo $recordGeneral | jq -r '.general.lastContactTime')
    JAMFLastCheckinTime=${JAMFLastCheckinTime:: -5}
    JAMFLastCheckinTime=$(date -j -f "%Y-%m-%dT%H:%M:%S" $JAMFLastCheckinTime +"%Y-%m-%d %H:%M:%S")

    lastRebootFormatted=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Last Restart") | .values[]' )
    #lastRebootFormatted=$(date -j -f "%b %d" "$lastRebootFormatted" +"%Y-%m-%d %H:%M:%S")

    userPassword=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Password Plist Entry") | .values[]' )

    # Get Wi-Fi and IP address info
    wifiName=$(echo $recordExtensions | jq -r '.extensionAttributes[] | select(.name == "Wi-Fi SSID") | .values[]' )
    currentIPAddress=$(echo $recordGeneral | jq -r '.general.lastReportedIp')
fi

# 
# "Common" calculations for either local or remote information
#

# Disk Space calculation
DiskFreeSpace=$((100 * $deviceAvailStorage / $deviceTotalStorage ))

# Password age calculation

userPassword=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" $userPassword +"%Y-%m-%d")
passswordAge=$(duration_in_days $userPassword $(date))

# determine falcon status

[[ $falcon_connect_status == *"Running"* ]] && falcon_connect_status="Connected" || falcon_connect_status="Not Connected"

# determine zScaler status
if [[ $zScaler_status == *"Logged In"* ]]; then
    zScaler_status="Logged In"
    zScaler_status_icon="success"
elif [[ $zScaler_status == *"Tunnel Bypassed"* ]]; then
    zScaler_status="Bypassed"
    zScaler_status_icon="error"
else
    zScaler_status="Unknown"
    zScaler_status_icon="fail"
fi 

# Calculate the pass/fail for requred items

# OS versions
is-at-least "${MIN_OS_VERSION}" "${macOSVersion}" && os_status_icon="success" || os_status_icon="fail"

# disk space free
is-at-least "$MIN_HD_SPACE" "$deviceAvailStorage" && hd_status_icon="success" || hd_status_icon="fail"

# check FV Status
[[ $filevaultStatus == "FV Enabled" ]] && filevaultStatus_icon="success" || filevaultStatus_icon="fail"
[[ $falcon_connect_status == "Connected" ]] && falcon_connect_icon="success" || falcon_connect_icon="fail"

#Determine JAMF last check-in
days=$(duration_in_days $JAMFLastCheckinTime $(date))
[[ ${days} -le ${JAMF_CHECKIN_DELTA} ]] && JAMF_checkin_icon="success" || JAMF_checkin_icon="fail"

#Determine last reboot

[[ -z $lastRebootFormatted ]] && days="365" || days=$(duration_in_days $lastRebootFormatted $(date))
[[ ${days} -le ${LAST_REBOOT_DELTA} ]] && reboot_icon="success" || reboot_icon="fail"

# Construct the list of items and display it to the user

create_message_body "Device Name" "${ICON_FILES}HomeFolderIcon.icns" "$deviceName" "" "first"
create_message_body "macOS Version" "${ICON_FILES}FinderIcon.icns" "macOS "$macOSVersion "$os_status_icon" 
create_message_body "User Logged In" "${ICON_FILES}UserIcon.icns" "$deviceLastLoggedInUser" ""
create_message_body "Password Last Changed" "https://www.iconarchive.com/download/i42977/oxygen-icons.org/oxygen/Apps-preferences-desktop-user-password.ico" "$userPassword ($passswordAge days ago)" ""
create_message_body "Model" "SF=apple.logo color=black" "$deviceModel" "" 
create_message_body "CPU Type" "SF=cpu.fill color=black" "$deviceCPU" ""
create_message_body "Crowdstrike Falcon" "/Applications/Falcon.app/Contents/Resources/AppIcon.icns" "$falcon_connect_status" "$falcon_connect_icon"
create_message_body "zScaler" "/Applications/ZScaler/Zscaler.app/Contents/Resources/AppIcon.icns" "$zScaler_status" "$zScaler_status_icon"
create_message_body "Battery Condition" "SF=batteryblock.fill color=green" "${BatteryCondition}" ""
create_message_body "Last Reboot" "https://use2.ics.services.jamfcloud.com/icon/hash_5d46c28310a0730f80d84afbfc5889bc4af8a590704bb9c41b87fc09679d3ebd" $lastRebootFormatted "" "$reboot_icon"
create_message_body "Serial Number" "https://www.iconshock.com/image/RealVista/Accounting/serial_number" "$deviceSerialNumber" ""
create_message_body "Current Network" "${ICON_FILES}GenericNetworkIcon.icns" "$wifiName" ""
create_message_body "Active Connections" "${ICON_FILES}AirDrop.icns" "$adapter" ""
create_message_body "Current IP" "https://www.iconarchive.com/download/i91394/icons8/windows-8/Network-Ip-Address.ico" "$currentIPAddress" ""
create_message_body "FileVault Status" "${ICON_FILES}FileVaultIcon.icns" "$filevaultStatus" "$filevaultStatus_icon"
create_message_body "Free Disk Space"  "https://ics.services.jamfcloud.com/icon/hash_522d1d726357cda2b122810601899663e468a065db3d66046778ceecb6e81c2b" "${deviceAvailStorage}Gb ($DiskFreeSpace% Free)" "$hd_status_icon"
create_message_body "JAMF ID #" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" $jamfID ""
create_message_body "Last Jamf Checkin:" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" "$JAMFLastCheckinTime" "$JAMF_checkin_icon"
create_message_body "MDM Profile Status" "https://resources.jamf.com/images/logos/Jamf-Icon-color.png" "$mdmprofile" "" "last"

display_device_info
exit 0