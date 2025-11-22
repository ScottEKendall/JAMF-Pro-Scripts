#!/bin/zsh --no-rcs
#
# JAMFStaticGroupUtility.sh
#
# by: Scott Kendall
#
# Written: 10/09/2025
# Last updated: 11/22/2025
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
#   Parameter 6: JAMF Static Group name
# 	Parameter 7: Action to take on group (Add/Remove)
#	Parameter 8: Show the dialog window (Yes/No)
#
# 1.0 - Initial
# 1.1 - Add function to make sure Client / Secret are passed into the script
# 1.2 - Added options to pass group action (Add/Remove) and whether or not to show to selection window
# 1.3 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
SCRIPT_NAME="JAMFStaticGroupUtility"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_HOST_NAME=$(hostname -d)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)

chmod 666 $JSON_DIALOG_BLOB

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Static Group Modification"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="${ICON_FILES}ToolbarCustomizeIcon.icns"

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
CLIENT_ID="${4}"           
CLIENT_SECRET="${5}"
JAMF_GROUP_NAME=${6}          
JAMF_GROUP_ACTION=${7:-"Add"}
SHOW_WINDOW=${8:-"Yes"}  

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
    [[ $retval == *"does not exist"* ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
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

function JAMF_retrieve_static_group_members ()
{
    # PURPOSE: Retrieve the members of a static group
    # RETURN: array of members
    # EXPECTED: jamfpro_url, api_token
    # PARMATERS: $1 = JAMF Static group ID
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}JSSResource/computergroups/id/${1}")
    echo $tmp #| jq -r '.computer_group.computers[].name'
}

function JAMF_static_group_action ()
{
    # PURPOSE: Write out the changes to the static group
    # RETURN: None
    # Expected jamfprourl, api_token, JAMFjson_BLOB
    # PARMATERS: $1 = JAMF Static group id
    #            $2 - Serial # of device
    #            $3 = Acton to take "Add/Remove"
    declare apiData

    if [[ ${3:l} == "remove" ]]; then
        apiData="<computer_group><computer_deletions><computer><serial_number>${MAC_SERIAL}</serial_number></computer></computer_deletions></computer_group>"
    else
        apiData="<computer_group><computer_additions><computer><serial_number>${MAC_SERIAL}</serial_number></computer></computer_additions></computer_group>"
    fi
    ## curl call to the API to add the computer to the provided group ID
    retval=$(/usr/bin/curl -s -f -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/xml" "${jamfpro_url}JSSResource/computergroups/id/${1}" -X PUT -d "${apiData}")
    # Check API response
    [[ $retval == *"409"* ]] && echo "ERROR: System not in group" 1>&2
    [[ $? -eq 0 ]] && return 0 || return 1
}

function JAMF_get_inventory_record()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: The inventory record in JSON format
    # PARMS:  $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $2 - Filter condition to use for search

    filter=$(convert_to_hex $2)
    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computers-inventory?section=$1&filter=$filter" 2>/dev/null)
    echo $retval | tr -d '\n'
}
    function JAMF_retreive_static_group_id ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID # of static group
    # EXPECTED: jamfpro_url, api_token
    # PARMATERS: $1 = JAMF Static group name
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computer-groups/static-groups?page=0&page-size=100&sort=id%3Aasc&filter=name%3D%3D%22"${1}%22)
    echo $tmp | jq -r '.results[].id'
}
}

function JAMF_retrieve_data_blob ()
{    
    # PURPOSE: Extract the summary of the JAMF conmand results
    # RETURN: XML contents of command
    # PARAMTERS: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   JAMF_COMMAND_SUMMARY - specific JAMF API call to execute
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server  

    declare format=$2
    [[ -z "${format}" ]] && format="xml"
    retval=$(echo -E $(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}" ))
    echo $retval
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

    echo "$result"
}

function convert_to_array() 
{
    IFS=',' read -r -A array <<< "$1"
    # Remove surrounding quotes from each element
    for i in "${!array[@]}"; do
        array[$i]="${array[$i]//\"/}"
    done
    echo "${array[1]}"
}

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - tyoe of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    #        $5 - Option icon to show
    # EXPECTED: None

    declare xml_blob
    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is JSON, then parse the XML data
        xml_blob=$(echo -E $4 | jq -r "${3}")
    else
        # If the second parameter is XML, then parse the JSON data
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

    [[ "$5:l" == "first" ]] && line+='"listitem" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    [[ "$5:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function construct_dialog_header_settings ()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
    "icon" : "'${SD_ICON_FILE}'",
    "overlayicon" : "'${OVERLAY_ICON}'",
    "message" : "'$1'",
    "bannerimage" : "'${SD_BANNER_IMAGE}'",
    "bannertitle" : "'${SD_WINDOW_TITLE}'",
    "infobox" : "'${SD_INFO_BOX_MSG}'",
    "titlefont" : "shadow=1",
    "button1text" : "OK",
    "button2text" : "Cancel",
    "moveable" : "true",
    "quitkey" : "0",
    "ontop" : "true",
    "width" : 800,
    "height" : 540,
    "json" : "true",
    "quitkey" : "0",
    "messagefont" : "shadow=1",
    "messageposition" : "top",'
}

