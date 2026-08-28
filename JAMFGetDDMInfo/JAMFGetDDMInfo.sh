#!/bin/zsh
#
# GetDDMInfo.sh
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 08/26/2026
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
# 1.0RC1 - Added more DDM reporting details (current Model #, Current OS, Security Certificates)
#       More JQ error trapping
# 1.0RC2 - more JQ error trapping
#       Added Current OS to CSV reports
#       Moved JAMF Token process inside of main loop to make sure it gets renewed after each selection
#       Added BP Name (optional) so you can name your CSV file
#       Cleaned up the output TXT file for individual systems
# 1.0RC3 - Added more JAMF error trapping
#       Add option to Force Sync DDM commands
#       Converted the output of the DDM Supported Payloads into a more readable format
# 1.0RC4 - Fixed reporting for blueprint not found when scanning for blueprint IDs
#       Add invalid blueprint information to system display and CSV output file
#       Significant rework of logic to determine valid, invalid or unknown deployments
# 1.0RC5 - Fixed issue of failed blueprints not returning correct results when doing a blueprint scan
#       Added option for cross reference file so you can associate Blueprint IDs to Names and it will show the name results during scans
#       Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 1.0RC6 - Added extensive logging and comments
#       Added centralized cleanup traps
#       Added thread-safe CSV writes
#       Added thread-safe SwiftDialog command writes
#       Added background worker failure tracking
#       Added reliable dialog process waiting
#       Added HTTP and JSON validation for DDM API calls
#       Added Force Sync support
#       Added Blueprint friendly-name cross-reference support
#       Added Failed, Invalid, Active, Inactive, Conditional, and Not Found result classifications
#       Added result-specific Blueprint filtering
#       Added display-only-matching behavior
#       Added consistent CSV and display classifications
#       Added CSV field escaping
#       Improved Jamf group dropdown construction
#       Corrected initial SwiftDialog list-item status values
#       Prevented empty progress commands during list updates
#       Improved handling of missing DDM data and management IDs
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
declare DIALOG_PROCESS
SCRIPT_NAME="GetDDMInfo"
SCRIPT_VERSION="1.0RC6"
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
MIN_SD_REQUIRED_VERSION="3.1.0"
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
chown "$USER_UID" \
    "$JSON_DIALOG_BLOB" \
    "$DIALOG_COMMAND_FILE"

chmod 600 \
    "$JSON_DIALOG_BLOB" \
    "$DIALOG_COMMAND_FILE"

chown root:wheel "$TMP_FILE_STORAGE"
chmod 600 "$TMP_FILE_STORAGE"

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
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="GE_SD_BannerImage.png"
    BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
    BANNER_SUBTITLE=""
fi
[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Retrieve JAMF DDM Info"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="SF=list.bullet.circle,color=orange,weight=heavy,bgcolor=none"
#OVERLAY_ICON="/System/Applications/App Store.app"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_INSTALL_POLICY="install_jq"
CSV_PATH="$USER_DIR/Desktop/DDM Data Dump for "
DDM_CROSS_REF_FILE="${USER_DIR}/Documents/DDMCrossRef.csv"

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
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && [[ "${SD_BANNER_IMAGE}" =~ \.(jpg|png|heic)$ ]] && /usr/local/bin/jamf policy -event ${SUPPORT_FILE_INSTALL_POLICY}
    if ! command -v jq >/dev/null 2>&1; then
        /usr/local/bin/jamf policy -event "$JQ_INSTALL_POLICY"
    fi
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

function cleanup_files ()
{
    # Peform a clean-up on all of the temp files that were created at run-time
    local file

    for file in \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE" \
        "$TMP_FILE_STORAGE"
    do
        [[ -n "$file" && -e "$file" ]] && /bin/rm -f -- "$file"
    done

    [[ -n "$CSV_LOCK_DIR" && -d "$CSV_LOCK_DIR" ]] && /bin/rmdir "$CSV_LOCK_DIR" 2>/dev/null
    [[ -n "$DIALOG_LOCK_DIR" && -d "$DIALOG_LOCK_DIR" ]] && /bin/rmdir "$DIALOG_LOCK_DIR" 2>/dev/null
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"
    cleanup_files
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM
trap 'cleanup_files' EXIT


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
 
        "create" )
 
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
  
            dialog_cmd "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" 
            ;;

        "buttonaction" )

            # Change button 1 action
            dialog_cmd 'button1action: "'${2}'"'
            ;;
  
        "buttonchange" )

            # change text of button 1
            dialog_cmd "button1text: ${2}"
            ;;

        "buttondisable" )

            # disable button 1
            dialog_cmd "button1: disable"
            ;;

        "buttonenable" )

            # Enable button 1
            dialog_cmd "button1: enable"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar

            dialog_cmd "listitem: title: ${3}, status: ${5}, statustext: ${4}"
            [[ -n "$6" ]] && dialog_cmd "progress: ${6}"
            ;;

  
        "clear" )
  
            # Clear the list and show an optional message  
            dialog_cmd "list: clear"
            dialog_cmd "message: ${2}"
            ;;
  
        "delete" )
  
            # Delete item from list  
            dialog_cmd "listitem: delete, title: ${2}"
            ;;
 
        "destroy" )
     
            # Kill the progress bar and clean up
            dialog_cmd "quit:"
            ;;
 
        "done" )
          
            # Complete the progress bar and clean up  
            dialog_cmd "progress: complete"
            dialog_cmd "progresstext: $5"
            ;;
          
        "icon" )
  
            # set / clear the icon, pass <nil> if you want to clear the icon  
            [[ -z ${2} ]] && dialog_cmd "icon: none" || dialog_cmd "icon: ${2}"
            ;;
  
  
        "image" )
  
            # Display an image and show an optional message  
            dialog_cmd "image: ${2}"
            [[ ! -z ${3} ]] && dialog_cmd "progresstext: $5"
            ;;
  
        "infobox" )
  
            # Show text message  
            dialog_cmd "infobox: ${2}"
            ;;

        "infotext" )
  
            # Show text message  
            dialog_cmd "infotext: ${2}"
            ;;
  
        "show" )
  
            # Activate the dialog box
            dialog_cmd "activate:"
            ;;
  
        "title" )
  
            # Set / Clear the title, pass <nil> to clear the title
            [[ -z ${2} ]] && dialog_cmd "title: none:" || dialog_cmd "title: ${2}"
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            dialog_cmd "progress: ${6}"
            dialog_cmd "progresstext: ${5}"
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
        "subtitledetail" : "'${BANNER_SUBTITLE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : true,
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1,color='${BANNER_TEXT_COLOR}',offset='${BANNER_TEXT_PADDING}'",
        "button1text" : "OK",
        "button2text" : "Cancel",
        "infotext": "'$SCRIPT_VERSION'",
        "height" : 700,
        "width" : 900,
        "moveable" : true,
        "resizeable" : true,
        "json" : true,
        "quitkey" : "0",
        "messageposition" : "top",'
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined

    declare xml_blob
    construct_dialog_header_settings "$1" > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # Parse the JSON data using jq and extract the relevant information
        xml_blob=$(echo -E "$4" | jq -r "${3}")
    else
        # Parse the XML data using xmllint and extract the relevant information
        xml_blob=$(echo "$4" | xmllint --xpath '//'"$3" - 2>/dev/null)
    fi

    echo "$xml_blob" | while IFS= read -r line; do
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
    if [[ "${5:l}" == "first" ]]; then
        printf '%s\n' '"button1disabled" : true, "listitem" : [' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ "${5:l}" == "last" ]]; then
        /usr/bin/sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']}' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ -n "$1" ]]; then
        printf '%s\n' '{"title":"'"$1"'","icon":"'"$2"'","status":"'"$3"'","statustext":"'"$4"'"},' >> "$JSON_DIALOG_BLOB"
    fi
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
    #        $4 - first or last - construct appropriate listitem headers / footers

    declare line && line=""

    [[ "$4:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2'], "default" : "'$3'"},'
    if [[ "${4:l}" == "last" ]]; then
        /usr/bin/sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']' >> "$JSON_DIALOG_BLOB"
        return 0
    fi
    echo $line >> ${JSON_DIALOG_BLOB}
}

function construct_dropdown_list_items ()
{
    local input_json="$1"
    local jq_path="$2"
    local line
    local -a values=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        values+=("$(jq -Rn --arg value "$line" '$value')")
    done < <(printf '%s' "$input_json" | /usr/bin/jq -r "${jq_path} | \"\\(.id) - \\(.name)\"")

    printf '%s' "${(j:,:)values}"
}

function create_checkbox_message_body ()
{
    # PURPOSE: Construct a checkbox style body of the dialog box
    #"checkbox" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - name (internal reference)
    #        $3 - icon
    #        $4 - Default Checked (true/false)
    #        $5 - disabled (true/false)
    #        $6 - first or last - construct appropriate listitem headers / footers
    local line=""

    if [[ "${6:l}" == "first" ]]; then
        printf '%s\n' '"checkbox" : [' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ -n "$1" ]]; then
        printf '%s\n' '{"name":"'"$2"'","label":"'"$1"'","icon":"'"$3"'","checked":'"${4:-false}"',"disabled":'"${5:-false}"'},' >> "$JSON_DIALOG_BLOB"
    fi

    if [[ "${6:l}" == "last" ]]; then
        /usr/bin/sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']' >> "$JSON_DIALOG_BLOB"
    fi
}

