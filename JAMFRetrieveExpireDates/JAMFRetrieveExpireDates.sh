#!/bin/zsh
#
# JAMFRetrieveExpireDates
#
# by: Scott Kendall
#
# Written: 04/22/2026
# Last updated: 04/23/2026
#
# Script Purpose: This script is designed to retrieve the expiration dates of PKI, ADE, VPP & APNS tokens and Configuration Profiles from JAMF Pro 
#
# 1.0 - Initial
# 1.1 - Minor wording change from APNS Token to APNS Certificate, Also added some additional verbiage to the welcome message to clarify tokens and/or certificates

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="JAMFRetrieveExpireDates"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.0.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
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
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="GE_SD_BannerImage.png"
    BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
fi
[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Retrieve Expiration Dates"
SD_ICON_FILE="/System/Applications/Calendar.app"
OVERLAY_ICON="SF=checkmark.seal.fill,weight=bold,color=green,bgcolor=none"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"
JAMF_CLI_INSTALL_POLICY="install_jamf_cli"
JAMF_CLI="/usr/local/bin/jamf-cli"

THRESHOLD_DAYS_WARNING=60   # Number of days before expiration to trigger a warning log message
THRESHOLD_DAYS_CRITICAL=14   # Number of days before expiration to trigger a critical log message
ADE_SYNC_WARNING_THRESHOLD=2 # Number of days since last sync to trigger a warning log message
USE_JAMF_CLI=false # Set to true to use the JAMF_CLI for API calls, false to use curl.  

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
    fi
    SD_VERSION=$( ${SW_DIALOG} --version) 
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

	/usr/local/bin/jamf policy -event ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -event ${SUPPORT_FILE_INSTALL_POLICY}
    [[ $(which jq) == *"not found"* ]] && /usr/local/bin/jamf policy -event ${JQ_INSTALL_POLICY}
    [[ ! -e "${JAMF_CLI}" ]] && /usr/local/bin/jamf policy -event ${JAMF_CLI_INSTALL_POLICY}
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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br><br>"
    SD_INFO_BOX_MSG+="#### Expiration Thresholds ####<br>"
    SD_INFO_BOX_MSG+="Warning: ${THRESHOLD_DAYS_WARNING} days<br>"
    SD_INFO_BOX_MSG+="Critical: ${THRESHOLD_DAYS_CRITICAL} days<br>"
    SD_INFO_BOX_MSG+="ADE: ${ADE_SYNC_WARNING_THRESHOLD} days overdue<br>"
}

