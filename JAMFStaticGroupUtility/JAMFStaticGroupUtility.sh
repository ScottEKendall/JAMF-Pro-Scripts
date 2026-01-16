#!/bin/zsh --no-rcs
#
# JAMFStaticGroupUtility.sh
#
# by: Scott Kendall
#
# Written: 10/09/2025
# Last updated: 02/16/2026
#
# Script Purpose: View, Add or Delete JAMF static group members
#

######################
#
# Script Parameters:
#
#####################
#
#   Parameter 4: API client ID (Classic or Modern)
#   Parameter 5: API client secret
#   Parameter 6: Single / Migrate action
#   Parameter 7: JAMF Static Group name
# 	Parameter 8: Action to take on group (Add/Remove)
#	Parameter 9: Show the dialog window (Yes/No)
#   Parameter 10: View / Migrate groups
#   Parameter 11: Admin access (wether or not user can choose any machine)
#
# 1.0 - Initial
# 1.1 - Add function to make sure Client / Secret are passed into the script
# 1.2 - Added options to pass group action (Add/Remove) and whether or not to show to selection window
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 2.0 - Add option to do a copy of group membership from one computer to another
# 2.1 - Optimized header variables section
#       Optimized some JAMF functions for faster processing

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
declare DIALOG_PROCESS
SCRIPT_NAME="JAMFStaticGroupUtility"
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
MIN_SD_REQUIRED_VERSION="2.5.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX")
DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")
chmod 666 $JSON_DIALOG_BLOB
chmod 666 $DIALOG_COMMAND_FILE

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}JAMF Static Group Utility"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="${ICON_FILES}ToolbarCustomizeIcon.icns"
HELP_MESSAGE="**Single Group Method**<br> \
1.  Select the group<br> \
2.  Type in the HOSTNAME of the device<br> \
3.  Chose Action to perform<br> \
    1.  (Add) device to group<br> \
    2.  (Delete) device from group<br> \
    3.  (View) see if device is group<br><br> \
**Migrate Options**<br><br> \
1. Select (Old) System to migrate FROM<br> \
2. Select (New) system to migrate TO<br>"
 

# Trigger installs for Images & icons

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
CLIENT_ID="${4}"           
CLIENT_SECRET="${5}"
REQUEST_TYPE=${6:-"single"} # single/migrate
JAMF_GROUP_NAME=${7}          
JAMF_GROUP_ACTION=${8:-"Add"}
SHOW_WINDOW=${9:-"Yes"}  
ACTION_TAKEN=${10:-"view"} #view or migrate groups
ACCESS_TYPE=${11:-""} #Wether or not user can choose any machine

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine which JAMF credentials we are using

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
    # PARAMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
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
	SD_INFO_BOX_MSG+="{osname} {osversion}<br>"
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
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
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* || -z $retval ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
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
    # PARAMS: None
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
    # PARAMS: None
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

function JAMF_retrieve_static_group_id ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID # of static group
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static group name
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computer-groups/static-groups?page=0&page-size=100&sort=id%3Aasc&filter=name%3D%3D%22"${1}%22)
    printf "%s" $tmp | jq -r '.results[].id'
}

function JAMF_retrieve_static_group_members ()
{
    # PURPOSE: Retrieve the members of a static group
    # RETURN: array of members
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static group ID
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}JSSResource/computergroups/id/${1}")
    printf "%s" "$tmp" 
}