function extract_string ()
{
    # PURPOSE: Extract (grep) results from a string 
    # RETURN: parsed string
    # PARAMS: $1 = String to search in
    #         $2 = key to extract
    
    echo -E "$1" | tr -d '\n' | jq -r "$2"
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "**Problems retrieving JAMF Info**<br><br>Error Message: $1"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

}

function dialog_cmd ()
{
    # Perform a lock file function on all dialog commands so that it isn't overwritten by other processes
    local command="$1"
    local lock_dir="/var/tmp/${SCRIPT_NAME}.dialog.lock"
    local attempts=0

    while ! /bin/mkdir "$lock_dir" 2>/dev/null; do
        /bin/sleep 0.02
        (( attempts++ ))

        if (( attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for dialog command lock" >&2
            return 1
        fi
    done

    {
        /usr/bin/printf '%s\n' "$command" >> "$DIALOG_COMMAND_FILE"
    } always {
        /bin/rmdir "$lock_dir" 2>/dev/null
    }
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
    jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url) || {
        logMe "ERROR: Unable to read Jamf Pro URL" >&2
        return 1
    }
    jamfpro_url="${jamfpro_url%/}"
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
    # PURPOSE: Extract the summary of the JAMF command results
    # RETURN: XML contents of command
    # parameters: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   JAMF_COMMAND_SUMMARY - specific JAMF API call to execute
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server   
    local format="${2:-xml}"
    echo $(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}/${1}" )
}

function JAMF_retrieve_data_details ()
{    
    # PURPOSE: Extract the summary of the JAMF command results
    # RETURN: XML contents of command
    # parameters: $1 = The API command of the JAMF atrribute to read
    #            $2 = format to return XML or JSON
    # EXPECTED: 
    #   api_token - base64 hex code of your bearer token
    #   jamppro_url - the URL of your JAMF server
    local format="${2:-xml}"
    xmlBlob=$(/usr/bin/curl -s --header "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}/${1}")
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
    
    retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/$format" "${jamfpro_url}/${1}")
    case "${retval}" in
        *"INVALID_ID"* ) retval="INVALID_ID" ;;
        *"PRIVILEGE"* ) retval="ERR" ;;
        *) [[ ! -z $3 ]] && retval=$(printf "%s" "$retval" | jq  '[.[] | select('$3')]') ;;
    esac
    printf "%s" "$retval"
}

function JAMF_get_inventory_record ()
{
    # PURPOSE: Uses the JAMF 
    # RETURN: the device ID (UDID) for the device in question.
    # PARMS:  $1 - Section of inventory record to retrieve (GENERAL, DISK_ENCRYPTION, PURCHASING, APPLICATIONS, STORAGE, USER_AND_LOCATION, CONFIGURATION_PROFILES, PRINTERS, 
    #                                                      SERVICES, HARDWARE, LOCAL_USER_ACCOUNTS, CERTIFICATES, ATTACHMENTS, PLUGINS, PACKAGE_RECEIPTS, FONTS, SECURITY, OPERATING_SYSTEM,
    #                                                      LICENSED_SOFTWARE, IBEACONS, SOFTWARE_UPDATES, EXTENSION_ATTRIBUTES, CONTENT_CACHING, GROUP_MEMBERSHIPS)
    #        $2 - Filter condition to use for search

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || return 1
    http_status=$(/usr/bin/curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
        --data-urlencode "section=$1" --data-urlencode "filter=$2" "${jamfpro_url}/api/v2/computers-inventory")

    case "$http_status" in
        200)
            /bin/cat "$response_file"
            ;;
        401)
            logMe "ERROR: Jamf authentication failed retrieving DDM data, HTTP 401" >&2
            /bin/cat "$response_file" >&2
            /bin/rm -f "$response_file"
            return 1
            ;;
        403)
            logMe "ERROR: Insufficient privilege to retrieve DDM data, HTTP 403" >&2
            /bin/cat "$response_file" >&2
            /bin/rm -f "$response_file"
            return 1
            ;;
        404)
            printf 'Client %s not found. Is DDM enabled on that Mac?\n' "$1"
            /bin/rm -f "$response_file"
            return 1
            ;;
        *)
            logMe "ERROR: Unexpected Jamf response, HTTP ${http_status}" >&2
            /bin/cat "$response_file" >&2
            /bin/rm -f "$response_file"
            return 1
            ;;
    esac

    /bin/rm -f "$response_file"
}

function JAMF_get_bulk_inventory_record ()
{
    # PURPOSE: Uses the JAMF modern API to retrieve inventory info
    # NOTE: You can change the JAMF_INVENTORY_PAGE_SIZE to control how many results are returen in a single API call.
    #       This can be adjusted to suite your environment / performance results
    # RETURN: JSON blob of inventory records
    # PARMS:  None
    # EXPECTED: jamfpro_url, api_token

    local JAMF_API_KEY="api/v3/computers-inventory"
    local page=0
    local first_item=true  # Flag to track the very first item
    ${SW_DIALOG} --notification --style banner --identifier "inventory" --title "Retrieving JAMF Inventory Records" --message "Please be patient" --button1text "Dismiss"

    echo '[' > "$TMP_FILE_STORAGE"
    while :; do
        if ! results=$(curl -s -S -H "Authorization: Bearer $api_token" -H "Accept: application/json" "$jamfpro_url/$JAMF_API_KEY?page=$page&page-size=$JAMF_INVENTORY_PAGE_SIZE"); then
            logMe "ERROR: Unable to retrieve inventory page ${page}" >&2
        return 1
        fi

        if ! /usr/bin/jq -e '.results | arrays' >/dev/null 2>&1 <<< "$results"; then
            logMe "ERROR: Invalid inventory response on page ${page}" >&2
            return 1
        fi
        
        # a couple of verification checks to make sure we have valid data
        [[ -z "$results" || "$results" == "null" ]] && break
        
        results_count=$(jq '.results | length' <<<"$results")
        (( results_count == 0 )) && break
        
        # Process each object in the current results page
        # jq -c ensures each object is on a single line
        while IFS= read -r line; do
            if [[ "$first_item" == true ]]; then
                printf '  %s\n' "$line" >> "$TMP_FILE_STORAGE"
                first_item=false
            else
                printf '  ,%s\n' "$line" >> "$TMP_FILE_STORAGE"
            fi
        done < <(
            jq -c '
                .results[] |
                {
                    id: .id,
                    name: .general.name,
                    managementId: .general.managementId
                }
            ' <<< "$results"
        )
        ((page++))
    done
    # Close the JSON array
    echo ']' >> "$TMP_FILE_STORAGE"

    # Re-read in the file into an array for faster processing
    /bin/cat "$TMP_FILE_STORAGE"
}

function JAMF_get_deviceID ()
{
    # PURPOSE: uses the serial number or hostname to get the device ID from the JAMF Pro server.
    # RETURN: the device ID for the device in question.
    # PARMS: $1 - search identifier to use (serial or Hostname)
    #        $2 - Computer ID (serial/hostname)
    #        $3 - jq filter to extract the ID

    local retval type id total
    [[ $1 == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}/api/v3/computers-inventory?section=GENERAL&filter=${type}=='${2}'") || {
        display_failure_message "Failed to contact Jamf Pro"
        echo "ERR"
        return 1
    }

    if [[ $retval == *"PRIVILEGE"* ]]; then
        display_failure_message "Invalid Privilege to read inventory"
        echo "PRIVILEGE"
        return 1
    fi

    # Basic JSON validity check
    if ! jq -e . >/dev/null 2>&1 <<<"$retval"; then
        display_failure_message "Invalid JSON response from Jamf Pro"
        echo "ERR"
        return 1
    fi

    total=$(/usr/bin/jq -r '.totalCount // 0' <<< "$retval") || {
        display_failure_message "Unable to parse Jamf inventory response"
        printf '%s\n' "ERR"
        return 1
    }

    if (( total == 0 )); then
        display_failure_message "Inventory record '${2}' was not found."
        printf '%s\n' "NOT FOUND"
        return 1
    fi

    if (( total > 1 )); then
        display_failure_message "More than one inventory record matched '${2}'."
        printf '%s\n' "ERR"
        return 1
    fi

    id=$(printf '%s\n' "$retval" |  tr -d '[:cntrl:]' | jq -r "${3}")
    if [[ -z $id || $id == "null" ]]; then
        display_failure_message "$retval"
        echo "ERR"
        return 1
    fi
    printf '%s\n' "$id"
    return 0
}

