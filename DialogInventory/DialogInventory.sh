#!/bin/zsh
#
# DialogInventory
#
# by: Scott Kendall
#
# Written: 06/03/2025
# Last updated: 06/03/2025
#
# Script Purpose: Perform the JAMF Recon command with Swift Dialog feedback
#
# 1.0 - Initial

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

SD_WINDOW_TITLE="Update Inventory"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"
OVERLAY_ICON="/Applications/Self Service.app"
TMP_LOG_FILE=$(mktemp /var/tmp/DialogInventory.XXXXX)
DIALOG_CMD_FILE=$(mktemp /var/tmp/DialogInventory.XXXXX)
JSON_DIALOG_BLOB=$(mktemp /var/tmp/DialogInventory.XXXXX)
chmod 655 $DIALOG_CMD_FILE
chmod 655 $JSON_DIALOG_BLOB

####################################################################################################
#
# Functions
#
####################################################################################################

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None

    if [[ ! -x "${SW_DIALOG}" ]]; then
        install_swift_dialog
        SD_VERSION=$( ${SW_DIALOG} --version)        
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        install_swift_dialog
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
     
 
        "destroy" )
     
            # Kill the progress bar and clean up
            /bin/echo "quit:" >> "${DIALOG_CMD_FILE}"
            ;;
 
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            /bin/echo "progresstext: ${2}" >> "${DIALOG_CMD_FILE}"
            ;;
  
    esac
}

function cleanup_and_exit ()
{
	[[ -f ${TMP_LOG_FILE} ]] && /bin/rm -rf ${TMP_LOG_FILE}
	[[ -f ${JSON_DIALOG_BLOB} ]] && /bin/rm -rf ${JSON_DIALOG_BLOB}
    [[ -f ${DIALOG_CMD_FILE} ]] && /bin/rm -rf ${DIALOG_CMD_FILE}
	exit 0
}

function welcomemsg ()
{
    echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "iconsize" : "100",
        "message" : "Performing the JAMF inventory update process...",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "messageposition" : "true",
        "progress" : "true",
        "moveable" : "true",
        "mini" : "true",
        "position" : "topright",
        "button1text" : "none",
        "commandfile" : "'${DIALOG_CMD_FILE}'"
        }' > "${JSON_DIALOG_BLOB}"

    ${SW_DIALOG} --jsonfile ${JSON_DIALOG_BLOB} &
}

function update_inventory ()
{
    sudo jamf recon
    wait
} >> "${TMP_LOG_FILE}" 2>&1

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

check_swift_dialog_install
welcomemsg

# Start update inventory
update_inventory &
update_pid=$!

# While the process is still running, display the log entries
while kill -0 "$update_pid" 2> /dev/null; do
    lastLogEntry=$(tail -n 1 "${TMP_LOG_FILE}")
    update_display_list "progress" $lastLogEntry
    sleep 0.5
done

update_display_list "progress" "Inventory Updated, exiting ..."
sleep 2
update_display_list "destroy"
cleanup_and_exit