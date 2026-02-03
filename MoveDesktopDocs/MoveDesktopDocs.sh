#!/bin/zsh
#
# MoveDesktopDocs.sh
#
# by: Scott Kendall
#
# Written: 02/02/2026
# Last updated: 02/02/2026
#
# Script Purpose: Move Desktop & Documents to /Users/Shared so other users can access files
#
# 1.0 - Initial
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

SCRIPT_NAME="MoveDesktopDocs"
SCRIPT_VERSION="1.0R"
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
MIN_SD_REQUIRED_VERSION="2.5.6"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

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

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Move Desktop & Documents"
SD_ICON_FILE="SF=folder.fill,color=accent"
OVERLAY_ICON="SF=arrow.up.and.down.and.arrow.left.and.right"

DEST_DIR="/Users/Shared/"

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

function welcomemsg ()
{
    message="This utility will move your current Desktop & Documents into a Shared folder that all the users on this Mac can have access to.<br><br>"
    message+="After the process is finished, your files will be located in ${DEST_DIR}${LOGGED_IN_USER}.  A shortcut link to those folders will be put on your desktop."

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
        --width 820
        --height 460
        --ignorednd
        --quitkey 0
        --moveable
        --button1text "OK"
        --button2text "Cancel"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ "$returnCode" == "2" ]] && {logMe "Cancel..."; cleanup_and_exit 0; }
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --message "**Problems copying files**<br><br>Please contact the TSD for assistance"
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

function create_dest_folder ()
{
    # PURPOSE: Create the destination folder if it doesn't exist
    local dest_folder=${DEST_DIR}${LOGGED_IN_USER}
    if [[ ! -e $dest_folder ]]; then
        logMe "$dest_folder doesn't exist...creating"
        mkdir -p "${dest_folder}" || {
            logMe "Failed to create destination directory: $dest_folder" >&2
            return 1
        }
    else
        logMe "$dest_folder exists...verifying permissions"
    fi
    chmod -R 777 $DEST_DIR

}

function move_folder_to_dest ()
{
    # PURPOSE: Move contents of folder to the destination and verify contents before removing originals
    local dest_folder="${DEST_DIR}${LOGGED_IN_USER}/${1}"

    logMe "Copying from $USER_DIR/$1 to $dest_folder ..."
    # First pass: copy preserving metadata
    # -a archive (preserve perms/mtime, recursive), -v verbose, -h human
    rsync -avh --progress "${USER_DIR}/${1}/" "${dest_folder}/" --log-file="${LOG_FILE}" #| tee "$LOG_FILE"
    rsync_status=${pipestatus[1]}

    if (( rsync_status != 0 )); then
        logMe "Initial rsync copy failed with status $rsync_status. Not deleting anything." >&2
        return $rsync_status
    fi

    logMe "Verifying copied data with checksum comparison ..."
    # Second pass: verify with checksums only (no changes)
    # -n dry-run, --checksum forces full-file checksum comparison.
    rsync -avhn --checksum "${USER_DIR}/${1}/" "$dest_folder/" > /dev/null
    verify_status=$?

    if (( verify_status != 0 )); then
        logMe "Verification failed (status $verify_status). Source will NOT be deleted." >&2
        return $verify_status
    fi

    logMe "Copy and verification successful. Deleting original documents from $USER_DIR ..."
    # Extra safety: only delete the contents, not the Documents directory itself
    rm -rf "${USER_DIR}/$1"/* 2>/dev/null

    logMe "Original contents removed from $USER_DIR."
    return 0
}

function make_alias_to_dest ()
{
    # PURPOSE: Make Alias to new folder onto users Desktop
    logMe "Making alias to ${DEST_DIR}${LOGGED_IN_USER}"
    ln -s "${DEST_DIR}${LOGGED_IN_USER}" "${USER_DIR}/Desktop/Desktop & Documents"
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
welcomemsg
create_dest_folder
move_folder_to_dest "Desktop"
[[ $? -ne 0 ]] && { display_failure_message
    cleanup_and_exit 1
    }

move_folder_to_dest "Documents"
[[ $? -ne 0 ]] && { display_failure_message
    cleanup_and_exit 1
    }
make_alias_to_dest
${SW_DIALOG} --message "The migration of Documents & Data to ${DEST_DIR}${LOGGED_IN_USER} was successful!" \
    --button1text "OK" \
    --mini \
    --icon $SD_ICON_FILE \
    --title $SD_WINDOW_TITLE
exit 0