#!/bin/zsh
#
# RemovePrinters
#
# by: Scott Kendall
#
# Written: 03/18/2026
# Last updated: 03/18/2026  
#
# Script Purpose: Remove currently installed printers
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="RemovePrinters"
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
MIN_SD_REQUIRED_VERSION="2.5.0"
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
    SPACING=5 #5 spaces to accommodate for icon offset
fi
BANNER_TEXT_PADDING="${(j::)${(l:$SPACING:: :)}}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Remove Printers"
SD_ICON_FILE="/System/Library/CoreServices/AddPrinter.app"
OVERLAY_ICON="SF=trash.fill,color=blakc"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

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
        "overlayicon" : "'${SD_OVERLAY_ICON}'",
        "ontop" : "true",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1",
        "helpmessage" : "Please choose the printers you wish to remove from the dropdown menu.<br>For assistance, please contact the TSD.",
        "button1text" : "OK",
        "button2text" : "Cancel",
        "moveable" : "true",
        "height" : "480",
        "width" : "900",
        "json" : "true", 
        "ignorednd" : "true",
        "quitkey" : "0",'
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - type of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    # EXPECTED: None

    printerlist=""
    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_listitem_message_body "" "" "" "" "" "first"

    for item in "${app_list[@]}"; do
        [[ -z "$item" ]] && continue
        icon_path=$(get_printer_icon "${item}") #Get the printer icon from the PPD file
        results=$(lpstat -p | grep "$item" | grep "enabled" 2>/dev/null) #Check to see if the printer is enabled or not
        [[ ! -z "$results" ]] && {lpstat1="success"; lpstat2="Idle"; }|| {lpstat1="error"; lpstat2="Paused"; }
        create_listitem_message_body "$item" "" "$icon_path" "$lpstat2" "$lpstat1" ""
        printerlist+='"'$item'",'
    done
    echo "]," >> "${JSON_DIALOG_BLOB}"
    create_dropdown_message_body "Select Printers to Remove:" "${printerlist%,}" "first"
    echo "]}" >> "${JSON_DIALOG_BLOB}"
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

    [[ "$6:l" == "first" ]] && line+='"listitem" : ['
    [[ ! -z $1 ]] && [[ ! -z $2 ]] && line+='{"title" : "'$1'", "subtitle" : "'$2'", "icon" : "'$3'", "status" : "'$5'", "statustext" : "'$4'"},'
    [[ ! -z $1 ]] && [[ -z $2 ]] && line+='{"title" : "'$1'", "icon" : "'$3'", "status" : "'$5'", "statustext" : "'$4'"},'
    [[ "$6:l" == "last" ]] && line+=']}'
    echo $line >> ${JSON_DIALOG_BLOB}
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
            DIALOG_RESULTS=$($SW_DIALOG --jsonfile "${JSON_DIALOG_BLOB}" --commandfile "${DIALOG_COMMAND_FILE}") #&
            DIALOG_PROCESS=$! #Grab the process ID of the background process
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
            /bin/echo "listitem: title: ${3}, status: ${5}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"

            /bin/sleep .5
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: ${5}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
    esac
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
####################################################################################################
#
# Script Specific Functions
#
####################################################################################################

function read_in_printers ()
{
    # PURPOSE: Read in the currently installed printers and create an array of them
    # RETURN: None
    # EXPECTED: None
    # PARMS: None

    app_list=()
    while IFS= read -r line; do
        app_list+=("$line")
    done < <(lpstat -p | awk '{print $2}')
}

function get_printer_icon ()
{
    # PURPOSE: Get the printer icon from the PPD file for a given printer
    # RETURN: None
    # EXPECTED: None
    # PARMS: $1 - printer name

    ppd_file="/private/etc/cups/ppd/$1.ppd"
    icon_path=$(grep "*APPrinterIconPath:" "$ppd_file" | cut -d '"' -f 2)
    [[ -z "$icon_path" ]] && icon_path="/System/Library/CoreServices/AddPrinter.app"
    echo "$icon_path"
}

function choose_printers ()
{
    # PURPOSE: Display the printer selection dialog and return the selected printers
    # RETURN: None
    # EXPECTED: None
    # PARMS: None

    local selectedPrinter=""
    create_listitem_list "This utility will allow you to remove currently installed printers. Please select the printer(s) you wish to remove and click 'OK'."
    DIALOG_RESULTS=$($SW_DIALOG --jsonfile "${JSON_DIALOG_BLOB}" --commandfile "${DIALOG_COMMAND_FILE}")
    if [[ "$?" == "0" ]]; then
        selectedPrinter=$(echo $DIALOG_RESULTS | plutil -extract "SelectedOption" 'raw' -)
    fi
    echo "${selectedPrinter}" 
}

function confirm_printer_removal ()
{
    # PURPOSE: Display a confirmation dialog to the user to confirm printer removal
    # RETURN: None
    # EXPECTED: None
    # PARMS: $1 - Printer name
    
    icon_path=$(get_printer_icon "${1}") #Get the printer icon from the PPD file
	MainDialogBody=(
        --message "Please confirm that you want to remove the printer '$1'."
        --titlefont shadow=1
        --ontop
        --icon "${icon_path}"
        --overlayicon warning
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --button1text "Confirm"
        --button2text "Cancel"
    )

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    [[ "$?" == "0" ]] && return 0 || return 1
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

local -a app_list

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
read_in_printers
selectedPrinter=$(choose_printers)
[[ -z "$selectedPrinter" ]] && {logMe "No printer selected...exiting"; cleanup_and_exit 0; }
if confirm_printer_removal "$selectedPrinter"; then
    logMe "User confirmed printer removal...removing printer '$selectedPrinter'"
    lpadmin -x "$selectedPrinter"
    [[ $? -eq 0 ]] && results="Successfully removed" || results="Failed to remove"
    logMe "${results} printer '$selectedPrinter'"
else
    logMe "User canceled printer removal...exiting"
fi
cleanup_and_exit 0