function JAMF_static_group_action_by_serial ()
{
    # PURPOSE: Write out the changes to the static group
    # RETURN: None
    # Expected jamfprourl, api_token, JAMFjson_BLOB
    # PARAMETERS: $1 = JAMF Static group id
    #            $2 - Serial # of device
    #            $3 = Acton to take "Add/Remove"
    declare apiData
    declare tmp


    if [[ ${3:l} == "remove" ]]; then
        apiData="<computer_group><computer_deletions><computer><name>${2}</name></computer></computer_deletions></computer_group>"
    else
        apiData="<computer_group><computer_additions><computer><name>${2}</name></computer></computer_additions></computer_group>"
    fi

    ## curl call to the API to add the computer to the provided group ID
    tmp=$(/usr/bin/curl -s -f -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/xml" "${jamfpro_url}JSSResource/computergroups/id/${1}" -X PUT -d "${apiData}")
    #Evaluate the responses
    if [[ "$tmp" = *"<id>${1}</id>"* ]]; then

        retval="Successful $3 of $2 on group"
        logMe "$retval" 1>&2
    elif [[ $tmp == *"409"* ]]; then
        retval="$2 Not a member of group"
        logMe "$retval" 1>&2
    else
        retval="API Error #$? has occurred while try to $3 $2 to group"
        logMe "$retval" 1>&2
    fi
    printf "%s" "$retval" 
}

function JAMF_get_inventory_record ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: The inventory record in JSON format
    # PARAMS:  $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $2 - Filter condition to use for search

    filter=$(convert_to_hex $2)
    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computers-inventory?section=$1&filter=$filter" 2>/dev/null)
    printf "%s" "$retval"    
}

function JAMF_retrieve_data_blob ()
{    
    # PURPOSE: Extract the summary of the JAMF command results
    # RETURN: XML contents of command
    # PARAMETERS: $1 = The API command of the JAMF attribute to read
    #            $2 = format to return XML or JSON
    #            $3 = JSON filter to use    
    # EXPECTED: 
    #   JAMF_COMMAND_SUMMARY - specific JAMF API call to execute
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server 

    local format="${2:-xml}"
    local retval
    
    retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}")
    case "${retval}"" in
        *"INVALID_ID"* ) retval="INVALID_ID" ;;
        *"PRIVILEGE"* ) retval="ERR" ;;
        *) [[ ! -z $3 ]] && retval=$(echo -E "$retval" | jq  '[.[] | select('$3')]') ;;
    esac
    printf "%s" "$retval"
}

function convert_to_hex ()
{
    local input="$1"
    local length="${#input}"
    local result=""

    for (( i = 0; i <= length; i++ )); do
        local char="${input[i]}"
        if [[ "$char" =~ [^a-zA-Z0-9.] ]]; then
            hex=$(printf '%x' "'$char")
            result+="%$hex"
        else
            result+="$char"
        fi
    done

    printf "%s" "$result"
}

function convert_to_array () 
{
    IFS=',' read -r -A array <<< "$1"
    # Remove surrounding quotes from each element
    for i in "${!array[@]}"; do
        array[$i]="${array[$i]//\"/}"
    done
    printf "%s" "${array[1]}"
}

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function create_listitem_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},
    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title 
    #        $2 - icon
    #        $3 - status text (for display)
    #        $4 - status
    #        $5 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    [[ "$5:l" == "first" ]] && line+='"button1disabled" : "true", "listitem" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    [[ "$5:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - type of data to parse XML or JSON
    #        #3 - string / key to parse for list items
    #        $4 - string to parse for list items
    #        $5 - Option icon to show
    # EXPECTED: None

    declare xml_blob
    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is JSON, then parse the JSON data
        xml_blob=$(echo -E $4 | jq -r $3)
    else
        # If the second parameter is XML, then parse the XML data
        xml_blob=$(echo $4 | xmllint --xpath '//'$3 - 2>/dev/null)
    fi

    echo $xml_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo "$line" | sed 's/[[:space:]]*$//')
        if [[ $line == $hostName ]]; then
            create_listitem_message_body "$line" "$5" "Found" "success"
        else
            create_listitem_message_body "$line" "$5" "" ""
        fi
    done
    create_listitem_message_body "" "" "" "" "last"
    ${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null
}