function JAMF_get_DDM_info ()
{
    # PURPOSE: Retrieve DDM status items using the management ID.
    # RETURN:
    #   0 and JSON on stdout when successful
    #   1 on API, HTTP, or transport failure
    # PARMS:
    #   $1 - Management ID

    local management_id="$1"
    local response_file
    local http_status
    local curl_status

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary DDM response file" >&2
        return 1
    }

    {
        http_status=$(/usr/bin/curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url%/}/api/v1/ddm/${management_id}/status-items")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving DDM data for management ID ${management_id}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if ! /usr/bin/jq -e . "$response_file" >/dev/null 2>&1; then
                    logMe "ERROR: Jamf returned invalid JSON for management ID ${management_id}" >&2
                    /bin/cat "$response_file" >&2
                    return 1
                fi

                /bin/cat "$response_file"
                ;;

            401)
                logMe "ERROR: Jamf authentication failed retrieving DDM data, HTTP 401" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege to retrieve DDM data, HTTP 403" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;

            404)
                printf 'Client %s not found. Is DDM enabled on that Mac?\n' \
                    "$management_id"
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response, HTTP ${http_status}" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;
        esac
        } always {
           /bin/rm -f "$response_file"
        }
}

function JAMF_force_ddm_sync ()
{
    # PURPOSE: Request a DDM status sync for a management ID.
    # RETURN:
    #   0 for HTTP 204
    #   1 for transport or HTTP failure
    # PARMS:
    #   $1 - Management ID

    local management_id="$1"
    local response_file
    local http_status
    local curl_status

    response_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary DDM sync response file" >&2
        return 1
    }

    {
        http_status=$(/usr/bin/curl -s -S -L -o "$response_file" -w '%{http_code}' -X 'POST' -H "Authorization: Bearer ${api_token}" -H "accept: */*" "${jamfpro_url%/}/api/v1/ddm/${management_id}/sync" -d '')
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed sending DDM sync for management ID ${management_id}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            204)
                logMe "DDM sync successfully requested for management ID ${management_id}"
                return 0
                ;;

            400)
                logMe "ERROR: Jamf rejected the DDM sync request, HTTP 400" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;

            401)
                logMe "ERROR: Jamf authentication failed sending DDM sync, HTTP 401" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege to send DDM sync, HTTP 403" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;

            404)
                logMe "ERROR: DDM client ${management_id} was not found, HTTP 404" >&2
                return 1
                ;;

            500)
                logMe "ERROR: Jamf server error sending DDM sync, HTTP 500" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf DDM sync response, HTTP ${http_status}" >&2
                /bin/cat "$response_file" >&2
                return 1
                ;;
        esac
    } always {
        /bin/rm -f "$response_file"
    }
}

function JAMF_retrieve_ddm_blueprint_statuses ()
{
    # PURPOSE: Retrieve the status of each blueprint insalled on a system
    local json="$1"
    local value_str
    local blueprintID
    local record

    DDMBlueprintSuccess=()
    DDMBlueprintInactive=()
    DDMBlueprintInvalid=()
    DDMBlueprintFailed=()

    if ! value_str=$(printf '%s' "$json" | /usr/bin/jq -r '.value // empty'); then
        logMe "WARNING: Unable to extract blueprint configuration value" >&2
        return 1
    fi

    while IFS= read -r record; do
        [[ -z "$record" ]] && continue

        blueprintID=$(printf '%s\n' "$record" | /usr/bin/sed -n 's/.*identifier=Blueprint_\([^,}]*\).*/\1/p')
        blueprintID=$(printf '%s\n' "$blueprintID" | /usr/bin/sed 's/_s[0-9].*$//')

        [[ -z "$blueprintID" ]] && continue

        # These are intentionally independent tests.
        # One blueprint can have multiple state indicators.

        [[ "$record" == *"status=failed"* ]] && DDMBlueprintFailed+=("$blueprintID")
        [[ "$record" == *"valid=invalid"* ]] && DDMBlueprintInvalid+=("$blueprintID")
        [[ "$record" == *"active=true"* ]] && DDMBlueprintSuccess+=("$blueprintID")
        if [[ "$record" == *"active=false"* ]] ||
            [[ "$record" == *"valid=unknown"* ]]; then
            DDMBlueprintInactive+=("$blueprintID")
        fi

    done < <(printf '%s' "$value_str" | /usr/bin/tr '{}' '\n' )
    return 0
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
    # PURPOSE: Extract the Software Updates files from the system
    local input_json="$1"
    local results

    DDMSoftwareUpdateFailures=()

    if ! jq -e . >/dev/null 2>&1 <<< "$input_json"; then
        logMe "WARNING: Invalid DDM JSON while parsing software update failures" >&2
        return 1
    fi

    results=$(jq -r '.statusItems[]? | select((.key | type == "string") and (.key | startswith("softwareupdate.failure-reason.")) and (.value != null))
            | "\(.key | ltrimstr("softwareupdate.failure-reason.")):\(.value)" ' <<< "$input_json"
    ) || return 1

    [[ -n "$results" ]] && DDMSoftwareUpdateFailures=("${(@f)results}")
    return 0
}

function JAMF_retrieve_ddm_blueprint_invalid_reason ()
{
    local json="$1"
    local results
    local value_str
    
    value_str=$(printf '%s\n' "$json" | perl -ne 'print $1 if /"value":\s*"([^"]*)"/')
    results=$(printf '%s\n' "$value_str" | tr '{}' '\n\n' | grep -oE 'Error=[^}]+' | sed 's/^Error=//')
    DDMBlueprintInvalidReason=("${(f)results}")
}

function JAMF_retrieve_ddm_keys ()
{
    local input_json="$1"
    local requested_key="$2"

    printf '%s' "$input_json" | /usr/bin/jq -r --arg requested_key "$requested_key" '.statusItems[]? | select(.key == $requested_key)'
}

function JAMF_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* || -z $retval ]] && retval=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    printf '%s\n' "$retval"
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

    message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, You can choose to search all of your computers for a Blueprint ID, a single computer's Declarative Device Management (DDM) status, or a smart/static group "
    message+="for each computer's DDM status.<br><br>After your selection, another menu will appear with more options."

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --message $message
        --messagefont name=Arial,size=17
        --selecttitle "DDM Action (Read / Sync):",radio --selectvalues "Scan Blueprint ID, View Single System, Scan Smart/Static Group, Force Sync Single System, Populate Cross Reference File"
        --helpmessage $helpmessage
        --helpimage "qr="$helpmessageurl
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 480
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?
    [[ $buttonpress = 2 ]] && DDMoption="quit" || DDMoption=$(echo $message | plutil -extract 'SelectedOption' 'raw' -)
    logMe "${DDMoption} was chosen"
}

