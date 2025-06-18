#!/bin/zsh
#
# JAMFBackupUtilities
#
# by: Scott Kendall
#
# Written: 06/03/2025
# Last updated: 06/03/2025
#
# Script Purpose: This script will extract all of the email addresses from your JAMF server and store them in local folder in a VCF format.
#
# 1.0 - Initial
# 2.0 - Added options to export Smart /Static groups, 
#       export VCF cards for specific groups
#       send email to specific groups
#       added support for JAMF Pro OAuth API
# 2.1 - Added variable EMAIL_APP to allow users to choose which email app to use (have to use the bundle identifier)
# 2.2 - Added option to export Application Usage

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

OS_PLATFORM=$(/usr/bin/uname -p)

[[ "$OS_PLATFORM" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/logs"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.5.0"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
JQ_INSTALL_POLICY="install_jq"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BACKGROUND_TASKS=20 # Number of background tasks to run in parallel

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}JAMF System Admin Tools"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/JAMFSystemUtilities.log"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="/Applications/Self Service.app"
JSON_DIALOG_BLOB=$(mktemp /var/tmp/JAMFSystemUtilities.XXXXX)
DIALOG_CMD_FILE=$(mktemp /var/tmp/JAMFSystemUtilities.XXXXX)
# Use the bundle identifier of your email app. you can find it by this command "osascript -e 'id of app "<appname>"' "
EMAIL_APP='com.microsoft.outlook'
/bin/chmod 666 $JSON_DIALOG_BLOB
/bin/chmod 666 $DIALOG_CMD_FILE

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   
CLIENT_ID="$4"
CLIENT_SECRET="$5"

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with JAMF creentials we are using

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
	exit 0
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
  
            /bin/echo "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_CMD_FILE}"
            ;;

        "create" )

            #
            # Create the progress bar
            #

            ${SW_DIALOG} \
                --progress \
                --jsonfile "${JSON_DIALOG_BLOB}" \
                --commandfile ${DIALOG_CMD_FILE} \
                --height 800 \
                --width 920 & /bin/sleep .2
            ;;
        "buttonenable" )

                # Enable button 1
                /bin/echo "button1: enable" >> "${DIALOG_CMD_FILE}"
                ;;

        "destroy" )
        
            #
            # Kill the progress bar and clean up
            #
            echo "quit:" >> "${DIALOG_CMD_FILE}"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar
            /bin/echo "listitem: title: "$3", status: $5, statustext: $6" >> "${DIALOG_CMD_FILE}"
            /bin/echo "progress: $2" >> "${DIALOG_CMD_FILE}"

            /bin/sleep .5
            ;;

        "progress" )

            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            /bin/echo "progress: ${6}" >> "${DIALOG_CMD_FILE}"
            /bin/echo "progresstext: ${5}" >> "${DIALOG_CMD_FILE}"
            ;;
            
	esac
}

function extract_xml_data ()
{
    declare -a retval
    # PURPOSE: extract an XML string from the passed string
    # RETURN: parsed XML string
    # PARAMETERS: $1 - XML "blob"
    #             $2 - String to extract
    # EXPECTED: None
    retval=$(echo "$1" | xmllint --xpath "//$2/text()" - 2>/dev/null)
    echo $retval
}

function make_apfs_safe ()
{
    # PURPOSE: Remove any "illegal" APFS macOS characters from filename
    # RETURN: ADFS safe filename
    # PARAMETERS: $1 - string to format
    # EXPECTED: None
    echo $(echo "$1" | sed -e 's/:/_/g' -e 's/|/-/g') #-e 's/\//-/g'
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

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function construct_dialog_header_settings ()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
		"icon" : "'${SD_ICON_FILE}'",
		"message" : "'$1'",
		"bannerimage" : "'${SD_BANNER_IMAGE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : "true",
		"bannertitle" : "'${SD_WINDOW_TITLE}'",
		"titlefont" : "shadow=1",
		"button1text" : "OK",
		"moveable" : "true",
        "json" : "true", 
		"quitkey" : "0",
		"messageposition" : "top",'
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - tyoe of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    # EXPECTED: None

    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is XML, then parse the XML data
        xml_blob=$(echo $4 | jq -r '.results[]'$3)
    else
        # If the second parameter is JSON, then parse the JSON data
        xml_blob=$(echo $4 | xmllint --xpath '//'$3 - 2) #>/dev/null)
    fi

    echo $xml_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo $line | sed 's/[[:space:]]*$//')
        create_listitem_message_body "$line" "" "pending" "Pending..."
    done
    create_listitem_message_body "" "" "" "" "last"
    update_display_list "Create"
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

    [[ "$5:l" == "first" ]] && line+='"button1disabled" : "true", "listitem" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    [[ "$5:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
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
    [[ ! -z $1 ]] && line+='{"name" : "'$1'", "title" : "'$2'", "isdate" : "true", "required" : "true", "value" : "'$today'" },'
    [[ "$3:l" == "last" ]] && line+=']'
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
        xml_blob=$(echo $4 | jq -r '.results[]'$3)
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
    # PARMS: $1 - XML variable to parse 
    declare xml_blob
    declare line
    xml_blob=$(echo $1 |jq -r '.computer_groups[] | "\(.id) - \(.name)"')
    echo $xml_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo $line | sed 's/[[:space:]]*$//')
        array+='"'$line'",'
    done
    # Remove the trailing comma from the array
    array="${array%,}"
    echo $array
}

function create_checkbox_message_body ()
{
    # PURPOSE: Construct a checkbox style body of the dialog box
    #"checkbox" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - name (intenral reference)
    #        $3 - icon
    #        $4 - Default Checked (true/false)
    #        $5 - disabled (true/false)
    #        $6 - first or last - construct appropriate listitem heders / footers

    declare line && line=""
    [[ "$6:l" == "first" ]] && line+=' "checkbox" : ['
    [[ ! -z $1 ]] && line+='{"name" : "'$2'", "label" : "'$1'", "icon" : "'$3'", "checked" : "'$4'", "disabled" : "'$5'"},'
    [[ "$6:l" == "last" ]] && line+='] ' #,"checkboxstyle" : {"style" : "switch", "size"  : "small"}'
    echo $line >> ${JSON_DIALOG_BLOB}
}

###########################
#
# JAMF functions
#
###########################

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
    echo $(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}" )
}