function create_dropdown_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - values (comma separated list)
    #        $3 - default item
    #        $4 - first or last - construct appropriate listitem heders / footers
    #        $5 - Trailing closure commands
    #        $6 - Name of dropdown item

    declare line && line=""
  
    [[ "$4:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2']'
    [[ ! -z $3 ]] && line+=', "default" : "'$3'"'
    [[ ! -z $6 ]] && line+=', "name" : "'$6'", "required" : "true", '
    [[ ! -z $5 ]] && line+="$5"
    [[ "$4:l" == "last" ]] && line+='],'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_dropdown_list ()
{
    # PURPOSE: Create the dropdown list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARAMS: $1 - message to be displayed on the window
    #        $2 - type of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    # EXPECTED: None
    declare -a array

    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_dropdown_message_body "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is XML, then parse the XML data
        xml_blob=$(echo -E $4 | jq -r '.results[]'$3)
    else
        # If the second parameter is JSON, then parse the JSON data
        xml_blob=$(echo $4 | xmllint --xpath '//'$3 - 2) #>/dev/null)
    fi
    
    echo $xml_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo $line | sed 's/[[:space:]]*$//')
        array+='"'$line'",'
    done
    # Remove the trailing comma from the array
    array="${array%,}"
    create_dropdown_message_body "Select Groups:" "$array" "last"

    #create_dropdown_message_body "" "" "last"
    update_display_list "Create"
}

function construct_dropdown_list_items ()
{
    # PURPOSE: Construct the list of items for the dropdown menu
    # RETURN: formatted list of items
    # EXPECTED: None
    # PRAMS: $1 - JSON variable to parse
    #        $2 - JSON Blob name

    declare json_blob
    declare line
    json_blob=$(echo -E $1 |jq -r ${2})
    echo $json_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo $line | sed 's/[[:space:]]*$//')
        array+='"'$line'",'
    done
    # Remove the trailing comma from the array
    array="${array%,}"
    echo $array
}

function create_textfield_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARAMS: $1 - item name (internal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem headers / footers

    declare line && line=""
    declare today && today=$(date +"%m/%d/%y")

    [[ "$3:l" == "first" ]] && line+='"textfield" : ['
    [[ ! -z $1 ]] && line+='{"name" : "'$1'", "title" : "'$2'", "required" : "true" },'
    [[ "$3:l" == "last" ]] && line+=']'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_radio_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARAMS: $1 - item name (internal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem headers / footers

    declare line && line=""

    [[ "$3:l" == "first" ]] && line+='"selectitems" :[ {"title" : "'$2'", { "values" : ['
    [[ ! -z $1 ]] && line+='"'$1'",'
    [[ "$3:l" == "last" ]] && line+='], "style" : "radio"}]'
    echo $line >> ${JSON_DIALOG_BLOB}
}

####################################################################################################
#
# App Specific Functions
#
####################################################################################################

function construct_dialog_header_settings ()
{
    # Construct the basic Swift Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARAMS Passed: $1 is message to be displayed on the window

    case "${REQUEST_TYPE:l}-${ACTION_TAKEN:l}" in
        "migrate-view" )
            buttons='"button1text" : "OK",  "button2text" : "Cancel",'
            ;;
        "migrate-migrate" )
            buttons='"button1text" : "Migrate", "button2text" : "Quit",'
            ;;
        "single-view" )
            buttons='"button1text" : "OK",  "button2text" : "Cancel",'
            ;;
        * )
            buttons='"button1text" : "OK",  "button2text" : "Cancel",'
            ;;
    esac
    tmp='{
    "icon" : "'${SD_ICON_FILE}'",
    "overlayicon" : "'${OVERLAY_ICON}'",
    "message" : "'$1'",
    "bannerimage" : "'${SD_BANNER_IMAGE}'",
    "bannertitle" : "'${SD_WINDOW_TITLE}'",
    "infobox" : "'${SD_INFO_BOX_MSG}'",
    "titlefont" : "shadow=1",
    "helpmessage" : "'$HELP_MESSAGE'",
    "moveable" : "true",
    "quitkey" : "0",
    "ontop" : "true",
    "width" : 840,
    "height" : 660,
    "json" : "true",
    "quitkey" : "0",
    "messageposition" : "top",'
    tmp+=$buttons
    echo $tmp
}

