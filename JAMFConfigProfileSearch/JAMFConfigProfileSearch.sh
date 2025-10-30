#!/bin/zsh
#
# JAMFConfigProfileSearch
#
# by: Scott Kendall
#
# Written: 10/16/2025
# Last updated: 10/30/2025
#
# Script Purpose: Search for strings inside all Configuration Profiles
#
# 1.0 - Initial
# 1.1 - Add function to make sure Client / Secret are passed into the script
# 1.2 - Made grep search case insenstive

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

JSON_DIALOG_BLOB=$(mktemp /var/tmp/JAMFCPSearch.XXXXX)
DIALOG_CMD_FILE=$(mktemp /var/tmp/JAMFCPSearch.XXXXX)
/bin/chmod 666 $JSON_DIALOG_BLOB
/bin/chmod 666 $DIALOG_CMD_FILE

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_FILE="${SUPPORT_DIR}/logs/JAMFConfigProfileSearch.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}JAMF Config Profile Search"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

BACKGROUND_TASKS=20                 # Number of background tasks to run in parallel
EMAIL_APP='com.microsoft.outlook'   # Use the bundle identifier of your email app. you can find it by this command "osascript -e 'id of app "<appname>"' "

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

	# If the log directory doesnt exist - create it and set the permissions (using zsh paramter expansion to get directory)
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
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function check_for_sudo_access () 
{
  # Check if the effective user ID is 0.
  if [[ $EUID -ne 0 ]]; then
    # Print an error message to standard error.
    echo "This script must be run with root privileges. Please use sudo." >&2
    # Exit the script with a non-zero status code.
    cleanup_and_exit 1
  fi
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
        create_listitem_message_body "$line" "$5" "pending" "Pending..."
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

        "buttonchange" )

            # change text of button 1
            /bin/echo "button1text: ${2}" >> "${DIALOG_CMD_FILE}"
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

function extract_data_blob ()
{
    declare -a retval
    # PURPOSE: extract an XML string from the passed string
    # RETURN: parsed XML string
    # PARAMETERS: $1 - XML "blob"
    #             $2 - String to extract
    #             $3 - String type to extract (XML or JSON)
    # EXPECTED: None
    declare format=$3
    [[ -z "${format}" ]] && format="xml"
    if [[ ${format} == "xml" ]]; then
        retval=$(echo "$1" | xmllint --xpath "//$2/text()" - 2>/dev/null)
    else
        retval=$(echo -E "$1" | jq -r "$2")
    fi
    echo $retval
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
    echo -E $(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}" )
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

###############################################
#
# Backup Configuration Profiles functions
#
###############################################

function retrieve_configuration_profiles ()
{
    declare processed_tasks=0
    declare tasks=()
    declare JAMF_API_KEY="JSSResource/osxconfigurationprofiles"
    logMe "Examining conifiguration profiles"
    ProfileList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json")
    create_listitem_list "The following configuration profiles are being examined for your search key:<br>**$searchString**" "json" ".os_x_configuration_profiles[].name" "$ProfileList" "SF=gear.circle.fill,color=brown"

    ProfileIDs=($(echo -E $ProfileList | jq -r '.os_x_configuration_profiles[].id'))
    ProfileCount=${#ProfileIDs}

    for item in ${ProfileIDs[@]}; do
        tasks+=("extract_profile_details $item")
    done
    execute_in_parallel $BACKGROUND_TASKS "${tasks[@]}"
    update_display_list "progress" "" "" "" "Finished Scanning" 100
    update_display_list "buttonenable"
    wait
}

function extract_profile_details ()
{
    # PURPOSE: extract the JSON string from the JAMF ID and create a list of found items
    # RETURN: None
    # PARAMETERS: $1 - API substring to call from JAMF
    # EXPECTED: xmlBlob should be globally defined
    declare profileName
    declare profileContents
    declare JAMF_API_KEY="JSSResource/osxconfigurationprofiles"

    [[ -z "${1}" ]] && return 0

    JAMF_retrieve_data_blob_global "$JAMF_API_KEY/id/$1" "json"

    profileName=$(extract_data_blob $xmlBlob ".os_x_configuration_profile.general.name" "json"| head -n 1)
    profileContents=$(extract_data_blob $xmlBlob ".os_x_configuration_profile.general.payloads" "json")

    # if the script shows as empty (probably due to import issues), then show as a failure and report it
    if [[ -z $profileContents ]]; then
        update_display_list "Update" "" "${profileName}" "" "fail" "Not exported!"
        logMe "Profile ${profileName} not exported due to empty contents"
    else
        update_display_list "Update" "" "${profileName}" "" "wait" "Working..."
        if [[ $(echo $profileContents | grep -i $searchString) ]]; then
            logMe "Found search string in: ${profileName}"
            update_display_list "Update" "" "${profileName}" "" "success" "Found!"
        else
            logMe "Not found in: ${profileName}"
            update_display_list "Update" "" "${profileName}" "" "" "Done"
        fi
    fi
}

function welcomemsg ()
{
    message="Enter your search criteria below to search thru all of your Configuration Profiles for that key.  Results will be displayed on the next screen."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --moveable
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --textfield "Search string",required,name=searchstring
        --helpmessage ""
        --width 820
        --height 450
        --ignorednd
        --json
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    [[ "$returnCode" == "2" ]] && {JAMF_invalidate_token; cleanup_and_exit 0;}

    searchString=$(echo $temp | jq -r '.searchstring')
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

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare api_token
declare jamfpro_url
declare searchString
declare xmlBlob

check_for_sudo_access
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
JAMF_check_connection
JAMF_get_server
JAMF_check_credentials
# Check if the JAMF Pro server is using the new API or the classic API
# If the client ID is longer than 30 characters, then it is using the new API
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token   
OVERLAY_ICON=$(JAMF_which_self_service) 

welcomemsg
retrieve_configuration_profiles
JAMF_invalidate_token
cleanup_and_exit 0