function check_logged_in_user ()
{    
    # PURPOSE: Make sure there is a logged in user
    # RETURN: None
    # EXPECTED: $LOGGED_IN_USER
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in, exiting"
        cleanup_and_exit 0
    else
        logMe "INFO: User $LOGGED_IN_USER is logged in"
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

    local helpmessage="The token information can be found on your JAMF server in these location(s):<br><br>**PKI** - <br>Settings > Global Management > PKI Certificates<br><br>**VPP** - <br>Settings > Global Management > Volume Purchasing<br><br>**ADE** - <br>Settings > Global Management > Automated Device Enrollment<br><br>**APNS** - <br>Settings > Global Management > Push Certificates<br><br>**Configuration Profiles** - <br>Computers > Configuration Profiles<br>Devices > Configuration Profiles"
	echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "message" : "'$1'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "subtitle" : "'${BANNER_SUBTITLE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "helpmessage" : "'${helpmessage}'",
        "ontop" : "true",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1",
        "button1text" : "OK",
        "height" : "75%",
        "width" : "950",
        "moveable" : "true",
        "json" : "true",
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
    #        $3 - status text (for display)
    #        $4 - status
    #        $5 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    [[ "$6:l" == "first" ]] && line+='"button1disabled" : "true", "listitem" : ['
    [[ ! -z $1 ]] && [[ ! -z $2 ]] && line+='{"title" : "'$1'", "subtitle" : "'$2'", "icon" : "'$3'", "status" : "'$5'", "statustext" : "'$4'"},'
    [[ ! -z $1 ]] && [[ -z $2 ]] && line+='{"title" : "'$1'", "icon" : "'$3'", "status" : "'$5'", "statustext" : "'$4'"},'
    [[ "$6:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
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

function JAMF_retrieve_config_profile_info ()
{
    # PURPOSE: Retrieve the configuration profile information from the JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL

    config_profile_info=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "$jamfpro_url/JSSResource/osxconfigurationprofiles")
    echo "$config_profile_info"
}

###########################
#
# Application functions
#
###########################


function JAMF_api_getpki ()
{
    # PURPOSE: Get PKI certificate information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url
    if [[ "$USE_JAMF_CLI" == true ]]; then
        pki_expire_date=$(${JAMF_CLI} pro certificate-authorities list | jq -r '.notAfter | strflocaltime("%m/%d/%Y")')
    else
        pki_expire_date=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "$jamfpro_url/api/v1/pki/certificate-authority/active" | jq -r '.notAfter | strflocaltime("%m/%d/%Y")')
    fi
    check_expiration "$pki_expire_date"
    expireDays=$?
    echo "$retval"
}

function JAMF_api_getvpp ()
{
    # PURPOSE: Get VPP token information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url
    declare vpp_array_ids vpp_expire_date
    if [[ "$USE_JAMF_CLI" == true ]]; then
        vpp_array_ids=$(${JAMF_CLI} pro -o json classic-vpp-accounts list | jq -r '.[].id')
    else
        vpp_array_ids=$(curl -s -H  "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/vppaccounts" | jq -r '.vpp_accounts[].id')
    fi
    for id in $vpp_array_ids; do
        if [[ "$USE_JAMF_CLI" == true ]]; then
            vpp_expire_date=$(${JAMF_CLI} pro -o json classic-vpp-accounts get $id | jq -r '.expiration_date')
            vpp_account_name=$(${JAMF_CLI} pro -o json classic-vpp-accounts get $id | jq -r '.name')
        else
            vpp_expire_date=$(curl -s -H  "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/vppaccounts/id/$id" | jq -r '.vpp_account.expiration_date')
            vpp_account_name=$(curl -s -H  "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/vppaccounts/id/$id" | jq -r '.vpp_account.name')
        fi
        echo $vpp_expire_date 1>&2
        vpp_expire_date=$(date -j -f "%Y/%m/%d" "$vpp_expire_date" +"%m/%d/%Y")
        check_expiration "$vpp_expire_date"
        expireDays=$?
        vpp_return_dates+=$vpp_expire_date" - "$vpp_account_name
    done
    echo "$vpp_return_dates"
}

function JAMF_api_getade ()
{
    # PURPOSE: Get ade token information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url

    declare ade_array_ids ade_expire_date ade_account_name
    if [[ "$USE_JAMF_CLI" == true ]]; then
        ade_array_ids=$(${JAMF_CLI} pro -o json device-enrollment-instances list | jq -r '.[].id')
    else
        ade_array_ids=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}api/v1/device-enrollments" | jq -r '.results[].id')
    fi
    for id in $ade_array_ids; do
        if [[ "$USE_JAMF_CLI" == true ]]; then
            ade_expire_date=$(${JAMF_CLI} pro -o json device-enrollment-instances get $id | jq -r '.tokenExpirationDate')
            ade_account_name=$(${JAMF_CLI} pro -o json device-enrollment-instances get $id | jq -r '.name')
        else
            ade_expire_date=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}api/v1/device-enrollments/$id" | jq -r '.tokenExpirationDate')
            ade_account_name=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}api/v1/device-enrollments/$id" | jq -r '.name')
        fi
        ade_expire_date=$(date -j -f "%Y-%m-%d" "$ade_expire_date" +"%m/%d/%Y")
        check_expiration "$ade_expire_date"  
        expireDays=$? 
        ade_return_dates+=$ade_expire_date" - "$ade_account_name
    done
    echo "$ade_return_dates"
}

