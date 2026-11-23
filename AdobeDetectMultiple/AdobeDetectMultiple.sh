#!/bin/zsh
#
# AdobeMultiVersionDetect.sh
#
# by: Scott Kendall
#
# Written: 11/25/2025
# Last updated: 11/23/2026
#
# Script Purpose: Detect if there a multiple versions of Adobe apps on a users system and display a friendly reminder to clean up the old version
#
# 1.0 - Initial
# 1.1 - Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.1 - Improved Adobe application detection using native zsh globbing
#       Added detailed reporting of installed versions for duplicate applications
#       Improved SwiftDialog prerequisite validation and error handling
#       Improved Jamf policy validation for support files and Adobe Cleanup
#       Removed unused temporary-file and jq handling
#       Improved function variable scoping and exit-code propagation
#       Removed legacy Jamf script-parameter handling

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="AdobeMultiVersionDetect"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

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

SUPPORT_DIR="${SUPPORT_DIR%/}"

if [[ "${SD_BANNER_IMAGE#/SupportFiles/}" != "$SD_BANNER_IMAGE" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE#/}"
elif [[ "${SD_BANNER_IMAGE:0:1}" != "/" ]]; then
    SD_BANNER_IMAGE="${SUPPORT_DIR}/${SD_BANNER_IMAGE}"
fi

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Adobe Multiple Version Detector"
SD_ICON="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
OVERLAY_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
ADOBE_CLEANUP="AdobeCleanup"
HELPDESK_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

##################################################
#
# User Variables
#
#################################################

SD_FIRST_NAME="${(C)LOGGED_IN_USER%%.*}"

####################################################################################################
#
# Functions
#
####################################################################################################
function admin_user ()
{
    (( UID == 0 ))
}

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
    local LOG_DIR="${LOG_FILE%/*}"

    admin_user || return 0

    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {print -u2 "ERROR: Unable to create log directory: ${LOG_DIR}"; return 1; }
    fi
    chmod 755 "$LOG_DIR" || {print -u2 "ERROR: Unable to set permissions on: ${LOG_DIR}"; return 1; }
    # If the log file does not exist - create it and set the permissions
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE" || {print -u2 "ERROR: Unable to create log file: ${LOG_FILE}"; return 1;}
    fi

    chmod 640 "$LOG_FILE" || {print -u2 "ERROR: Unable to secure log file: ${LOG_FILE}"; return 1;}
    return 0
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
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | /usr/bin/tee -a "${LOG_FILE}" >&2
    else
        echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}"
    fi
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

    if ! SD_VERSION=$("$SW_DIALOG" --version 2>/dev/null); then
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
    local JAMF_exit=0

    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install SwiftDialog."
        return 1
    fi

    /usr/local/bin/jamf policy -event "$DIALOG_INSTALL_POLICY"
    JAMF_exit=$?

    if (( JAMF_exit != 0 )); then
        logMe "ERROR: Jamf policy failed while installing SwiftDialog. Exit code: ${JAMF_exit}"
        return 1
    fi

    if [[ ! -x "$SW_DIALOG" ]]; then
        logMe "ERROR: SwiftDialog remains unavailable after the installation attempt."
        return 1
    fi

    return 0
}

