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
MAC_SERIAL_NUMBER=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.serial_number' 'raw' -)
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_VERSION=$( sw_vers -productVersion | xargs)

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/logs"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

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
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
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
		"message" : "'$1'",
		"bannerimage" : "'${SD_BANNER_IMAGE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : "true",
		"bannertitle" : "'${SD_WINDOW_TITLE}'",
		"titlefont" : "shadow=1",
		"button1text" : "OK",
		"moveable" : "true",
		"quitkey" : "0",
		"messageposition" : "top",'
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
    #        $3 - listitem
    #        $4 - status
    #        $5 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    if [[ "$5:l" == "first" ]]; then
        line='"button1disabled" : "true", "listitem" : ['
    elif [[ "$5:l" == "last" ]]; then
        line=']}'
    else
        line='{"title" : "'$1'", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    fi
    echo $line >> ${JSON_DIALOG_BLOB}
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

function create_display_list ()
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

    # Parse the XML data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is XML, then parse the XML data
        xml_blob=$(echo $4 | jq -r '.results[]'$3)
    else
        # If the second parameter is JSON, then parse the JSON data
        xml_blob=$(echo $4 | xmllint --xpath '//'$3 - 2) #>/dev/null)
    fi

    echo $xml_blob | while IFS= read -r line; do
        # Remove the opening tag
        line="${line/<name>/}"
        # Remove the closing tag
        line="${line/<\/name>/}"
        create_listitem_message_body "$line" "" "pending" "Pending..."
    done
    create_listitem_message_body "" "" "" "" "last"
    update_display_list "Create"
}

function extract_xml_data ()
{
    # PURPOSE: extract an XML strng from the passed string
    # RETURN: parsed XML string
    # PARAMETERS: $1 - XML "blob"
    #             $2 - String to extract
    # EXPECTED: None
    echo $(echo "$1" | xmllint --xpath 'string(//'${2}')' - 2>/dev/null)
}

function make_apfs_safe ()
{
    # PURPOSE: Remove any "illegal" APFS macOS characters from filename
    # RETURN: ADFS safe filename
    # PARAMETERS: $1 - string to format
    # EXPECTED: None
    echo $(echo "$1" | sed -e 's/:/_/g' -e 's/\//-/g' -e 's/|/-/g')
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

function JAMF_get_inventory_record ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/computers-inventory/$1?section=$2" 2>/dev/null)
    echo $retval | tr -d '\n'
}