function update_display_list ()
{
	# Function to handle various aspects of the Swift Dialog behaviour
    #
    # RETURN: None
	# VARIABLES expected: JSON_DIALOG_BLOB & Window variables should be set
	# PARMS List
	#
	# #1 - Action to be done ("Create, Destroy, "Update", "change")
	# #2 - Progress bar % (pass as integer)
	# #3 - Application Title (must match the name in the dialog list entry)
	# #4 - Progress Text (text to be display on bottom on window)
	# #5 - Progress indicator (wait, success, fail, pending)
	# #6 - List Item Text (text to be displayed while updating list entry)

	## i.e. update_display_list "Update" "8" "Google Chrome" "Calculating Chrome" "pending" "Working..."
	## i.e.	update_display_list "Update" "8" "Google Chrome" "" "success" "Done"

	case "$1:l" in

        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            /bin/echo "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "listcreate" )
            /bin/echo "listitem: show" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "create" )

            #
            # Create the progress bar
            #

            ${SW_DIALOG} \
                --progress \
                --jsonfile "${JSON_DIALOG_BLOB}" \
                --commandfile ${DIALOG_COMMAND_FILE} \
                --height 800 \
                --width 920 & 
                dialogPID=$!
                #/bin/sleep .2
            ;;
        "buttonenable" )

                # Enable button 1
                /bin/echo "button1: enable" >> "${DIALOG_COMMAND_FILE}"
                ;;

        "destroy" )
        
            #
            # Kill the progress bar and clean up
            #
            echo "quit:" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonchange" )

            # change text of button 1
            /bin/echo "button1text: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar
            /bin/echo "listitem: title: "$3", status: $5, statustext: $6" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progress: $2" >> "${DIALOG_COMMAND_FILE}"

            /bin/sleep .5
            ;;

        "progress" )

            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: ${5}" >> "${DIALOG_COMMAND_FILE}"
            ;;

	esac
}

function retrieve_user_systems ()
{
    # Retrieve all of the systems assigned to the current user
    #
    # RETURN: Array of Assigned computers
    local userName
    local tmp
    local -a tmp_array

    if [[ ${ACCESS_TYPE:l} == "admin" ]]; then
        # Once we have their JAMF username, then scan for all registered devices
        tmp=$(JAMF_get_inventory_record "GENERAL" "" | jq -r '.results[].general.name')
    else
        # Find the current logged in user's serial # and search on that to find their JAMF user name
        userName=$(JAMF_get_inventory_record "USER_AND_LOCATION" "general.name=='$MAC_HOST_NAME'" | jq -r '.results[].userAndLocation.username')

        # Once we have their JAMF username, then scan for all registered devices belonging to that user
        tmp=$(JAMF_get_inventory_record "GENERAL" "userAndLocation.username=='$userName'" | jq -r '.results[].general.name')
    fi
    # Take the output of the file and convert each element into an array and then format it for SD ("element 1", "element 2, "element 3").  This method will retain spaces in system names
    while IFS= read -r line; do
        tmp_array+=("\"$line\"")
    done <<< "$tmp"
    tmp_array=$(printf "%s," "${tmp_array[@]}" | sed -E 's/&quot;//g; s/,$//')
    echo $tmp_array
}

function display_msg_single ()
{
    # Retrieve the list of static groups from JAMF
    GroupList=$(JAMF_retrieve_data_blob "api/v2/computer-groups/static-groups?page=0&page-size=100&sort=id%3Aasc" "json")

    # IF the group name is not passed in, show a list of choices
    if [[ -z $JAMF_GROUP_NAME ]]; then
        message="Please select the static group from the list below and the action that you want to perform on the members"
        construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"
        create_dropdown_message_body "" "" "" "first"
        array=$(construct_dropdown_list_items $GroupList '.results[].name')
        create_dropdown_message_body "Select Group:" "$array" ""
        echo "}," >> $JSON_DIALOG_BLOB
    else
        message="From the static group listed below, choose the action that you want to perform on the members<br><br>Select Group:     **$JAMF_GROUP_NAME**"
        construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"
        echo '"selectitems" : [' >> ${JSON_DIALOG_BLOB}
    fi

    # Construct the possible ations
    echo '{ "title" : "Group Action:", "values" : [' >> ${JSON_DIALOG_BLOB}
    create_radio_message_body "View Users" ""
    create_radio_message_body "Add Users" ""
    create_radio_message_body "Remove Users" "" "last"
    echo "," >> "${JSON_DIALOG_BLOB}"

    # And ask for the host name
    create_textfield_message_body "HostName" "Computer Hostname" "first"
    create_textfield_message_body "" "" "last"
    echo "}" >> "${JSON_DIALOG_BLOB}"

    # Show the screen and get the results
    temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}" --vieworder "dropdown, radiobutton, listitem, textfield") 2>/dev/null
    returnCode=$?

    selectedGroup=$(echo $temp |  jq -r '."Select Group:".selectedValue')
    [[ ! -z $JAMF_GROUP_NAME ]] && selectedGroup=$JAMF_GROUP_NAME
    action=$(echo $temp |  jq -r '."Group Action:".selectedValue')
    hostName=$(echo $temp |  jq -r '."HostName"')

}