function check_support_files ()
{
    if [[ -f "$SD_BANNER_IMAGE" ]]; then
        logMe "Banner image found: ${SD_BANNER_IMAGE}"
    else
        logMe "Banner image not found: ${SD_BANNER_IMAGE}"

        if [[ -x /usr/local/bin/jamf ]]; then
            logMe "Running support-file installation policy."

            if ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"; then
                logMe "WARNING: Support-file installation policy failed."
            fi
        else
            logMe "WARNING: The local Jamf binary is unavailable. The support-file installation policy cannot be run."
        fi

        if [[ -f "$SD_BANNER_IMAGE" ]]; then
            logMe "Banner image successfully installed: ${SD_BANNER_IMAGE}"
        else
            logMe "WARNING: Banner image remains unavailable: ${SD_BANNER_IMAGE}"
        fi
    fi

    return 0
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

function normalize_adobe_name ()
{
    # PURPOSE: Remove the Adobe prefix and trailing numeric version/year
    # PARAMETERS: Adobe application directory name
    # RETURN: Normalized Adobe product name

    local app_name="${1#Adobe }"

    if [[ "$app_name" == *" "<-> ]]; then
        app_name="${app_name% *}"
    fi

    print -r -- "$app_name"
}

function detect_adobe_apps ()
{
    # PURPOSE: Scan for multiple versions of Adobe apps
    # PARAMETERS: None
    # RETURN: Formatted list of duplicate Adobe applications and installed versions
    # EXPECTED: None

    local app
    local app_name
    local normalized_name
    local count
    local name
    local duplicate_data=""

    local -a apps_array
    local -a app_names
    local -a results
    local -a installed_versions

    # Find top-level Adobe application directories
    apps_array=(/Applications/Adobe*(N/:t))

    for app in "${apps_array[@]}"; do

        # Exclude Adobe applications that shouldn't be checked
        case "$app" in
            "Adobe Creative Cloud"*)
                continue
                ;;
            "Adobe Acrobat"*)
                continue
                ;;
            "Adobe Experience Manager"*)
                continue
                ;;
            "Adobe Digital Editions"*)
                continue
                ;;
            "Adobe XD"*)
                continue
                ;;
        esac

        # Normalize application name for duplicate comparison
        normalized_name=$(normalize_adobe_name "$app")

        app_names+=("$normalized_name")
    done

    # Nothing found
    (( ${#app_names[@]} == 0 )) && return 0

    # Count occurrences of each normalized application name
    duplicate_data=$(printf '%s\n' "${app_names[@]}" | sort | uniq -c)

    while read -r count name; do

        [[ -z "$count" || -z "$name" ]] && continue
        if (( count > 1 )); then
            logMe "${name}: ${count} versions detected"
            results+=("* **${name}: ${count} versions detected**<br>")
            installed_versions=()

            # Find the original application names belonging to this product
            for app in "${apps_array[@]}"; do
                normalized_name=$(normalize_adobe_name "$app")
                if [[ "$normalized_name" == "$name" ]]; then
                    # Preserve the original application name for display
                    app_name="${app#Adobe }"
                    installed_versions+=("$app_name")
                    logMe "  - ${app_name}"
                fi
            done

            # Sort and display the actual installed versions
            while IFS= read -r app; do
                [[ -z "$app" ]] && continue
                results+=("  * ${app}<br>")
            done < <(printf '%s\n' "${installed_versions[@]}" | sort)
            results+=("<br>")
        fi
    done <<< "$duplicate_data"

    print -r -- "${(j::)results}"
}

function welcomemsg ()
{
    local message=""
    local returnCode=0
    local -a MainDialogBody

    message="Multiple versions of the following Adobe applications were detected:<br><br>"
    message+="${adobeDuplicates}"
    message+="Click **Cleanup** to launch the Adobe Removal Utility."

    MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --ontop
        --icon "${SD_ICON}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button."
        --width 920
        --height 480
        --infobuttontext "Get Help"
        --infobuttonaction "$HELPDESK_URL"
        --ignorednd
        --quitkey 0
        --button1text "Cleanup"
        --button2text "OK"
    )

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
    returnCode=$?

    case "${returnCode}" in
        0)
            logMe "User clicked Cleanup"

            if [[ ! -x /usr/local/bin/jamf ]]; then
                logMe "ERROR: Jamf binary not found. Unable to launch Adobe Cleanup."
                return 1
            fi

            if ! /usr/local/bin/jamf policy -event "${ADOBE_CLEANUP}"; then
                logMe "ERROR: Adobe Cleanup policy failed."
                return 1
            fi

            logMe "Adobe Cleanup policy completed successfully."
            ;;
        2)
            logMe "User dismissed the message"
            ;;
        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${returnCode}"
            return 1
            ;;
    esac
    return 0
}

####################################################################################################
#
# Main Script
#
####################################################################################################

autoload 'is-at-least'

typeset adobeDuplicates=""

if ! create_log_directory; then
    print -u2 -r -- "ERROR: Unable to initialize logging."
    exit 1
fi

adobeDuplicates=$(detect_adobe_apps)

if [[ -z "${adobeDuplicates}" ]]; then
    logMe "No duplicate Adobe applications detected"
    exit 0
fi

if ! check_swift_dialog_install; then
    logMe "ERROR: Unable to continue without a supported version of SwiftDialog."
    exit 1
fi

check_support_files

create_infobox_message

if ! welcomemsg; then
    logMe "ERROR: Adobe cleanup workflow did not complete successfully."
    exit 1
fi

exit 0