function JAMF_get_policy_list ()
{
    echo $(curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/xml" "${jamfpro_url}JSSResource/policies")

}

###############################################
#
# Backup Self Service Icons functions
#
###############################################

function backup_ss_icons ()
{

    declare processed_tasks=0
    declare tasks=()
    declare logMsg

    # PURPOSE: Backup all of the Self Service icons from JAMF
    logMe "Backing up Self Service icons"
    PolicyList=$(JAMF_get_policy_list)
    create_display_list "The following Self Service icons are being downloaded from JAMF" "xml" "name" "$PolicyList"

    PolicyIDList=$(echo $PolicyList | xmllint --xpath '//id' - 2>/dev/null)
    PolicyIDs=($(echo "$PolicyIDList" | grep -Eo "[0-9]+"))
    PoliciesCount=${#PolicyIDs[@]}

    logMe "Checking $PoliciesCount policies for Self Service icons ..."

    for item in ${PolicyIDs[@]}; do
        tasks+=("extract_ss_policy_icons $item")
    done
    execute_in_parallel 10 "${tasks[@]}"

   # Display how many Self Service icon files were downloaded.
    DirectoryCount=$(ls $location_SSIcons| wc -l | xargs )
    logMsg="$DirectoryCount Self Service icon files downloaded to $location_SSIcons."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function extract_ss_policy_icons ()
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

    JAMF_retrieve_data_details "JSSResource/policies/id/$1" "xml"
    PolicyName=$(extract_xml_data $xmlBlob "name")
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
        ss_icon_filepath="${formatted_ss_policy_name}"-"${id}"-"${ss_iconName}"
        logMe "${ss_icon_filepath} to ${menu_storageLocation}"

        curl -s ${ss_iconURI} -X GET > "$location_SSIcons/${ss_icon_filepath}"
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
function export_failed_mdm_devices ()
{

    declare processed_tasks=0
    declare tasks=()
    declare logMsg
    # PURPOSE: Export all of the failed MDM devices from JAMF
    logMe "Exporting failed MDM devices"
    DeviceList=$(JAMF_retrieve_data_summary "/api/v1/computers-inventory?section=GENERAL&page=0&page-size=100&sort=general.name%3Aasc" "json")
    create_display_list "The following failed MDM devices are being exported from JAMF" "json" ".general.name" "$DeviceList"
    
    DeviceIDs=($(echo $DeviceList | jq -r '.results[].general.name'))
    deviceCount=${#DeviceIDs[@]}

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

    JAMF_retrieve_data_details "JSSResource/computerhistory/name/$id" "xml"
    deviceName=$(extract_xml_data $xmlBlob "name")

    devicefailedMDM=$(extract_xml_data $xmlBlob "failed")
    # Remove any special characters that might mess with APFS
    formatted_deviceName=$(make_apfs_safe $deviceName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    # check to see if there are any failed command, use grep & awk to see if the results are empty
    if [[ -z $devicefailedMDM ]]; then
        update_display_list "Update" "" "${deviceName}" "" "success" "No failed Commands."
        #logMe "Device ${deviceName} not exported due to empty UDID"
        failedMigration+=("${formatted_deviceName}")
    else
        update_display_list "Update" "" "${deviceName}" "" "wait" "Working..."
        # Store the script in the destination folder
        exported_filename="$location_FailedMDM/${formatted_deviceName}.txt"
        logMe "Exporting failed MDM device ${deviceName} to ${exported_filename}"
        echo "${devicefailedMDM}" > "${exported_filename}"
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
    ScriptList=$(JAMF_retrieve_data_summary "JSSResource/scripts" "xml") 
    create_display_list "The following JAMF scripts are being downloaded from JAMF" "xml" "name" "$ScriptList"

    ScriptIDs=$(echo $ScriptList | xmllint --xpath '//id' - 2>/dev/null)
    ScriptIDs=($(echo "$ScriptIDs" | grep -Eo "[0-9]+"))
    scriptCount=${#ScriptIDs[@]}

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
    declare scriptInfo
    declare scriptCategory
    declare scriptFileName
    declare scriptContents
    declare formatted_scriptName
    declare exported_filename

    JAMF_retrieve_data_details "JSSResource/scripts/id/$1" "xml"

    scriptName=$(extract_xml_data $xmlBlob "name")
    scriptInfo=$(extract_xml_data $xmlBlob  "info")
    scriptCategory=$(extract_xml_data $xmlBlob "category")
    scriptFileName=$(extract_xml_data $xmlBlob "filename")
    # For some reason, the script contents are not being extracted correctly, so we will use the following line instead
    scriptContents=$(echo "$xmlBlob" | xmllint --xpath 'string(//'script_contents')' - 2>/dev/null)
    #scriptContents=$(extract_xml_data $xmlBlob "script_contents")

    # Remove any special characters that might mess with APFS
    formatted_scriptName=$(make_apfs_safe $scriptName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $scriptContents ]]; then
        update_display_list "Update" "" "${scriptName}" "" "fail" "Not exported!"
        logMe "Script ${scriptName} not exported due to empty contents"
        failedMigration+=("${formatted_scriptName}")
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

    ExtensionList=$(JAMF_retrieve_data_summary "JSSResource/computerextensionattributes" "xml")
    create_display_list "The following Computer EAs are being downloaded from JAMF" "xml" "name" "$ExtensionList"

    ExtensionIDs=$(echo $ExtensionList | xmllint --xpath '//id' - 2>/dev/null)
    ExtensionIDs=($(echo "$ExtensionIDs" | grep -Eo "[0-9]+"))
    extensionCount=${#ExtensionIDs[@]}

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

    JAMF_retrieve_data_details "JSSResource/computerextensionattributes/id/$1" "xml"

    extensionName=$(extract_xml_data $xmlBlob "name")
    #for some reason, the script contents are not being extracted correctly, so we will use the following line instea
  
    extensionScript=$(echo "$xmlBlob" | xmllint --xpath 'string(//'script')' - 2>/dev/null)
    #extensionScript=$(extract_xml_data $xmlBlob  "script")    

    # Remove any special characters that might mess with APFS
    formatted_extensionName=$(make_apfs_safe $extensionName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $extensionScript ]]; then
        update_display_list "Update" "" "${extensionName}" "" "fail" "Not exported!"
        logMe "Extension ${extensionName} not exported due to empty contents"
        failedMigration+=("${formatted_extensionName}")
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
    ProfileList=$(JAMF_retrieve_data_summary "JSSResource/osxconfigurationprofiles" "xml")
    create_display_list "The following configuration profiles are being downloaded from JAMF" "xml" "name" "$ProfileList"

    ProfileIDs=$(echo $ProfileList | xmllint --xpath '//id' - 2>/dev/null)
    ProfileIDs=($(echo "$ProfileIDs" | grep -Eo "[0-9]+"))
    profileCount=${#ProfileIDs[@]}

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
    declare profileUUID
    declare profileFileName
    declare profileContents
    declare formatted_profileName
    declare exported_filename

    [[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_details "JSSResource/osxconfigurationprofiles/id/$1" "xml"

    profileName=$(extract_xml_data $xmlBlob "name")
    profileUUID=$(extract_xml_data $xmlBlob "uuid")
    profileFileName=$(extract_xml_data $xmlBlob "filename")
    profileContents=$(echo "$xmlBlob" | xmllint --xpath 'string(//payloads)' - 2>/dev/null)

    # Remove any special characters that might mess with APFS
    formatted_profileName=$(make_apfs_safe $profileName)

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $profileContents ]]; then
        update_display_list "Update" "" "${profileName}" "" "fail" "Not exported!"
        logMe "Profile ${profileName} not exported due to empty contents"
        failedMigration+=("${formatted_profileName}")
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

function create_vcf_cards ()
{
    declare processed_tasks=0
    declare tasks=()
    declare logMsg
    # PURPOSE: Create VCF cards from the JAMF users
    logMe "Creating VCF Cards from JAMF users"
    UserList=$(JAMF_retrieve_data_summary "JSSResource/users" "xml")
    create_display_list "The following VCF Cards are being created from the JAMF server" "xml" "name" $UserList
    UserIDs=$(echo $UserList | xmllint --xpath '//id' - 2>/dev/null)
    UserIDs=($(echo "$UserIDs" | grep -Eo "[0-9]+"))
    userCount=${#UserIDs[@]}

    for item in ${UserIDs[@]}; do
        tasks+=("extract_user_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"

   # Display how many Failed MDM command files were downloaded.
    DirectoryCount=$(ls $location_Contacts | wc -l | xargs )
    logMsg="$DirectoryCount Contacts were downloaded to $location_Contacts."
    logMe $logMsg 
    update_display_list "progress" "" "" "" "$logMsg" 100
    update_display_list "buttonenable"
    wait
}

function extract_user_details ()
{
    # PURPOSE: extract the XNL string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substrint to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare managed && managed=true

	[[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_details "JSSResource/users/id/$1" "xml"

    userShortName=$(extract_xml_data $xmlBlob "name")
    userFullName=$(extract_xml_data $xmlBlob  "full_name")
    userEmail=$(extract_xml_data $xmlBlob "email_address")
    userPosition=$(extract_xml_data $xmlBlob "position")


    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $userFullName ]]; then
        update_display_list "Update" "" "${userShortName}" "" "fail" "Not exported"
        logMe "User ${userShortName} not exported due to empty full name"
        failedMigration+=("${userShortName}")
    else
        update_display_list "Update" "" "${userShortName}" "" "wait" "Working..."
        logMe "Exporting user ${userShortName} (${userFullName}) to VCF file"

        if [[ $menu_onlyManagedUsers == "true" ]]; then
            # if they choose to include non-managed users, then we will not check for managed systems
            managed=$(extract_assigned_systems ${xmlBlob})
        fi

        # if they choose to show managed users only, then check if the user has any managed systems
        if [[ $managed == "false" ]]; then
            update_display_list "Update" "" "${userShortName}" "" "fail" "No managed systems"
        else
            #export the VCF file
            userVCFBlob=$(export_vcf_file $userFullName $userEmail $userPosition)
            echo "${userVCFBlob}" > "$location_Contacts/${userShortName}.vcf"
            update_display_list "Update" "" "${userShortName}" "" "success" "Finished"
        fi
    fi
}

function export_vcf_file
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
        inventory_data=$(JAMF_get_inventory_record $id "GENERAL")
        # Check if the managed field is true
        [[ $(echo $inventory_data | jq -r '.general.remoteManagement.managed') == "true" ]] && managed=true
    done
    echo $managed
}

###############################################
#
# Application functions
#
###############################################

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

function welcomemsg ()
{
    # PURPOSE: Display the welcome message to the user
    message="This set of utilities is designed to backup various items from your JAMF server. <br><br>Please select a destination folder location below:"

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --width 800
        --height 660
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
        --checkbox "Exported failed MDM commands (*.txt)",checked,name=BackupFailedMDMCommands
        --checkbox "↳ (Failed MDM): Optionally clear failed items",name=ClearFailedMDMCommands
        --checkbox "Backup System Scripts (*.sh)",checked,name=BackupJAMFScripts
        --checkbox "Backup Computer Extensions (*.sh)",checked,name=BackupComputerExtensions
        --checkbox "Backup Configuration Profiles (*.mobileconfig)",checked,name=BackupConfigurationProfiles
        --checkbox "Create VCF cards from email address (*.vcf)",checked,name=createVCFcards
        --checkbox " ↳ (VCF Option): Export only users with managed systems",name=OnlyManagedUsers
    )
	
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

    menu_backupSSIcons=$( echo $temp | jq -r '.BackupSSIcons')
    menu_backupJAMFScripts=$( echo $temp | jq -r '.BackupJAMFScripts' )
    menu_createVCFcards=$( echo $temp | jq -r '.createVCFcards' )
    menu_storageLocation=$( echo $temp | jq -r '.StorageLocation' )
    menu_computerea=$( echo $temp | jq -r '.BackupComputerExtensions' )
    menu_onlyManagedUsers=$( echo $temp | jq -r '.OnlyManagedUsers')
    menu_configurationProfiles=$( echo $temp | jq -r '.BackupConfigurationProfiles')
    menu_backupFailedMDM=$( echo $temp | jq -r '.BackupFailedMDMCommands' )

}

function show_backup_errors ()
{
    message="$1<br><br>"
    for item in "${failedMigration[@]}"; do
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
    location_JAMFScripts="${menu_storageLocation}/JAMFScripts"
    location_ComputerEA="${menu_storageLocation}/ComputerEA"
    location_Contacts="${menu_storageLocation}/Contacts"
    location_ConfigurationProfiles="${menu_storageLocation}/ConfigurationProfiles"
    location_FailedMDM="${menu_storageLocation}/FailedMDM"

    [[ ! -d "${menu_storageLocation}" ]] && /bin/mkdir -p "${menu_storageLocation}"
    [[ ! -d "$location_SSIcons" ]] && /bin/mkdir -p "$location_SSIcons"
    [[ ! -d "$location_JAMFScripts" ]] && /bin/mkdir -p "${location_JAMFScripts}"
    [[ ! -d "$location_ComputerEA" ]] && /bin/mkdir -p "${location_ComputerEA}"
    [[ ! -d "$location_Contacts" ]] && /bin/mkdir -p "${location_Contacts}"
    [[ ! -d "$location_ConfigurationProfiles" ]] && /bin/mkdir -p "${location_ConfigurationProfiles}"
    [[ ! -d "$location_FailedMDM" ]] && /bin/mkdir -p "${location_FailedMDM}"
    chmod -R 755 "${menu_storageLocation}"
    chown -R "${LOGGED_IN_USER}" "${menu_storageLocation}"
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
declare -a failedMigration
declare scriptCount
declare userCount
declare deviceCount
declare menu_backupJAMFScripts
declare menu_backupSSIcons
declare menu_createVCFcards
declare menu_storageLocation
declare menu_onlyManagedUsers
declare menu_computerea
declare menu_configurationProfiles
declare menu_backupFailedMDM
declare location_SSIcons
declare location_JAMFScripts
declare location_ComputerEA
declare location_Contacts
declare location_ConfigurationProfiles
declare location_FailedMDM
declare jamfpro_version

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg

JAMF_check_connection
JAMF_get_server
JAMF_get_classic_api_token
check_directories

[[ "${menu_backupSSIcons}" == "true" ]] && backup_ss_icons
[[ "${menu_backupFailedMDM}" == "true" ]] && export_failed_mdm_devices
[[ "${menu_backupJAMFScripts}" == "true" ]] && backup_jamf_scripts
[[ "${menu_computerea}" == "true" ]] && backup_computer_extensions
[[ "${menu_configurationProfiles}" == "true" ]] && backup_configuration_profiles
[[ "${menu_createVCFcards}" == "true" ]] && create_vcf_cards

JAMF_invalidate_token

# If we get here, then we are done with the script
logMe "JAMF Backup Utilities completed successfully!"
# Show errors if any failed backups occurred
echo "Failed "$failedMigration
[[ ! -z $failedMigration ]] && show_backup_errors "The following items could not be backed up for some reason!"
cleanup_and_exit


