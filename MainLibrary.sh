#!/bin/zsh
#
# Main Library
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 12/23/2025
#
# Script Purpose: Main Library containing all of my commonly used functions.
#
# 1.0 - Initial
# 1.1 - Code optimization
# 1.1 - Changed the get_nic_info logic
# 1.2 - renamed all JAMF functions to start with JAMF_.....
# 1.3 - Changed JAMF function names to be more descriptive
# 1.4 - Added listitem, textbox, checkbox and dropdown functions
# 1.5 - Reworked top section for better idea of what can be modified
#       New create_log_directory check routine that parses the path and checks the directory structure
# 1.6 - Add several new MS Graph API routines
# 1.7 - Add more JAMF API Libraries for Static Group modifications & Checking to see which version of SS/SS+ is being used
# 1.8 - Added option to move some of the "defaults" to a plist file / Also used the variable SCRIPT_for temp files creation & log file cname
# 1.9 - Add more JAMF functions
#       Add Check for focus mode
# 1.10 -Added static group functions
# 1.11 -Removed dependencies of using systemprofiler command and use sysctl instead
#       Add RunAsUser & check_logged_in_user command
#       Changed create_infobox_message to use new OS & version variables
# 1.12 -Added function "admin_user" to detect if user is admin or not. 
#       Changed logging functions to only record if a user is admin
# 1.13 -Added more JAMF API calls
# 1.14 -Optimized Common section
#       Added functions for check_display_sleep and logged_in_user
#       Added JAMF DDM libraries

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="GetDDMInfo"
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
MIN_SD_REQUIRED_VERSION="2.5.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp -t "${SCRIPT_NAME}_json.XXXXX")
DIALOG_COMMAND_FILE=$(mktemp -t "${SCRIPT_NAME}_cmd.XXXXX")
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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Retrieve JAMF DDM Info"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
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

function check_display_sleep ()
{
    # PURPOSE: Determine if the mac is asleep or awake.
    # RETURN: will return 0 if awake, otherwise will return 1
    # EXPECTED: None
    local sleepval=$(pmset -g systemstate | tail -1 | awk '{print $4}')
    local retval=0
    logMe "INFO: Checking sleep status"
    [[ $sleepval -eq 4 ]] && logMe "INFO: System appears to be awake" || { logMe "INFO: System appears to be asleep, will pause notifications"; retval=1; }
    return $retval
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

    [[ "$returnCode" == "2" ]] && {logMe "Cancel..."; break; }

    # Examples of how to extra data from returned string
    search_type=$(echo $temp | plutil -extract "SelectedOption" 'raw' -)
    computer_id=$(echo $temp | plutil -extract "Device" 'raw' -)
    reason=$(echo $temp | plutil -extract "Reason" 'raw' -)
}

function check_focus_status ()
{
    # PURPOSE: Check to see if the user is in focus mode
    # RETURN: in focus mode (Off/On)
    # EXPECTED: None
    # PARMATERS: None

    results="Off"
    if [[ -e $FOCUS_FILE ]]; then
        retval=$(plutil -extract data.0.storeAssertionRecords.0.assertionDetails.assertionDetailsModeIdentifier raw -o - $FOCUS_FILE | grep -ic 'com.apple.')
        [[ $retval == "1" ]] && results="On"
    fi
    echo $results
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
OVERLAY_ICON=$(JAMF_which_self_service) 
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
    launchctl asuser "$USER_UID" sudo -iu "$LOGGED_IN_USER" open "$@"
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

function JAMF_get_inventory_record_byID ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS: $1 - The JAMF ID of the device to retrieve
    #        $2 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $3 - Filter to use for search

    retval=$(/usr/bin/curl --silent --fail  -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computers-inventory/$1?section=$2" 2>/dev/null)
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

function JAMF_send_recovery_lock_command()
{
    # PURPOSE: send the command to clear or remove the Recovery Lock 
    # RETURN: None
    # PARMS: $1 = Lock code to set (pass blank to clear)
    # Expected jamfpro_url, ap_token, ID
    echo "New Recovery Lock: "$2
    httpString='{"clientData": [
        {"managementId": "'$1'",
        "clientType": "COMPUTER"}],
    "commandData": {
        "commandType": "SET_RECOVERY_LOCK",'

    [[ -z $1 ]] && httpString+='"newPassword": ""}}' || httpString+='"newPassword": "'$2'"}}'

    #echo $httpString 1>&2

    returnval=$(curl -X POST -s "$jamfpro_url/api/v2/mdm/commands" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" \
        --data-raw "$httpString")

    logMe "Recovery Lock ${lockMode} for ${computer_id}"
    echo $returnval
}

function JAMF_view_recovery_lock ()
{
    retval=$(/usr/bin/curl -s -X 'GET' \
        "${jamfpro_url}api/v2/computers-inventory/$ID/view-recovery-lock-password" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer ${api_token}")
    retval=$(extract_string $retval '.recoveryLockPassword')
    echo $retval
}

function JAMF_retrieve_static_group_id ()
{
    # PURPOSE: Retrieve the ID of a static group
    # RETURN: ID # of static group
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static group name
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computer-groups/static-groups?page=0&page-size=100&sort=id%3Aasc&filter=name%3D%3D%22"${1}%22)
    echo $tmp | jq -r '.results[].id'
}

function JAMF_retrieve_static_group_members ()
{
    # PURPOSE: Retrieve the members of a static group
    # RETURN: array of members
    # EXPECTED: jamfpro_url, api_token
    # PARAMETERS: $1 = JAMF Static group ID
    declare tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}JSSResource/computergroups/id/${1}")
    echo $tmp #| jq -r '.computer_group.computers[].name'
}

function JAMF_retrieve_data_blob ()
{    
    local format="${2:-xml}"
    local retval
    
    retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}${1}")
    [[ "$retval" == *"INVALID_ID"* ]] && printf "INVALID_ID" || printf "%s" "$reval"
    [[ "$retval" == *"PRIVILEGE"* || -z "$retval" ]] && printf "ERR" || printf "%s" "$retval"
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
    echo $retval
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