function JAMF_api_getade-last-sync ()
{
    # PURPOSE: Get last ADE sync information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url

    if [[ "$USE_JAMF_CLI" == true ]]; then
        ade_last_sync=$(${JAMF_CLI} pro -o json device-enrollment-instance-sync-states list | jq -r '.[0].timestamp  | .[:19] + "Z" | fromdate | strftime("%m/%d/%Y %H:%M")')
    else
        ade_last_sync=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}api/v1/device-enrollments/syncs"| jq -r '.[0].timestamp  | .[:19] + "Z" | fromdate | strftime("%m/%d/%Y %H:%M")')
    fi
    echo $ade_last_sync 1>&2
    ade_last_sync=$(date -j -f "%m/%d/%Y %H:%M" "$ade_last_sync" +"%m/%d/%Y")

    check_expiration "$ade_last_sync"
    expireDays=$? 
    echo "$ade_last_sync"
}

function JAMF_api_getapns ()
{
    # PURPOSE: Get APNS expiration information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url

    if [[ "$USE_JAMF_CLI" == true ]]; then
        apns_expire_date=$(${JAMF_CLI} pro apns-client-push-status status| jq -r '.results[0].disabledAt')
    else
        apns_expire_date=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}api/v1/apns-client-push-status" | jq -r '.results[0].disabledAt')
    fi
    if [[ -n "$apns_expire_date" ]]; then
        apns_expire_date="No expiration alert"
        expireDays=100000
    else
        apns_expire_date=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$apns_expire_date" +"%m/%d/%Y")
        check_expiration "$apns_expire_date"
        expireDays=$?
    fi
    echo "$apns_expire_date"
}

function JAMF_api_getcomputer-profiles ()
{
    # PURPOSE: Get configuration profile information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url

    # 1. Get the list of all profiles using the Classic API (JSON format)
    declare ALL_PROFILES PROFILE_IDS DETAIL NAME CERT_DATA EXPIRATION RAW_DATE CLEAN_DATE FINAL_DATE
    if [[ "$USE_JAMF_CLI" == true ]]; then
        ALL_PROFILES=$(${JAMF_CLI} pro -o json classic-macos-config-profiles list)
        PROFILE_IDS=($(echo "$ALL_PROFILES" | tr -d '\n\r' | jq -r '.[].id'))
    else
        ALL_PROFILES=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/osxconfigurationprofiles")
        PROFILE_IDS=($(echo "$ALL_PROFILES" | tr -d '\n\r' | jq -r '.os_x_configuration_profiles[].id'))
    fi
    counter=0
    for ID in "${PROFILE_IDS[@]}"; do
        ((counter++))
        update_display_list "progress" "" "" "" "Scanning $counter/${#PROFILE_IDS[@]} Computer Configuration Profiles"
        # Fetch details for each individual profile
        if [[ "$USE_JAMF_CLI" == true ]]; then
            DETAIL=$(${JAMF_CLI} pro -o json classic-macos-config-profiles get $ID)
            NAME=$(echo -E "$DETAIL" | tr -d '\n\r' | jq -r '.general.name')
        else
            DETAIL=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/osxconfigurationprofiles/id/$ID")
            NAME=$(echo -E "$DETAIL" | tr -d '\n\r' | jq -r '.os_x_configuration_profile.general.name')
        fi
        
        # 3. Use jq to find the 'PayloadData' within the payload_content of each profile, which contains the JSON data for certificates.
        # This filter targets standard Certificate payloads.
        if [[ "$USE_JAMF_CLI" == true ]]; then
            CERT_DATA=$(echo -E "$DETAIL"  |  tr -d '\n\r' | jq -r '.general.payloads' | grep -oE '<data>[^<]+</data>' | sed -E 's/<\/?data>//g')
        else
            CERT_DATA=$(echo -E "$DETAIL"  |  tr -d '\n\r' | jq -r '.os_x_configuration_profile.general.payloads' | grep -oE '<data>[^<]+</data>' | sed -E 's/<\/?data>//g')
        fi
        if [[ -n "$CERT_DATA" ]]; then
            update_display_list "add" "Computer - $NAME" "pending" "Checking certificate..." ""

            # 4. Decode and check expiration via openssl
            # We try DER format first (standard for profiles), then PEM
            EXPIRATION=$(echo "$CERT_DATA" | base64 -d | openssl x509 -inform der -noout -enddate 2>/dev/null)
            [[ -z "$EXPIRATION" ]] && EXPIRATION=$(echo "$CERT_DATA" | base64 -d | openssl x509 -noout -enddate 2>/dev/null)
            
            # Extract and format the date
            RAW_DATE=$(echo "$CERT_DATA" | base64 -d | openssl x509 -inform der -noout -enddate 2>/dev/null)

            FINAL_DATE=""
            if [[ -n "$RAW_DATE" ]]; then
                # Format: notAfter=Feb 13 15:27:40 2036 GMT -> 02/13/2036
                CLEAN_DATE=$(echo "$RAW_DATE" | cut -d= -f2)
                FINAL_DATE=$(date -jf "%b %e %T %Y %Z" "$CLEAN_DATE" "+%m/%d/%Y")
            fi
            check_expiration "$FINAL_DATE"
            expireDays=$? 
            check_warning_threshold $expireDays
            update_display_list "update" "" "Computer - $NAME" "$FINAL_DATE" "$liststatus"

        fi
    done
}