function execute_in_parallel ()
{
    # PURPOSE: Execute items in parallel for faster processing
    local process_type="$1"
    shift

    local -a ids=("$@")
    local -a worker_pids=()

    local ID
    local pid
    local completed_pid

    local numberOfComputers=${#ids[@]}
    local completed_count=0
    local progress=0
    local worker_failures=0

    (( numberOfComputers == 0 )) && return 0

    for ID in "${ids[@]}"; do
        if [[ "$process_type" == "blueprint" ]]; then
            process_blueprint_computer "$ID" &
        else
            process_group_computer "$ID" &
        fi

        worker_pids+=("$!")
        # Record the worker PIDs so we know when everything is done
        if (( ${#worker_pids[@]} >= BACKGROUND_TASKS )); then
            completed_pid="${worker_pids[1]}"

            if ! wait "$completed_pid"; then
                (( worker_failures++ ))
            fi

            worker_pids[1]=()

            (( completed_count++ ))
            progress=$(( completed_count * 100 / numberOfComputers ))

            update_display_list "progress" "" "" "" "Processed ${completed_count} of ${numberOfComputers}" "$progress"
        fi
    done

    # Wait for all of the work PIDs to finish
    for pid in "${worker_pids[@]}"; do
        if ! wait "$pid"; then
            (( worker_failures++ ))
        fi

        (( completed_count++ ))
        progress=$(( completed_count * 100 / numberOfComputers ))

        update_display_list "progress" "" "" "" "Processed ${completed_count} of ${numberOfComputers}" "$progress"
    done

    # If something failed, then record it
    if (( worker_failures > 0 )); then
        logMe "WARNING: ${worker_failures} background worker(s) failed" >&2
        return 1
    fi

    return 0
}

function csv_escape ()
{
    local value="$1"

    value=${value//$'\r'/ }
    value=${value//$'\n'/\\n}
    value=${value//\"/\"\"}

    printf '"%s"' "$value"
}

function append_csv_row ()
{
    # PURPOSE:
    #   Construct, escape, lock, and append one CSV record.
    #
    # PARAMETERS:
    #   $1  - System name
    #   $2  - Management ID
    #   $3  - Current OS
    #   $4  - Last update
    #   $5  - Status
    #   $6  - Failed Blueprint IDs
    #   $7  - Inactive Blueprint IDs
    #   $8  - Inactive reason
    #   $9  - Invalid Blueprint IDs
    #   $10 - Invalid reason
    #   $11 - Software update failures
    #
    # RETURN:
    #   0 - Record written
    #   1 - Lock or write failure

    local lock_dir="/var/tmp/${SCRIPT_NAME}.csv.lock"
    local attempts=0
    local csv_line

    if (( $# != 11 )); then
        logMe "ERROR: append_csv_row expected 11 fields but received $#" >&2
        return 1
    fi

    csv_line="$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
        "$(csv_escape "$1")" \
        "$(csv_escape "$2")" \
        "$(csv_escape "$3")" \
        "$(csv_escape "$4")" \
        "$(csv_escape "$5")" \
        "$(csv_escape "$6")" \
        "$(csv_escape "$7")" \
        "$(csv_escape "$8")" \
        "$(csv_escape "$9")" \
        "$(csv_escape "${10}")" \
        "$(csv_escape "${11}")")"

    while ! /bin/mkdir "$lock_dir" 2>/dev/null; do
        /bin/sleep 0.02
        (( attempts++ ))

        if (( attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for CSV lock" >&2
            return 1
        fi
    done

    {
        if ! /usr/bin/printf '%s\n' "$csv_line" >> "$CSV_OUTPUT"; then
            logMe "ERROR: Unable to append CSV record for: $1" >&2
            return 1
        fi
    } always {
        /bin/rmdir "$lock_dir" 2>/dev/null
    }

    return 0
}

###########################
#
# Populate Cross Reference functions
#
##########################

function welcomemsg_crossreference ()
{
    DDMCrossRef=$(read_crossref_file)

    message="**Populate Cross Reference File**<br><br>JAMF does not support viewing of Blueprints by Name. Follow the below instructions to create a cross reference file"
    message+=" that will display the name of the Blueprint with the ID:<br><br>"
    message+="1.  Enter just the blueprint ID and the name of your blueprint seperated by a comma<br>"
    message+="    _ex: 8bb536f0-140a-44e5-8e88-fe88523e9742,OS | Sequoia | Minor | Update_<br>"
    message+="2.  Make sure to put a return at the end of each line.<br>"
    message+="3.  The file will be saved here: **$DDM_CROSS_REF_FILE**<br>"
    message+="4.  The Blueprint Name will be included when possible in tasks & reports.<br>"
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --message "$message"
        --messagefont name=Arial,size=17
        --textfield "DDM Cross Reference,editor",value="$DDMCrossRef",name=crossref
        --button1text "Continue"
        --button2text "Cancel"
        --width 950
        --height 720
        --moveable
    )
    retval=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    [[ $buttonpress -eq 0 ]] && write_crossref_file "$retval"

}

function read_crossref_file ()
{
    local CSV_CONTENT
    if [[ ! -f "$DDM_CROSS_REF_FILE" ]]; then
        logMe "Error: File '$DDM_CROSS_REF_FILE' not found." 1>&2
        return 1
    fi
    # Read file, replace newlines with spaces to maintain single-line# then remove trailing spaces.
    CSV_CONTENT=$(cat "$DDM_CROSS_REF_FILE") # | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    logMe "File '$DDM_CROSS_REF_FILE' loaded into the editor" 1>&2
    printf '%s\n' "$CSV_CONTENT"
}

function write_crossref_file ()
{
    local input_data="$1"
    clean_string="${input_data#crossref : }"
    # Initialize the file
    : > "$DDM_CROSS_REF_FILE"
    # Write out each line and make sure there is a CRLF at the end of each line
    for line in "${(f)clean_string}"; do
        clean_line=$(printf '%s\n' "$line")
        if [[ -n "$clean_line" ]]; then
            printf '%s\n' "$clean_line" >> "$DDM_CROSS_REF_FILE"
        fi
    done
    logMe "Contents written out to: $DDM_CROSS_REF_FILE" 1>&2
}

function crossref_lookup ()
{
    local -a target_list=("$@")
    local uuid name rest item
    local -A xref
    [[ -f $DDM_CROSS_REF_FILE ]] || { echo "File not found: $DDM_CROSS_REF_FILE"; return 1; }

    # Read CSV lines; split on first comma only
    while IFS= read -r line; do
        [[ -z $line ]] && continue

        uuid=${line%%,*}
        rest=${line#*,}
        name=${rest%%,*}   # keep only field 2; ignore extra columns

        # trim leading/trailing whitespace
        uuid=${uuid##[[:space:]]#}; uuid=${uuid%%[[:space:]]#}
        name=${name##[[:space:]]#}; name=${name%%[[:space:]]#}

        [[ -n $uuid ]] && xref[$uuid]=$name
    done < "$DDM_CROSS_REF_FILE"

    # export results
    for item in "${target_list[@]}"; do
        if [[ -n ${xref[$item]-} ]]; then
            reply+=("$item (${xref[$item]})")
        else
            reply+=("$item")
        fi
    done
}

###########################
#
# Blueprint functions
#
##########################

function array_contains ()
{
    # PURPOSE: Scan an array for a "key" match
    local match="$1"
    shift

    local item
    for item in "$@"; do
        [[ "$item" == "$match" ]] && return 0
    done
    return 1
}

function welcomemsg_blueprint ()
{
    message="**View DDM info from Blueprints**<br><br>You have selected to view information from a Blueprint ID.  Please paste the entire URL of your JAMF blueprint, and all systems "
    message+="will be scanned for the existence of the blueprint (regardless of status).<br><br>*NOTE: If you choose to export the data to a CSV file, it will be created to show the data with more details.*"
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --message "$message"
        --messagefont name=Arial,size=17
        --vieworder "textfield,dropdown"
        --selecttitle "CSV results" --selectvalues "Everything, Failed Only, Invalid Only, Active Only, Inactive Only, Active & Inactive, Not Found Only" --selectdefault "Everything"
        --textfield "Blueprint URL",name=BPUrl,required
        --textfield "Blueprint Name (optional)",name=BPName
        --checkbox "Export CSV file",name="exportCSV"
        --checkbox "Display only matching systems",name="filterDisplay"
        --checkboxstyle switch
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?

    [[ $buttonpress = 2 ]] && return
    local blueprint_url

    blueprint_url=$(jq -r '.BPUrl // empty' <<< "$message")
    blueprint_url="${blueprint_url%%\?*}"
    blueprint_url="${blueprint_url%%\#*}"
    blueprint_url="${blueprint_url%/}"
    blueprintID="${blueprint_url##*/}"

    if [[ -z "$blueprintID" ]]; then
        display_failure_message "A valid Blueprint URL or Blueprint ID was not provided."
        return 1
    fi
        writeCSVFile=$(printf '%s' "$message" | jq -r '.exportCSV')
        blueprintName=$(printf '%s' "$message" | jq -r '.BPName')
        displayResults=$(printf '%s' "$message" | jq -r '."CSV results" .selectedValue')
        filterDisplay=$(printf '%s' "$message" | jq -r '.filterDisplay')
        process_blueprint "$blueprintID"
}

function process_blueprint ()
{
    # PURPOSE: Display the blueprint screen and get options from the user
    # RETURN: None
    # EXPECTED: Nonex

    local blueprintID=$1
    local computerList numberOfComputers ids
    local CSVfile

    # Initialize CSV if needed
    [[ ! -z $blueprintName ]] && CSVfile=$blueprintName || CSVfile=$blueprintID
    if [[ "$writeCSVFile" == true ]]; then
        CSV_OUTPUT="${CSV_PATH}${CSVfile} ($displayResults).csv"
        printf "%s\n" "$CSV_HEADER" > "$CSV_OUTPUT"
        logMe "Creating file: $CSV_OUTPUT"
    fi

    logMe "Retrieving DDM Info for Blueprint: $CSVfile"

    # Read in the computer inventory for all systems, capture, the ID, name & managementID of each computer
    # by using the modern API with the inventory pagination method, we are doing to use as little RAM as possible
    
    if ! computerList=$(JAMF_get_bulk_inventory_record); then
        display_failure_message "Unable to retrieve Jamf inventory records."
        return 1
    fi
    numberOfComputers=$(jq -r 'length' <<< "$computerList")
    logMe "INFO: There are $numberOfComputers Computers to scan for $CSVfile"

    create_listitem_list "Displaying all systems that have Blueprint:<br>$CSVfile for ($displayResults)" "json" ".[].name" "$computerList" "SF=desktopcomputer.and.macbook"
 
     # Get the list of IDs
    ids=($(jq -r '.[].id' <<< "$computerList"))

    # Execute parallel tasks
    if ! execute_in_parallel "blueprint" "${ids[@]}"; then
        logMe "WARNING: One or more blueprint workers failed" >&2
        update_display_list "progress" "" "" "Completed with worker errors" "" 100
    else
        update_display_list "progress" "" "" "Completed" "" 100
    fi

    # all done, so enable the button and wait for a keypress
    update_display_list "buttonenable"
    [[ -n "$DIALOG_PROCESS" ]] && wait "$DIALOG_PROCESS"
}

function process_blueprint_computer () 
{
    # PURPOSE: perform the actual processing of each system, show the blueprint status for the requested type
    # RETURN: None
    # EXPECTED: Nonex

    local JAMF_API_KEY2="api/v2/computers-inventory"
    local ID="$1"
    local statusmessage="BP Installed (Active)"
    local DDMDeviceCurrentOSName
    local sanitized_clean_swu=""
    local sanitized_bpfailed=""
    local sanitized_bpinactive=""
    local sanitized_bpinactive_reason=""
    local sanitized_bpinvalid=""
    local sanitized_bpinvalid_reason=""
    local DDMInfo DDMInfo_clean DDMKeys
    local JSONblob
    local name managementId lastUpdateTime canWrite liststatus
    local blueprintIsActive=false
    local blueprintIsInactive=false
    local blueprintIsInvalid=false
    local blueprintHasErrors=false
    local DDMInactiveReason
    liststatus="success"

    # Extract info from Computer Inventory
    JSONblob=$(JAMF_retrieve_data_blob "$JAMF_API_KEY2/$ID?section=GENERAL" "json")
    [[ -z "$JSONblob" ]] && return

    # DDM works by using the Management ID to retrieve the DDM info, so we need to extract that from the inventory record first
    name=$(printf "%s" "$JSONblob" | jq -r '.general.name')
    managementId=$(printf "%s" "$JSONblob" | jq -r '.general.managementId')
    if [[ -z "$managementId" || "$managementId" == "null" ]]; then
        logMe "ERROR: No management ID returned for $name" >&2
        update_display_list "Update" "" "$name" "Management ID unavailable" "error"
        return 1
    fi

    # Retrieve the DDM info for this computer using the Management ID
    if ! DDMInfo=$(JAMF_get_DDM_info "$managementId"); then
        if [[ "$DDMInfo" == *"not found"* ]]; then
            logMe "INFO: DDM information was not found for $name"
            update_display_list "Update" "" "$name" "DDM may not be active" "error"
            return 0
        fi
        logMe "ERROR: Unable to retrieve DDM information for $name" >&2
        update_display_list "Update" "" "$name" "Unable to retrieve DDM info" "error"
        return 1
    fi
    # Check to see if the BP is actually found anywhere in the DDM Info Blob
    if ! /usr/bin/grep -Fq -- "$blueprintID" <<< "$DDMInfo"; then
        liststatus="fail"
        statusmessage="BP not found"
        canWrite=false

        # If filtering by specific criteria, then allow the list to be updated
        if [[ "$displayResults" == "Not Found Only" || "$displayResults" == "Everything" ]]; then
            canWrite=true
        fi

        # Either show or delete the item based on the mainmenu options
        if [[ "$filterDisplay" == true && "$canWrite" != true ]]; then
            update_display_list "delete" "$name"
        else
            update_display_list "Update" "" "$name" "$statusmessage" "$liststatus"
        fi

        # Log the info
        logMe "$statusmessage on system: $name"

        # And write it out to the CSV file if that option is turnd on
        if [[ "$writeCSVFile" == true && "$canWrite" == true ]]; then
            append_csv_row "$name" "$managementId" "" "N/A" "Not Found" "" "" "" "" "" ""
        fi

        return 0
    fi
    # sanitize the DDMInfo to remove any control characters that may cause issues with jq parsing
    DDMInfo_clean=$(tr -d '[:cntrl:]' <<< "$DDMInfo")

    # Extract the relevant DDM keys and information
    DDMKeys=$(jq -r '.statusItems[]? |  select(.key == "management.declarations.configurations")' <<< "$DDMInfo_clean")
    lastUpdateTime=$(jq -r '(.statusItems[]? |  select(.key == "softwareupdate.failure-reason.reason") | .lastUpdateTime) // "N/A"' <<< "$DDMInfo_clean")
    DDMDeviceCurrentOSName=$(jq -r '.statusItems[]? |  select(.key == "device.operating-system.marketing-name").value' <<< "$DDMInfo_clean")

    if ! JAMF_retrieve_ddm_blueprint_statuses "$DDMKeys"; then
        logMe "ERROR: Unable to parse blueprint status for $name" >&2
        update_display_list "Update" "" "$name" "Unable to parse BP status" "error"
        return 1
    fi
    JAMF_retrieve_ddm_softwareupdate_failures "$DDMInfo_clean"
    JAMF_retrieve_ddm_blueprint_invalid_reason "$DDMKeys"

    # Detemrine the status of the blueprint for this system, check for failed, then check for not found, then check for invalid.  If none of those, it is active.
    array_contains "$blueprintID" "${DDMBlueprintSuccess[@]}" && blueprintIsActive=true
    array_contains "$blueprintID" "${DDMBlueprintInactive[@]}" && blueprintIsInactive=true
    array_contains "$blueprintID" "${DDMBlueprintInvalid[@]}" && blueprintIsInvalid=true
    array_contains "$blueprintID" "${DDMBlueprintFailed[@]}" && blueprintHasErrors=true

    # Determine the displayed status.
    #
    # Precedence:
    #   1. Invalid
    #   2. Failed
    #   3. Active and Inactive
    #   4. Active
    #   5. Inactive
    #   6. Not found

    local blueprintClassification="BP Not Found"

    if [[ "$blueprintIsInvalid" == true ]]; then
        blueprintClassification="Invalid"
        liststatus="error"
        statusmessage="BP Installed (Invalid)"

    elif [[ "$blueprintHasErrors" == true ]]; then
        blueprintClassification="Failed"
        liststatus="fail"
        statusmessage="BP Installed (Failed)"

    elif [[ "$blueprintIsActive" == true && "$blueprintIsInactive" == true ]]; then
        blueprintClassification="Conditional"
        liststatus="pending"
        statusmessage="BP Installed (Conditional)"

    elif [[ "$blueprintIsActive" == true ]]; then
        blueprintClassification="Active"
        liststatus="success"
        statusmessage="BP Installed (Active)"

    elif [[ "$blueprintIsInactive" == true ]]; then
        blueprintClassification="Inactive"
        liststatus="fail"
        statusmessage="BP Installed (Inactive)"

    else
        blueprintClassification="Not Found"
        liststatus="fail"
        statusmessage="BP not found"
    fi

    # Eval criteria

    canWrite=false

    case "$displayResults" in
        "Everything")           canWrite=true ;;
        "Failed Only")          [[ "$blueprintClassification" == "Failed" ]] && canWrite=true ;;
        "Invalid Only")         [[ "$blueprintClassification" == "Invalid" ]] && canWrite=true ;;
        "Active Only")          [[ "$blueprintClassification" == "Active" ]] && canWrite=true ;;
        "Inactive Only")        [[ "$blueprintClassification" == "Inactive" ]] && canWrite=true ;;
        "Active & Inactive")    [[ "$blueprintClassification" == "Conditional" ]] && canWrite=true ;;
        "Not Found Only")       [[ "$blueprintClassification" == "Not Found" ]] && canWrite=true ;;
        *)                      logMe "WARNING: Unknown blueprint display filter: $displayResults" >&2 ;;
    esac

    # Either show or delete the item based on the mainmenu options
    if [[ "$filterDisplay" == true && "$canWrite" != true ]]; then
        update_display_list "delete" "$name"
    else
        update_display_list "Update" "" "$name" "$statusmessage" "$liststatus"
    fi

    logMe "$statusmessage on system: $name"

    # Early exit if we don't need to write out the CSV file
    if [[ "$writeCSVFile" != true ]]; then
        printf 'INFO: System: %s - ManagementID: %s - Status: %s\n' "$name" "$managementId" "$statusmessage"
        return 0
    fi
    
    # Sanitize the output to be CSV save and then write it out
    if [[ "$canWrite"  = true ]]; then
        sanitized_clean_swu="${(j:;:)DDMSoftwareUpdateFailures}"
        sanitized_bpfailed="${(j:;:)DDMBlueprintFailed}"
        sanitized_bpinactive="${(j:;:)DDMBlueprintInactive}"
        sanitized_bpinvalid="${(j:;:)DDMBlueprintInvalid}"
        sanitized_bpinvalid_reason="${(j:;:)DDMBlueprintInvalidReason}"
        if (( ${#DDMBlueprintInactive[@]} > 0 )); then
            DDMInactiveReason=$(printf "%s" "$DDMKeys" | perl -ne 'print "$1\n" if /code=([^},]+)/')
            sanitized_bpinactive_reason="${DDMInactiveReason//,/;}"
        fi

        # Write out this info to the CSV file
        local csvBlueprintStatus
        csvBlueprintStatus="$blueprintClassification"
        append_csv_row "$name" "$managementId" "$DDMDeviceCurrentOSName" "$lastUpdateTime" "$csvBlueprintStatus" "$sanitized_bpfailed" "$sanitized_bpinactive" "$sanitized_bpinactive_reason" "$sanitized_bpinvalid" \
        "$sanitized_bpinvalid_reason" "$sanitized_clean_swu"
    fi
}

###########################
#
# View Individual computer functions
#
##########################

function welcomemsg_individual ()
{
    message="**View Individual System**<br><br>Please enter the serial or hostname of the device you wish to see the DDM information for.  The results for Software Updates, Active & Failed Blueprints, as well as any error messages will be displayed.<br><br>"
    message+="*NOTE: If you choose to export the data, a TXT file will be created at your chosen location.  Leave the TXT Folder location empty if you do not want to export data*."
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --message $message
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --selecttitle "Serial,required"
        --textfield "TXT folder location,fileselect,filetype=folder,prompt=$CSV_PATH,name=writeTXTFile"
        --checkboxstyle switch
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    [[ $buttonpress = 2 ]] && return
    search_type=$(printf '%s' "$message" | jq -r '.SelectedOption')
    computer_id=$(printf '%s' "$message" | jq -r '.Device')
    writeTXTFile=$(printf '%s' "$message" | jq -r '.writeTXTFile // empty')
    process_individual "$search_type" "$computer_id" "View"
}

function process_individual ()
{
    local search_type=$1
    local computer_id=$2
    local action_type=$3
    local DDMInfo
    local DDMKeys
    local DDMDevicename
    local DDMDeviceModel
    local DDMDeviceCurrentOSBuild
    local DDMDeviceCurrentOSName
    local DDMDeviceSecurityCertificates
    local active_display
    local DDMBatteryHealth
    local DDMClientSupportedPayload
    local DDMClientSupportedVersions
    local DDMInfo_clean
    local DDMInactiveReason
    local message
    local logMessage
    local clean

    # First we have to get the JAMF ManagementID of the machine
    echo "Searching for $search_type: $computer_id"

    ID=$(JAMF_get_deviceID "${search_type}" "${computer_id}" ".results[].general.managementId")
    [[ $ID == *"ERR"* ]] && cleanup_and_exit 1
    [[ $ID == *"NOT FOUND"* || $ID == *"PRIVILEGE"* ]] && return 1

    # Second is to extract the DDM info for the machine
    if ! DDMInfo=$(JAMF_get_DDM_info "$ID"); then
        if [[ "$DDMInfo" == *"not found"* ]]; then
            logMe "INFO: DDM may not be active on device: $computer_id"
            display_failure_message "No DDM information was found for ${computer_id}.<br><br>DDM may not be enabled on this Mac."
            return 1
        fi

        logMe "ERROR: Unable to retrieve DDM info for $computer_id" >&2
        display_failure_message "Unable to retrieve DDM information for ${computer_id}."
        return 1
    fi

    # Third, extract all the DDM info from this JSON blob

    DDMDevicename=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.model.marketing-name").value')
    DDMDeviceModel=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.model.identifier").value')
    DDMDeviceCurrentOSName=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.operating-system.marketing-name").value')
    DDMDeviceCurrentOSBuild=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.operating-system.build-version").value')
    DDMBatteryHealth=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.power.battery-health").value')
    DDMClientSupportedPayload=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "management.client-capabilities.supported-payloads.declarations.configurations").value' | tr ',' '\n')
    DDMDeviceSecurityCertificates=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "security.certificate.list").value')
    [[ -z $DDMDeviceSecurityCertificates ]] && DDMDeviceSecurityCertificates="None"
    DDMClientSupportedVersions=$(echo -E "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "management.client-capabilities.supported-versions").value')

    logMe "INFO: Device Name: $DDMDevicename"
    logMe "INFO: Device Model: $DDMDeviceModel"
    logMe "INFO: Current OS Name: $DDMDeviceCurrentOSName"
    logMe "INFO: Current OS Build: $DDMDeviceCurrentOSBuild"
    logMe "INFO: Battery Health: $DDMBatteryHealth"
    logMe "INFO: Client Supported Payloads: $DDMClientSupportedPayload"
    logMe "INFO: Security Certificates: $DDMDeviceSecurityCertificates"
    logMe "INFO: Client Supported Versions: $DDMClientSupportedVersions"

    # Fourth, extract the DDM Software Update info for the machine
    JAMF_retrieve_ddm_softwareupdate_info "$DDMInfo"
    logMe "INFO: Software Update Info: $DDMSoftwareUpdateActive"

    # Fifth, see if there are any software update failures
    DDMInfo_clean=$(tr -d '[:cntrl:]' <<< "$DDMInfo")
    JAMF_retrieve_ddm_softwareupdate_failures "${DDMInfo_clean}"
    [[ -z $DDMSoftwareUpdateFailures ]] && DDMSoftwareUpdateFailures="None"
    logMe "INFO: Software Update Failures: $DDMSoftwareUpdateFailures"

    # Sixth, extract the DDM blueprint IDs assigned to the machine
    DDMKeys=$(JAMF_retrieve_ddm_keys "$DDMInfo" "management.declarations.configurations")
    if ! JAMF_retrieve_ddm_blueprint_statuses "$DDMKeys"; then
        logMe "ERROR: Unable to parse blueprint status for $DDMDevicename" >&2
        return 1
    fi
    
    # For each of the following arrays, we will cross reference the blueprint ID with the cross reference file to get the name of the blueprint if it exists
    #
    # BlueprintSuccess
    # BlueprintFailed
    # BlueprintInvalid
    # BlueprintInactive

    reply=()    
    crossref_lookup "${DDMBlueprintSuccess[@]}"
    [[ -f $DDM_CROSS_REF_FILE ]] && DDMBlueprintSuccess=("${reply[@]}")
    for i in {1..${#DDMBlueprintSuccess[@]}}; do
        [[ -z ${DDMBlueprintSuccess[i]} ]] && continue
        logMe "INFO: Active Blueprints: $DDMBlueprintSuccess[i]"
    done
    if (( ${#DDMBlueprintSuccess[@]} > 0 )); then
        active_display="${(j:<br>:)DDMBlueprintSuccess}"
    else
        active_display="None"
    fi

    reply=()    
    crossref_lookup "${DDMBlueprintFailed[@]}"
    [[ -f $DDM_CROSS_REF_FILE ]] && DDMBlueprintFailed=("${reply[@]}")
    for i in {1..${#DDMBlueprintFailed[@]}}; do
        [[ -z ${DDMBlueprintFailed[i]} ]] && continue
        logMe "INFO: Failed Blueprints: $DDMBlueprintFailed[i]"
    done
    (( ${#DDMBlueprintFailed[@]} == 0 )) && DDMBlueprintFailed=("None") 
  

    reply=()    
    crossref_lookup "${DDMBlueprintInvalid[@]}"
    [[ -f $DDM_CROSS_REF_FILE ]] && DDMBlueprintInvalid=("${reply[@]}")
    for i in {1..${#DDMBlueprintInvalid[@]}}; do
        [[ -z ${DDMBlueprintInvalid[i]} ]] && continue
        logMe "INFO: Invalid Blueprints: $DDMBlueprintInvalid[i]"
    done
    (( ${#DDMBlueprintInvalid[@]} == 0 )) && DDMBlueprintInvalid=("None")

    reply=()
    crossref_lookup "${DDMBlueprintInactive[@]}"
    [[ -f $DDM_CROSS_REF_FILE ]] && DDMBlueprintInactive=("${reply[@]}")
    logMe "INFO: Inactive Blueprints: $DDMBlueprintInactive"

    for i in {1..${#DDMBlueprintInactive[@]}}; do
        [[ -z ${DDMBlueprintInactive[i]} ]] && continue
        logMe "INFO: Inactive Blueprints: $DDMBlueprintInactive[i]"
    done
    if (( ${#DDMBlueprintInactive[@]} > 0 )); then
        DDMInactiveReason=$(printf '%s' "$DDMKeys" | /usr/bin/perl -ne 'print "$1\n" if /code=([^},]+)/')
    else
        DDMInactiveReason="None"
        DDMBlueprintInactive=("None")
    fi

    # Lastly, see if there are any invalid blueprints
    JAMF_retrieve_ddm_blueprint_invalid_reason "$DDMKeys"
    [[ -z $DDMBlueprintInvalidReason ]] && DDMBlueprintInvalidReason="None"

    logMe "INFO: Invalid Blueprints: "$DDMBlueprintInvalid
    logMe "INFO: Invalid Blueprint Reason: "$DDMBlueprintInvalidReason

    #Show the results and log it
    message="**Device name:** <br>$computer_id<br><br>**JAMF Management ID:**<br>$ID<br><br><br>"
    message+="**Device Info**<br>$DDMDevicename ($DDMDeviceModel)<br>Running: $DDMDeviceCurrentOSName ($DDMDeviceCurrentOSBuild)<br>Battery Health: $DDMBatteryHealth<br>"
    message+="<br><br>**DDM Client Supported Version**<br>$DDMClientSupportedVersions"
    message+="<br><br>**DDM Blueprints Active**<br>$active_display<br>"
    message+="<br><br>**DDM Blueprints Failed**<br>${(j:<br>:)DDMBlueprintFailed}<br>"
    message+="<br><br>**DDM Blueprint Inactive**<br>${(j:<br>:)DDMBlueprintInactive}<br>"
    message+="<br><br>**DDM Blueprint Inactive Reason**<br>$DDMInactiveReason<br>"
    message+="<br><br>**DDM Blueprint Invalid**<br>${(j:<br>:)DDMBlueprintInvalid}<br>"
    message+="<br><br>**DDM Blueprint Invalid Reason**<br>${(j:<br>:)DDMBlueprintInvalidReason}<br>"
    message+="<br><br>**DDM Software Update Info**<br>${(j:<br>:)DDMSoftwareUpdateActive}<br>"
    message+="<br><br>**DDM Software Update Failures**<br>${(j:<br>:)DDMSoftwareUpdateFailures}<br>"
    message+="<br><br>**DDM Client Supported Payload**<br>$DDMClientSupportedPayload"
    message+="<br><br>**DDM Security Certificates**<br>$DDMDeviceSecurityCertificates"
    display_results "$message" "$ID" "$action_type" "$computer_id"
 
    if [[ -n "$writeTXTFile" ]]; then
        # Create the output file with the results
        CSV_OUTPUT="$writeTXTFile/DDM Results for $computer_id.txt"
        logMessage="${message//<br>/\\n}"
        clean="${logMessage//\*\*/--}"
        logMe "Export file: $CSV_OUTPUT"
        printf '%s\n' "$clean" > "$CSV_OUTPUT"
    fi
}

function display_results ()
{
    local message=$1
    local computer_id=$2
    local action_type=$3
    local ComputerName=$4
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --message "Here are the result of the DDM info for this mac:<br><br>$message"
        --messagefont name=Arial,size=14
        --helpmessage "Add this URL prefix to the Blueprint ID to find the Blueprint details<br>${jamfpro_url}/view/mfe/blueprints/"
        --button1text "OK"
        --ontop
        --width 900
        --height 750
        --moveable
    )

    [[ $extractRAWData == "true" ]] && MainDialogBody+=(--infotext "The CSV file will be stored in $USER_DIR/Desktop") || MainDialogBody+=(--infotext $SCRIPT_VERSION)
    if [[ "$action_type" == "View" ]] && (( ${#DDMBlueprintSuccess[@]} > 0 )); then
        MainDialogBody+=(--button2text "Open BP Links")
    elif [[ "$action_type" == "Sync" ]]; then
        MainDialogBody+=(--button2text "Force Sync")
    fi


    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
    [[ $buttonpress = 0 ]] && return

    if [[ $action_type == "View" ]]; then
        open_blueprint_links
    elif [[ $action_type == "Sync" ]]; then
        logMe "Forcing DDM Sync on system: $computer_id"
        retval=$(JAMF_force_ddm_sync $computer_id)
        if [[ $? -eq 0 ]]; then
            message="Sync Command successful for system $ComputerName ($computer_id)<br><br>The next time the system checks-in you can view the updated results."
            "$SW_DIALOG" --message "$message" \
                --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}" \
                --bannerimage "${SD_BANNER_IMAGE}" \
                --bannertitle "${SD_WINDOW_TITLE}" \
                --icon "${SD_ICON_FILE}" \
                --overlayicon "${OVERLAY_ICON}" \
                --ontop
        fi
    fi

}

function open_blueprint_links ()
{
    local item
    local blueprint_id

    for item in "${DDMBlueprintSuccess[@]}"; do
        blueprint_id="${item%% \(*}"
        /usr/bin/open "${jamfpro_url%/}/view/mfe/blueprints/${blueprint_id}"
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

    message="**View DDM info from groups**<br><br>You have selected to view information from Smart/Static Groups.<br>Please select the group and display results from the options below:<br><br>"
    message+="*NOTE: If you choose to export the data to a CSV file, it will be created to show the data with more details.*"
    construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"

    # Read in the JAMF groups and create a dropdown list of them
    tempArray=$(JAMF_retrieve_data_blob "$JAMF_API_KEY" "json")
    GroupList=$(echo "$tempArray" | jq -r '.computer_groups')
    if [[ -z $GroupList ]]; then
        logMe "Having problems reading the groups list from JAMF, exiting..."
        cleanup_and_exit 1
    fi
    create_dropdown_message_body "" "" "" "first"
    array=$(construct_dropdown_list_items "$GroupList" '.[]')
    create_dropdown_message_body "Select Groups:" "$array" "1"


    create_dropdown_message_body "Display results" '"Everything", "Failed Only", "Inactive Only", "Invalid Only", "No Errors Only"' "Everything"
    create_dropdown_message_body "" "" "" "last"
    echo ',' >> "${JSON_DIALOG_BLOB}"
    create_checkbox_message_body "" "" "" "" "" "first"
    create_checkbox_message_body "Export all data to CSV File" "exportcsv" "" "true" "false"
    create_checkbox_message_body "Include SW Update failures in CSV File" "includeSWUFail" "" "true" "false" "last"
    printf '%s\n' '}' >> "$JSON_DIALOG_BLOB"

	message=$(${SW_DIALOG} --vieworder "dropdown, checkbox" --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    buttonpress=$?
    [[ $buttonpress = 2 ]] && return

    #jamfGroup=$(printf '%s' "$message" | jq '."Select Groups:" .selectedValue')
    jamfGroup=$(jq -r '."Select Groups:".selectedValue' <<< "$message")
    displayResults=$(printf '%s' "$message" | jq -r '."Display results" .selectedValue')
    writeCSVFile=$(printf '%s' "$message" | jq '.exportcsv')
    includeSWUFail=$(printf '%s' "$message" | jq '.includeSWUFail')
    process_group "$jamfGroup" "$displayResults"
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
    # API workflow - You have to call the inventory to get the ID of the computer and the Management ID (these are two separate items)
    # then, you have to use the Management ID to call the DDM info

    # Remove double quotes and split by '-' into an array 'parts'
    local group_selection="${1//\"/}"
    local GroupID="${group_selection%% - *}"
    local GroupName="${group_selection#* - }"
    GroupID="${GroupID//[[:space:]]/}"
 
    #local GroupID="${parts[1]//[[:space:]]/}"
    #local GroupName="${parts[2]}"
    local JAMF_API_KEY="JSSResource/computergroups/id"
    local computerList
    local numberOfComputers

    # Initialize CSV if needed
    if [[ "$writeCSVFile" == true ]]; then
        CSV_OUTPUT="${CSV_PATH}${GroupName} ($displayResults).csv"
        printf "%s\n" "$CSV_HEADER" > "$CSV_OUTPUT"
        logMe "Creating file: $CSV_OUTPUT"
    fi

    logMe "Retrieving DDM Info for group: $GroupName (ID: $GroupID)"
    # Locate the IDs of each computer in the selected group and then call the DDM info for each computer in parallel
    logMe "INFO: Retrieve information for: $1"
    computerList=$(JAMF_retrieve_data_blob "$JAMF_API_KEY/$GroupID" "json")
    if [[ "$computerList" == "ERR" ]]; then
        logMe "ERROR: Insufficient privileges to read Groups"
        cleanup_and_exit 1
    fi

    numberOfComputers=$(jq -r '.computer_group.computers | length' <<< "$computerList") 
    logMe "INFO: There are $numberOfComputers Computers in $GroupName"

    create_listitem_list "Retrieving DDM Info from computers that are in group:<br> $GroupName." \
        "json" ".computer_group.computers[].name" "$computerList" "SF=desktopcomputer.and.macbook"
 
     # Get the list of IDs
    ids=($(jq -r '.computer_group.computers[].id' <<< "$computerList"))

    # Execute parallel tasks
    if ! execute_in_parallel "group" "${ids[@]}"; then
        logMe "WARNING: One or more group workers failed" >&2
        update_display_list "progress" "" "" "Completed with worker errors" "" 100
    else
        update_display_list "progress" "" "" "Completed" "" 100
    fi
    update_display_list "buttonenable"
  
    [[ -n "$DIALOG_PROCESS" ]] && wait "$DIALOG_PROCESS"
}

function process_group_computer () 
{
    local JAMF_API_KEY2="api/v2/computers-inventory"
    local ID="$1"
    local statusmessage="No BP errors found"
    local DDMInfo
    local DDMInfo_clean
    local DDMKeys
    local sanitized_bpfailed 
    local sanitized_clean_swu
    local JSONblob
    local csvBlueprintStatus
    local canWrite=false
    local name managementId 
    local lastUpdateTime 
    local liststatus
    local DDMDeviceCurrentOSName
    local DDMInactiveReason
    liststatus="success"

    # Extract info from Computer Inventory

    JSONblob=$(JAMF_retrieve_data_blob "$JAMF_API_KEY2/$ID?section=GENERAL" "json")
    [[ -z "$JSONblob" ]] && return

    name=$(printf "%s" "$JSONblob" | jq -r '.general.name')
    managementId=$(printf "%s" "$JSONblob" | jq -r '.general.managementId')
    if [[ -z "$managementId" || "$managementId" == "null" ]]; then
        logMe "ERROR: No management ID returned for $name" >&2
        update_display_list "Update" "" "$name" "Management ID unavailable" "error"
        return 1
    fi

    if ! DDMInfo=$(JAMF_get_DDM_info "$managementId"); then
        if [[ "$DDMInfo" == *"not found"* ]]; then
            logMe "INFO: DDM may not be active on device: $name"
            update_display_list "Update" "" "$name" "DDM may not be active" "error"
            return 0
        fi

        logMe "ERROR: Unable to retrieve DDM info for $name" >&2
        update_display_list "Update" "" "$name" "Unable to retrieve DDM info" "error"
        return 1
    fi
    DDMInfo_clean=$(tr -d '[:cntrl:]' <<< "$DDMInfo")
    DDMKeys=$(jq -r '.statusItems[]? |  select(.key == "management.declarations.configurations")' <<< "$DDMInfo_clean")
    lastUpdateTime=$(jq -r '(.statusItems[]? |  select(.key == "softwareupdate.failure-reason.reason") | .lastUpdateTime) // "N/A"' <<< "$DDMInfo_clean")
    DDMDeviceCurrentOSName=$(jq -r '.statusItems[]? |  select(.key == "device.operating-system.marketing-name").value' <<< "$DDMInfo_clean")

    if ! JAMF_retrieve_ddm_blueprint_statuses "$DDMKeys"; then
        logMe "ERROR: Unable to parse blueprint status for $name" >&2
        update_display_list "Update" "" "$name" "Unable to parse BP status" "error"
        return 1
    fi
    JAMF_retrieve_ddm_softwareupdate_failures "$DDMInfo_clean"
    JAMF_retrieve_ddm_blueprint_invalid_reason "$DDMKeys"

    if (( ${#DDMBlueprintInvalid[@]} > 0 )); then
        liststatus="error"
        statusmessage="BP Invalid"
    elif (( ${#DDMBlueprintFailed[@]} > 0 )); then
        liststatus="fail"
        statusmessage="BP Failed"
    elif (( ${#DDMBlueprintInactive[@]} > 0 )); then
        liststatus="warning"
        statusmessage="BP Inactive"
    else
        liststatus="success"
        statusmessage="No BP errors found"
    fi
    update_display_list "Update" "" "${name}" "${statusmessage}" "${liststatus}"

    # Eval criteria
    canWrite=false

    case "$displayResults" in
        "Failed Only")          (( ${#DDMBlueprintFailed[@]} > 0 )) && canWrite=true ;;
        "Inactive Only")        (( ${#DDMBlueprintInactive[@]} > 0 )) && canWrite=true ;;
        "Invalid Only")         (( ${#DDMBlueprintInvalid[@]} > 0 )) && canWrite=true ;;
        "No Errors Only")       if (( ${#DDMBlueprintFailed[@]} == 0 && ${#DDMBlueprintInactive[@]} == 0 && ${#DDMBlueprintInvalid[@]} == 0 )); then
                                canWrite=true
                                fi ;;
        "Everything")           canWrite=true ;;
        *)                      logMe "WARNING: Unknown group display filter: $displayResults" >&2 ;;
    esac


    # Early exit if we don't need to write out the CSV file
    if [[ "$writeCSVFile" != true ]]; then
        [[ "$canWrite" == true ]] && printf 'INFO: System: %s - ManagementID: %s - Status: %s\n' "$name" "$managementId" "$statusmessage"
        return 0
    fi

    [[ "$includeSWUFail" == false ]] && DDMSoftwareUpdateFailures=()

    local sanitized_clean_swu=""
    local sanitized_bpfailed=""
    local sanitized_bpinactive=""
    local sanitized_inactive_reason=""
    local sanitized_bpinvalid=""
    local sanitized_bpinvalid_reason=""

    sanitized_clean_swu="${(j:;:)DDMSoftwareUpdateFailures}"
    sanitized_bpfailed="${(j:;:)DDMBlueprintFailed}"
    sanitized_bpinactive="${(j:;:)DDMBlueprintInactive}"
    sanitized_bpinvalid="${(j:;:)DDMBlueprintInvalid}"
    sanitized_bpinvalid_reason="${(j:;:)DDMBlueprintInvalidReason}"

    if (( ${#DDMBlueprintInactive[@]} > 0 )); then
        DDMInactiveReason=$(printf '%s' "$DDMKeys" | /usr/bin/perl -ne 'print "$1\n" if /code=([^},]+)/' )
        sanitized_inactive_reason="${DDMInactiveReason//,/;}"
    fi

    case "$statusmessage" in
        "No BP errors found")   csvBlueprintStatus="No BP errors found" ;;
        "BP Failed")            csvBlueprintStatus="Failed" ;;
        "BP Inactive")          csvBlueprintStatus="Inactive" ;;
        "BP Invalid")           csvBlueprintStatus="Invalid" ;;
        *)                      csvBlueprintStatus="$statusmessage" ;;
    esac

    logMe "$statusmessage on system: $name"

    # Write out this info to the CSV file
    if [[ $canWrite  = true ]]; then
        append_csv_row "$name" "$managementId" "$DDMDeviceCurrentOSName" "$lastUpdateTime" "$csvBlueprintStatus" "$sanitized_bpfailed" "$sanitized_bpinactive" "$sanitized_inactive_reason" "$sanitized_bpinvalid" \
        "$sanitized_bpinvalid_reason" "$sanitized_clean_swu"
    fi
}

###########################
#
# Force Sync functions
#
##########################

function welcomemsg_forcesync ()
{
    message="**Force Sync Individual System**<br><br>Please enter the serial or hostname of the device you wish to see the DDM information for.  The results for Software Updates, Active & Failed Blueprints, as well as any error messages will be displayed.<br><br>"
    message+="There will be an option to force sync DDM data to the machine on the next screen."
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext $SCRIPT_VERSION
        --message $message
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --selecttitle "Serial,required"
        --checkboxstyle switch
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$($SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    [[ $buttonpress = 2 ]] && return
    search_type=$(printf '%s' "$message" | jq -r '.SelectedOption')
    computer_id=$(printf '%s' "$message" | jq -r '.Device')
    process_individual "$search_type" "$computer_id" "Sync"
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
typeset -gaU DDMSoftwareUpdateActive
typeset -gaU DDMSoftwareUpdateFailures
typeset -gaU DDMBlueprintInactive
typeset -gaU DDMBlueprintSuccess
typeset -gaU DDMBlueprintInvalid
typeset -gaU DDMBlueprintFailed
typeset -gaU DDMBlueprintInvalidReason
declare -a writeCSVFile
declare CSV_HEADER="System,ManagementID,Current OS,Last Update,Status,Blueprint Failed IDs,Blueprint Inactive IDs,Inactive Reason,Blueprint Invalid IDs,Invalid Reason,Software Update Failures"
#declare jamfGroup
#declare displayResults

check_for_sudo
check_logged_in_user
create_log_directory
check_swift_dialog_install

check_support_files
create_infobox_message

JAMF_check_connection
JAMF_check_credentials
JAMF_get_server
OVERLAY_ICON=$(JAMF_which_self_service)

# Show the welcome message and give the user some options
while true; do
    computer_id=''
    DDMOption=''
    DDMSoftwareUpdateActive=()
    DDMSoftwareUpdateFailures=()
    DDMBlueprintInvalid=()
    DDMBlueprintInactive=()
    DDMBlueprintSuccess=()
    DDMBlueprintFailed=()
    DDMBlueprintInvalidReason=()
    writeCSVFile=''

    welcomemsg
    # Check if the JAMF Pro server is using the new API or the classic API
    # If the client ID is longer than 30 characters, then it is using the new API
    [[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token  

    case "${DDMoption}" in
        *"Populate"* )    { welcomemsg_crossreference; JAMF_invalidate_token; };;
        *"Force Sync"* )  { welcomemsg_forcesync; JAMF_invalidate_token;} ;;
        *"View Single"* ) { welcomemsg_individual; JAMF_invalidate_token;};;
        *"Group"* )       { welcomemsg_group; JAMF_invalidate_token;};;
        *"Blueprint"* )   { welcomemsg_blueprint; JAMF_invalidate_token;};;
        *"quit"* )        { JAMF_invalidate_token; cleanup_and_exit 0; } ;;
        *)                { logMe "ERROR: Invalid option selected: $DDMoption"; cleanup_and_exit 1 ; } ;;
    esac
done
