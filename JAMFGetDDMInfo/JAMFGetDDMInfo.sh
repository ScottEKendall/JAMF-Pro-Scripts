#!/bin/zsh
#
# GetDDMInfo.sh
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 01/16/2026
#
# Script Purpose: Retrieve the DDM info for JAMF devices
#
# 0.1 - Initial
# 0.2 - had to add "echo -E $1" before each of the jq commands to strip out non-ascii characters (it would cause jq to crash) - Thanks @RedShirt
#       Script can now perform functions based on SmartGroups
# 0.3 - Put error trap in JAMF API calls to see if returns "INVALID_PRIVILEGE""
# 0.4 - Optimized some loop routines and put in more error trapping.  Add feature to include DDM Software Failures in CSV report / Optimized JAMF functions for faster processing
# 0.5 - Added support for both smart & static groups (had to use the Classic API to do this)
#       Added Verbal description of Blueprint activation failures
#       Took advantage of some AI Tools to optimize the "common" section and optimize more JAMF functions
#       Removed the extra verbiage at the end of the Blueprint IDs
#       Added button to open the Blueprint links in your browser
# 0.6 - Add more safety net around the JQ command to make sure it won't error out.
#       More detailed reporting in CSV file
#       Reported if DDM is not enabled on a system.
# 0.7 - Background processing!  Major speed improvement
#       Progress during list items to show actual progress
# 0.8	Preliminary support for blueprints
#       Several GUI enhancements, including verbiage and typos
#       Ability to choose export location for Individual systems
#       Report on more DDM fields
# 0.9 - Got the scan for blueprints feature working (fully multitasking aware)
#       Added option to show success and/or failed on blueprint scan
#       Made minor GUI changes
#       Show dialog notification during long inventory retrievals


######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
declare DIALOG_PROCESS
SCRIPT_NAME="GetDDMInfo"
SCRIPT_VERSION="0.9 Alpha"
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
DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")
TMP_FILE_STORAGE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")
chmod 666 $JSON_DIALOG_BLOB
chmod 666 $DIALOG_COMMAND_FILE
chmod 666 $TMP_FILE_STORAGE

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Retrieve JAMF DDM Info"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="SF=list.bullet.circle,color=orange,weight=heavy,bgcolor=none"
#OVERLAY_ICON="/System/Applications/App Store.app"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"
CSV_OUTPUT="$USER_DIR/Desktop/DDM Data Dump for "

# Multitasking items

BACKGROUND_TASKS=10                 # Number of background tasks to run in parallel
JAMF_INVENTORY_PAGE_SIZE=100        # JAMF records to return at once from the API inventory lookup
##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"
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

function update_display_list ()
{
    # setopt -s nocasematch
    # This function updates the Swift Dialog list display with easy to implement parameter passing...
    # The Swift Dialog native structure is very strict with the command structure...this routine makes
    # it easier to implement
    #
    # Param list
    #
    # $1 - Action to be done ("Create", "Add", "Change", "Clear", "Info", "Show", "Done", "Update")
    # ${2} - Affected item (2nd field in JSON Blob listitem entry)
    # ${3} - Icon status "wait, success, fail, error, pending or progress"
    # ${4} - Status Text
    # $5 - Progress Text (shown below progress bar)
    # $6 - Progress amount
            # increment - increments the progress by one
            # reset - resets the progress bar to 0
            # complete - maxes out the progress bar
            # If an integer value is sent, this will move the progress bar to that value of steps
    # the GLOB :l converts any inconing parameter into lowercase

    
    case "${1:l}" in
 
        "create" | "show" )
 
            # Display the Dialog prompt
            $SW_DIALOG --progress --jsonfile "${JSON_DIALOG_BLOB}" --commandfile "${DIALOG_COMMAND_FILE}" &
            DIALOG_PROCESS=$! #Grab the process ID of the background process
            ;;
     
        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            /bin/echo "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonaction" )

            # Change button 1 action
            /bin/echo 'button1action: "'${2}'"' >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "buttonchange" )

            # change text of button 1
            /bin/echo "button1text: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttondisable" )

            # disable button 1
            /bin/echo "button1: disable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonenable" )

            # Enable button 1
            /bin/echo "button1: enable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar
            /bin/echo "listitem: title: "$3", status: $5, statustext: $4" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progress: $6" >> "${DIALOG_COMMAND_FILE}"

            /bin/sleep .5
            ;;
  
        "clear" )
  
            # Clear the list and show an optional message  
            /bin/echo "list: clear" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "message: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "delete" )
  
            # Delete item from list  
            /bin/echo "listitem: delete, title: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
 
        "destroy" )
     
            # Kill the progress bar and clean up
            /bin/echo "quit:" >> "${DIALOG_COMMAND_FILE}"
            ;;
 
        "done" )
          
            # Complete the progress bar and clean up  
            /bin/echo "progress: complete" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: $5" >> "${DIALOG_COMMAND_FILE}"
            ;;
          
        "icon" )
  
            # set / clear the icon, pass <nil> if you want to clear the icon  
            [[ -z ${2} ]] && /bin/echo "icon: none" >> "${DIALOG_COMMAND_FILE}" || /bin/echo "icon: ${2}" >> $"${DIALOG_COMMAND_FILE}"
            ;;
  
  
        "image" )
  
            # Display an image and show an optional message  
            /bin/echo "image: ${2}" >> "${DIALOG_COMMAND_FILE}"
            [[ ! -z ${3} ]] && /bin/echo "progresstext: $5" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "infobox" )
  
            # Show text message  
            /bin/echo "infobox: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "infotext" )
  
            # Show text message  
            /bin/echo "infotext: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "show" )
  
            # Activate the dialog box
            /bin/echo "activate:" >> $"${DIALOG_COMMAND_FILE}"
            ;;
  
        "title" )
  
            # Set / Clear the title, pass <nil> to clear the title
            [[ -z ${2} ]] && /bin/echo "title: none:" >> "${DIALOG_COMMAND_FILE}" || /bin/echo "title: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: ${5}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
    esac
}

