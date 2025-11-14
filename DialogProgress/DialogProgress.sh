#!/bin/zsh
#set -x
#!/bin/zsh
#
# DialogProgress.sh
#
# by: Scott Kendall
#
# Written: 11/02/2023
# Last updated: 11/02/2025
#
# Script Purpose: This script will pop up a mini dialog with progress of a jamf pro policy
# Extracted from Bart Reardon's script: 
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="DialogProgress"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

# Make some temp files for this app

DIALOG_CMD_FILE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
/bin/chmod 666 $DIALOG_CMD_FILE

# App specific variables

jamfPID=""
jamf_log="/var/log/jamf.log"
count=0


###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################


# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
fi
# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Run Policy"
OVERLAY_ICON="SF=square.and.arrow.down.fill,bgcolor=none,color=auto,weight=bold"

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
window_title="${4:-"${SD_WINDOW_TITLE}"}"         # Window Title
policyTrigger="${5}"                            # NAME of policy to run
icon="${6}"                                     # Can be app or URL

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

function dialogcmd()
{
    echo "${1}" >> "${DIALOG_CMD_FILE}"
    sleep 0.1
}

function displaymsg ()
{
	MainDialogBody=(
        --message "Please wait while ${window_title} is installed …"
        --title "Installing ${window_title}"
        --mini
        --moveable
        --progress
        --icon "${icon}"
        --overlayicon "${OVERLAY_ICON}"
		--commandfile "${DIALOG_CMD_FILE}"
        --position bottomright
    )

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null &

    logMe "main dialog running in the background with PID $PID"
}

function runPolicy() 
{
    logMe "Running policy ${policyTrigger}"
    /usr/local/bin/jamf policy -event ${policyTrigger} &
}

function dialogError()
{
	logMe "launching error dialog"
    errormsg="### Error\n\nSomething went wrong. Please contact IT support and report the following error message:\n\n${1}"
    MainDialogBody=(
        --message "${errormsg}"
        --title "JAMF Policy Error"
        --ontop
        --icon "${icon}"
        --overlayicon caution
    )

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null &
    logMe "error dialog running in the background with PID $PID"
}

function quitScript() 
{
	logMe "quitscript was called"
    dialogcmd "quit: "
    sleep 1
    logMe "Exiting"
    # brutal hack - need to find a better way
    killall tail
    if [[ -e ${DIALOG_CMD_FILE} ]]; then
        logMe "removing ${DIALOG_CMD_FILE}"
		rm "${DIALOG_CMD_FILE}"
    fi
    exit 0
}

function getPolicyPID() 
{
    datestamp=$(date "+%a %b %d %H:%M")
    while [[ ${jamfPID} == "" ]]; do
        jamfPID=$(grep "${datestamp}" "${jamf_log}" | grep "Checking for policies triggered by \"${policyTrigger}\"" | tail -n1 | awk -F"[][]" '{print $2}')
        sleep 0.1
    done
    logMe "JAMF PID for this policy run is ${jamfPID}"
}

function readJAMFLog() 
{
    logMe "Starting jamf log read"    
    if [[ ! -z "${jamfPID}" ]]; then
        logMe "Processing jamf pro log for PID ${jamfPID}"
        while read -r line; do    
            statusline=$(echo "${line}" | grep "${jamfPID}")
            case "${statusline}" in
                *Success*)
                    logMe "Success"
                    dialogcmd "progresstext: Complete"
                    dialogcmd "progress: complete"
                    sleep 1
                    dialogcmd "quit:"
                    logMe "Success Break"
                    #break
                    quitScript
                ;;
                *failed*)
                    logMe "Failed"
                    dialogcmd "progresstext: Policy Failed"
                    dialogcmd "progress: complete"
                    sleep 1
                    dialogcmd "quit:"
                    dialogError "${statusline}"
                    logMe "Error Break"
                    #break
                    quitScript
                ;;
                *)
                    progresstext=$(echo "${statusline}" | awk -F "]: " '{print $NF}')
                    logMe "Reading policy entry : ${progresstext}"
                    dialogcmd "progresstext: ${progresstext}"
                    dialogcmd "progress: increment"
                ;;
            esac
            ((count++))
            if [[ ${count} -gt 10 ]]; then
                logMe "Hit maxcount"
                dialogcmd "progress: complete"
                sleep 0.5
                #break
                quitscript
            fi
        done < <(tail -f -n1 $jamf_log) 
    else
        logMe "Something went wrong"
        echo "ok, something weird happened. We should have a PID but we don't."
    fi
    logMe "End while loop"
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


if [[ -z $5 ]]; then
    echo "Usage: $0 <policy name> <policy id> [<policy icon>]"
    quitScript
fi

if [[ -z $6 ]]; then
    icon=$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path )
fi

# In case we want the start of the log format including the hour, e.g. "Mon Aug 08 11"
# datepart=$(date +"%a %b %d %H")

logMe "***** Start *****"
logMe "Running displaymsg function"
displaymsg
logMe "Launching Policy in the background" 
runPolicy
sleep 1
logMe "Getting Policy ID"
getPolicyPID
logMe "Policy ID is ${jamfPID}"
logMe "Processing Jamf Log"
readJAMFLog
logMe "All Done we think"
logMe "***** End *****"
quitScript