function JAMF_api_getdevice-profiles ()
{
    # PURPOSE: Get configuration profile information from JAMF Pro API
    # RETURN: None
    # EXPECTED: $JAMF_TOKEN, $JAMF_URL, jamfpro_url

    # 1. Get the list of all profiles using the Classic API (JSON format)
    declare ALL_PROFILES PROFILE_IDS DETAIL NAME CERT_DATA EXPIRATION RAW_DATE CLEAN_DATE FINAL_DATE
    if [[ "$USE_JAMF_CLI" == true ]]; then
        ALL_PROFILES=$(${JAMF_CLI} pro -o json classic-macos-config-profiles list)
        PROFILE_IDS=($(echo "$ALL_PROFILES" | tr -d '\n\r' | jq -r '.[].id'))
    else
        ALL_PROFILES=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/mobiledeviceconfigurationprofiles")
        PROFILE_IDS=($(echo "$ALL_PROFILES" | tr -d '\n\r' | jq -r '.configuration_profiles[].id'))
    fi
    counter=0
    for ID in "${PROFILE_IDS[@]}"; do
        ((counter++))
        update_display_list "progress" "" "" "" "Scanning $counter/${#PROFILE_IDS[@]} Device Configuration Profiles"
        # Fetch details for each individual profile
        if [[ "$USE_JAMF_CLI" == true ]]; then
            DETAIL=$(${JAMF_CLI} pro -o json classic-macos-config-profiles get $ID)
            NAME=$(echo -E "$DETAIL" | tr -d '\n\r' | jq -r '.general.name')
        else
            DETAIL=$(curl -s -H "Authorization: Bearer $api_token" -H "Accept: application/json" "${jamfpro_url}JSSResource/mobiledeviceconfigurationprofiles/id/$ID")
            NAME=$(echo -E "$DETAIL" | tr -d '\n\r' | jq -r '.configuration_profile.general.name')
        fi
        
        # 3. Use jq to find the 'PayloadData' within the payload_content of each profile, which contains the JSON data for certificates.
        # This filter targets standard Certificate payloads.
        if [[ "$USE_JAMF_CLI" == true ]]; then
            CERT_DATA=$(echo -E "$DETAIL"  |  tr -d '\n\r' | jq -r '.general.payloads' | grep -oE '<data>[^<]+</data>' | sed -E 's/<\/?data>//g')
        else
            CERT_DATA=$(echo -E "$DETAIL"  |  tr -d '\n\r' | jq -r '.configuration_profile.general.payloads' | grep -oE '<data>[^<]+</data>' | sed -E 's/<\/?data>//g')
        fi
        if [[ -n "$CERT_DATA" ]]; then
            update_display_list "add" "Device - $NAME" "pending" "Checking certificate..." ""

            # 4. Decode and check expiration via openssl
            # We try DER format first (standard for profiles), then PEM
            EXPIRATION=$(echo "$CERT_DATA" | base64 -d | openssl x509 -inform der -noout -enddate 2>/dev/null)
            [[ -z "$EXPIRATION" ]] && EXPIRATION=$(echo "$CERT_DATA" | base64 -d | openssl x509 -noout -enddate 2>/dev/null)
            
            # Extract and format the date
            RAW_DATE=$(echo "$CERT_DATA" | base64 -d | openssl x509 -inform der -noout -enddate 2>/dev/null)

            FINAL_DATE=""
            if [[ -n "$RAW_DATE" ]]; then
                # Format: notAfter=Feb 13 15:27:40 2036 GMT -> 02/13/2036
                CLEAN_DATE=$(echo "$RAW_DATE" | cut -d= -f2)
                FINAL_DATE=$(date -jf "%b %e %T %Y %Z" "$CLEAN_DATE" "+%m/%d/%Y")
            fi
            check_expiration "$FINAL_DATE"
            expireDays=$? 
            check_warning_threshold $expireDays
            update_display_list "update" "" "Device - $NAME" "$FINAL_DATE" "$liststatus"

        fi
    done
}