function construct_dialog_header_settings ()
{
    # Construct the basic Swift Dialog screen info that is used on all messages
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
        "button2text" : "Cancel",
        "infotext": "'$SCRIPT_VERSION'",
        "height" : "640",
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

function create_dropdown_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - values (comma separated list)
    #        $3 - default option
    #        $4 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    [[ "$4:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2'], "default" : "'$3'",},'
    [[ "$4:l" == "last" ]] && line+=']'
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
    json_blob=$(echo -E $1 |jq -r ' '${2}' | "\(.id) - \(.name)"')
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

function extract_string ()
{
    # PURPOSE: Extract (grep) results from a string 
    # RETURN: parsed string
    # PARAMS: $1 = String to search in
    #         $2 = key to extract
    
    echo -E $1 | tr -d '\n' | jq -r "$2"
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --message "**Problems retrieving JAMF Info**<br>Error Message: $ID"
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
}

###########################
#
# JAMF functions
#
###########################

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
    local format="${2:-xml}"
    echo $(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}" )
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
    local format="${2:-xml}"
    xmlBlob=$(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}")
}

function JAMF_retrieve_data_blob ()
{
    # PURPOSE: Extract the summary of the JAMF command results
    # RETURN: formatted contents of command
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
    case "${retval}" in
        *"INVALID_ID"* ) retval="INVALID_ID" ;;
        *"PRIVILEGE"* ) retval="ERR" ;;
        *) [[ ! -z $3 ]] && retval=$(echo -E "$retval" | jq  '[.[] | select('$3')]') ;;
    esac
    printf "%s" "$retval"
}

function JAMF_get_inventory_record()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS:  $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $2 - Filter condition to use for search

    local retval
    retval=$(/usr/bin/curl --silent --fail --get -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" --data-urlencode "section=$1" --data-urlencode "filter=$2" "${jamfpro_url}api/v2/computers-inventory")
    printf "%s" "$retval"
}

function JAMF_get_bulk_inventory_record ()
{
    # PURPOSE: Uses the JAMF moern API to retrieve inventory info
    # NOTE: You can change the JAMF_INVENTORY_PAGE_SIZE to control how many results are returen in a single API call.
    #       This can be adjusted to suite your environment / performance results
    # RETURN: JSON blob of inventory records
    # PARMS:  None
    # EXPECTED: jamfpro_url, api_token

    local JAMF_API_KEY="api/v3/computers-inventory"
    local page=0
    local first_item=true  # Flag to track the very first item
    ${SW_DIALOG} --notification --identifier "inventory" --title "Retieving JAMF Inventory Records" --message "Please be patient" --button1text "Dismiss"

    echo '[' > "$TMP_FILE_STORAGE"
    while :; do
        results=$(curl -sS -H "Authorization: Bearer $api_token" -H "Accept: application/json" "$jamfpro_url/$JAMF_API_KEY?page=$page&page-size=$JAMF_INVENTORY_PAGE_SIZE")
        
        # a couple of verification checks to make sure we have valid data
        [[ -z "$results" || "$results" == "null" ]] && break
        
        results_count=$(jq '.results | length' <<<"$results")
        (( results_count == 0 )) && break
        
        # Process each object in the current results page
        # jq -c ensures each object is on a single line
        jq -c '.results[] | {id: .id, name: .general.name, managementId: .general.managementId}' <<<"$results" | while read -r line; do
            if [[ "$first_item" == true ]]; then
                echo "  $line" >> "$TMP_FILE_STORAGE"
                first_item=false
            else
                # Prepend a comma to all subsequent items
                echo "  ,$line" >> "$TMP_FILE_STORAGE"
            fi
        done
        ((page++))
    done
    # Close the JSON array
    echo ']' >> "$TMP_FILE_STORAGE"

    ${SW_DIALOG} --notification --identifier "inventory" --remove
    # Re-read in the file into an array for faster processing
    printf "%s" $(<"$TMP_FILE_STORAGE")
}

