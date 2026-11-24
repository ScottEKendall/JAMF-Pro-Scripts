#!/bin/zsh

#
# ArchitectureScan
#
# by: Scott Kendall
#
# Written: 03/05/2026
# Last updated: 11/24/2026
#
# Script Purpose:
# Scan a user-defined list of applications to determine their architecture type.
#
# 1.0 - Initial
# 1.1 - Changed the -trigger keyword to -event for Jamf policy commands
# 1.2 - Added check for the lipo command
# 1.3 - Added file command fallback
#       Added executable lookup fallback
#       Added shell script recognition
#       Added option to hide .app extensions
#       Added WebApp detection
#       Added scans inside the logged-in user's Applications directory
# 1.4 - Reworked scan logic using zsh features
# 1.5 - Added option to show the application path
# 1.6 - Changed the Rosetta deprecation reference to macOS 27
# 2.0 - Updated SwiftDialog requirement to 3.1.0
#       Added configurable banner subtitle, color, and padding
# 2.1 - Unified application discovery and scan arrays
#       Rebuilt the SwiftDialog JSON using jq
#       Separated Intel and Unknown application results
#       Improved temporary-file cleanup and export handling
#       Added zero-application and dialog-process safeguards
#

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="ArchitectureScan"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX") || exit 1
DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX") || exit 1
INTEL_EXPORT_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_intel.XXXXX") || exit 1
UNKNOWN_EXPORT_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_unknown.XXXXX") || exit 1

chmod 644 "${JSON_DIALOG_BLOB}"
chmod 644 "${DIALOG_COMMAND_FILE}"
chmod 600 "${INTEL_EXPORT_FILE}"
chmod 600 "${UNKNOWN_EXPORT_FILE}"

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

SD_WINDOW_TITLE="Architecture Scan"
SD_ICON_FILE="/System/Applications/App Store.app"
SD_OVERLAY_ICON="SF=magnifyingglass.circle.fill,color=black,bgcolor=none"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

###################################################
#
# Modifiable Runtime variables
#
###################################################

# Define directories to scan (defaulting to /Applications and /System/Applications)
APPDIR_SCAN=("/Applications"
             "/System/Applications"
             "$USER_DIR/Applications")

STRIP_EXTENSION="yes"  # Hide the .app extension in display names: yes or no
SHOW_PATH="no"         # Show the application path beneath the display name: yes or no

####################################################################################################
#
# Functions
#
####################################################################################################

function admin_user ()
{
    (( UID == 0 ))
}

