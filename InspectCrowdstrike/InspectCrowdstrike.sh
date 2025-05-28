#!/bin/zsh
#
# by: Scott Kendall
#
# Written: 01/24/2025
# Last updated: 05/28/2025
#
# Script Purpose: Display information about Crowdstrike sensor
#
# 1.0 - Initial code
# 1.1 - Code cleanup to be more consistant with all apps
#
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
SD_WINDOW_TITLE=$BANNER_TEXT_PADDING"Crowdstrike Inspector"
SD_WINDOW_ICON="${ICON_FILES}/GenericNetworkIcon.icns"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/CrowdstrikeInspector.log"
SD_ICON_FILE="/Applications/Falcon.app"
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/FalconInspector.XXXX)
/bin/chmod 666 "${DIALOG_COMMAND_FILE}"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
FALCON_PATH="/Applications/Falcon.app/Contents/Resources/falconctl"
TIMER_IN_SECONDS=2

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
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

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

function create_welcome_msg ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --icon "${SD_ICON_FILE}" --iconsize 100
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  This script analyzes the installation of CrowdStrike Falcon then reports the findings in this window.  \n\nPlease wait …"
        --iconsize 135
        --messagefont name=Arial,size=17
        --button1disabled
        --progress
        --progresstext "$welcomeProgressText"
        --button1text "Wait"
        --height 400
        --width 650
        --moveable
        --commandfile "$DIALOG_COMMAND_FILE"
        )
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
    # $1 - Action to be done ("Create", "Add", "Change", "Clear", "Info", "Show", "Done", "Update" "message")
    # ${2} - Affected item (2nd field in JSON Blob listitem entry)
    # ${3} - Icon status "wait, success, fail, error, pending or progress"
    # ${4} - Status Text
    # ${5} - Progress Text (shown below progress bar)
    # ${6} - Progress amount
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
            if [[ ! -z $2 ]]; then 
                /bin/echo "listitem: title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            fi
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

        "message" )
            # Change the displayed message
            /bin/echo "message: ${4}" >> "${DIALOG_COMMAND_FILE}"
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

function check_falcon_install ()
{

    if [[ -e ${FALCON_PATH} ]]; then
        logMe "CrowdStrike Falcon installed; proceeding …"
    else
        logMe "CrowdStrike Falcon not installed; exiting"
        cleanup_and_exit
    fi
}

function get_falcon_stats ()
{
    logMe "Create Welcome Dialog …"

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null & sleep .3


    update_display_list "progress" "" "" "" "Inspecting..." "5"

    sleep "${TIMER_IN_SECONDS}"

    SECONDS="0"

    # CrowdStrike Falcon Inspection: Installation

    update_display_list "progress" "" "" "" "Installation..." "18"

    # CrowdStrike Falcon Inspection: Version

    falconVersion=$( ${FALCON_PATH} stats | awk '/version/ {print $2}' )
    update_display_list "progresss" "" "" "" "Version..." "36" 

    # CrowdStrike Falcon Inspection: System Extension List

    systemExtensionTest=$( systemextensionsctl list | awk '/com.crowdstrike.falcon.Agent/ {print $7,$8}' | wc -l )
    [[ "${systemExtensionTest}" -gt 0 ]] && systemExtensionStatus="Loaded" || systemExtensionStatus="Likely **not** running"
    update_display_list "progress" "" "" "" "System Extension..." "54" 

    # CrowdStrike Falcon Inspection: Agent ID

    falconAgentID=$( ${FALCON_PATH} stats | awk '/agentID/ {print $2}' | tr '[:upper:]' '[:lower:]' | sed 's/\-//g' )
    update_display_list "progress" "" "" "" "Agent ID..." "72"

    # CrowdStrike Falcon Inspection: Heartbeats

    falconHeartbeats6=$( ${FALCON_PATH} stats | awk '/SensorHeartbeatMacV4/ {print $4,$5,$6,$7,$8}' | sed 's/ /\ | /g' )
    update_display_list "progress" "" "" "" "Heartbeats..." "90"

    # Capture results to log
    logMe "Results for ${loggedInUser}"
    logMe "Installation Status: Installed"
    logMe "Version: ${falconVersion}"
    logMe "System Extension: ${systemExtensionStatus}"
    logMe "Agent ID: ${falconAgentID}"
    logMe "Heartbeats: ${falconHeartbeats6}"
    logMe "Elapsed Time: $(printf '%dh:%dm:%ds\n' $((SECONDS/3600)) $((SECONDS%3600/60)) $((SECONDS%60)))"

    # Display results to user
    timestamp="$( date '+%Y-%m-%d-%H:%M:%S' )"
    update_display_list "progress" "" "" "" "Complete!" "100"
    update_display_list "message" "" "" "message: **Results for ${LOGGED_IN_USER} on ${timestamp}**<br><br>**Installation Status:** Installed<br>**Version:** ${falconVersion}<br>**System Extension:** ${systemExtensionStatus}<br>**Agent ID:** ${falconAgentID}<br>**Heartbeats:** ${falconHeartbeats6}"
    sleep "${TIMER_IN_SECONDS}"
    update_display_list "buttonchange" "Done"
    update_display_list "buttonenable"
    #updateWelcomeDialog "progresstext: Elapsed Time: $(printf '%dh:%dm:%ds\n' $((SECONDS/3600)) $((SECONDS%3600/60)) $((SECONDS%60)))"

}

####################################################################################################
#
# Main Script
#
####################################################################################################

autoload 'is-at-least'

check_swift_dialog_install
check_support_files
check_falcon_install
create_welcome_msg
get_falcon_stats
exit 0
