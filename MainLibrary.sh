#!/bin/zsh
#
# Main Library
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 10/03/2025
#
# Script Purpose: Main Library containing all of my commonly used fuctions.
#
# 1.0 - Initial
# 1.1 - Code optimization
# 1.1 - Changed the get_nic_info logic
# 1.2 - renamed all JAMF functions to start with JAMF_.....
# 1.3 - Changed JAMF function names to be more descriptive
# 1.4 - Added listitem, textbox, checkbox and dropdown functions
# 1.5 - Reworked top section for better idea of what can be modified
#       New create_log_direcotry check routine that parses the path and checks the directory structure
# 1.6 - Add several new MS Graph API routines
# 1.7 - Add more JAMF API Librarys for Static Group modifications & Checking to see which version of SS/SS+ is being used
# 1.8 - Added option to move some of the "defaults" to a plist file / Also used the variable SCRIPT_for temp files creation & log file cname

######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="MainLibrary"
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

JSON_OPTIONS=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
TMP_FILE_STORAGE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
/bin/chmod 666 $JSON_OPTIONS
/bin/chmod 666 $TMP_FILE_STORAGE

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
    SD_BANNER_IMAGE=$SUPPORT_DIR$(defaults read $DEFAULTS_DIR "BannerImage")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
fi

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Delete Applications"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

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
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
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

function welcomemsg ()
{
    message=""

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
        --width 920
        --ignorednd
        --quitkey 0
        --button1text "OK"
        --button2text "Create Ticket"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    # Examples of how to extra data from returned string
    search_type=$(echo $temp | plutil -extract "SelectedOption" 'raw' -)
    computer_id=$(echo $temp | plutil -extract "Device" 'raw' -)
    reason=$(echo $temp | plutil -extract "Reason" 'raw' -)
}


####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_for_sudo_access
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg
exit 0

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
            eval "${JSON_OPTIONS}"
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

        "change" )
          
            # Change the listitem Status
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
             
            /bin/echo "listitem: title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            if [[ ! -z $5 ]]; then
                /bin/echo "progresstext: $5" >> "${DIALOG_COMMAND_FILE}"
                /bin/echo "progress: $6" >> "${DIALOG_COMMAND_FILE}"
            fi
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

function unload_and_delete_daemon ()
{
    # Unloads the launch daemon from launchctl
    #
    # RETURNS: None
    /bin/launchctl unload -wF "${LAUNCH_DAEMON_PATH:r}"
    /bin/rm -f "${LAUNCH_DAEMON_PATH}"
}

function runAsUser () 
{  
  if [ "$LoggedInUser" != "loginwindow" ]; then
    launchctl asuser "$uid" sudo -iu "$LoggedInUser" open "$@"
  else
    echo "no user logged in"
    # uncomment the exit command
    # to make the function exit with an error when no user is logged in
    # exit 1
  fi
}

function Contains ()
{
    # Purpose: Scan for item inside an arry
    # Paramters: #1 - Pass entire array
    #            #2 - Item to look for in array
    # Returns: Return 0 if element exists in array

    local list=$1[@]
    local elem=$2

    for i in "${!list}"
    do
        [[ "$i" == "${elem}" ]] && return 0
    done
    return 1
}

function unload_and_delete_daemon ()
{
    # Unloads the launch daemon from launchctl
    #
    # RETURNS: None
    /bin/launchctl unload -wF "${LAUNCH_DAEMON_PATH:r}"
    /bin/rm -f "${LAUNCH_DAEMON_PATH}"
}

function read_lockfile_pid ()
{
    # Reads a file which contains a PID.
    #
    # RETURNS: A string representation of a PID or nothing if 
    #          the file is empty or doesnt exist

    [[ ! -e ${LOCKFILE_PATH} ]] && return

    pid=$(cat "${LOCKFILE_PATH}")
    echo $pid
}

function clear_lock_file ()
{
    # Remove the lock file - we use this if we exit for a deferral and d
    # not want to clean up other files
    #
    # RETURNS: None
    /bin/rm -f "${LOCKFILE_PATH}"
}

function set_lock_file_with_pid ()
{
    printf $$ > "${LOCKFILE_PATH}"
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
    wifiName=$(sudo wdutil info | grep "SSID" | head -1 | awk -F ":" '{print $2}' | xargs)

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
    echo $(echo "$1" | sed -e 's/:/_/g' -e 's/\//-/g' -e 's/|/-/g')
}