function check_for_sudo ()
{
    if ! admin_user; then
        print -u2 -r -- "ERROR: This script must be run as root."
        return 1
    fi

    return 0
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

function check_logged_in_user ()
{
    if [[ -z "${LOGGED_IN_USER}" ||
          "${LOGGED_IN_USER}" == "loginwindow" ||
          -z "${USER_DIR}" ||
          ! -d "${USER_DIR}" ]]; then

        logMe "ERROR: No valid logged-in user was found."
        return 1
    fi

    logMe "Logged-in user: ${LOGGED_IN_USER}"
    logMe "User home directory: ${USER_DIR}"

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
    local jamf_exit=0

    if [[ ! -x /usr/local/bin/jamf ]]; then
        logMe "ERROR: Jamf binary not found. Cannot install SwiftDialog."
        return 1
    fi

    /usr/local/bin/jamf policy -event "$DIALOG_INSTALL_POLICY"
    jamf_exit=$?

    if (( jamf_exit != 0 )); then
        logMe "ERROR: Jamf policy failed while installing SwiftDialog. Exit code: ${jamf_exit}"
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

    if ! command -v jq >/dev/null 2>&1; then
        logMe "jq is not installed."

        if [[ ! -x /usr/local/bin/jamf ]]; then
            logMe "ERROR: The local Jamf binary is unavailable, so jq cannot be installed."
            return 1
        fi

        logMe "Running jq installation policy."

        if ! /usr/local/bin/jamf policy -event "$JQ_FILE_INSTALL_POLICY"; then
            logMe "ERROR: jq installation policy failed."
            return 1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        logMe "ERROR: jq remains unavailable after installation."
        return 1
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

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM

    [[ -n "${JSON_DIALOG_BLOB:-}" && -f "${JSON_DIALOG_BLOB}" ]] && /bin/rm -f -- "${JSON_DIALOG_BLOB}"
    [[ -n "${DIALOG_COMMAND_FILE:-}" && -f "${DIALOG_COMMAND_FILE}" ]] && /bin/rm -f -- "${DIALOG_COMMAND_FILE}"
    [[ -n "${INTEL_EXPORT_FILE:-}" && -f "${INTEL_EXPORT_FILE}" ]] && /bin/rm -f -- "${INTEL_EXPORT_FILE}"
    [[ -n "${UNKNOWN_EXPORT_FILE:-}" && -f "${UNKNOWN_EXPORT_FILE}" ]] && /bin/rm -f -- "${UNKNOWN_EXPORT_FILE}"
    [[ -n "${DIALOG_COMMAND_FILE:-}" && -d "${DIALOG_COMMAND_FILE}.lock" ]] && /bin/rm -rf -- "${DIALOG_COMMAND_FILE}.lock"

    exit "${exit_code}"
}

####################################################################################################
#
# SwiftDialog functions
#
####################################################################################################

function construct_dialog_json ()
{
    local message="$1"
    local app_list_file
    local jq_exit=0
    local app

    app_list_file=$(/usr/bin/mktemp "/var/tmp/${SCRIPT_NAME}_applist.XXXXX") || {
        logMe "ERROR: Unable to create temporary application-list file."
        return 1
    }

    /bin/chmod 600 "${app_list_file}"

    #
    # Store the actual application paths.
    # One application per line.
    #
    for app in "${APP_LIST[@]}"; do
        print -r -- "${app}" >> "${app_list_file}"
    done

    #
    # Construct the complete SwiftDialog configuration with ONE jq process.
    #
    /usr/bin/jq -Rn \
        --arg icon "${SD_ICON_FILE}" \
        --arg message "${message}" \
        --arg bannerimage "${SD_BANNER_IMAGE}" \
        --arg subtitle "${BANNER_SUBTITLE}" \
        --arg titlefont "shadow=1,offset=${BANNER_TEXT_PADDING},color=${BANNER_TEXT_COLOR:l}" \
        --arg infobox "${SD_INFO_BOX_MSG}" \
        --arg overlayicon "${SD_OVERLAY_ICON}" \
        --arg bannertitle "${SD_WINDOW_TITLE}" \
        --arg strip_extension "${STRIP_EXTENSION:l}" \
        --arg show_path "${SHOW_PATH:l}" \
        '
        [
            inputs |
            select(length > 0) |

            . as $path |

            ($path | split("/") | last) as $filename |

            (
                if $strip_extension == "yes" then
                    $filename | sub("\\.app$"; "")
                else
                    $filename
                end
            ) as $title |

            (
                if $show_path == "yes" then
                    $path | split("/") | .[0:-1] | join("/") |
                    if . == "" then "/" else . end
                else
                    ""
                end
            ) as $app_path |

            {
                title: $title,
                icon: $path,
                status: "pending",
                statustext: "Pending..."
            }
            +
            if $app_path != "" then
                {
                    subtitle: $app_path
                }
            else
                {}
            end
        ] as $listitem |

        {
            icon: $icon,
            message: $message,
            bannerimage: $bannerimage,
            subtitle: $subtitle,
            titlefont: $titlefont,
            infobox: $infobox,
            overlayicon: $overlayicon,
            ontop: true,
            bannertitle: $bannertitle,
            button1text: "Export",
            button2text: "OK",
            button1disabled: true,
            moveable: true,
            height: 780,
            width: 900,
            ignorednd: true,
            quitkey: "0",
            listitem: $listitem
        }
        ' < "${app_list_file}" > "${JSON_DIALOG_BLOB}"

    jq_exit=$?

    /bin/rm -f "${app_list_file}"

    if (( jq_exit != 0 )) || [[ ! -s "${JSON_DIALOG_BLOB}" ]]; then
        logMe "ERROR: Unable to create the SwiftDialog JSON configuration."
        return 1
    fi

    return 0
}

function start_scan_dialog ()
{
    "${SW_DIALOG}" --progress --jsonfile "${JSON_DIALOG_BLOB}" --commandfile "${DIALOG_COMMAND_FILE}" &
    DIALOG_PROCESS=$!
    /bin/sleep 1

    if ! /bin/kill -0 "${DIALOG_PROCESS}" 2>/dev/null; then
        wait "${DIALOG_PROCESS}"
        local dialog_exit_code=$?
        DIALOG_PROCESS=""
        logMe "ERROR: SwiftDialog failed to start. Exit code: ${dialog_exit_code}"
        return 1
    fi
}

function update_display_list ()
{
    local action="${1:l}"
    local item_title="$2"
    local status_text="$3"
    local item_status="$4"
    local progress_value="$5"
    local progress_text="$6"

    case "${action}" in
        update|change)
            print -r -- "listitem: title: ${item_title}, status: ${item_status}, statustext: ${status_text}" >> "${DIALOG_COMMAND_FILE}"
            print -r -- "progress: ${progress_value}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        progress)
            print -r -- "progress: ${progress_value}" >> "${DIALOG_COMMAND_FILE}"

            if [[ -n "${progress_text}" ]]; then
                print -r -- "progresstext: ${progress_text}" >> "${DIALOG_COMMAND_FILE}"
            fi
            ;;

        buttondisable)
            print -r -- "button1: disable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        buttonenable)
            print -r -- "button1: enable" >> "${DIALOG_COMMAND_FILE}"
            ;;
    esac
}

