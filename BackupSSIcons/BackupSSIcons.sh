#!/bin/zsh
#
# BackupSSIcons
#
# by: Scott Kendall
#
# Written: 05/21/2025
# Last updated: 05/21/2025
#
# Script Purpose: Backup JAMF Self service icons to a local folder
#
# 1.0 - Initial

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
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
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

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Backup Self Service Icons"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/BackupSSIcons.log"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/Applications/Self Service.app"
DIALOG_CMD_FILE=$(mktemp /var/tmp/BackupSSIcons.XXXXX)
JSON_DIALOG_BLOB=$(mktemp /var/tmp/BackupSSIcons.XXXXX)
/bin/chmod 666 $JSON_DIALOG_BLOB
/bin/chmod 666 $DIALOG_CMD_FILE

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
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

function welcomemsg ()
{
    message="This script will extract all of the Self Service icons from JAMF and store them in folder.  Please select a destination folder location below:"

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 800
        --height 460
        --ignorednd
        --quitkey 0
        --button1text "OK"
        --button2text "Cancel"
        --textfield "Select a storage location",fileselect,filetype=folder
    )
	
			
	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?
    [[ "$returnCode" == "2" ]] && cleanup_and_exit

	ssStoragePath=$( echo $temp | /usr/bin/grep "location" | awk -F ": " '{print $NF}' | tr -d '\' | tr -d '"')

}

function construct_dialog_header_settings()
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

	case "$1" in

	"Create" )

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

	"Destroy" )
	
		#
		# Kill the progress bar and clean up
		#
		echo "quit:" >> "${DIALOG_CMD_FILE}"
		;;

	"Update" | "Change" )

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

function check_ss_policy_icons ()
{

    declare PolicyId="$1"
    declare PolicyName
    declare ss_policy_check
    declare ss_icon
    declare ss_iconName
    declare ss_iconURI

	[[ -z "${PolicyId}" ]] && return 0

    #JAMF_Check_And_Renew_API_Token

    ss_xml_data=$(/usr/bin/curl -s "${jamfpro_url}JSSResource/policies/id/${PolicyId}"  -H "accept: application/xml" -H "Authorization: Bearer ${api_token}")
    PolicyName=$( echo "$ss_xml_data" | xmllint --xpath '/policy/general/name/text()' - 2>/dev/null)
    ss_policy_check=$(echo "$ss_xml_data" | xmllint --xpath '/policy/self_service/use_for_self_service/text()' - 2>/dev/null)
    ss_icon=$(echo "$ss_xml_data" | xmllint --xpath '/policy/self_service/self_service_icon/id/text()' - 2>/dev/null)
    ss_iconName=$(echo "$ss_xml_data" | xmllint --xpath '/policy/self_service/self_service_icon/filename/text()' - 2>/dev/null)
    ss_iconURI=$(echo "$ss_xml_data" | xmllint --xpath '/policy/self_service/self_service_icon/uri/text()' - 2>/dev/null)

    # Remove any special characters that might mess with APFS
    formatted_ss_policy_name=$(echo ${PolicyName} | sed -e 's/:/-/g' -e 's/ //g' -e 's/\//-/g' -e 's/|/-/g')
    ss_iconName=$(echo ${ss_iconName} | sed -e 's/:/-/g' -e 's/ //g')

    if [[ "$ss_policy_check" = "true" ]] && [[ -n "$ss_icon" ]] && [[ -n "$ss_iconURI" ]]; then
       # If the policy has an icon associated with it then extract the name & icon name and format it correctly and then download it
        update_display_list "Update" "" "${formatted_ss_policy_name}" "" "wait" "Working..."

        # Retrieve the icon and store it in the dest folder
        ss_icon_filepath="${formatted_ss_policy_name}"-"${PolicyId}"-"${ss_iconName}"
        logMe "${ss_icon_filepath} to ${ssStoragePath}."

        curl -s ${ss_iconURI} -X GET > "${ssStoragePath}"/"${ss_icon_filepath}"
        update_display_list "Update" "" "${formatted_ss_policy_name}" "" "success" "Finished"
    else
        update_display_list "Update" "" "${formatted_ss_policy_name}" "" "error" "No Icon"
    fi
}

function create_display_list ()
{
    construct_dialog_header_settings "The following Self Service Policy icons will be backed up" > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "first"

    echo $PolicyList | xmllint --xpath '//name' - | while IFS= read -r line; do
        # Remove the opening tag
        line="${line/<name>/}"
        # Remove the closing tag
        line="${line/<\/name>/}"
        line=$(echo ${line} | sed -e 's/:/-/g' -e 's/ //g' -e 's/\//-/g'  -e 's/|/-/g')
        create_listitem_message_body "$line" "" "pending" "Pending..."
    done
    create_listitem_message_body "" "" "" "" "last"
    update_display_list "Create"
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

function validate_JAMF_token () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")
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

function get_jamf_policy_list()
{
    PolicyList=$(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/xml" "${jamfpro_url}JSSResource/policies" )
    echo $PolicyList
}

function JAMF_Check_And_Renew_API_Token ()
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

     validate_JAMF_token

     # If the api_authentication_check has a value of 200, that means that the current
     # bearer token is valid and can be used to authenticate an API call.

     if [[ ${api_authentication_check} == 200 ]]; then

     # If the current bearer token is valid, it is used to connect to the keep-alive endpoint. This will
     # trigger the issuing of a new bearer token and the invalidation of the previous one.

          api_token=$(/usr/bin/curl "${jamfpro_url}/api/v1/auth/keep-alive" --silent --request POST -H "Authorization: Bearer ${api_token}" | plutil -extract token raw -)

     else

          # If the current bearer token is not valid, this will trigger the issuing of a new bearer token
          # using Basic Authentication.

          get_JamfPro_Classic_API_Token
     fi
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

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare api_token
declare jamfpro_url
declare ssStoragePath
declare PolicyList

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg

check_JSS_Connection
get_JAMF_Server
get_JamfPro_Classic_API_Token

# Download all Jamf Pro policy ID numbers

JAMF_Check_And_Renew_API_Token
PolicyList=$(get_jamf_policy_list)
create_display_list

PolicyIDList=$(echo $PolicyList | xmllint --xpath '//id' - 2>/dev/null)

IFS=$'\n'
PolicyIDs=($(echo "$PolicyIDList" | grep -Eo "[0-9]+"))
PoliciesCount=$(echo "$PolicyIDs" | grep -c ^)

logMe "Checking $PoliciesCount policies for Self Service icons ..."

# Loop thru all of the policies by multiple background processes

maxCurrentJobs=10
activeJobs=0

for item in ${PolicyIDs[@]}; do
    ((activeJobs=activeJobs%maxCurrentJobs)); ((activeJobs++==0)) #&& wait
    check_ss_policy_icons $item &
done

# Wait for remaining concurrent jobs to finish
sleep 10

DirectoryCount=$(ls ${ssStoragePath} | wc -l | xargs )

# Display how many Self Service icon files were downloaded.

logMe "$DirectoryCount Self Service icon files downloaded to $ssStoragePath."
invalidate_JAMF_Token
update_display_list "progress" "" "" "" "All Done!" 100
update_display_list "buttonenable"
wait
cleanup_and_exit