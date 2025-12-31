#!/bin/zsh
#
# GetDDMInfo.sh
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 12/23/2025
#
# Script Purpose: Retrieve the DDM info for JAMF devices
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="GetDDMInfo"
SCRIPT_VERSION="1.0 Alpha"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$( /usr/bin/sw_vers -productName )
MACOS_VERSION=$( /usr/bin/sw_vers -productVersion )
MAC_RAM=$( /usr/sbin/sysctl -n hw.memsize 2>/dev/null | /usr/bin/awk '{printf "%.0f GB", $1/1024/1024/1024}' )
MAC_CPU=$( /usr/sbin/sysctl -n machdep.cpu.brand_string)
# Fallback to uname if sysctl fails
#[[ -z "$MAC_CPU" ]] && [[ "$(/usr/bin/uname -m)" == "arm64" ]] && MAC_CPU="Apple Silicon" || MAC_CPU="Intel"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e "${DEFAULTS_DIR}" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "${DEFAULTS_DIR}" "SupportFiles")
    SD_BANNER_IMAGE=$(defaults read "${DEFAULTS_DIR}" "BannerImage")
    spacing=$(defaults read "${DEFAULTS_DIR}" "BannerPadding")
    SD_BANNER_IMAGE="${SUPPORT_DIR}${SD_BANNER_IMAGE}"
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Retrieve JAMF DDM Info"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/System/Applications/App Store.app"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"
##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID=${4}                               # user name for JAMF Pro
CLIENT_SECRET=${5}
[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF credentials we are using

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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
}