function JAMF_get_deviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID from the JAMF Pro server.
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - search identifier to use (serial or Hostname)
    #        $2 - Conputer ID (serial/hostname)
    local retval
    local ID
    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    retval=$(/usr/bin/curl -s --fail -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computers-inventory?section=GENERAL&filter=${type}=='${2}'")
    ID=$(echo $retval |  tr -d '[:cntrl:]' | jq -r "${3}")

    # 4. Streamlined Error Handling
    if [[ -z "$ID" ]]; then
        display_failure_message
        echo "ERR"
        return 1
    fi
    echo "$ID"
}

function JAMF_get_DDM_info ()
{
    # PURPOSE: uses the ManagementId to retrieve the DDM info
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - Management ID
    local retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/ddm/${1}/status-items")
    case "${retval}" in
        *"INVALID"* | *"PRIVILEGE"* ) printf '%s\n' "ERR" ;;
        *"Client $1 not found"* ) printf '%s\n' "NOT FOUND" ;;  # DDM not active
        *) printf '%s\n' "${retval}";;
    esac
}

function JAMF_retrieve_ddm_softwareupdate_info () 
{
    # PURPOSE: extract the DDM Software update info from the computer record
    # RETURN: array of the DDM software update information
    # PARMS: $1 - DDM JSON blob of the computer
    local results
    results=$(jq -r '[.statusItems[]? | select(.key | startswith("softwareupdate.pending-version.")) | select(.value != null) | (.key | ltrimstr("softwareupdate.pending-version.")) + ":" + (.value | tostring)] +
        [.statusItems[]? | select(.key | startswith("softwareupdate.install-")) | .value] | join("\n")' <<< "$1")
    DDMSoftwareUpdateActive=("${(f)results}")
}

function JAMF_retrieve_ddm_softwareupdate_failures () 
{
    cleaned=$(printf '%s' "$1" | perl -pe 's/([\x00-\x1F])/sprintf("\\u%04X", ord($1))/eg')
    results=$(printf '%s' "$cleaned" | jq -r '.statusItems[]? | select(.key | startswith("softwareupdate.failure-reason.")) | select(.value != null) | "\(.key | ltrimstr("softwareupdate.failure-reason.")):\(.value)"')
    DDMSoftwareUpdateFailures=("${(f)results}")
}

function JAMF_retrieve_ddm_blueprint_active ()
{
    # 1. jq extracts the inner 'value' string.
    # 2. perl searches for blocks containing active=false.
    # 3. The regex captures the ID, optionally skipping the 'Blueprint_' prefix.
    DDMBlueprintSuccess=(${(f)"$(printf "%s" "$1" | jq -r '.value' | perl -nle 'while(/active=true, identifier=(Blueprint_)?([^,}_]+)(?:_s1_sys_act1)?/g) { print $2 }')"})
}

function JAMF_retrieve_ddm_blueprint_errrors ()
{
    # 1. jq extracts the inner 'value' string.
    # 2. perl searches for blocks containing active=false.
    # 3. The regex captures the ID, optionally skipping the 'Blueprint_' prefix.
    DDMBlueprintErrors=(${(f)"$(printf "%s" "$1" | jq -r '.value' | perl -nle 'while(/active=false, identifier=(Blueprint_)?([^,}_]+)(?:_s1_sys_act1)?/g) { print $2 }')"})
}

function JAMF_retrieve_ddm_keys ()
{
    # PURPOSE: uses the ManagementId to retrieve the DDM info
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - Management ID
    #        $2 - Specific DDM Keys to extract
    printf "%s" $1 | jq -r '.statusItems[] | select(.key == "'$2'")'
}

function JAMF_DDM_export_summary_to_csv ()
{
    # PURPOSE: Extract (display) all of the DDM entries and store them in a CSV file for better readability
    # RETURN: None
    # PARMS: $1 - DDMInfo for the computer record (should have already been populated)

    printf "%s" $1 | jq -r '.statusItems[] | select(.key) | [.lastUpdateTime, .key, .value] | @csv' >> $CSV_OUTPUT
}

function JAMF_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* || -z $retval ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    echo $retval
}

###########################
#
# Application functions
#
###########################