function show_system_choices ()
{
    # PURPOSE: Consruct the dialog box to show the user and ask for system info
    # RETURN: olSystem & newSystem will be populated if user continues
    # EXPECTED: message
    # PARMS: $1 - System(s) found assigned to user
    if [[ "{$ACTION_TAKEN:l}" = *"view"* ]]; then
        message="$SD_DIALOG_GREETING, $SD_FIRST_NAME. Please select the system that you want to view and the next screen will display the results of the group memebership."
    else
        message="$SD_DIALOG_GREETING, $SD_FIRST_NAME. When you receive a new computer, you may need to access certain applications that are already linked to your account. This migration tool is here to help by ensuring your new computer is connected to the same application groups you had on your previous computer.<br><br>Please select your Old and New system, and click on 'Migrate'."
    fi
    construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"
    create_dropdown_message_body "" "" "" "first"
    create_dropdown_message_body "Old Computer Name" "$userSystems" "$MAC_HOST_NAME" "" "}," "oldsystem"

    if [[ "{$ACTION_TAKEN:l}" = *"migrate"* ]]; then
        create_dropdown_message_body "New Computer Name" "$userSystems" "" "" "}," "newsystem"
    fi
    
    create_dropdown_message_body "" "" "" "last" ""
    echo "}" >> $JSON_DIALOG_BLOB

    # Show the screen and get the results
    temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null)
    buttonpress=$?
    [[ $buttonpress == 2 ]] && {JAMF_invalidate_token; cleanup_and_exit;}

    oldSystem=$(echo $temp | jq -r '.oldsystem.selectedValue')
    newSystem=$(echo $temp | jq -r '.newsystem.selectedValue')
}

function display_msg_migrate ()
{
    # PURPOSE: Show the list of groups that the user belongs to
    # RETURN: None
    # EXPECTED: staticGroupIDs should be populated with group IDs
    # PARMS: None

    if [[ "{$ACTION_TAKEN:l}" = *"migrate"* ]]; then
        message="${oldSystem} is a member of the following group(s).  If this looks correct, click on OK to add ${newSystem} to these groups, otherwsise click on Quit and contact the TSD for assistance."
    else
        message="${oldSystem} is a member of the following group(s)"
    fi
    construct_dialog_header_settings $message > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "-- Static Group Membership --" "" "" "" "first"
    create_listitem_message_body "" "" "" "" "last"

    update_display_list "Create"
    # Loop thru each group ID and see if their system is a member of that group
    i=1
    membersofGroup=()
    groupNumbers=()

    while (( i < ${#staticGroupIDs[@]} )); do
        group_id=${staticGroupIDs[i]}
        groupMembers=$(JAMF_retrieve_static_group_members $group_id)
        if [[ $(echo $groupMembers | grep $oldSystem) ]]; then
            update_display_list "add" "${staticGroupName[i]}" "success" ""
            #This system is part of a static group so add it to the member array
            groupNumbers+=($group_id)
            membersofGroup+=($staticGroupName[i])
        fi
        ((i++))
    done

    update_display_list "progress" "" "" "" "$oldSystem is a member of ${#membersofGroup[@]} groups" 100
    update_display_list "buttonenable"
    # Now that the list is created, show on the screen what groups the user is in
    wait "$dialogPID"
    buttonpress=$?
    [[ $buttonpress == 2 ]] && {JAMF_invalidate_token; cleanup_and_exit 0;}
    groupNumbers=(${(z)groupNumbers})
}

function static_group_single ()
{
    # PURPOSE: Allow the user to perform actions on a single static group
    # RETURN: None
    # EXPECTED: None
    # PARMS: None 
    # If they want to show the window then do so, otherwise set the action to their passed in action
    declare retval
    if [[ "${SHOW_WINDOW:l}" == "yes" ]]; then
        display_msg_single
    else
        selectedGroup=${JAMF_GROUP_NAME}
        action=${JAMF_GROUP_ACTION}
        hostName=${MAC_HOSTNAME}
    fi
    # Convert any special characters in the filter name to hex so that it can be used correctly in the JAMF search
    hexGroupName=$(convert_to_hex $selectedGroup)
    groupID=$(JAMF_retrieve_static_group_id "$hexGroupName")
    case "${action:l}" in
        *"add"* )
            logMe "Adding $hostName to $groupID"
            retval=$(JAMF_static_group_action_by_serial $groupID $hostName "add")
            progressResults+=("${retval} $selectedGroup<br>")
            ;;

        *"remove"* )
            logMe "Removing $hostName from $groupID"
            retval=$(JAMF_static_group_action_by_serial $groupID $hostName "remove")
            progressResults+=("${retval} $selectedGroup<br>")
            ;;

        *"view"* )
            memberList=$(JAMF_retrieve_static_group_members $groupID)
            [[ "${memberList}" == *"${hostName}"* ]] && hostnameFound="is" || hostnameFound="is not"
            create_listitem_list "The following are the members of <br>**$selectedGroup**.<br><br>The computer *$hostnameFound* in this group." "json" ".computer_group.computers[].name" "$memberList" "SF=desktopcomputer.and.macbook"
            ;;
        *)
            logMe "No action taken"
            ;;
    esac
}