function check_logged_in_user ()
{
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in"
        cleanup_and_exit 0
    fi
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function check_for_sudo ()
{
	# Ensures that script is run as ROOT
    if ! admin_user; then
    	MainDialogBody=(
        --message "In order for this script to function properly, it must be run as an admin user!"
		--ontop
		--icon computer
		--overlayicon "$STOP_ICON"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
		--button1text "OK"
    )
    	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
		cleanup_and_exit 1
	fi
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

function JAMF_retrieve_data_summary ()
{    
    # PURPOSE: Extract the summary of the JAMF conmand results
    # RETURN: XML contents of command
    # PARAMTERS: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   JAMF_COMMAND_SUMMARY - specific JAMF API call to execute
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server   
    [[ -z "${2}" ]] && $2="xml"
    echo $(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$2" "${jamfpro_url}${1}" )
}

function JAMF_retrieve_data_details ()
{    
    # PURPOSE: Extract the summary of the JAMF conmand results
    # RETURN: XML contents of command
    # PARAMTERS: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server
    declare format=$2
    [[ -z "${format}" ]] && format="xml"
    xmlBlob=$(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}")
}

function JAMF_get_inventory_record()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS:  $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $2 - Filter condition to use for search

    filter=$(convert_to_hex $2)
    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computers-inventory?section=$1&filter=$filter" 2>/dev/null)
    echo $retval | tr -d '\n'
}

function JAMF_get_deviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID from the JAMF Pro server.
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - search identifier to use (serial or Hostname)
    #        $2 - Conputer ID (serial/hostname)
    #        $3 - Field to return ('managementId' / udid)

    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    retval=$(/usr/bin/curl -s --fail  -H "Authorization: Bearer ${api_token}" \
        -H "Accept: application/json" \
        "${jamfpro_url}api/v2/computers-inventory?section=GENERAL&page=0&page-size=100&sort=general.name%3Aasc&filter=$type=='$2'")

    ID=$(extract_string $retval $3)
    echo $ID
    [[ "$ID" == *"Could not extract value"* || "$ID" == *"null"* || -z "$ID" ]] && display_failure_message
}

function JAMF_get_DDM_info ()
{
    # PURPOSE: uses the ManagementId to retrieve the DDM info
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - Management ID

    echo $(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" \
        -H "Accept: application/json" \
        "${jamfpro_url}api/v1/ddm/${1}/status-items")
}

function JAMF_retrieve_ddm_softwareupdate_info ()
{
    # PURPOSE: extract the DDM Software update info from the computer record
    # RETURN: array of the DDM software update information
    # PARMS: $1 - DDM JSON blob of the computer

    retval=$(echo "$1" | jq -r '.statusItems[] | select(.key | startswith("softwareupdate.pending")) | select(.value != null) | "\(.key):\(.value)"' | sed 's/^softwareupdate.pending-version.//')
    DDMSoftwareUpdateInfo=("${(f)retval}")
}

function JAMF_retrieve_ddm_softwareupdate_failures ()
{
    # PURPOSE: extract the DDM Software update failures from the computer record
    # RETURN: array of the DDM software update information
    # PARMS: $1 - DDM JSON blob of the computer

    retval=$(echo $1 | jq -r '.statusItems[] | select(.key | startswith("softwareupdate.failure-reason")) | select(.value != null) | "\(.key):\(.value)"'| sed 's/^softwareupdate.failure-reason.//')
    DDMSoftwareUpdateFailures=("${(f)retval}")
}

function JAMF_retrieve_ddm_blueprint_active ()
{
    local json_blob="$1"
    local value_content
    local identifier
    local declarations
    
    # 1. Use 'sed' to extract the raw 'value' content and replace the '},{' separator with a specific unique temporary delimiter.
    # We remove the outer quotes and "value": part as well.
    value_content=$(echo "$json_blob" | sed -n 's/.*"value" : "\({.*\)}".*/\1/p' | sed 's/},{/|NEWLINE|/g')

    # 2. Use Zsh parameter expansion to split by the temporary delimiter into an array.
    # The (ps/|NEWLINE|/) flags mean 'Parameter Split by the string |NEWLINE|'
    declarations=("${(ps/|NEWLINE|/)value_content}")

    # 3. Iterate over each declaration block
    for item in "${declarations[@]}"; do
        # Check if the block contains 'active=true'
        if [[ "$item" == *"active=true"* ]]; then
            # Extract the identifier value specifically using sed within the loop
            identifier=$(echo "$item" | sed -E 's/.*identifier=([^,>]*).*/\1/')
            if [[ "$identifier" == "Blueprint_"* ]]; then
                DDMBlueprintInfo+=($(echo $identifier | sed 's/^Blueprint_//; s/_s1_sys_act1$//'))
            fi
        fi
    done
}

function JAMF_retrieve_ddm_inactive_blueprint_errors ()
{
    local json_blob="$1"
    local declarations
    local delimiter="}], "
    
    # 1. Use 'sed' to extract the raw 'value' content and replace the '},{' separator with a specific unique temporary delimiter.
    # We remove the outer quotes and "value": part as well.
    local value_content=$(echo "$json_blob" | sed -n 's/.*"value" : "\({.*\)}".*/\1/p' | sed 's/},{/|NEWLINE|/g')

    # 2. Use Zsh parameter expansion to split by the temporary delimiter into an array.
    # The (ps/|NEWLINE|/) flags mean 'Parameter Split by the string |NEWLINE|'
    declarations=("${(ps/|NEWLINE|/)value_content}")

    # 3. Iterate over each declaration block
    for decl in "${declarations[@]}"; do
        # Check if the block contains 'active=false'
        if [[ "$decl" == *"active=false"* ]]; then
            # Extract the identifier value specifically using sed within the loop
            code_value=$(echo "$decl" |  awk -F "code=" '{print $NF}')
            if [[ -n "$code_value" ]]; then
                # Clean up potential trailing braces/brackets that might be captured
                error_code=$(echo "$code_value" | awk -F "code=" '{print $NF}')
                error_code="${error_code%%$delimiter*}"
            fi
            local identifier=$(echo "$decl" | sed -E 's/.*identifier=([^,>]*).*/\1/')

            # Check if the extracted identifier starts with 'Blueprint_'
            if [[ "$identifier" == "Blueprint_"* ]]; then
                DDMBlueprintErrors+=($(echo $identifier | sed 's/^Blueprint_//; s/_s1_sys_act1$//')" - "$error_code)
            fi
        fi
    done
}

function JAMF_retrieve_ddm_keys ()
{
    # PURPOSE: uses the ManagementId to retrieve the DDM info
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - Management ID
    #        $2 - Specific DDM Keys to extract

    echo $(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/ddm/${1}/status-items/$2")
}

function JAMF_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    echo $retval
}

function welcomemsg ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 100
        --infotext $SCRIPT_VERSION
        --titlefont shadow=1
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, please enter the serial or hostname of the device you wish to see the DDM information for.  Active & failed Blueprints will be displayed as well as any pending software updates."
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --selecttitle "Serial,required"
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 400
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0

    search_type=$(echo $message | plutil -extract 'SelectedOption' 'raw' -)
    computer_id=$(echo $message | plutil -extract 'Device' 'raw' -)
}

function extract_string ()
{
    # PURPOSE: Extract (grep) results from a string 
    # RETURN: parsed string
    # PARAMS: $1 = String to search in
    #         $2 = key to extract
    
    echo $1 | tr -d '\n' | jq -r "$2"
}

function display_results ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 100
        --titlefont shadow=1
        --infotext $SCRIPT_VERSION
        --message "Here are the result of the DDM info for this mac:<br><br>$1"
        --messagefont name=Arial,size=14
        --helpmessage "Add this URL prefix to the Blueprint ID to find the Blueprint details<br>$jamfpro_url/view/mfe/blueprints/"
        --button1text "OK"
        --ontop
        --resizable
        --width 850
        --height 600
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )
    #buttonpress=$?
    #[[ $buttonpress = 2 ]] && exit 0
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare api_token
declare jamfpro_url
declare computer_id
declare -a DDMSoftwareUpdateInfo
declare -a DDMSoftwareUpdateFailures
declare -a DDMBlueprintErrors
declare -a DDMBlueprintInfo

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message