function welcomemsg ()
{
    helpmessageurl="https://support.apple.com/guide/deployment/intro-to-declarative-device-management-depb1bab77f8/web"
    helpmessage="Apple's Declarative Device Management (DDM) is a modern, autonomous management framework that allows Apple devices (iOS, iPadOS, macOS) to proactively apply settings, enforce security policies, and report status changes without constant,"
    helpmessage+="synchronous polling from an MDM server. It enhances performance and scalability by enabling devices to act independently based on predefined, locally stored declarations.<br><br>"
    helpmessage+="Apple's official documentation:<br><br>"$helpmessageurl

    message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, You can choose to search all of your computers for a Blueprint ID, a single computer's Declarative Device Maanagement (DDM) status, or a smart/static group "
    message+="for each computer's DDM status.<br><br>After your selection, another menu will appear with more options."

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --titlefont shadow=1
        --message $message
        --messagefont name=Arial,size=17
        --selecttitle "View DDM data from:",radio --selectvalues "Blueprint ID, Single System, Smart/Static Group"
        --helpmessage $helpmessage
        --helpimage "qr="$helpmessageurl
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 440
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?
    [[ $buttonpress = 2 ]] && DDMoption="quit" || DDMoption=$(echo $message | plutil -extract 'SelectedOption' 'raw' -)
    logMe "$DDMoption was choosen"
    echo $DDMoption
}