####################################################################################################
#
# Application scan functions
#
####################################################################################################

function preload_apps ()
{
    local scan_directory
    local app
    local -a discovered_apps

    APP_LIST=()
    discovered_apps=()

    for scan_directory in "${APPDIR_SCAN[@]}"; do
        [[ -d "${scan_directory}" ]] || continue

        discovered_apps+=(
            "${scan_directory}"/*.app(N)
            "${scan_directory}"/*/*.app(N)
        )
    done

    if (( ${#discovered_apps[@]} > 0 )); then
        APP_LIST=("${(@ou)discovered_apps}")
    fi

    APPLIST_COUNT=${#APP_LIST[@]}

    logMe "INFO: Found ${APPLIST_COUNT} applications in the configured scan locations."
}

function get_application_architecture ()
{
    local app="$1"
    local bundle_info=""
    local bundle_id=""
    local executable_path=""
    local file_output=""
    local -a executable_files

    bundle_info=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "${app}/Contents/Info.plist" 2>/dev/null)
    bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "${app}/Contents/Info.plist" 2>/dev/null)

    if [[ -n "${bundle_info}" ]]; then
        executable_path="${app}/Contents/MacOS/${bundle_info}"
    fi

    if [[ -z "${executable_path}" || ! -f "${executable_path}" ]]; then
        executable_files=("${app}/Contents/MacOS/"*(N.))

        if (( ${#executable_files[@]} > 0 )); then
            executable_path="${executable_files[1]}"
        else
            executable_path=""
        fi
    fi

    if [[ -n "${executable_path}" && -f "${executable_path}" ]]; then
        file_output=$(/usr/bin/file -b "${executable_path}" 2>/dev/null)

        case "${file_output}" in
            *"Mach-O universal binary"*)
                REPLY="Universal"
                ;;

            *"Mach-O 64-bit executable arm64"*|*"Mach-O executable arm64"*)
                REPLY="Apple Silicon"
                ;;

            *"Mach-O 64-bit executable x86_64"*|*"Mach-O executable x86_64"*)
                REPLY="Intel"
                ;;

            *"shell script"*|*"script text executable"*)
                REPLY="Shell Script"
                ;;

            *)
                REPLY="Unknown"
                ;;
        esac
    elif [[ "${bundle_id}" == *"Safari.WebApp"* ]]; then
        REPLY="WebApp"
    else
        REPLY="Unknown"
    fi
}

function scan_apps ()
{
    local count=0
    local progress_value=0
    local app
    local app_name
    local architecture
    local app_status

    INTEL_APPS=()
    UNKNOWN_APPS=()

    : > "${INTEL_EXPORT_FILE}"
    : > "${UNKNOWN_EXPORT_FILE}"

    if (( APPLIST_COUNT == 0 )); then
        logMe "INFO: No applications are available to scan."
        return 1
    fi

    for app in "${APP_LIST[@]}"; do
        (( count++ ))

        if [[ "${STRIP_EXTENSION:l}" == "yes" ]]; then
            app_name="${app:t:r}"
        else
            app_name="${app:t}"
        fi

        get_application_architecture "${app}"
        architecture="${REPLY}"

        case "${architecture}" in
            Universal|Apple\ Silicon|Shell\ Script|WebApp)
                app_status="success"
                ;;

            Intel)
                app_status="fail"
                INTEL_APPS+=("${app}")
                print -r -- "${app}" >> "${INTEL_EXPORT_FILE}"
                ;;

            *)
                app_status="error"
                UNKNOWN_APPS+=("${app}")
                print -r -- "${app}" >> "${UNKNOWN_EXPORT_FILE}"
                ;;
        esac

        progress_value=$(( count * 100 / APPLIST_COUNT ))
        logMe "${app_name} has an architecture of: ${architecture}"
        update_display_list "update" "${app_name}" "${architecture}" "${app_status}" "${progress_value}" ""
    done

    return 0
}