JAMF_check_connection
JAMF_get_server
# Check if the JAMF Pro server is using the new API or the classic API
# If the client ID is longer than 30 characters, then it is using the new API
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token   
OVERLAY_ICON=$(JAMF_which_self_service) 

welcomemsg

# First we have to get the JAMF ManagementID of the machine
ID=$(JAMF_get_deviceID "${search_type}" ${computer_id} ".results[].general.managementId")

# Second is to extract the DDM info for the machine
DDMInfo=$(JAMF_get_DDM_info $ID)
logMe "INFO: JAMF ID: $ID"

# Third, extract the DDM Software Update info for the machine
JAMF_retrieve_ddm_softwareupdate_info $DDMInfo
logMe "INFO: Software Update Info: "$DDMSoftwareUpdateInfo

# Fourth, see if there are any software update failures
JAMF_retrieve_ddm_softwareupdate_failures $DDMInfo
logMe "INFO: Software Update Failures: "$DDMSoftwareUpdateFailures

# Fifth, extract the DDM blueprint IDs assigned to the machine
DDMKeys=$(JAMF_retrieve_ddm_keys $ID "management.declarations.activations")
#echo $DDMKeys

JAMF_retrieve_ddm_blueprint_active $DDMKeys
logMe "INFO: Active Blueprints: "$DDMBlueprintInfo

# Sixth, see if there are any inactive Blueprints
JAMF_retrieve_ddm_inactive_blueprint_errors $DDMKeys
logMe "INFO: Inactive Blueprints: "$DDMBlueprintErrors

#Show the results and log it

message="**Device name:** $computer_id<br>"
message+="**JAMF Management ID:** $ID<br><br>"
message+="<br><br>**DDM Blueprints Active**<br>"
for item in "${DDMBlueprintInfo[@]}"; do
    message+=$item"<br>"
done
message+="<br><br>**DDM Blueprint Failures**<br>"
for item in "${DDMBlueprintErrors[@]}"; do
    message+=$item"<br>"
done
message+="<br><br>**DDM Software Update Info**<br>"
for item in "${DDMSoftwareUpdateInfo[@]}"; do
    message+=$item"<br>"
done
message+="<br><br>**DDM Software Update Failures**<br>"
for item in "${DDMSoftwareUpdateFailures[@]}"; do
    message+=$item"<br>"
done

# Log and show the results
logMessage=$(echo "$message" | sed 's/<br>/\\n/g')
logMe "Results: "$logMessage
display_results $message

JAMF_invalidate_token
cleanup_and_exit 0
