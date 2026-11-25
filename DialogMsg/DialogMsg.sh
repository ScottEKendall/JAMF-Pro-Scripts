#!/bin/zsh
#
# DialogMsg
# 
# Written by: Scott Kendall
#
# Created Date: 01/27/2025
# Last modified: 11/25/2026
#
# Script Purpose: Display a generic SWifDialog notification to Jamf users.  Pass in variables to customize display
#
# 1.0 - Initial script
# 1.1 - Code cleanup to be more consistent with all apps
# 1.2 - the JAMF_LOGGED_IN_USER will default to LOGGED_IN_USER if there is no name present
#      - Added -ignorednd to make sure that the message is displayed regardless of focus setting
#      - Will display the inbox items if you can the function first
#      - Minimum version of SwiftDialog is now 2.5.0
# 1.3 - Changed variable declarations around for better readability
# 1.4 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 1.5 - Fixed typos
#       Optimized "Common" section for better performance
#       Fixed Swift Dialog not reporting properly
# 2.0 - Add functions to check for a logged in user and that the system is awake (message will only display if system is awake and a user is logged in)
#       Added more logged in sleep status, message button status
# 2.1 - Fixed window layout for Tahoe & SD v3.0
# 2.2 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
# 2.3 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.4 - Improved script workflow and error handling
#       Added validation for logged-in user context
#       Improved SwiftDialog installation and version validation
#       Improved support-file installation handling
#       Added multilingual message support based on the user's preferred language
#       Added default-language fallback when no preferred-language match is found
#       Improved handling of Jamf parameters and optional display images
#
# Expected Parameters: 
# #4 - Title
# #5 - Full formatted message to display
# #6 - Alternate language to display (formatted as <2 Digit Lang code> | <message>)
# #7 - Button1 Text
# #8 - Image to display
# #9 - JAMF policy to load image if it doesn't exist
# #10 - Notification icon name
# #11 - Timer (in seconds) to wait until dismissal

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="DialogMsg"
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
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

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
echo "Setting Default values"
SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles 2>/dev/null) || SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage 2>/dev/null) || SD_BANNER_IMAGE="GE_SD_BannerImage.png"
BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding 2>/dev/null) || BANNER_TEXT_PADDING=10
BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle 2>/dev/null) || BANNER_SUBTITLE=""
BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor 2>/dev/null) || BANNER_TEXT_COLOR="white"

[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_IMAGE_TO_DISPLAY="${SUPPORT_DIR}/SupportFiles/PasswordChange.png"
SD_OVERLAY_ICON="computer"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

SD_DEFAULT_LANGUAGE="EN" # Change your default language here!
DISPLAY_MESSAGE=""

##################################################
#
# Passed in variables
# 
#################################################

JAMF_PARAMETER_USER="$3"
SD_WINDOW_TITLE="$4"
SD_WELCOME_MSG="${5:-"Information Message"}"
SD_WELCOME_MSG_ALT="${6:-""}"
SD_BUTTON1_PROMPT="${7:-"OK"}"
SD_IMAGE_TO_DISPLAY="${8:-""}"
SD_IMAGE_POLICY="${9:-""}"
SD_ICON_PRIMARY="${10:-"${ICON_FILES}AlertNoteIcon.icns"}"
SD_TIMER="${11-120}"


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
    local SD_VERSION

    logMe "Ensuring that SwiftDialog is installed..."

    if [[ ! -x "$SW_DIALOG" ]]; then
        logMe "SwiftDialog is missing. Attempting installation."

        if ! install_swift_dialog || [[ ! -x "$SW_DIALOG" ]]; then
            logMe "ERROR: SwiftDialog installation failed." >&2
            return 1
        fi
    fi

    if ! SD_VERSION=$("$SW_DIALOG" --version ); then
        logMe "ERROR: Unable to determine SwiftDialog version." >&2
        return 1
    fi

    if [[ -z "$SD_VERSION" ]]; then
        logMe "ERROR: SwiftDialog returned an empty version." >&2
        return 1
    fi

    if ! is-at-least "$MIN_SD_REQUIRED_VERSION" "$SD_VERSION"; then
        logMe "SwiftDialog ${SD_VERSION} is outdated. Attempting update."

        if ! install_swift_dialog; then
            logMe "ERROR: SwiftDialog update failed." >&2
            return 1
        fi

        if ! SD_VERSION=$("$SW_DIALOG" --version 2>/dev/null); then
            logMe "ERROR: Unable to read SwiftDialog version after update." >&2
            return 1
        fi

        if ! is-at-least "$MIN_SD_REQUIRED_VERSION" "$SD_VERSION"; then
            logMe "ERROR: SwiftDialog remains below the required version." >&2
            return 1
        fi
    fi

    logMe "SwiftDialog version ${SD_VERSION} is available."
    return 0
}