function execute_in_parallel ()
{
    local process_type=$1 #First param is what type of processing
    shift
    local ids=("$@")  # Receive as array
    current_jobs=0
    item_count=1
    numberOfComputers=${#ids}
    for ID in "${ids[@]}"; do
        while (( (current_jobs=${#jobstates}) >= BACKGROUND_TASKS )); do sleep 0.05; done  # Tighter polling
        progress=$(( (item_count * 100) / numberOfComputers ))
        update_display_list "progress" "" "" "" "" $progress
        ((item_count++))
        if [[ $process_type == "blueprint" ]]; then
            process_blueprint_computer "$ID" &
        else
            process_group_computer "$ID" &
        fi
    done
}

###########################
#
# Blueprint functions
#
##########################

function welcomemsg_blueprint ()
{
    message="**View DDM info from Blueprints**<br><br>You have selected to view information from a Blueprint ID.  Please paste the entire URL of your JAMF blueprint, and all systems "
    message+="will be scanned for the existence of the blueprint (regardless of status).<br><br>*NOTE: If you choose to export the data to a CSV file, it will be created to show the data with more details.*"
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --titlefont shadow=1
        --message "$message"
        --messagefont name=Arial,size=17
        --vieworder "textfield,dropdown"
        --selecttitle "Display results" --selectvalues "Both Active & Failed,Failed Only,Active Only" --selectdefault "Both Active & Failed"
        --textfield "Blueprint URL,name=BPUrl,required"
        --checkbox "Export CSV file",name="exportCSV"
        --checkboxstyle switch
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?

    [[ $buttonpress = 2 ]] && exit 0
    blueprintID=$(echo $message | jq -r '.BPUrl')
    blueprintID=$(echo $blueprintID:t)
    writeCSVFile=$(echo $message | jq -r '.exportCSV')
    displayResults=$(echo $message | jq -r '."Display results" .selectedValue')
    process_blueprint $blueprintID
}

function process_blueprint ()
{
    # PURPOSE: Scan all system to locate the requested blueprint that are active or disabled 
    # RETURN: None
    # EXPECTED: Nonex
    # NOTE: Three JAMF keys are used here
    #       JAMF_API_KEY = Faster lookup of computer names (for display purposes)
    #       JAMF_API_KEY2 = Modern API call to get computer IDs (for JAMF )
    #
    # API workflow - You have to call the inventory to get the ID of the computer and the Management ID (these are two seperate items)
    # then, you have to use the Management ID to call the DDM info

    # Remove double quotes and split by '-' into an array 'parts'
    local blueprintID=$1    
    local shouldWrite=false
    local CSV_HEADER="System, ManagementID,LastUpdate,Status,Blueprint Failed IDs,Blueprint Failed Reason, Software Update Failures"
    local computerList numberOfComputers ids

    # Initialize CSV if needed
    if [[ "$writeCSVFile" == true ]]; then
        CSV_OUTPUT+="$blueprintID ($displayResults).csv"
        printf "%s\n" "$CSV_HEADER" > "$CSV_OUTPUT"
        logMe "Creating file: $CSV_OUTPUT"
    fi

    logMe "Retrieving DDM Info for Blueprint: $blueprintID"

    # Read in the computer inventory for all systems, capture, the ID, name & managementID of each computer
    # by using the modern API with the inventory pagination method, we are doing to use as litle RAM as possible
    computerList=$(JAMF_get_bulk_inventory_record)

    numberOfComputers=$(jq -r 'length' <<< "$computerList")
    logMe "INFO: There are $numberOfComputers Computers to scan for $blueprintID"

    create_listitem_list "Locating asssigned systems that have Blueprint:<br>$blueprintID installed." \
        "json" ".[].name" "$computerList" "SF=desktopcomputer.and.macbook"
 
     # Get the list of IDs
    ids=($(jq -r '.[].id' <<< "$computerList"))

    # Execute parallel tasks
    execute_in_parallel "blueprint" "${ids[@]}"

    update_display_list "progress" "" "" "" "" 100
    update_display_list "buttonenable"
    wait
}

function process_blueprint_computer () 
{
    local JAMF_API_KEY2="api/v2/computers-inventory"
    local ID="$1"
    local statusmessage="BP found (Active)"
    local DDMInfo DDMInfo_clean DDMKeys
    local sanitized_bperrors_reason sanitized_bperrors sanitized_clean_swu
    local numberOfComputers JSONblob
    local name managementId lastUpdateTime canWrite liststatus

    local DDMErrorReason
    liststatus="success"

    # Extract info from Computer Inventory

    JSONblob=$(JAMF_retrieve_data_blob "$JAMF_API_KEY2/$ID?section=GENERAL" "json")
    [[ -z "$JSONblob" ]] && return

    name=$(printf "%s" "$JSONblob" | jq -r '.general.name')
    managementId=$(printf "%s" "$JSONblob" | jq -r '.general.managementId')

    DDMInfo=$(JAMF_get_DDM_info "$managementId")
    [[ "$DDMInfo" == "ERR" ]] && { 
        logMe "ERROR: Insufficient privileges to read DDM Info for $name" >&2
        return 1
    }
    [[ "$DDMInfo" == "NOT FOUND" ]] && {
        logMe "ERROR: DDM may not be active on device: $name"
        update_display_list "Update" "" "${name}" "DDM may not be active" "error" 
        return 0
    }
    # See if the BP exists in the DDM record, if nothing found, exit early
    if [[ -z $(echo $DDMInfo | grep "$blueprintID") ]]; then
        update_display_list "Update" "" "${name}" "BP not found." "pending"
        return 0
    fi

    DDMInfo_clean=$(tr -d '[:cntrl:]' <<< "$DDMInfo")
    DDMKeys=$(jq -r '.statusItems[] | select(.key == "management.declarations.activations")' <<< "$DDMInfo_clean")
    lastUpdateTime=$(jq -r '(.statusItems[] | select(.key == "softwareupdate.failure-reason.reason") | .lastUpdateTime) // "N/A"' <<< "$DDMInfo_clean")

    JAMF_retrieve_ddm_blueprint_active "$DDMKeys"
    JAMF_retrieve_ddm_blueprint_errrors "$DDMKeys"
    JAMF_retrieve_ddm_softwareupdate_failures "$DDMInfo_clean"

    [[ -n "$DDMBlueprintErrors" ]] && { liststatus="fail"; statusmessage="BP found (Failed)"; }
    update_display_list "Update" "" "${name}" "${statusmessage}" "${liststatus}"

    # Eval criteria
    case "$displayResults" in
        "Failed Only") [[ "$liststatus" == "fail" ]] && canWrite=true ;;
        "Active Only") [[ "$liststatus" == "success" ]] && canWrite=true ;;
        *) canWrite=true ;;
    esac

    # Early exit if we don't need to write out the CSV file
    [[ "$writeCSVFile" = false && "$canWrite" = true ]] && { printf "INFO: System: %s - ManagementID: %s - Status: %s\n" "$name" "$managementId" "$statusmessage"; return 0; }

    [[ "$includeSWUFail" == false ]] && DDMSoftwareUpdateFailures=""

    sanitized_clean_swu="${DDMSoftwareUpdateFailures//,/;}"
    sanitized_bperrors="${DDMBlueprintErrors//,/;}" 
    sanitized_bperrors_reason=""
    if [[ -n "$DDMBlueprintErrors" ]]; then
        DDMErrorReason=$(printf "%s" "$DDMKeys" | perl -ne 'print "$1\n" if /code=([^},]+)/')
        sanitized_bperrors_reason="${DDMErrorReason//,/;}"
    fi

    if [[ $canWrite  = true ]]; then
        # Write out this info to the CSV file
        printf "%s, %s, %s, %s, %s, %s, %s\n" "$name" "$managementId" "$lastUpdateTime" "$liststatus" "$sanitized_bperrors" "$sanitized_bperrors_reason" "$sanitized_clean_swu" >> "$CSV_OUTPUT"
        logMe "$statusmessage found on system: $name"
    fi
}

###########################
#
# Individual computer functions
#
##########################

function welcomemsg_individual ()
{
    message="**View Individual System**<br><br>Please enter the serial or hostname of the device you wish to see the DDM information for.  The results for Software Updates, Active & Failed Blueprints, as well as any error messages will be displayed.<br><br>"
    message+="*NOTE: If you choose to export the data, a TXT file will be created at your choosen location.  Leave the TXT Folder location empty if you do not want to export data*."
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --titlefont shadow=1
        --message $message
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --selecttitle "Serial,required"
        --textfield "TXT folder location,fileselect,filetype=folder,prompt=$CSV_OUTPUT,name=writeTXTFile"
        --checkboxstyle switch
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    [[ $buttonpress = 2 ]] && exit 0
    search_type=$(echo $message | jq -r '.SelectedOption')
    computer_id=$(echo $message | jq -r '.Device')
    writeTXTFile=$(echo $message | jq -r '.writeTXTFile')
}

function process_individual ()
{

    declare search_type=$1
    declare computer_id=$2
    declare DDMInfo
    declare DDMKeys

    # First we have to get the JAMF ManagementID of the machine

    ID=$(JAMF_get_deviceID "${search_type}" ${computer_id} ".results[].general.managementId")
    [[ $ID == *"ERR"* ]] && cleanup_and_exit 1

    # Second is to extract the DDM info for the machine
    DDMInfo=$(JAMF_get_DDM_info $ID)
    logMe "INFO: JAMF ID: $ID"

    # Lets extract all the DDM info from this JSON blob

    DDMBatteryHealth=$(echo $DDMInfo | jq -r '.statusItems[] | select(.key == "device.power.battery-health").value')
    DDMClientSupportedVersions=$(echo $DDMInfo | jq -r '.statusItems[] | select(.key == "management.client-capabilities.supported-versions").value')
    DDMClientSupportedPayload=$(echo $DDMInfo | jq -r '.statusItems[] | select(.key == "management.client-capabilities.supported-payloads.declarations.configurations").value')

    # Third, extract the DDM Software Update info for the machine
    JAMF_retrieve_ddm_softwareupdate_info "$DDMInfo"
    logMe "INFO: Software Update Info: "$DDMSoftwareUpdateActive

    # Fourth, see if there are any software update failures
    JAMF_retrieve_ddm_softwareupdate_failures "$DDMInfo"
    logMe "INFO: Software Update Failures: "$DDMSoftwareUpdateFailures

    # Fifth, extract the DDM blueprint IDs assigned to the machine
    DDMKeys=$(JAMF_retrieve_ddm_keys $DDMInfo "management.declarations.activations")

    JAMF_retrieve_ddm_blueprint_active "$DDMKeys"
    logMe "INFO: Active Blueprints: "$DDMBlueprintSuccess

    # Sixth, see if there are any inactive Blueprints
    JAMF_retrieve_ddm_blueprint_errrors "$DDMKeys"
    logMe "INFO: Inactive Blueprints: "$DDMBlueprintErrors

    if [[ ! -z $DDMBlueprintErrors ]]; then
        #DDMErrorReason=$(echo $DDMKeys)
        DDMErrorReason=$(echo $DDMKeys | perl -ne 'print "$1\n" if /code=([^},]+)/')
    fi
    #Show the results and log it

    message="**Device name:** <br>$computer_id<br><br>**JAMF Management ID:**<br>$ID<br><br><br>"
    message+="<br><br>**DDM Client Supported Version**<br>$DDMClientSupportedVersions"
    message+="<br><br>**DDM Blueprints Active**<br>${(j:<br>:)DDMBlueprintSuccess}<br>"
    message+="<br><br>**DDM Blueprint Failures**<br>${(j:<br>:)DDMBlueprintErrors}<br>"
    message+="<br><br>**DDM Blueprint Failure Reason**<br>$DDMErrorReason<br>"
    message+="<br><br>**DDM Software Update Info**<br>${(j:<br>:)DDMSoftwareUpdateActive}<br>"
    message+="<br><br>**DDM Software Update Failures**<br>${(j:<br>:)DDMSoftwareUpdateFailures}<br>"
    message+="<br><br>**DDM Client Supported Payload**<br>$DDMClientSupportedPayload"


    # Log and show the results
    logMessage="${message//<br>/\\n}"
    #logMe "Results: "$logMessage
    display_results $message

    if [[ ! -z "$writeTXTFile" ]]; then
        CSV_OUTPUT="$writeTXTFile/DDM Resuults for $computer_id.txt"
        logMe "Export file: $CSV_OUTPUT"
        echo $logMessage > "$CSV_OUTPUT"
        #JAMF_DDM_export_summary_to_csv $DDMInfo
    fi
}

function display_results ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --titlefont shadow=1
        --message "Here are the result of the DDM info for this mac:<br><br>$1"
        --messagefont name=Arial,size=14
        --helpmessage "Add this URL prefix to the Blueprint ID to find the Blueprint details<br>$jamfpro_url/view/mfe/blueprints/"
        --button1text "OK"
        --ontop
        --width 850
        --height 750
        --json
        --moveable
    )

    [[ $extractRAWData == "true" ]] && MainDialogBody+=(--infotext "The CSV file will be stored in $USER_DIR/Desktop") || MainDialogBody+=(--infotext $SCRIPT_VERSION)
    [[ ! -z $DDMBlueprintSuccess ]] && MainDialogBody+=(--button2text "Open BP Links")
    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    [[ $buttonpress = 2 ]] && openn_blueprint_links
}