function check_expiration ()
{
    # PURPOSE: Check expiration dates and determine if any are within the warning threshold
    # RETURN: None
    # EXPECTED: $pki_expire_date, $THRESHOLD_DAYS_WARNING
    # All dates are converted to seconds since epoch for easy comparison
    # and the dates must be formatted as "MM/DD/YYYY" for the date command to work properly

    current_date=$(date +%s)
    expire_date_seconds=$(date -j -f "%m/%d/%Y" "$1" +%s)
    time_until_expire=$((expire_date_seconds - current_date))
    expireDays=$(( time_until_expire / (24 * 60 * 60) ))
    return $expireDays
}

function check_warning_threshold () 
{
    # PARAMS: $1 = days_until, $2 = mode
    local days_until=$1
    local mode=$2
    
    # We will set this global variable directly
    # typeset -g liststatus 

    # --- ADE SYNC LOGIC ---
    if [[ $mode == "ade_sync" ]]; then
        liststatus="success"
        if (( days_until >= ADE_SYNC_WARNING_THRESHOLD )); then
            liststatus="fail"
            if (( ICON_OVERLAY_STATUS < 2 )); then
                ICON_OVERLAY_STATUS=2
                OVERLAY_ICON="SF=xmark.app.fill,weight=heavy,color=red,bgcolor=none"
                echo "overlayicon: $OVERLAY_ICON" >> "${DIALOG_COMMAND_FILE}"
            fi
        fi
        return 
    fi

    # --- CERTIFICATE / GENERAL LOGIC ---
    if (( days_until <= THRESHOLD_DAYS_CRITICAL )); then
        liststatus="fail"
        if (( ICON_OVERLAY_STATUS < 2 )); then
            ICON_OVERLAY_STATUS=2
            OVERLAY_ICON="SF=xmark.app.fill,weight=heavy,color=red,bgcolor=none"
            echo "overlayicon: $OVERLAY_ICON" >> "${DIALOG_COMMAND_FILE}"
        fi
    elif (( days_until <= THRESHOLD_DAYS_WARNING )); then
        liststatus="error"
        if (( ICON_OVERLAY_STATUS < 1 )); then
            ICON_OVERLAY_STATUS=1
            OVERLAY_ICON="SF=exclamationmark.triangle.fill,weight=heavy,color=yellow,bgcolor=none"
            echo "overlayicon: $OVERLAY_ICON" >> "${DIALOG_COMMAND_FILE}"
        fi
    else
        liststatus="success"
        if (( ICON_OVERLAY_STATUS == 0 )); then
            OVERLAY_ICON="SF=checkmark.seal.fill,weight=bold,color=green,bgcolor=none"
        fi
    fi
}