function install_swift_dialog ()
{
    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install SwiftDialog."
        return 1
    fi

    /usr/local/bin/jamf policy -event "${DIALOG_INSTALL_POLICY}"
    local jamf_exit=$?

    if (( jamf_exit != 0 )); then
        logMe "ERROR: Jamf policy failed while installing SwiftDialog. Exit code: ${jamf_exit}"
        return 1
    fi

    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "ERROR: SwiftDialog is still missing after install attempt."
        return 1
    fi

    return 0
}

function check_support_files ()
{
    if [[ ! -e "$SD_BANNER_IMAGE" ]] && [[ "$SD_BANNER_IMAGE" =~ \.(jpg|png|heic)$ ]]; then
        if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"
        then
            logMe "WARNING: Support-file installation failed." >&2
        fi
    fi
    if [[ -n "$SD_IMAGE_TO_DISPLAY" && ! -e "$SD_IMAGE_TO_DISPLAY" ]]; then
        if [[ -n "$SD_IMAGE_POLICY" ]]; then
            logMe "Image missing. Attempting installation with event: ${SD_IMAGE_POLICY}"

            if ! /usr/local/bin/jamf policy -event "$SD_IMAGE_POLICY"; then
                logMe "WARNING: Image installation policy failed." >&2
            fi
        else
            logMe "WARNING: Image is missing and no installation policy was supplied."
        fi
    fi
    return 0
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"
    exit "$exit_code"
}

function initialize_user_context ()
{
    LOGGED_IN_USER=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ {print $3}')

    if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "loginwindow" ]]; then
        printf '%s\n' "INFO: No interactive user is logged in."
        return 1
    fi

    if ! USER_UID=$(id -u "$LOGGED_IN_USER"); then
        printf '%s\n' "ERROR: Unable to resolve UID for ${LOGGED_IN_USER}." >&2
        return 1
    fi

    if ! USER_DIR=$(dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory | awk '{ print $2 }'); then
        printf '%s\n' "ERROR: Unable to resolve home directory for ${LOGGED_IN_USER}." >&2
        return 1
    fi

    if [[ -z "$USER_DIR" || ! -d "$USER_DIR" ]]; then
        printf '%s\n' "ERROR: Invalid home directory for ${LOGGED_IN_USER}: ${USER_DIR}" >&2
        return 1
    fi

    JAMF_LOGGED_IN_USER="${JAMF_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${JAMF_LOGGED_IN_USER%%.*}}"
    return 0
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

function display_msg ()
{
    local return_code
    local -a MainDialogBody
    MainDialogBody=(
        --message "${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  ${DISPLAY_MESSAGE}"
        --ontop
        --icon "${SD_ICON_PRIMARY}"
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=$BANNER_TEXT_PADDING"
        --overlayicon "${SD_OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --ignorednd
        --moveable
        --helpmsg ""
        --quitkey 0
        --timer "${SD_TIMER}"
        --button1text "${SD_BUTTON1_PROMPT}"
        )
        [[ -n "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

    # Show the dialog screen and allow the user to choose

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    return_code=$?

    [[ "$return_code" == 4 ]] && logMe "Timer Expired"
    [[ "$return_code" == 0 ]] && logMe "User Clicked $SD_BUTTON1_PROMPT"

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

function check_language_support ()
{
    local preferred_language="${LANG[1,2]:u}"
    local entry
    local lang_code
    local message
    local default_message=""
    local first_message=""
    local -a language_array

    # Preserve each configured message as a single array element
    language_array=("$SD_WELCOME_MSG")

    [[ -n "$SD_WELCOME_MSG_ALT" ]] && language_array+=("$SD_WELCOME_MSG_ALT")

    for entry in "${language_array[@]}"; do

        # If an entry does not contain a language code,
        # preserve it as a possible fallback
        if [[ "$entry" != *"|"* ]]; then
            [[ -z "$first_message" ]] && first_message="$entry"
            continue
        fi

        # Split only on the first "|" character
        lang_code="${entry%%|*}"
        message="${entry#*|}"

        # Normalize the language code
        lang_code="${lang_code//[[:space:]]/}"
        lang_code="${lang_code:u}"

        # Remove leading whitespace from the message
        while [[ "$message" == [[:space:]]* ]]; do
            message="${message#?}"
        done

        # Save the first valid message as a final fallback
        [[ -z "$first_message" ]] && first_message="$message"

        # Save the configured default-language message
        if [[ "$lang_code" == "${SD_DEFAULT_LANGUAGE:u}" ]]; then
            default_message="$message"
        fi

        # Return the preferred-language message
        if [[ "$lang_code" == "$preferred_language" ]]; then
            print -r -- "$message"
            return 0
        fi
    done

    # No preferred-language match, use configured default
    if [[ -n "$default_message" ]]; then
        print -r -- "$default_message"
        return 0
    fi

    # Final fallback
    print -r -- "$first_message"
    return 0
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

initialize_user_context || cleanup_and_exit 0
create_log_directory || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1

# Check and make sure there is a user logged in and system is awake

check_display_sleep || cleanup_and_exit 0

create_infobox_message
DISPLAY_MESSAGE=$(check_language_support)
logMe "Displaying Message"
display_msg
exit 0