function static_group_multiple ()
{
    # PURPOSE: Allow the user to migrate one computer groups to another
    # RETURN: None
    # EXPECTED: None
    # PARMS: None 
    declare JAMF_API_KEY="api/v2/computer-groups/static-groups"

    # Retrieve the sytem(s) assigned to user and show the migrate/view options
    userSystems=$(retrieve_user_systems)

    show_system_choices $userSystems
    # Script continues if user choose not to quit

    groupBlob=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json" "")
    # Now the we have the static group complete list, we need to search for the membership of each group ID
    # this has to use the Classic API for this

    staticGroupIDs=($(echo $groupBlob | jq -r '.results[].id'))
    results=$(echo $groupBlob | jq -r '.results[].name')
    # take the results and put them into a proper array format
    staticGroupName=(${(f@)results})

    display_msg_migrate

    if [[ "{$ACTION_TAKEN:l}" == *"migrate"* ]]; then

        # Write out the new System to the groups
        i=1
        while (( i <= ${#groupNumbers[@]} )); do
            echo "Adding $newSystem to $groupNumbers[i] ($membersofGroup[i])"
            retval=$(JAMF_static_group_action_by_serial $groupNumbers[i] $newSystem "Add")
            progressResults+=("${retval} $membersofGroup[i])<br>")
            ((i++))
        done
    fi
}
####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare api_token
declare jamfpro_url
declare selectedGroup
declare action
declare hostName
declare -a json_BLOB
declare -a groupNumbers
declare oldSystem
declare newSystem
declare dialogPID
declare membersofGroup
declare -a progressResults

# If you want to use the SS/SS+ is an overlay icon, uncomment this line
#OVERLAY_ICON=$(JAMF_which_self_service)

create_log_directory
check_swift_dialog_install
check_support_files
JAMF_check_connection
JAMF_get_server
JAMF_check_credentials

# Check if the JAMF Pro server is using the new API or the classic API
# If the client ID is longer than 30 characters, then it is using the new API
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token   

# Determine if this is a single or migrate request
if [[ "${REQUEST_TYPE:l}" == "single" ]]; then
    static_group_single
else
    static_group_multiple
fi

JAMF_invalidate_token

# Show the reults if there are any
if [[ ! -z $progressResults ]]; then
    combined_string="${(@j::)progressResults}"
    ${SW_DIALOG} \
        --title "Static Group Results" \
        --icon ${SD_ICON_FILE} \
        --message "$combined_string" \
        --messagefont "size=12" \
        --ontop
fi
cleanup_and_exit 0