function export_scan_results ()
{
    local desktop_directory="${USER_DIR}/Desktop"
    local intel_destination="${desktop_directory}/Intel Apps.txt"
    local unknown_destination="${desktop_directory}/Unknown Architecture Apps.txt"
    local user_group
    local exported_count=0

    if [[ ! -d "${desktop_directory}" ]]; then
        logMe "ERROR: The logged-in user's Desktop directory could not be found."
        return 1
    fi

    user_group=$(/usr/bin/id -gn "${LOGGED_IN_USER}" 2>/dev/null)

    if [[ -z "${user_group}" ]]; then
        logMe "ERROR: Unable to determine the primary group for ${LOGGED_IN_USER}."
        return 1
    fi

    #
    # Intel applications
    #
    if (( ${#INTEL_APPS[@]} > 0 )); then

        if [[ ! -s "${INTEL_EXPORT_FILE}" ]]; then
            logMe "ERROR: Intel applications were detected, but the Intel export file is missing or empty."
        elif /bin/cp "${INTEL_EXPORT_FILE}" "${intel_destination}"; then

            /usr/sbin/chown "${LOGGED_IN_USER}:${user_group}" "${intel_destination}"
            /bin/chmod 644 "${intel_destination}"
            logMe "Intel application list exported to ${intel_destination}"

            (( exported_count++ ))
        else
            logMe "ERROR: Unable to export Intel application list."
        fi
    fi

    #
    # Unknown applications
    #
    if (( ${#UNKNOWN_APPS[@]} > 0 )); then

        if [[ ! -s "${UNKNOWN_EXPORT_FILE}" ]]; then
            logMe "ERROR: Unknown applications were detected, but the Unknown export file is missing or empty."
        elif /bin/cp "${UNKNOWN_EXPORT_FILE}" "${unknown_destination}"; then

            /usr/sbin/chown "${LOGGED_IN_USER}:${user_group}" "${unknown_destination}"
            /bin/chmod 644 "${unknown_destination}"

            logMe "Unknown architecture application list exported to ${unknown_destination}"

            (( exported_count++ ))
        else
            logMe "ERROR: Unable to export Unknown architecture application list."
        fi
    fi

    if (( exported_count == 0 )); then
        logMe "INFO: No scan results were exported."
    fi

    return 0
}

function run_architecture_scan ()
{
    local message
    local dialog_exit_code

    message="Apple has announced that Rosetta support will be deprecated after macOS 27. "
    message+="This utility scans installed applications and identifies their architecture so applications requiring updates can be located."

    preload_apps

    if (( APPLIST_COUNT == 0 )); then
        logMe "INFO: No applications were found in the configured scan locations."

        "${SW_DIALOG}" --bannertitle "${SD_WINDOW_TITLE}" \
            --bannerimage "${SD_BANNER_IMAGE}" \
            --icon "${SD_ICON_FILE}" \
            --overlayicon warning \
            --message "No applications were found in the configured scan locations." \
            --button1text "OK" \
            --width 700 \
            --ontop 2>/dev/null

        return 0
    fi

    if ! construct_dialog_json "${message}"; then
        logMe "ERROR: Failed to construct SwiftDialog configuration."
        return 1
    fi

    start_scan_dialog || {
        logMe "ERROR: Unable to start the scan dialog."
        return 1
    }

    scan_apps || {
        logMe "ERROR: Architecture scan failed."
        return 1
    }


    update_display_list "progress" "" "" "" "100" "Scan complete. Intel: ${#INTEL_APPS[@]} | Unknown: ${#UNKNOWN_APPS[@]}"
    update_display_list "buttonenable" "" "" "" "" ""

    wait "${DIALOG_PROCESS}"
    dialog_exit_code=$?

    DIALOG_PROCESS=""

    case "${dialog_exit_code}" in
        0)
            export_scan_results
            ;;

        2)
            logMe "INFO: Scan completed without exporting results."
            ;;

        *)
            logMe "INFO: SwiftDialog exited with code ${dialog_exit_code}."
            ;;
    esac
}

####################################################################################################
#
# Main
#
####################################################################################################

autoload -Uz is-at-least

trap 'cleanup_and_exit 1' HUP INT TERM

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1
check_logged_in_user || cleanup_and_exit 1
check_swift_dialog_install || cleanup_and_exit 1
check_support_files || cleanup_and_exit 1

create_infobox_message

run_architecture_scan || cleanup_and_exit 1

cleanup_and_exit 0