function convert_to_hex ()
{
    local input="$1"
    local length="${#input}"
    local result=""

    for (( i = 0; i <= length; i++ )); do
        local char="${input[i]}"
        if [[ "$char" =~ [^a-zA-Z0-9] ]]; then
            hex=$(printf '%x' "'$char")
            result+="%$hex"
        else
            result+="$char"
        fi
    done

    echo "$result"
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

function runAsUser()
{  
  if [ "$currentUser" != "loginwindow" ]; then
    launchctl asuser "$UID" sudo -u "$currentUser" "$@"
  else
    echo "no user logged in"
  fi
}

###########################
#
# MS-GRAPH API functions
#
###########################

function msgraph_getdomain ()
{
    # PURPOSE: construct the domain from the jamf.plist file
    # PARAMETERS: None
    # RETURN: None
    # EXPECTED: MS_DOMAIN

    local url
    url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)

    # Extract the desired part using Zsh parameter expansion
    tmp=${url#*://}  # Remove the protocol part
    MS_DOMAIN=${tmp%%.*}".com"  # Remove everything after the first dot and add '.com' to the end
}

function msgraph_get_access_token ()
{
    # PURPOSE: obtain the MS inTune Graph API Token
    # PARAMETERS: None
    # RETURN: access_token
    # EXPECTED: TENANT_ID, CLIENT_ID, CLIENT_SECRET

    token_response=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&scope=https://graph.microsoft.com/.default")

    MS_ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token')

    if [[ "$MS_ACCESS_TOKEN" == "null" ]] || [[ -z "$MS_ACCESS_TOKEN" ]]; then
        echo "Failed to acquire access token"
        echo "$token_response"
        exit 1
    fi
    echo "Valid Token Acquired"
}

function msgraph_upn_sanity_check ()
{
    # PURPOSE: format the user name to make sure it is in the format <first.last>@domain.com
    # RETURN: None
    # PARAMETERS: $1 = User name
    # EXPECTED: LOGGED_IN_USER, MS_DOMAIN, MS_USER_NAME

    # if the local name already contains “@”, then it should be good
    if [[ "$LOGGED_IN_USER" == *"@"* ]]; then
        echo "$LOGGED_IN_USER"
        return 0
    fi
    # If the user name doesn't have a "." in it, then it must be formatted correctly so that MS Graph API can find them
    
    # if it isn't ormatted correctly, grab it from the users com.microsoft.CompanyPortalMac.usercontext.info
    if [[ "$CLEAN_USER" != *"."* ]]; then
        CLEAN_USER=$(/usr/bin/more $SUPPORT_DIR/com.microsoft.CompanyPortalMac.usercontext.info | xmllint --xpath 'string(//dict/key[.="aadUserId"]/following-sibling::string[1])' -)
    fi
    
    # if it still isn't formatted correctly, try the email from the system JSS file
    
    if [[ "$CLEAN_USER" != *"."* ]]; then
        CLEAN_USER=$(/usr/libexec/plistbuddy -c "print 'User Name'" $SYSTEM_JSS_FILE 2>&1)
    fi

    # if it ends with the domain without the “@” → we add the @ sign
    if [[ "$LOGGED_IN_USER" == *"$MS_DOMAIN" ]]; then
        CLEAN_USER=${LOGGED_IN_USER%$MS_DOMAIN}
        MS_USER_NAME="${CLEAN_USER}@${MS_DOMAIN}"
    else
        # 3) normal short name → user@domain
        MS_USER_NAME="${LOGGED_IN_USER}@${MS_DOMAIN}"
    fi
}

function msgraph_get_password_data ()
{
    # PURPOSE: Retrieve the user's Graph API Record
    # RETURN: last_password_change
    # EXPECTED: MS_USER_NAME, MS_ACCESS_TOKEN

    user_response=$(curl -s -X GET "https://graph.microsoft.com/v1.0/users/$MS_USER_NAME?\$select=lastPasswordChangeDateTime" -H "Authorization: Bearer $MS_ACCESS_TOKEN")
    last_password_change=$(echo "$user_response" | jq -r '.lastPasswordChangeDateTime')
    echo $last_password_change

}

function msgraph_get_group_data ()
{
    # PURPOSE: Retrieve the user's Graph API group membership
    # PARAMETERS: None
    # RETURN: None
    # EXPECTED: MS_USER_NAME, MS_ACCESS_TOKEN, MSGRAPH_GROUP

    response=$(curl -s -X GET "https://graph.microsoft.com/v1.0/users/$MS_USER_NAME/memberOf" -H "Authorization: Bearer $MS_ACCESS_TOKEN" | jq -r '.value[].displayName')

    # Use a while loop to read and handle the line break delimiter - store the final list into an array
    MSGRAPH_GROUPS=()
    while IFS= read -r line; do
        MSGRAPH_GROUPS+=("$line")
    done <<< "$response"   
}

function msgraph_get_user_photo_etag ()
{
    # PURPOSE: Retrieve the user's Graph API Record
    # RETURN: last_password_change
    # EXPECTED: MS_USER_NAME, ms_access_token

    user_response=$(curl -s -X GET "https://graph.microsoft.com/v1.0/users/${MS_USER_NAME}/photo" -H "Authorization: Bearer $ms_access_token")
    echo "$user_response" | jq -r '."@odata.mediaEtag"'
}

function msgraph_get_user_photo_jpeg ()
{
    # PURPOSE: Retrieve the user's Graph API JPEG photo
    # PARAMETERS: $1 - Photo file to store download file
    # RETURN: None
    # EXPECTED: MS_USER_NAME, ms_access_token

    curl -s -L -H "Authorization: Bearer ${ms_access_token}" "https://graph.microsoft.com/v1.0/users/${MS_USER_NAME}/photo/\$value" --output "$$1"
    [[ ! -s "$1" ]] && { echo "ERROR: Downloaded file empty"; cleanup_and_exit 1; }
}

function create_photo_dir ()
{
    # Store retrieved file to perm location  
    PERM_PHOTO_FILE="${PERM_PHOTO_DIR}/${LOGGED_IN_USER}.jpg"
    /bin/mkdir -p "$PERM_PHOTO_DIR"
    /bin/cp "$PHOTO_FILE" "$PERM_PHOTO_FILE"
    /bin/chmod 644 "$PERM_PHOTO_FILE"
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
    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/computers-inventory?section=$1&filter=$filter" 2>/dev/null)
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

    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v1/computers-inventory/$1?section=$2" 2>/dev/null)
    echo $retval | tr -d '\n'
}

function JAMF_get_policy_list ()
{
    # PURPOSE: Get the list of policies from JAMF Pro
    # RETURN: XML contents of command
    # EXPECTED: api_token, jamfpro_url
    # PARMS: None

    echo $(curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/xml" "${jamfpro_url}JSSResource/policies")

}

function JAMF_clear_failed_mdm_commands()
{
    # PURPOSE: clear failed MDM commands for the computer in Jamf Pro
    # RETURN: None
    # Expected jamfpro_url, api_token, ID
    
    response=$(curl -s -X DELETE "${jamfpro_url}JSSResource/commandflush/computers/id/$1/status/Failed" -H "Authorization: Bearer $api_token")
    logMe "Clear MDM Commands Response: $response"
}

function JAMF_fileVault_recovery_key_valid_check () 
{
     # Verify that a FileVault recovery key is available by running an API command
     # which checks if there is a FileVault recovery key present.
     #
     # The API call will only return the HTTP status code.

     filevault_recovery_key_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/computers-inventory/$ID/filevault" --request GET -H "Authorization: Bearer ${api_token}")
}

function JAMF_fileVault_recovery_key_retrieval () 
{
     # Retrieves a FileVault recovery key from the computer inventory record.
     filevault_recovery_key_retrieved=$(/usr/bin/curl --silent --fail -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}/api/v1/computers-inventory/$ID/filevault" | plutil -extract personalRecoveryKey raw -)   
}

function JANMF_send_recovery_lock_command()
{
    # PURPOSE: send the command to clear or remove the Recovery Lock 
    # RETURN: None
    # PARMS: $1 = Lock code to set (pass blank to clear)
    # Expected jamfpro_url, ap_token, ID
	local newPassword="$1"
	
	returnval=$(curl -w "%{http_code}" "$jamfpro_url/api/v2/mdm/commands" \
		-H "accept: application/json" \
		-H "Authorization: Bearer ${api_token}"  \
		-H "Content-Type: application/json" \
		-X POST -s -o /dev/null \
		-d @- <<EOF
		{
			"clientData": [{ "managementId": "$ID", "clientType": "COMPUTER" }],
			"commandData": { "commandType": "SET_RECOVERY_LOCK", "newPassword": "$newPassword" }
		}
EOF
	)
	logMe "Recovery Lock ${lockMode} for ${computer_id}"
}

function JAMF_retreive_static_group_id ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID # of static group
    # EXPECTED: jamppro_url, api_token
    # PARMATERS: $1 = JAMF Static group name
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/xml" "${jamfpro_url}JSSResource/computergroups")
    echo $tmp | xmllint --xpath 'string(//computer_group[name="'$1'"]/id)' -
}

function JAMF_static_group_action ()
{
	# PURPOSE: Remove record from JAMF static group
    # RETURN: None
    # EXPECTED: jamfpro_url, api_token
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
    retval=$(curl -f -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/xml" ${jamfpro_url}JSSResource/computergroups/id/${1} -X PUT -d "${apiData}")
    [[ $retval == *"409"* ]] && echo "ERROR: System not in group" 1>&2
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
#######################################################################################################
# 
# Functions for system & user level TCCC Database
#
#######################################################################################################

function configure_system_tccdb ()
{
    local values=$1
    local dbPath="/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sudo sqlite3 "$dbPath" "$sqlQuery"
}

function configure_user_tccdb () 
{
    local values=$1
    local dbPath="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sqlite3 "$dbPath" "$sqlQuery"
}