function JAMF_retrieve_data_blob_global ()
{    
    # PURPOSE: Extract the summary of the JAMF conmand results
    # RETURN: XML contents of command
    # PARAMTERS: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   api_token - base64 hex code of your bearer token
    #  jamppro_url - the URL of your JAMF server
    
    declare format=$2
    [[ -z "${format}" ]] && format="xml"
    xmlBlob=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}")
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
    retval=$(/usr/bin/curl -s --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/computers-inventory?section=$1&filter=$filter" 2>/dev/null)
    echo $retval | tr -d '\n'
}

function JAMF_get_inventory_record_byID ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - The JAMF ID of the device to retrieve
    #        $2 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $3 - Filter to use for search

    retval=$(/usr/bin/curl -s --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/computers-inventory/$1?section=$2" 2>/dev/null)
    echo $retval | tr -d '\n'
}

function JAMF_clear_failed_mdm_commands()
{
    # PURPOSE: clear failed MDM commands for the computer in Jamf Pro
    # RETURN: None
    # Expected jamfpro_url, api_token, ID
    
    response=$(curl -s -X DELETE "${jamfpro_url}JSSResource/commandflush/computers/id/$1/status/Failed" -H "Authorization: Bearer $api_token")
    logMe "Clear MDM Commands Response: $response"
}

###############################################
#
# Backup Self Service Icons functions
#
###############################################