function openn_blueprint_links ()
{
    declare -a BPLinks
    for item in "${DDMBlueprintSuccess[@]}"; do
        open "${jamfpro_url}/view/mfe/blueprints/$item"
    done
}

###########################
#
# Smart/Static group functions
#
##########################

function welcomemsg_group ()
{
    # PURPOSE: Export Application Usage for a users / group
    # RETURN: None
    # EXPECTED: None
    declare GroupList
    declare xml_blob
    declare -a array
    declare JAMF_API_KEY="JSSResource/computergroups"

    message="**View DDM info from groups**<br><br>You have selected to view information from Smart/Static Groups.<br>Please select the group and display results fron options below:<br><br>"
    message+="*NOTE: If you choose to export the data to a CSV file, it will be created to show the data with more details.*"
    construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"

    # Read in the JAMF groups and create a dropdown list of them
    tempArray=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json")
    GroupList=$(echo $tempArray | jq -r '.computer_groups')
    if [[ -z $GroupList ]]; then
        logMe "Having problems reading the groups list from JAMF, exiting..."
        cleanup_and_exit 1
    fi
    create_dropdown_message_body "" "" "" "first"
    array=$(construct_dropdown_list_items $GroupList '.[]')
    create_dropdown_message_body "Select Groups:" "$array" "1"


    create_dropdown_message_body "Display results" '"Both Active & Failed", "Failed Only", "Active Only"' "Both Active & Failed"
    create_dropdown_message_body "" "" "" "last"
    echo ',' >> "${JSON_DIALOG_BLOB}"
    create_checkbox_message_body "" "" "" "" "" "first"
    create_checkbox_message_body "Export all data to CSV File" "exportcsv" "" "true" "false"
    create_checkbox_message_body "Include SW Update failures in CSV File" "includeSWUFail" "" "true" "false" "last"
    echo "}" >> "${JSON_DIALOG_BLOB}"

	message=$(${SW_DIALOG} --vieworder "dropdown, checkbox" --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    buttonpress=$?
    [[ $buttonpress = 2 ]] && cleanup_and_exit 0

    jamfGroup=$(echo $message | jq '."Select Groups:" .selectedValue')
    displayResults=$(echo $message | jq -r '."Display results" .selectedValue')
    writeCSVFile=$(echo $message | jq '.exportcsv')
    includeSWUFail=$(echo $message | jq '.includeSWUFail')
    process_group $jamfGroup $displayResults
}

function process_group ()
{
    # PURPOSE: Export the application usage for each computer in the group
    # RETURN: None
    # EXPECTED: None
    # NOTE: Three JAMF keys are used here
    #       JAMF_API_KEY = Faster lookup of computer names (for display purposes)
    #       JAMF_API_KEY2 = Modern API call to get computer IDs (for JAMF )
    #
    # API workflow - You have to call the inventory to get the ID of the computer and the Management ID (these are two seperate items)
    # then, you have to use the Management ID to call the DDM info

    # Remove double quotes and split by '-' into an array 'parts'
    local parts=("${(@s:-:)${1//\"/}}")

    # Assign variables and trim surrounding whitespace using the (z) flag or expansion
    local GroupID="${parts[1]//[[:space:]]/}"
    local GroupName="${parts[2]}"
    local JAMF_API_KEY="JSSResource/computergroups/id"
    local computerList
    local CSV_HEADER="System, ManagementID,LastUpdate,Status,Blueprint Failed IDs,Blueprint Failed Reason, Software Update Failures"
    local shouldWrite=false
    local numberOfComputers
    local ids
    local current_jobs

    # Initialize CSV if needed
    if [[ "$writeCSVFile" == true ]]; then
        CSV_OUTPUT+="$GroupName ($displayResults).csv"
        printf "%s\n" "$CSV_HEADER" > "$CSV_OUTPUT"
        logMe "Creating file: $CSV_OUTPUT"
    fi

    logMe "Retrieving DDM Info for group: $GroupName (ID: $GroupID)"
    # Locate the IDs of each computer in the selected gruop
    logMe "INFO: Retrieve information for: $1"
    computerList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY/$GroupID" "json")
    [[ $computerList == "ERR" ]] && {logMe "ERROR: Insufficient privleges to read Groups"; cleanup_and_exit 1;}

    numberOfComputers=$(jq -r '.computer_group.computers | length' <<< "$computerList") 
    logMe "INFO: There are $numberOfComputers Computers in$GroupName"

    create_listitem_list "Retrieving DDM Info from computers that are in group:<br> $GroupName." \
        "json" ".computer_group.computers[].name" "$computerList" "SF=desktopcomputer.and.macbook"
 
     # Get the list of IDs
    ids=($(jq -r '.computer_group.computers[].id' <<< "$computerList"))

    # Execute parallel tasks
    execute_in_parallel "group" "${ids[@]}"

    update_display_list "progress" "" "" "" "" 100
    update_display_list "buttonenable"
    wait
}

function process_group_computer () 
{
    local JAMF_API_KEY2="api/v2/computers-inventory"
    local ID="$1"
    local statusmessage="No BP errors found"
    local DDMInfo DDMInfo_clean DDMKeys
    local sanitized_bperrors_reason sanitized_bperrors sanitized_clean_swu
    local numberOfComputers JSONblob
    local name managementId lastUpdateTime canWrite liststatus

    local DDMErrorReason
    liststatus="success"

    # Extract info from Computer Inventory

    JSONblob=$(JAMF_retrieve_data_blob "$JAMF_API_KEY2/$ID?section=GENERAL" "json")
    [[ -z "$JSONblob" ]] && return

    name=$(printf "%s" "$JSONblob" | jq -r '.general.name')
    managementId=$(printf "%s" "$JSONblob" | jq -r '.general.managementId')

    DDMInfo=$(JAMF_get_DDM_info "$managementId")
    [[ "$DDMInfo" == "ERR" ]] && { 
        logMe "ERROR: Insufficient privileges to read DDM Info for $name" >&2
        return 1
    }
    [[ "$DDMInfo" == "NOT FOUND" ]] && {
        logMe "ERROR: DDM may not be active on device: $name"
        update_display_list "Update" "" "${name}" "DDM may not be active" "error" 
        return 0
    }

    DDMInfo_clean=$(tr -d '[:cntrl:]' <<< "$DDMInfo")
    DDMKeys=$(jq -r '.statusItems[] | select(.key == "management.declarations.activations")' <<< "$DDMInfo_clean")
    lastUpdateTime=$(jq -r '(.statusItems[] | select(.key == "softwareupdate.failure-reason.reason") | .lastUpdateTime) // "N/A"' <<< "$DDMInfo_clean")

    JAMF_retrieve_ddm_blueprint_active "$DDMKeys"
    JAMF_retrieve_ddm_blueprint_errrors "$DDMKeys"
    JAMF_retrieve_ddm_softwareupdate_failures "$DDMInfo_clean"

    [[ -n "$DDMBlueprintErrors" ]] && { liststatus="fail"; statusmessage="BP errors found"; }
    update_display_list "Update" "" "${name}" "${statusmessage}" "${liststatus}"

    # Eval criteria
    case "$displayResults" in
        "Failed Only") [[ "$liststatus" == "fail" ]] && canWrite=true ;;
        "Active Only") [[ "$liststatus" == "success" ]] && canWrite=true ;;
        *) canWrite=true ;;
    esac

    # Early exit if we don't need to write out the CSV file
    [[ "$writeCSVFile" = false && "$canWrite" = true ]] && { printf "INFO: System: %s - ManagementID: %s - Status: %s\n" "$name" "$managementId" "$statusmessage"; return 0; }

    [[ "$includeSWUFail" == false ]] && DDMSoftwareUpdateFailures=""

    sanitized_clean_swu="${DDMSoftwareUpdateFailures//,/;}"
    sanitized_bperrors="${DDMBlueprintErrors//,/;}" 
    sanitized_bperrors_reason=""
    if [[ -n "$DDMBlueprintErrors" ]]; then
        DDMErrorReason=$(printf "%s" "$DDMKeys" | perl -ne 'print "$1\n" if /code=([^},]+)/')
        sanitized_bperrors_reason="${DDMErrorReason//,/;}"
    fi

    if [[ $canWrite  = true ]]; then
        # Write out this info to the CSV file
        printf "%s, %s, %s, %s, %s, %s, %s\n" "$name" "$managementId" "$lastUpdateTime" "$liststatus" "$sanitized_bperrors" "$sanitized_bperrors_reason" "$sanitized_clean_swu" >> "$CSV_OUTPUT"
        logMe "Writing DDM $liststatus for system: $name"
    fi
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'
zmodload zsh/parameter

declare api_token
declare jamfpro_url
declare computer_id
declare -a DDMSoftwareUpdateActive
declare -a DDMSoftwareUpdateFailures
declare -a DDMBlueprintErrors
declare -a DDMBlueprintSuccess
declare -a writeCSVFile
#declare jamfGroup
#declare displayResults

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

# Show the welcome message and give the user some options
while true; do
    DDMoption=$(welcomemsg)
    # Process their choices
    case "${DDMoption}" in
        *"Single"* )
            welcomemsg_individual
            process_individual $search_type $computer_id
            ;;
        *"Group"* )
            welcomemsg_group
            ;;
        *"Blueprint"* )
            welcomemsg_blueprint
            #process_blueprint
            ;;
        *"quit"* )
            #Cleanup
            JAMF_invalidate_token
            cleanup_and_exit 0
    esac
done