function create_radio_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - item name (interal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    [[ "$3:l" == "first" ]] && line+='"selectitems" :[ {"title" : "'$2'", { "values" : ['
    [[ ! -z $1 ]] && line+='"'$1'",'
    [[ "$3:l" == "last" ]] && line+='], "style" : "radio"}]'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_dropdown_list ()
{
    # PURPOSE: Create the dropdown list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - tyoe of data to parse XML or JSON
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

function create_dropdown_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - values (comma separated list)
    #        $3 - first or last - construct appropriate listitem heders / footers
    #        $4 - Required (Yes/No)

    declare line && line=""

    [[ "$3:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2']},'
    [[ "$3:l" == "last" ]] && line+=']'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function construct_dropdown_list_items ()
{
    # PURPOSE: Construct the list of items for the dropdowb menu
    # RETURN: formatted list of items
    # EXPECTED: None
    # PARMS: $1 - JSON variable to parse
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
    # PARMS: $1 - item name (interal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem heders / footers

    declare line && line=""
    declare today && today=$(date +"%m/%d/%y")

    [[ "$3:l" == "first" ]] && line+='"textfield" : ['
    [[ ! -z $1 ]] && line+='{"name" : "'$1'", "title" : "'$2'", "required" : "true" },'
    [[ "$3:l" == "last" ]] && line+=']'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function displaymsg ()
{
    # Retrieve the list of static groups from JAMF
    GroupList=$(JAMF_retrieve_data_blob "api/v2/computer-groups/static-groups?page=0&page-size=100&sort=id%3Aasc" "json")

    # IF the group name is not passed in, show a list of choices
    if [[ -z $JAMF_GROUP_NAME ]]; then
        message="Please select the static group from the list below and the action that you want to perform on the members"
        construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"
        create_dropdown_message_body "" "" "first"
        array=$(construct_dropdown_list_items $GroupList '.results[].name')
        create_dropdown_message_body "Select Group:" "$array"
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



create_log_directory
check_swift_dialog_install
check_support_files
JAMF_check_connection
JAMF_get_server
JAMF_check_credentials

# Check if the JAMF Pro server is using the new API or the classic API
# If the client ID is longer than 30 characters, then it is using the new API
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token   
#OVERLAY_ICON=$(JAMF_which_self_service)

# If they want to show the window then do so, otherwise set the action to their passed in action
if [[ "${SHOW_WINDOW:l}" == "yes" ]]; then
    displaymsg
else
    selectedGroup=${JAMF_GROUP_NAME}
    action=${JAMF_GROUP_ACTION}
    hostName=${MAC_HOSTNAME}
fi
# Convert any special characters in the filter name to hex so that it can be used correctly in the JAMF search
hexGroupName=$(convert_to_hex $selectedGroup)
groupID=$(JAMF_retreive_static_group_id "$hexGroupName")

case "${action:l}" in
    *"add"* )
        JAMF_static_group_action $groupID $hostName "Add"
        ;;

    *"remove"* )
        JAMF_static_group_action $groupID $hostName "Remove"
        ;;

    *"view"* )
        memberList=$(JAMF_retrieve_static_group_members $groupID)
        [[ "${memberList}" == *"${hostName}"* ]] && hostnameFound="is" || hostnameFound="is not"
        create_listitem_list "The following are the members of **$selectedGroup**.<br>The computer *$hostnameFound* in this group." "json" ".computer_group.computers[].name" "$memberList" #"SF=desktopcomputer.and.macbook"
        ;;
    *)
        logMe "No action taken"
        ;;
esac
JAMF_invalidate_token
cleanup_and_exit 0