function backup_ss_icons ()
{
    declare tasks=()
    declare logMsg

    # PURPOSE: Backup all of the Self Service icons from JAMF
    logMe "Backing up Self Service icons"
    PolicyList=$(JAMF_retrieve_data_blob "JSSResource/policies" "xml" )
    create_listitem_list "The following Self Service icons are being downloaded from JAMF" "xml" "name" "$PolicyList"

    PolicyIDList=$(echo $PolicyList | xmllint --xpath '//id' - 2>/dev/null)
    PolicyIDs=($(remove_xml_tags "$PolicyIDList" "id"))

    logMe "Checking policies for Self Service icons ..."

    for item in ${PolicyIDs[@]}; do
        tasks+=("backup_ss_icons_detail $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Self Service icon files were downloaded.
    DirectoryCount=$(ls $location_SSIcons| wc -l | xargs )
    logMsg="$DirectoryCount Self Service icon files downloaded to $location_SSIcons."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function backup_ss_icons_detail ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items 
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    # This function will extract the Self Service icon from the policy and download it to the SSIcons folder
    # EXPECTED: menu_storageLocation should be defined

    declare id="${1}"
    declare PolicyName
    declare ss_policy_check
    declare ss_icon
    declare ss_iconName
    declare ss_iconURI

    JAMF_retrieve_data_blob_global "JSSResource/policies/id/$1" "xml"
    # Extract the policy name, icon ID, icon filename, and icon URI from the XML blob
    PolicyName=$(extract_xml_data $xmlBlob "name" | head -n 1)
    ss_icon=$(extract_xml_data $xmlBlob "self_service_icon/id")
    ss_iconName=$(extract_xml_data $xmlBlob "self_service_icon/filename")
    ss_iconURI=$(extract_xml_data $xmlBlob "self_service_icon/uri")
    ss_policy_check=$(extract_xml_data $xmlBlob "self_service/use_for_self_service")


    # Remove any special characters that might mess with APFS
    formatted_ss_policy_name=$(make_apfs_safe "${PolicyName}")
    ss_iconName=$(make_apfs_safe "${ss_iconName}")
    if [[ "$ss_policy_check" = "true" ]] && [[ -n "$ss_icon" ]] && [[ -n "$ss_iconURI" ]]; then
       # If the policy has an icon associated with it then extract the name & icon name and format it correctly and then download it
        update_display_list "Update" "" "${PolicyName}" "" "wait" "Working..."

        # Retrieve the icon and store it in the dest folder
        exported_filename="${location_SSIcons}/${formatted_ss_policy_name}"-"${id}"-"${ss_iconName}"
        logMe "${ss_iconName} to ${exported_filename}"
        # Use curl to download the icon from the JAMF server
        curl -s ${ss_iconURI} -X GET > "${exported_filename}"
        update_display_list "Update" "" "${PolicyName}" "" "success" "Finished"
    else
        update_display_list "Update" "" "${PolicyName}" "" "error" "No Icon"
    fi
}

###############################################
#
# export failed MDM devices functions
#
###############################################

function export_failed_mdm_commands_menu ()
{

    message="**Export Failed MDM Commands**<br><br>You have selected to export the failed MDM commnds.<br><br>There are some additional items to select:"
    MainDialogBody=(
        --message "$message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --checkbox "Clear failed items while exporting",name=ClearFailedMDMCommands
        --width 800
        --height 460
        --ignorednd
        --quitkey 0
        --json
        --button1text "OK"
        --button2text "Cancel"
    )

    temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

    menu_clearFailedMDM=$( echo $temp | jq -r '.ClearFailedMDMCommands' )
}

function export_failed_mdm_devices ()
{
    # PURPOSE: Export all of the failed MDM devices from JAMF
    declare tasks=()
    declare logMsg

    logMe "Exporting failed MDM devices"
    DeviceList=$(JAMF_retrieve_data_blob "api/v1/computers-inventory?section=GENERAL&page=0&page-size=100&sort=general.name%3Aasc" "json")
    create_listitem_list "The following failed MDM devices are being exported from JAMF" "json" ".general.name" "$DeviceList"
    
    DeviceIDs=($(echo $DeviceList | jq -r '.results[].general.name'))

    for item in ${DeviceIDs[@]}; do
        tasks+=("export_failed_mdm_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Failed MDM command files were downloaded.
    DirectoryCount=$(ls $location_FailedMDM | wc -l | xargs )
    logMsg="$DirectoryCount Failed MDM files were downloaded to $location_FailedMDM."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function export_failed_mdm_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare id="${1}"
    declare deviceName
    declare deviceSerialNumber
    declare deviceUDID
    declare deviceModel
    declare deviceOSVersion
    declare formatted_deviceName
    declare exported_filename

    JAMF_retrieve_data_blob_global "JSSResource/computerhistory/name/$id" "xml"
    deviceName=$(extract_xml_data $xmlBlob "name" | head -n 1)
    deviceID=$(extract_xml_data $xmlBlob "id" | head -n 1)

    devicefailedMDM=$(extract_xml_data $xmlBlob "failed")
    devicefailedMDM=("${(@f)devicefailedMDM}")
    devicefailedStatus=$(extract_xml_data $xmlBlob "//failed//status")
    devicefailedStatus=("${(@f)devicefailedStatus}")
    devicefailedName=$(extract_xml_data $xmlBlob "//failed//name")
    devicefailedName=("${(@f)devicefailedName}")
    # Remove any special characters that might mess with APFS
    formatted_deviceName=$(make_apfs_safe $deviceName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    # check to see if there are any failed command, use grep & awk to see if the results are empty
    if [[ -z $devicefailedMDM ]]; then
        update_display_list "Update" "" "${deviceName}" "" "success" "No failed Commands."
        return 1
    fi
    update_display_list "Update" "" "${deviceName}" "" "wait" "Working..."
    # Store the script in the destination folder
    exported_filename="$location_FailedMDM/${formatted_deviceName}.txt"
    logMe "Exporting failed MDM device ${deviceName} to ${exported_filename}"

    # Write out each failed MDM command to the file
    for ((i=1; i<=${#devicefailedMDM[@]}; i++)); do
        MDMfailures+="$devicefailedName[i] ($devicefailedStatus[i]) @ $devicefailedMDM[i]\n" # Add the failed MDM command to the list
    done
    echo "Computer ID:${id} ($deviceID)\n${MDMfailures}" > "${exported_filename}"

    if [[ $menu_clearFailedMDM == "true" ]]; then
        if [[ -z $deviceID ]]; then
            logMe "Error: Failed to retrieve device ID for ${deviceName}"
            update_display_list "Update" "" "${deviceName}" "" "error" "Failed to retrieve device ID"
            return 1
        fi
        # If the menu_clearFailedMDM is set to true, then clear the failed MDM commands
        logMe "Clearing failed MDM commands for ${deviceName}"
        JAMF_clear_failed_mdm_commands "$deviceID"
        update_display_list "Update" "" "${deviceName}" "" "success" "Cleared failed commands"
    else
        update_display_list "Update" "" "${deviceName}" "" "error" "Exported failed commands"

    fi
}

###############################################
#
# Backup System Scripts functions
#
###############################################

function backup_jamf_scripts ()
{
    declare processed_tasks=0
    declare tasks=()
    declare logMsg
    # PURPOSE: Backup all of the JAMF scripts from JAMF
    logMe "Backing up JAMF scripts"
    ScriptList=$(JAMF_retrieve_data_blob "JSSResource/scripts" "xml")
    create_listitem_list "The following JAMF scripts are being downloaded from JAMF" "xml" "name" "$ScriptList"

    ScriptIDs=$(echo $ScriptList | xmllint --xpath '//id' - 2>/dev/null)
    ScriptIDs=($(remove_xml_tags "$ScriptIDs" "id"))

    for item in ${ScriptIDs[@]}; do
        tasks+=("extract_script_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Failed MDM command files were downloaded.
    DirectoryCount=$(ls $location_JAMFScripts | wc -l | xargs )
    logMsg="$DirectoryCount Script files were downloaded to $location_JAMFScripts."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
    
}

function extract_script_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare scriptName
    declare scriptCategory
    declare scriptContents
    declare formatted_scriptName
    declare exported_filename

    JAMF_retrieve_data_blob_global "JSSResource/scripts/id/$1" "xml"
    
    scriptName=$(extract_xml_data $xmlBlob "name")
    # if the Script name is empty, then we will not be able to export it, so show as a failure and report it
    if [[ -z $scriptName ]]; then
        fix_import_errors "$xmlBlob" "Problems saving script"
        return 1
    fi
    scriptCategory=$(extract_xml_data $xmlBlob "category")
    # For some reason, the script contents are not being extracted correctly, so we will use the following line instead
    scriptContents=$(echo "$xmlBlob" | xmllint --xpath 'string(//'script_contents')' - 2>/dev/null)

    # Remove any special characters that might mess with APFS
    formatted_scriptName=$(make_apfs_safe $scriptName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $scriptContents ]]; then
        update_display_list "Update" "" "${scriptName}" "" "fail" "Not exported!"
        logMe "Script ${scriptName} not exported due to empty contents"
        failedItems+=("${scriptName}")
        echo "errors found: $failedItems"
    else
        update_display_list "Update" "" "${scriptName}" "" "wait" "Working..."
        # Store the script in the destination folder
        exported_filename="$location_JAMFScripts/${formatted_scriptName}.sh"
        logMe "Exporting script ${scriptName} to ${exported_filename}"
        echo "${scriptContents}" > "${exported_filename}"
        update_display_list "Update" "" "${scriptName}" "" "success" "Finished"
    fi
}

###############################################
#
# Backup Computer Extensions attributes 
#
###############################################

function  backup_computer_extensions ()
{
    declare processed_tasks=0
    declare tasks=()
    declare logMsg
    # PURPOSE: Backup the computer extensions from JAMF
    # RETURN: None
    # EXPECTED: None

    logMe "Backing up computer extensions"

    ExtensionList=$(JAMF_retrieve_data_blob "JSSResource/computerextensionattributes" "xml")
    create_listitem_list "The following Computer EAs are being downloaded from JAMF" "xml" "name" "$ExtensionList"

    ExtensionIDs=$(echo $ExtensionList | xmllint --xpath '//id' - 2>/dev/null)
    ExtensionIDs=($(remove_xml_tags "$ExtensionIDs" "id"))

    for item in ${ExtensionIDs[@]}; do
        tasks+=("extract_extension_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Failed MDM command files were downloaded.
    DirectoryCount=$(ls $location_ComputerEA | wc -l | xargs )
    logMsg="$DirectoryCount Computer EAs were downloaded to $location_ComputerEA."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function extract_extension_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare extensionName
    declare extensionScript
    declare formatted_extensionName
    declare exported_filename

    [[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_blob_global "JSSResource/computerextensionattributes/id/$1" "xml"

    extensionName=$(extract_xml_data $xmlBlob "name")
    #for some reason, the script contents are not being extracted correctly, so we will use the following line instea
  
    extensionScript=$(echo "$xmlBlob" | xmllint --xpath 'string(//'script')' - 2>/dev/null)   

    # Remove any special characters that might mess with APFS
    formatted_extensionName=$(make_apfs_safe $extensionName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $extensionScript ]]; then
        update_display_list "Update" "" "${extensionName}" "" "fail" "Not exported!"
        logMe "Extension ${extensionName} not exported due to empty contents"
        failedItems+=("${formatted_extensionName}")
        echo "errors found: $failedItems"
    else
        update_display_list "Update" "" "${extensionName}" "" "wait" "Working..."
        # Store the script in the destination folder
        exported_filename="$location_ComputerEA/${formatted_extensionName}.sh"
        logMe "Exporting extension ${extensionName} to $exported_filename"
        echo "${extensionScript}" > "${exported_filename}"
        update_display_list "Update" "" "${extensionName}" "" "success" "Finished"
    fi
}

###############################################
#
# Backup Configuration Profiles functions
#
###############################################

function backup_configuration_profiles ()
{
    declare processed_tasks=0
    declare tasks=()
    declare logMsg
    # PURPOSE: Backup all of the configuration profiles from JAMF
    logMe "Backing up configuration profiles"
    ProfileList=$(JAMF_retrieve_data_blob "JSSResource/osxconfigurationprofiles" "xml")
    create_listitem_list "The following configuration profiles are being downloaded from JAMF" "xml" "name" "$ProfileList"

    ProfileIDs=$(echo $ProfileList | xmllint --xpath '//id' - 2>/dev/null)
    ProfileIDs=($(remove_xml_tags "$ProfileIDs" "id"))

    for item in ${ProfileIDs[@]}; do
        tasks+=("extract_profile_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Failed MDM command files were downloaded.
    DirectoryCount=$(ls $location_ConfigurationProfiles | wc -l | xargs )
    logMsg="$DirectoryCount Configuration profiles were downloaded to $location_ConfigurationProfiles."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function extract_profile_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare profileName
    declare profileContents
    declare formatted_profileName
    declare exported_filename

    [[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_blob_global "JSSResource/osxconfigurationprofiles/id/$1" "xml"

    profileName=$(extract_xml_data $xmlBlob "name" | head -n 1)
    profileContents=$(echo "$xmlBlob" | xmllint --xpath 'string(//payloads)' - 2>/dev/null)

    # Remove any special characters that might mess with APFS
    formatted_profileName=$(make_apfs_safe $profileName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $profileContents ]]; then
        update_display_list "Update" "" "${profileName}" "" "fail" "Not exported!"
        logMe "Profile ${profileName} not exported due to empty contents"
        failedItems+=("${formatted_profileName}")
        echo "errors found: $profileName"
    else
        update_display_list "Update" "" "${profileName}" "" "wait" "Working..."
        # Store the script in the destination folder
        exported_filename="$location_ConfigurationProfiles/${formatted_profileName}.mobileconfig"
        logMe "Exporting profile ${profileName} to ${exported_filename}"
        echo "${profileContents}" > "${exported_filename}"
        update_display_list "Update" "" "${profileName}" "" "success" "Finished"
    fi
}

###############################################
#
# Create VCF Card functions
#
###############################################

function create_vcf_cards_menu ()
{
    # PURPOSE: Create the VCF Cards menu
    # RETURN: None
    # EXPECTED: None
    declare GroupList
    declare xml_blob
    declare -a array

    message="**Create VCF Cards Additional Options**<br><br>You have selected to create VCF cards from the JAMF server.  If you select a group, it will create a subfolder under the main contacts folder with all of the entries.<br><br>There are some additional items to select:"
    construct_header_settings "$message" > "${JSON_DIALOG_BLOB}"
    create_checkbox_message_body "Only users with managed systems" "onlyManaged" "" "true" "false" "first"
    create_checkbox_message_body "Create CSV file with emails" "csvfile" "" "true" "false"
    create_checkbox_message_body "Compose Email after completion" "compose" "" "true" "false" "last"
    echo "," >> "${JSON_DIALOG_BLOB}"

    create_dropdown_message_body "" "" "first"
    # Read in the JAMF groups and create a dropdown list of them
    # create_listitem_list "The following Smart / Static groups are being exported from the JAMF server" "xml" "name" $GroupList
    GroupList=$(JAMF_retrieve_data_blob "JSSResource/computergroups" "json")
    array=$(construct_dropdown_list_items $GroupList)
    create_dropdown_message_body "Select Groups:" "$array"
    create_dropdown_message_body "" "" "last"
	echo '}' >> "${JSON_DIALOG_BLOB}"

	temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

    menu_onlyManagedUsers=$( echo $temp | jq -r '.onlyManaged')
    menu_createCSV=$( echo $temp | jq -r '.csvfile')
    menu_composeEmail=$( echo $temp | jq -r '.compose')
    menu_groupVCFExport=$( echo $temp  | jq -r '.SelectedOption')
}

function create_vcf_cards ()
{
    # PURPOSE: Create VCF cards from the JAMF users
    # RETURN: None
    # EXPECTED: None

    declare processed_tasks=0
    declare tasks=()
    declare -i i

    if [[ $menu_composeEmail == "true" ]]; then
        [[ -e ${location_Contacts}/contacts.txt ]] && rm -f ${location_Contacts}/contacts.txt
    fi

    # If the user selected to create VCF cards from a specific group, then we will retrieve the group members and create a list of user IDs
    menu_groupVCFExport=$(echo $menu_groupVCFExport | xargs)
    if [[ ! -z $menu_groupVCFExport ]]; then
        UserIDs=()
        UserList=()

        logMe "Creating VCF Cards from JAMF users in group: $menu_groupVCFExport"
        # Split the group name into ID and Name (this came from the dropdown list)
        GroupID=$(echo $menu_groupVCFExport | awk -F "-" '{print $1}' | xargs)
        GroupName=$(echo $menu_groupVCFExport | awk -F "-" '{print $2}' | xargs)

        # If they chose to export a specific group, then we will append that group name to create the VCF file
        location_Contacts+="/${GroupName}"
        location_Contacts=$(make_apfs_safe "${location_Contacts}")
        # Create the directory if it does not exist
        if [[ ! -d "${location_Contacts}" ]]; then
            mkdir -p "${location_Contacts}"
            logMe "Created directory ${location_Contacts}"
        fi
        # Retrieve the group members and create a list of computer IDs
        computerList=$(JAMF_retrieve_data_blob "JSSResource/computergroups/id/$GroupID" "xml")

        # do a quick check to see if the group has members in it
        if [[ $(echo $computerList | xmllint --xpath '//computers//size' -) == "<size>0</size>" ]]; then
            logMe "Group $GroupName has no members, skipping VCF card creation"
            ${SW_DIALOG} --title "No Members in Group" --message "The group $GroupName has no members, so no VCF cards will be created." --button1text "OK" --quitkey 0 --icon "${SD_ICON_FILE}"
            return 1
        fi
        ComputerIDs=($(echo $computerList | xmllint --xpath '//computers//id' - 2>/dev/null))

        # If the user selected to only create VCF cards for managed users, then we will filter the computer IDs to only include those that are managed
        i=0
        for item in ${ComputerIDs[@]}; do
            item=$(echo $item | awk -F '<id>|</id>' '{print $2}'| xargs)
            # We need to find the users ID, but the group record does not have the user ID, so we need to get the inventory record for their computer, and then find the users by their computer ID to get their email
            # Get the inventory record for each computer and extract the their email
            inventory_data=$(JAMF_get_inventory_record "USER_AND_LOCATION" "id=='$item'")
            userEmail=$(echo $inventory_data | jq -r '.results[].userAndLocation.email')
            if [[ $i -eq 0 ]]; then
                # Show a message that we are creating VCF cards from the group (this is the first item)
                construct_dialog_header_settings "The following VCF Cards are being created from the JAMF group:<br><br>** $GroupName" > "${JSON_DIALOG_BLOB}"
                create_listitem_message_body "$userEmail" "" "Adding User..." "pending" "frst"
                create_listitem_message_body "" "" "" "" "last"
                update_display_list "Create"
            else
                # Check to see if the user is already in the list, if so, then skip adding them
                if [[ -z $(cat ${DIALOG_CMD_FILE} | grep -w "$userEmail") ]]; then
                    update_display_list "add" "$userEmail" "pending" "Adding User..."
                fi
            fi
            # Look up the user by their email address and retrieve their user ID
            userEmail=$(convert_to_hex "$userEmail")
            inventory_data=$(JAMF_retrieve_data_blob "JSSResource/users/email/$userEmail" "json")
            UserIDs+=($(echo $inventory_data | jq -r '.users[].id'))
            ((i++))
        done
    else
        logMe "Creating VCF Cards from JAMF users"
        UserList=$(JAMF_retrieve_data_blob "JSSResource/users" "xml")
        create_listitem_list "The following VCF Cards are being created from the JAMF server" "xml" "name" $UserList
        UserIDs=$(echo $UserList | xmllint --xpath '//id' - 2>/dev/null)
    fi
    UserIDs=($(echo "$UserIDs" | grep -Eo "[0-9]+" | xargs))

    for item in ${UserIDs[@]}; do
        tasks+=("extract_user_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

    # Display how many VCF files were downloaded.
    DirectoryCount=$(ls $location_Contacts | wc -l | xargs )
    logMsg="$DirectoryCount Contacts were downloaded to $location_Contacts."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
    if [[ $menu_composeEmail == "true" ]]; then
        email_address=$(cat ${location_Contacts}/contacts.txt)
        # Create a mailto link to open in Outlook with the email addresses
        email_clean=$(echo "$email_address" | tr -d '\r' | tr -d '\n')
        /usr/bin/open -b "${EMAIL_APP}" 'mailto:'${email_clean}'?subject=Subject&body=Type your message here'
    fi
}

function extract_user_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substrint to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare managed && managed=true

	[[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_blob_global "JSSResource/users/id/$1" "xml"
    userShortName=$(extract_xml_data $xmlBlob "name" | head -n 1)
    userFullName=$(extract_xml_data $xmlBlob  "full_name")
    userEmail=$(extract_xml_data $xmlBlob "email_address")
    userPosition=$(extract_xml_data $xmlBlob "position")


    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $userFullName ]]; then
        update_display_list "Update" "" "${userShortName}" "" "fail" "Not exported"
        logMe "User ${userShortName} not exported due to empty full name"
        failedItems+=("${userShortName}")
        echo "errors found: $userShortName"
    else
        update_display_list "Update" "" "${userShortName}" "" "wait" "Working..."

        if [[ $menu_onlyManagedUsers == "true" ]]; then
            # if they choose to include only managed users, then we will check for managed systems
            managed=$(extract_assigned_systems ${xmlBlob})
        fi

        if [[ $managed == "false" ]]; then
            update_display_list "Update" "" "${userShortName}" "" "fail" "No managed systems"
        else
            #export the VCF file
            userVCFBlob=$(export_vcf_file $userFullName $userEmail $userPosition)
            exported_filename="${location_Contacts}/${userShortName}.vcf"
            logMe "Exporting user ${userShortName} (${userFullName}) to ${exported_filename}"     
            echo "${userVCFBlob}" > "${exported_filename}"
            if [[ $menu_composeEmail == "true" || $menu_createCSV == "true" ]]; then
                # If the user selected to compose an email with emails, then we will append the email to the txt file
                # This is designed for simple import into outlook
                echo "${userEmail};" >> "${location_Contacts}/contacts.txt"
            fi
            update_display_list "Update" "" "${userShortName}" "" "success" "Finished"
        fi
    fi
}

function export_vcf_file ()
{

    # Write to VCF file

VCF_DATA="BEGIN:VCARD
VERSION:3.0
FN:$1
EMAIL:$2
TITLE:$3
END:VCARD"
echo $VCF_DATA
}

function extract_assigned_systems ()
{
    # PURPOSE: Extract the assigned systems from the XML string
    # RETURN: None
    # PARAMETERS: $1 - XML string to parse
    # EXPECTED: None
    declare managed && managed=false
    computer_ids=($(echo "$1" | xmllint --xpath "//computer/id/text()" - )) #2>/dev/null)
 
    # Loop through and evaluate each computer ID
    for id in "${computer_ids[@]}"; do
        inventory_data=$(JAMF_get_inventory_record_byID $id "GENERAL")
        # Check if the managed field is true
        [[ $(echo $inventory_data | jq -r '.general.remoteManagement.managed') == "true" ]] && managed=true
    done
    echo $managed
}

###############################################
#
# Create Smart Groups functions
#
###############################################


function export_computer_groups ()
{
    declare processed_tasks=0
    declare tasks=()
    declare logMsg
    # PURPOSE: Export all of the computer groups from JAMF
    logMe "Export computer groups from JAMF"
    GroupList=$(JAMF_retrieve_data_blob "JSSResource/computergroups" "xml")
    
    create_listitem_list "The following Smart / Static groups are being exported from the JAMF server" "xml" "name" $GroupList
    GroupIDs=$(echo $GroupList | xmllint --xpath '//id' - 2>/dev/null)
    GroupIDs=($(remove_xml_tags "$GroupIDs" "id" ))

    for item in ${GroupIDs[@]}; do
        tasks+=("export_computer_group_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Static/Smart groups files were downloaded.
    DirectoryCount=$(ls -R $location_backupSmartGroups | wc -l | xargs)
    logMsg="$DirectoryCount Static/Smart groups were downloaded to $location_backupSmartGroups"
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function export_computer_group_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substrint to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare managed && managed=true
    declare groupName
    declare groupid=$1

    JAMF_retrieve_data_blob_global "JSSResource/computergroups/id/$groupid" "xml"

    groupName=$(extract_xml_data $xmlBlob "name" | head -n 1)
    # Parse the XML to get the group details
    # get the group name and see if it is a smart group or a static group
    # this section will store every condition into an array, so that we can display it later
    
    groupIsSmart=$(extract_xml_data $xmlBlob "is_smart")

    [[ $groupIsSmart == "true" ]] && groupIsSmart="Smart" || groupIsSmart="Static"

    # extract the group criteria
    # opening and closing parentheses
    groupOpenParen=$(extract_xml_data $xmlBlob  "opening_paren")
    groupOpenParen=("${(@f)groupOpenParen}") # Convert to array
    
    groupCloseParen=$(extract_xml_data $xmlBlob "closing_paren")
    groupCloseParen=("${(@f)groupCloseParen}") # Convert to array
    
    groupAndOr=$(extract_xml_data $xmlBlob "and_or")
    groupAndOr=("${(@f)groupAndOr}") # Convert to array
    groupAndOr=("${(U)groupAndOr[@]}") # Convert to uppercase
    groupAndOr=("${groupAndOr[@]:1}") # Remove the first element, which is not needed
    
    # extract the group criteria, search type and value
    groupCriteria=$(extract_xml_data $xmlBlob "criteria//name")
    groupCriteria=("${(@f)groupCriteria}") # Convert to array    

    groupSearchType=$(extract_xml_data $xmlBlob "criteria//search_type")
    groupSearchType=("${(@f)groupSearchType}") # Convert to array

    groupValue=$(extract_xml_data $xmlBlob "criteria//value")
    groupValue=("${(@f)groupValue}") # Convert to array
 
    if [[ $groupIsSmart == "Smart" ]]; then
        # If the group is a smart group, then we will create the conditions
        groupCondition="$groupIsSmart group ($groupid)\n\nConditions:\n\n"
        for ((i=0; i<=${#groupCriteria[@]}; i++)); do
            # Check if the groupCriteria is empty, if so, skip it
            [[ -z "${groupCriteria[i]}" ]] && continue
            [[ $groupOpenParen[i] == "true" ]] && OpenParen="(" || OpenParen="" #Determine if we need to add an opening parenthesis
            [[ $groupCloseParen[i] == "true" ]] && CloseParen=")" || CloseParen="" #Determine if we need to add a closing parenthesis
            groupCondition+="${OpenParen}'${groupCriteria[i]}' ${groupSearchType[i]} '${groupValue[i]}'${CloseParen} ${groupAndOr[i]}\n"
        done
    else
        # If the group is a static group, then we will just list the members
        groupCondition="$groupIsSmart group ($groupid)\n\nMembers:\n\n"
        memberID=$(extract_xml_data $xmlBlob  "computers//name")
        groupCondition+="$(echo "${memberID[@]}" | sed 's/ /\n/g')\n"
    fi
    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $groupName ]]; then
        update_display_list "Update" "" "${groupName}" "" "fail" "Not exported"
        logMe "Group ${groupName} not exported due to empty group name"
        failedItems+=("${groupName}")
        echo "errors found: $groupName"
    else
        update_display_list "Update" "" "${groupName}" "" "wait" "Working..."
        logMe "Exporting ${groupIsSmart} group ${groupName} to text file"
        echo "${groupCondition}" > "$location_backupSmartGroups/${groupIsSmart}/${groupName}.txt"
        update_display_list "Update" "" "${groupName}" "" "success" "Finished"
    fi
}

###############################################
#
# Export Application Usage
#
###############################################

function export_usage_menu ()
{
    # PURPOSE: Export Application Usage for a users / group
    # RETURN: None
    # EXPECTED: None
    declare GroupList
    declare xml_blob
    declare -a array

    message="**Export Usage Additional Options**<br><br>You have selected to export Application Usage<br>from the JAMF server.  There are some additional items to select:"
    construct_header_settings "$message" > "${JSON_DIALOG_BLOB}"
    create_textfield_message_body "StartDate" "Starting date for report:" "first"
    create_textfield_message_body "EndDate" "Enter Ending date:" "last"
    echo "," >> "${JSON_DIALOG_BLOB}"

    create_dropdown_message_body "" "" "first"
    # Read in the JAMF groups and create a dropdown list of them
    # create_listitem_list "The following Smart / Static groups are being exported from the JAMF server" "xml" "name" $GroupList
    GroupList=$(JAMF_retrieve_data_blob "JSSResource/computergroups" "json")
    array=$(construct_dropdown_list_items $GroupList)
    create_dropdown_message_body "Select Groups:" "$array"
    create_dropdown_message_body "" "" "last"
	echo '}' >> "${JSON_DIALOG_BLOB}"

	temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

    menu_startDateUsage=$(echo $temp | jq -r '.StartDate')
    menu_endDateUsage=$(echo $temp | jq -r '.EndDate')
    menu_groupAppUsage=$( echo $temp  | jq -r '.SelectedOption')
    menu_startDateUsage=$(date -j -f "%m/%d/%y" "$menu_startDateUsage" +"%Y-%m-%d")
    menu_endDateUsage=$(date -j -f "%m/%d/%y" "$menu_endDateUsage" +"%Y-%m-%d")
}

function export_usage ()
{
    # PURPOSE: Export the application usage for each computer in the group
    # RETURN: None
    # EXPECTED: None

    declare tasks=()
    declare computerList=()

    # Split the group name into ID and Name (this came from the dropdown list)
    GroupID=$(echo $menu_groupAppUsage | awk -F "-" '{print $1}' | xargs)
    GroupName=$(echo $menu_groupAppUsage | awk -F "-" '{print $2}' | xargs)
    logMe "Exporting App Usage from JAMF users in group: $GroupName"

    # If they chose to export a specific group, then we will append that group name to create the VCF file
    location_ApplicationUsage+="/${GroupName}"
    formatted_ApplicationUsage_name=$(make_apfs_safe "${location_ApplicationUsage}")
    [[ ! -d "$formatted_ApplicationUsage_name" ]] && /bin/mkdir -p "${formatted_ApplicationUsage_name}"
    computerList=$(JAMF_retrieve_data_blob "JSSResource/computergroups/id/$GroupID" "xml")
    create_listitem_list "The following Usage report will be generated from group:<br><br>**$GroupName**" "xml" "computer//name" "$computerList"
    ComputerIDs=$(echo $computerList | xmllint --xpath '//computer//name' - 2>/dev/null)
    ComputerIDs=($(remove_xml_tags "$ComputerIDs" "name"))
    
    for item in ${ComputerIDs[@]}; do
        tasks+=("export_usage_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

    # Display how many usage Reports were downloaded
    DirectoryCount=$(ls $formatted_ApplicationUsage_name | wc -l | xargs )
    logMsg="$DirectoryCount Usage reports were downloaded to $formatted_ApplicationUsage_name."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function export_usage_details ()
{
    # PURPOSE: extract the Usage info from the record ID and parse the info
    # RETURN: None
    # PARAMETERS: $1 - Computer Name to search
    # EXPECTED: xmlBlob should be globally defined

    declare filename
    declare appDate

	[[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_blob_global "JSSResource/computerapplicationusage/name/$1/${menu_startDateUsage}_${menu_endDateUsage}" "json"

    # if the script returns <computer_application_usage/> then there is no data to show
    if [[ ${xmlBlob} == '{"computer_application_usage":[]}' ]]; then
        update_display_list "Update" "" "${1}" "" "fail" "No Usage Data"
        logMe "No computer usage data found for ${1}"
        failedItems+=("${1}")
    else
        appDate=($(echo $xmlBlob | jq -r '.computer_application_usage[].date'))
        update_display_list "Update" "" "${1}" "" "wait" "Working..."

        #export the Usage Report
        if [[ ! -z ${#appDate[@]} ]]; then
            filename="${formatted_ApplicationUsage_name}/$1.csv"
            logMe "Creating Usage Report $filename"
            touch "$filename"
            echo "Serial #, Date, App Name,Total Hours,Version" >> $filename
            for item in ${appDate[@]}; do
                echo $xmlBlob | jq -r '.computer_application_usage[] | select(.date == "'$item'") | .apps[] | "'$1','$item',\(.name),\(.foreground),\(.version)"' >> $filename
            done
        fi
        update_display_list "Update" "" "${1}" "" "success" "Finished"
    fi
}


###############################################
#
# Application functions
#
###############################################

function construct_header_settings ()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
    "icon" : "'${SD_ICON_FILE}'",
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

function execute_in_parallel ()
{
    # PURPOSE: Execute a list of tasks in parallel, with a limit on the number of concurrent jobs
    # RETURN: None
    # PARAMETERS: $1 - Maximum number of concurrent jobs
    #             $2 - Array list of tasks to execute
    # EXPECTED: None

    declare max_jobs=$1
    shift
    declare tasks=("$@")
    declare current_jobs=0
    declare pids=()

    for task in "${tasks[@]}"; do
        eval "${task}" &
        pids+=($!)
        ((current_jobs++))
        if [[ $current_jobs -ge $max_jobs ]]; then
            for pid in "${pids[@]}"; do wait $pid; done
            current_jobs=0
            pids=()
        fi
    done

    # Wait for any remaining jobs
    for pid in "${pids[@]}"; do wait $pid; done
}

function display_welcome_msg ()
{
    # PURPOSE: Display the welcome message to the user
    message="This set of utilities is designed to backup various items from your JAMF server.  Please select a destination folder location below:<br><br>##### + If choosen, additional screens will appear for the selected option."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --width 890
        --height 720
        --ignorednd
        --json
        --moveable
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
        --infobuttontext "My Repo"
        --infobuttonaction "https://github.com/ScottEKendall/JAMF-Pro-Scripts"
        --helpmessage "This script will backup various items from your JAMF server.  Please select the items you wish to backup and the location to store them."
        --textfield "Select a storage location",fileselect,filetype=folder,required,name=StorageLocation
        --checkbox "Backup Self Service Icons (*.png)",checked,name=BackupSSIcons
        --checkbox "+ Exported failed MDM commands (*.txt)",checked,name=BackupFailedMDMCommands
        --checkbox "Backup System Scripts (*.sh)",checked,name=BackupJAMFScripts
        --checkbox "Backup Computer Policies (*.xml)",checked,name=BackupComputerPolicy
        --checkbox "Backup Computer Extension Attributes (*.sh)",checked,name=BackupComputerExtensions
        --checkbox "Backup Configuration Profiles (*.mobileconfig)",checked,name=BackupConfigurationProfiles
        --checkbox "Backup Smart Groups & Static Groups (*.txt)",checked,name=BackupSmartGroups
        --checkbox "+ Create VCF cards from email address or Smart Groups (*.vcf)",checked,name=createVCFcards
        --checkbox "+ Export Application Usage from Users / Groups (*.csv)",checked,name=exportApplicationUsage
        )
	
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

    menu_backupSSIcons=$( echo $temp | jq -r '.BackupSSIcons')
    menu_backupJAMFScripts=$( echo $temp | jq -r '.BackupJAMFScripts' )
    menu_createVCFcards=$( echo $temp | jq -r '.createVCFcards' )
    menu_storageLocation=$( echo $temp | jq -r '.StorageLocation' )
    menu_computerea=$( echo $temp | jq -r '.BackupComputerExtensions' )
    menu_configurationProfiles=$( echo $temp | jq -r '.BackupConfigurationProfiles')
    menu_backupFailedMDM=$( echo $temp | jq -r '.BackupFailedMDMCommands' )
    menu_backupSmartGroups=$( echo $temp | jq -r '.BackupSmartGroups' )
    menu_exportApplicationUsage=$( echo $temp | jq -r '.exportApplicationUsage' )
    menu_backupComputerPolicy=$( echo $temp | jq -r '.BackupComputerPolicy' )
    
    [[ $menu_backupFailedMDM == "true" ]] && export_failed_mdm_commands_menu
    [[ $menu_createVCFcards == "true" ]] && create_vcf_cards_menu
    [[ $menu_exportApplicationUsage == "true" ]] && export_usage_menu
    
}

function show_backup_errors ()
{
    message="$1<br><br>"
    for item in "${failedItems[@]}"; do
        message+="* $item<br>"
    done
    message+="<br>This might be due to improper formatting in the original script or invalid characters.  You might need to copy these scripts manually out of JAMF."

	MainDialogBody=(
        --message "$message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 800
        --height 460
        --ignorednd
        --quitkey 0
        --button1text "OK"
    )
	
    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
}

function check_directories ()
{
    # PURPOSE: Check if the directories exist and create them if they do not
    # RETURN: None
    # EXPECTED: menu_storageLocation should be set
    # PARMS: None

    location_SSIcons="${menu_storageLocation}/SSIcons"
    location_JAMFScripts="${menu_storageLocation}/SystemScripts"
    location_ComputerEA="${menu_storageLocation}/ComputerEA"
    location_Contacts="${menu_storageLocation}/Contacts"
    location_ConfigurationProfiles="${menu_storageLocation}/ConfigurationProfiles"
    location_FailedMDM="${menu_storageLocation}/FailedMDM"
    location_backupSmartGroups="${menu_storageLocation}/ComputerGroups"
    location_ApplicationUsage="${menu_storageLocation}/AppUsage"

    [[ ! -d "${menu_storageLocation}" ]] && /bin/mkdir -p "${menu_storageLocation}"
    [[ ! -d "$location_SSIcons" ]] && /bin/mkdir -p "$location_SSIcons"
    [[ ! -d "$location_JAMFScripts" ]] && /bin/mkdir -p "${location_JAMFScripts}"
    [[ ! -d "$location_ComputerEA" ]] && /bin/mkdir -p "${location_ComputerEA}"
    [[ ! -d "$location_Contacts" ]] && /bin/mkdir -p "${location_Contacts}"
    [[ ! -d "$location_ConfigurationProfiles" ]] && /bin/mkdir -p "${location_ConfigurationProfiles}"
    [[ ! -d "$location_FailedMDM" ]] && /bin/mkdir -p "${location_FailedMDM}"
    [[ ! -d "$location_backupSmartGroups" ]] && /bin/mkdir -p "${location_backupSmartGroups}"
    [[ ! -d "$location_backupSmartGroups/Smart" ]] && /bin/mkdir -p "${location_backupSmartGroups}/Smart"
    [[ ! -d "$location_backupSmartGroups/Static" ]] && /bin/mkdir -p "${location_backupSmartGroups}/Static"
    [[ ! -d "$location_ApplicationUsage" ]] && /bin/mkdir -p "${location_ApplicationUsage}"

    chmod -R 755 "${menu_storageLocation}"
    chown -R "${LOGGED_IN_USER}" "${menu_storageLocation}"
}

function fix_import_errors ()
{
    # PURPOSE: Fix import errors by logging the error and adding it to the failItems array
    # RETURN: None
    # PARAMETERS: $1 - XML blob to parse for errors
    #             $2 - Error message to log
    # EXPECTED: None

    local errorMessage

    errorMessage=$(echo $1 | head -n 5 | awk -F '<name>|</name>' '{print $2}')
    update_display_list "Update" "" "${errorMessage}" "" "error" "$2"
    logMe "Error in import: $errorMessage $2"
    failedItems+=("$errorMessage")

}

function remove_xml_tags ()
{
    # PURPOSE: Remove the XML tags around an item
    # RETURN: formatted array
    # EXPECTED: None
    # PARAMETERS: $1 - Array of elements to clean
    #             $2 - tagname to remove
    # PARMS: None

    echo $1 | sed 's|<'$2'>||g; s|</'$2'>||g' | xargs #awk -F '<id>|</id>' '{print $2}'| xargs
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare api_token
declare jamfpro_url
declare ScriptList
declare UserList
declare xmlBlob
declare -a failedItems
declare menu_backupJAMFScripts
declare menu_backupSSIcons
declare menu_createVCFcards
declare menu_storageLocation
declare menu_onlyManagedUsers
declare menu_computerea
declare menu_configurationProfiles
declare menu_clearFailedMDM
declare menu_backupFailedMDM
declare location_SSIcons
declare location_JAMFScripts
declare location_ComputerEA
declare location_Contacts
declare location_ConfigurationProfiles
declare location_FailedMDM
declare jamfpro_version
declare menu_backupSmartGroups
declare menu_groupVCFExport
declare menu_createCSV
declare menu_composeEmail
declare menu_exportApplicationUsage
declare menu_startDateUsage
declare menu_endDdateUsage
declare menu_groupAppUsage
declare -a MDMfailures && MDMfailures=()

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
JAMF_check_connection
JAMF_get_server
# Check if the JAMF Pro server is using the new API or the classic API
# If the client ID is longer than 30 characters, then it is using the new API
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token    
display_welcome_msg

check_directories

[[ "${menu_backupSSIcons}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; backup_ss_icons;}
[[ "${menu_backupFailedMDM}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; export_failed_mdm_devices;}
[[ "${menu_backupJAMFScripts}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; backup_jamf_scripts;}
[[ "${menu_computerea}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; backup_computer_extensions;}
[[ "${menu_configurationProfiles}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; backup_configuration_profiles;}
[[ "${menu_backupSmartGroups}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; export_computer_groups;}
[[ "${menu_createVCFcards}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; create_vcf_cards;}
[[ "${menu_exportApplicationUsage}" == "true" ]] && {[[ JAMF_token = "new" ]] && JAMF_get_access_token; export_usage;}
JAMF_invalidate_token

# If we get here, then we are done with the script
logMe "JAMF Backup Utilities completed successfully!"
# Show errors if any failed backups occurred
echo $failedItems

[[ ! -z $failedItems ]] && show_backup_errors "The following items could not be backed up for some reason!"
cleanup_and_exit