function welcomemsg ()
{
    message="$SD_DIALOG_GREETING, $SD_FIRST_NAME. These are the expiration dates for your PKI, ADE, VPP, APNS, Computer & Device Configuration Profile tokens and/or certificates. Please review and take action if any items are nearing expiration."
    message+="<br><br>**Note:** This information is pulled directly from JAMF Pro and may not reflect local certificate information stored on this device.<br>"

    construct_dialog_header_settings $message > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "PKI Token" "" "" "pending" "pending" "first"
    create_listitem_message_body "VPP Token" "" "" "pending" "pending"
    create_listitem_message_body "ADE Token" "" "" "pending" "pending"
    create_listitem_message_body "ADE Last Sync" "" "" "pending" "pending"
    create_listitem_message_body "APNS Certificate" "" "" "pending" "pending"
    create_listitem_message_body "" "" "" "" "" "last"
    update_display_list "Create"
}

####################################################################################################
#
# Main Script
#
####################################################################################################
typeset api_token
typeset jamfpro_url
typeset -g pki_expire_date
typeset -g vpp_return_dates
typeset -g ade_return_dates
typeset -g ade_last_sync
typeset -g liststatus
typeset -g apns_expire_date
typeset -g expireDays=100000
typeset -g ICON_OVERLAY_STATUS
autoload 'is-at-least'

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
JAMF_check_connection
JAMF_get_server
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token
# Set the icon overlay status to 0 (no icon) by default, this will be updated if any items are within the warning threshold
# 0 = normal, 1 = warning, 2 = critical
ICON_OVERLAY_STATUS=0

welcomemsg

# Get PKI Expiration Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for PKI expiration..." 0
logMe "Retrieving PKI certificate information..."
JAMF_api_getpki
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "PKI Token" "$pki_expire_date" "$liststatus"

# Get VPP Expiration Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for VPP expiration..." 15
logMe "Retrieving VPP license information..."
JAMF_api_getvpp
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "VPP Token" "$vpp_return_dates" "$liststatus"

# Get ADE Expiration Date(s) and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for ADE expiration..." 30
logMe "Retrieving ADE license information..."
JAMF_api_getade
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "ADE Token" "$ade_return_dates" "$liststatus"

# Get ADE Last Sync Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for ADE last sync expiration..." 45
logMe "Retrieving ADE last sync information..."
JAMF_api_getade-last-sync
check_warning_threshold "$expireDays" "ade_sync"
update_display_list "update" "" "ADE Last Sync" "$ade_last_sync" "$liststatus" 

# Get APNS Expiration Date and check if it is within the warning threshold.
update_display_list "progress" "" "" "" "Checking for APNS expiration..." 60
logMe "Retrieving APNS certificate information..."
JAMF_api_getapns
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "APNS Certificate" "$apns_expire_date" "$liststatus"

# Get Configuration Profile Certificate Expiration Dates and check if they are within the warning threshold.
update_display_list "progress" "" "" "" "Checking for Configuration Profile expiration..." 75
logMe "Retrieving configuration profile certificate information..."
JAMF_api_getcomputer-profiles
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "Config Profile Certs" "$liststatus"

# Get Device Configuration Profile Certificate Expiration Dates and check if they are within the warning threshold.
update_display_list "progress" "" "" "" "Checking for Device Configuration Profile expiration..." 90
logMe "Retrieving device configuration profile certificate information..."
JAMF_api_getdevice-profiles
check_warning_threshold "$expireDays" "cert"
update_display_list "update" "" "Config Profile Certs" "$liststatus"

# All done, enable the button so the user can exit the dialog
update_display_list "progress" "" "" "" "Done!" 100
update_display_list "buttonenable" "OK"

cleanup_and_exit 0
