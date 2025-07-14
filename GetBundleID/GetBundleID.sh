#!/bin/zsh
#
# GetBundleID
#
# by: Scott Kendall
#
# Written: 07/11/2025
# Last updated: 07/11/2025
#
# Script Purpose: Exract the bundle ID of all of the apps found in a given directory
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
JSON_DIALOG_BLOB=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/ExtractBundleIDs.XXXXX)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Extract BundleID"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/ExtractBundleID"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/System/Applications/App Store.app"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

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
    message="This script is designed to display the BundleIDs of the applications found in a selected directory, with an option to export a list of found applications and their associated BundleIDs.<br><br>Please enter a location to get started."

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --textfield "Select a file location to scan",fileselect,filetype=folder,required,name=fileLocation
        --checkbox "Export list",checked,name=ExportList
        --height 500
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
    [[ $returnCode = 2 ]] && cleanup_and_exit

    # Examples of how to extra data from returned string
    fileLocation=$(echo $temp | plutil -extract "fileLocation" 'raw' -)
    exportList=$(echo $temp | plutil -extract "ExportList" 'raw' -)

}

function build_file_list_array ()
{
	declare -a tmp_array
	declare saved_IFS=$IFS

	IFS=$'\n'
	FILES_LIST=( $(/usr/bin/find $fileLocation/* -maxdepth 0 -type d -iname '*.app' ! -ipath '*Contents*' | /usr/bin/sort -f | /usr/bin/awk -F '/' '{ print $3 }' | /usr/bin/awk -F '.app' '{ print $1 }')) 2> /dev/null
	${IFS+':'} unset saved_IFS

	# remove the items from array that are in the Managed apps array

	for i in "${MANAGED_APPS[@]}"; do FILES_LIST=("${FILES_LIST[@]/$i}") ; done

	# Add only the non-empty items into the tmp_array

	for i in "${FILES_LIST[@]}"; do [[ -n "$i" ]] && tmp_array+=("${i}") ; done

	# copy the newly created array back into the working array

	FILES_LIST=(${tmp_array[@]})
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
        "width" : "1100",
        "height" : "800",
        "json" : "true", 
        "quitkey" : "0",
        "messageposition" : "top",'
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
            eval "${JSON_DIALOG_BLOB}"
            ;;
     
        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            /bin/echo "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonenable" )

            # Enable button 1
            /bin/echo "button1: enable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonchange" )

            # change text of button 1
            /bin/echo "button1text: ${2}" >> "${DIALOG_COMMAND_FILE}"
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
  
    esac
}

function construct_display_list ()
{

	# Construct the Swift Dialog display list based on files that can be deleted

	if [[ ${#FILES_LIST[@]} -ne 0 ]]; then

		# Construct the fils(s) list
        construct_dialog_header_settings "Below are the discovered apps and their BundleIDs" > "${JSON_DIALOG_BLOB}"
        create_listitem_message_body "" "" "" "" "first"
		for i in "${FILES_LIST[@]}"; do
            create_listitem_message_body "${i}" "${fileLocation}/${i}.app" "Working" "working"
		done
        create_listitem_message_body "" "" "" "" "last"
        /bin/chmod 644 "${JSON_DIALOG_BLOB}"
	fi

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

function get_bundleID ()
{
    # PURPOSE: Extract the BundleIDs from each application in the array
    # PARMS None
    # EXPECTED: FILES_LIST to be filled with list of applications
    # RETURN: None
    
    logMe "Extracting bundleIDs from $fileLocation"
    for i in "${FILES_LIST[@]}"; do
        bundleID=$(defaults read "${fileLocation}/${i}.app/Contents/Info.plist" CFBundleIdentifier)
        update_display_list "change" "${i}" "" "$bundleID"
    done
}

function export_bundleID_list ()
{
    # PURPOSE: Export the BundleIDs from each application in the array to a file on the desktop
    # PARMS None
    # EXPECTED: FILES_LIST to be filled with list of applications
    # RETURN: None

    touch "${USER_DIR}/Desktop/BundleIDlist.txt"
    for i in "${FILES_LIST[@]}"; do
        bundleID=$(defaults read "${fileLocation}/${i}.app/Contents/Info.plist" CFBundleIdentifier)
        echo ${fileLocation}/${i}.app : $bundleID >> "${USER_DIR}/Desktop/BundleIDlist.txt"
    done
    logMe "Export File list to: ${USER_DIR}/Desktop/BundleIDlist.txt"

}

####################################################################################################
#
# Main Script
#
####################################################################################################
declare fileLocation
declare exportList
typeset -a FILES_LIST

autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message
welcomemsg
build_file_list_array
if [[ ${#FILES_LIST[@]} -ne 0 ]];then
    construct_display_list
    ${SW_DIALOG} --jsonfile ${JSON_DIALOG_BLOB} --commandfile "${DIALOG_COMMAND_FILE}" & sleep .1
    get_bundleID
    [[ $exportList = "true" ]] && update_display_list "buttonchange" "Export"
    update_display_list "buttonenable"
    [[ $exportList = "true" ]] && export_bundleID_list 
fi
cleanup_and_exit