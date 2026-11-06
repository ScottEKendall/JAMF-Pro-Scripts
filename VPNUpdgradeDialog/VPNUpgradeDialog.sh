#!/bin/zsh --no-rcs
#
# VPNUpgradeDialog.sh
#
# by: Scott Kendall
#
# Written: 11/06/2026
# Last updated: 11/06/2026
#
# Script Purpose:
#   Determines whether an upgrade is required for the configured VPN
#   client application. If the VPN is connected, the script presents
#   a SwiftDialog notification that allows the logged-in user to begin
#   the update or defer it. The installation is performed by a Jamf Pro
#   policy using a custom event trigger.

#######################################################################
# VPN Client Configuration
#
# Update the following values to match the VPN client being managed.
#
# VPN_CLIENT_APP
#   Full path to the VPN client application.
##
# VPN_CLIENT_BINARY
#   Full path to the VPN client's command-line executable.
#
# VPN_STATUS_ARGS
#   Arguments passed to the VPN client's command-line executable
#   to retrieve the current connection status.
#
# VPN_CONNECTED_PATTERN
#   Text returned by the VPN CLI that identifies an active connection.
#
# The application name, dialog title, and application icon are
# automatically derived from VPN_CLIENT_APP.
#
# Also verify that get_vpn_client_version() retrieves the correct version
# from the target VPN application's Info.plist.
#######################################################################
# 1.0 - Initial production release
#       Added configurable VPN client, CLI, version, and connection-state detection
#       Added SwiftDialog notification for upgrades that interrupt an active VPN connection
#       Added configurable user deferrals with target-version tracking
#       Added Jamf Pro custom event support for VPN installation and upgrades
#       Added post-install version validation and Jamf inventory submission
#       Added automatic VPN application name, dialog title, and icon detection
#       Added per-VPN preference storage and deferral management
#       Added SwiftDialog installation, branding, logging, and error handling

VPN_CLIENT_APP="/Applications/Cisco/Cisco Secure Client.app"
VPN_CLIENT_BINARY="/opt/cisco/secureclient/bin/vpn"
VPN_STATUS_ARGS=(stats)
VPN_CONNECTED_PATTERN="Connection State:            Connected"

#######################################################################
# Derived VPN Client Settings
# No changes should normally be required below this line.
#######################################################################

VPN_CLIENT_NAME="${VPN_CLIENT_APP:t:r}"
SD_WINDOW_TITLE="${VPN_CLIENT_NAME} Update"
SD_ICON_FILE="$VPN_CLIENT_APP"

VPN_CLIENT_ID="${VPN_CLIENT_NAME:l}"
VPN_CLIENT_ID="${VPN_CLIENT_ID// /-}"
VPN_CLIENT_ID="${VPN_CLIENT_ID//[^a-z0-9._-]/}"

PREFS_DOMAIN="/Library/Preferences/com.gianteagle.vpn-upgrade.${VPN_CLIENT_ID}" # Preferences domain for the VPN client upgrade settings

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="VPNUpgradeDialog"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

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

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

##################################################
#JAMF 
# Passed in variables
# 
# Jamf Pro Policy Parameters
#
# Parameter 4: Custom event used to install/update the VPN client
# Parameter 5: Maximum number of user deferrals
# Parameter 6: Deferral duration in seconds
# Parameter 7: Required VPN client version
#######################################################################             

JAMF_PARAMETER_USER="${3:-}"            #If run from JAMF, this will be the logged in user. If run from terminal, this will be empty (and will use the logged in user)
JAMF_TRIGGER="${4:-updateVPN}"          # Parameter 4: Jamf custom event that performs the VPN upgrade
MAX_DEFERRALS="${5:-3}"                 # Parameter 5: Maximum allowed deferrals (defaults to 3)
DEFER_SECONDS="${6:-900}"               # Parameter 6: Deferral duration in seconds (defaults to 15 mins)
VPN_VERSION="${7:-}"                    # Parameter 7: Version # to check against

TITLE_FONT="shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"

JAMF_BIN="/usr/local/bin/jamf"

DEFERRAL_KEY="DeferralCount"
NEXT_RUN_KEY="NextAllowedRun"
TARGET_VERSION_KEY="TargetVersion"


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
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {
            print -u2 "ERROR: Unable to create log directory: ${LOG_DIR}"
            return 1
        }
    fi

    chmod 755 "$LOG_DIR" || {
        print -u2 "ERROR: Unable to set permissions on: ${LOG_DIR}"
        return 1
    }

    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE" || {
            print -u2 "ERROR: Unable to create log file: ${LOG_FILE}"
            return 1
        }
    fi

    chmod 640 "$LOG_FILE" || {
        print -u2 "ERROR: Unable to secure log file: ${LOG_FILE}"
        return 1
    }
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

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - INT TERM
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

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

function runAsUser ()
{
    if [[ -z "$LOGGED_IN_USER" || -z "$USER_UID" ]]; then
        logMe "ERROR: Logged-in user context is unavailable."
        return 1
    fi

    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "$LOGGED_IN_USER" "$@"
}
####################################################################################################
#
# Application Specific functions
#
####################################################################################################


function upgrade_is_required ()
{
    # Determine whether the configured VPN client requires an upgrade.
    #
    # Returns:
    #   0 - Upgrade required
    #   1 - Installed version meets or exceeds required version
    #   2 - Unable to evaluate the required version
    local installed_version

    if [[ -z "$VPN_VERSION" ]]; then
        logMe "ERROR: No target ${VPN_CLIENT_NAME} version was provided in Jamf parameter 7."
        return 2
    fi

    if ! installed_version=$(get_vpn_client_version); then
        logMe "${VPN_CLIENT_NAME} is not currently installed."
        return 0
    fi

    logMe "Installed ${VPN_CLIENT_NAME} version: ${installed_version}"
    logMe "Required ${VPN_CLIENT_NAME} version: ${VPN_VERSION}"

    if is-at-least "$VPN_VERSION" "$installed_version"; then
        logMe "${VPN_CLIENT_NAME} meets or exceeds the required version."
        return 1
    fi

    logMe "${VPN_CLIENT_NAME} requires an upgrade."
    return 0
}

function get_vpn_client_version ()
{
    # Determine the installed VPN version
    local app_path=""
    local version=""

    if [[ -d "${VPN_CLIENT_APP}" ]]; then
        app_path="${VPN_CLIENT_APP}"
    else
        return 1
    fi

    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${app_path}/Contents/Info.plist" 2>/dev/null)

    if [[ -n "${version}" ]]; then
        /bin/echo "${version}"
        return 0
    fi

    return 1
}

function reset_deferrals_for_new_version ()
{
    local stored_version

    stored_version=$(/usr/bin/defaults read "$PREFS_DOMAIN" "$TARGET_VERSION_KEY" 2>/dev/null)

    if [[ "$stored_version" != "$VPN_VERSION" ]]; then
        logMe "${VPN_CLIENT_NAME} target version changed from ${stored_version:-none} to ${VPN_VERSION}."

        clearDeferrals

        if ! /usr/bin/defaults write "$PREFS_DOMAIN" "$TARGET_VERSION_KEY" "$VPN_VERSION"; then
            logMe "ERROR: Unable to record target ${VPN_CLIENT_NAME} version ${VPN_VERSION}."
            return 1
        fi
    fi

    return 0
}

function get_vpn_connection_state ()
{
    local vpn_status=""

    if [[ ! -x "$VPN_CLIENT_BINARY" ]]; then
        logMe "ERROR: VPN client CLI was not found: ${VPN_CLIENT_BINARY}"
        return 2
    fi

    if ! vpn_status=$("$VPN_CLIENT_BINARY" "${VPN_STATUS_ARGS[@]}" 2>/dev/null); then
        logMe "ERROR: Unable to retrieve VPN connection status."
        return 2
    fi

    if /usr/bin/grep -Fq "$VPN_CONNECTED_PATTERN" <<< "$vpn_status"; then
        logMe "${VPN_CLIENT_NAME} connection state is Connected."
        return 0
    fi

    logMe "${VPN_CLIENT_NAME} is not currently connected."
    return 1
}

function deferralIsActive ()
{
    # Determine whether a previous deferral is still active
    local current_time
    local next_run

    current_time="$(/bin/date +%s)"

    next_run=$(/usr/bin/defaults read "${PREFS_DOMAIN}" "${NEXT_RUN_KEY}" 2>/dev/null)

    if [[ "${next_run}" == <-> ]] &&
       (( current_time < next_run )); then

        logMe "Upgrade is deferred until epoch ${next_run}."
        return 0
    fi

    return 1
}

function recordDeferral ()
{
    # Record a user deferral
    local current_count
    local next_count
    local next_run

    current_count=$(/usr/bin/defaults read "$PREFS_DOMAIN" "$DEFERRAL_KEY" 2>/dev/null)

    [[ "$current_count" == <-> ]] || current_count=0

    next_count=$(( current_count + 1 ))
    next_run=$(( $(/bin/date +%s) + DEFER_SECONDS ))

    if ! /usr/bin/defaults write "$PREFS_DOMAIN" "$DEFERRAL_KEY" -int "$next_count"; then
        logMe "ERROR: Unable to record the ${VPN_CLIENT_NAME} update deferral count."
        return 1
    fi

    if ! /usr/bin/defaults write "$PREFS_DOMAIN" "$NEXT_RUN_KEY" -int "$next_run"; then
        logMe "ERROR: Unable to record the next ${VPN_CLIENT_NAME} update time."
        return 1
    fi

    logMe "Deferral ${next_count} of ${MAX_DEFERRALS} recorded."
    return 0
}

function clearDeferrals ()
{
    # Clear stored deferrals

    /usr/bin/defaults delete "$PREFS_DOMAIN" "$DEFERRAL_KEY" 2>/dev/null
    /usr/bin/defaults delete "$PREFS_DOMAIN" "$NEXT_RUN_KEY" 2>/dev/null

    return 0
}
function showUpgradeMessage ()
{
    # Show the connected-VPN warning
    local installed_version
    local current_deferrals
    local remaining_deferrals
    local message
    local dialog_result

    installed_version="$(get_vpn_client_version)"
    [[ -n "${installed_version}" ]] || installed_version="Unknown"

    current_deferrals=$(/usr/bin/defaults read "${PREFS_DOMAIN}" "${DEFERRAL_KEY}" 2>/dev/null)
    [[ "${current_deferrals}" == <-> ]] || current_deferrals=0

    remaining_deferrals=$(( MAX_DEFERRALS - current_deferrals ))
    (( remaining_deferrals < 0 )) && remaining_deferrals=0

    message="${SD_DIALOG_GREETING}, ${SD_FIRST_NAME}.  An update is ready for ${VPN_CLIENT_NAME}.<br><br>"
    message+="Your VPN connection is currently active. Starting this update will temporarily disconnect the VPN and may interrupt access to company resources.<br><br>"
    message+=":red[Please save any work before continuing.]<br><br>"
    message+="**Installed version:** ${installed_version}"
    message+="<br>**Required version:** ${VPN_VERSION}"
    if (( remaining_deferrals > 0 )); then
        message+="<br><br>You may defer this update ${remaining_deferrals} more time"
        (( remaining_deferrals != 1 )) && message+="s"
        message+="."
    else
        message+="<br><br>The update can no longer be deferred."
    fi

    typeset -a dialog_options=(
        --bannerimage "$SD_BANNER_IMAGE"
        --subtitle "$BANNER_SUBTITLE"
        --bannertitle "$SD_WINDOW_TITLE"
        --titlefont "$TITLE_FONT"
        --message "${message}"
        --icon "${SD_ICON_FILE}"
        --iconsize 128
        --button1text "Update Now"
        --width 800
        --height 480
        --position center
        --ontop
        --moveable
        --quitkey x
    )

    (( remaining_deferrals > 0 )) && dialog_options+=(--button2text "Defer")

    runAsUser "$SW_DIALOG" "${dialog_options[@]}"
    dialog_result=$?

    case "$dialog_result" in
        0)
            logMe "User selected Update Now."
            return 0
            ;;

        2)
            if (( remaining_deferrals > 0 )); then
                logMe "User selected Defer."
                recordDeferral || return 1
                return 2
            fi

            logMe "Deferral was requested but no deferrals remain."
            return 0
            ;;

        10)
            if (( remaining_deferrals > 0 )); then
                logMe "Dialog was closed. Treating the result as a deferral."
                recordDeferral || return 1
                return 2
            fi

            logMe "Dialog was closed and no deferrals remain. Continuing."
            return 0
            ;;

        *)
            logMe "ERROR: SwiftDialog exited unexpectedly with code ${dialog_result}."
            return 1
            ;;
    esac
}

function performUpgrade ()
{
    # Run the Jamf upgrade policy
    local old_version
    local new_version
    local jamf_result

    old_version="$(get_vpn_client_version)"
    [[ -n "${old_version}" ]] || old_version="Unknown"

    if [[ ! -x "${JAMF_BIN}" ]]; then
        logMe "ERROR: Jamf binary was not found at ${JAMF_BIN}."
        return 1
    fi

    logMe "Starting ${VPN_CLIENT_NAME} upgrade."
    logMe "Current version: ${old_version}"
    logMe "Jamf custom event: ${JAMF_TRIGGER}"

    "${JAMF_BIN}" policy -event "${JAMF_TRIGGER}" -forceNoRecon

    jamf_result=$?

    if (( jamf_result != 0 )); then
        logMe "ERROR: Jamf policy returned exit code ${jamf_result}."
        return "${jamf_result}"
    fi

    new_version="$(get_vpn_client_version)"
    [[ -n "${new_version}" ]] || new_version="Unknown"
    
    logMe "${VPN_CLIENT_NAME} upgrade policy completed."
    logMe "Version before upgrade: ${old_version}"
    logMe "Version after upgrade: ${new_version}"

    if [[ "$new_version" == "Unknown" ]]; then
        logMe "ERROR: ${VPN_CLIENT_NAME} was not detected after the upgrade."
        return 1
    fi

    if ! is-at-least "$VPN_VERSION" "$new_version"; then
        logMe "ERROR: Installed ${VPN_CLIENT_NAME} version ${new_version} does not meet required version ${VPN_VERSION}."
        return 1
    fi

    logMe "${VPN_CLIENT_NAME} upgrade validation succeeded."

    clearDeferrals

    if ! "${JAMF_BIN}" recon; then
        logMe "WARNING: The upgrade succeeded, but Jamf inventory submission failed."
    fi

    return 0
}

####################################################################################################
#
# Main Script
#
####################################################################################################

autoload -Uz is-at-least

check_for_sudo || cleanup_and_exit 1
create_log_directory || cleanup_and_exit 1

logMe "Beginning ${VPN_CLIENT_NAME} upgrade workflow."

if [[ "$MAX_DEFERRALS" != <-> ]]; then
    logMe "WARNING: Invalid maximum deferral value: ${MAX_DEFERRALS}"
    MAX_DEFERRALS=3
fi

if [[ "$DEFER_SECONDS" != <-> ]] || (( DEFER_SECONDS < 60 )); then
    logMe "WARNING: Invalid deferral duration: ${DEFER_SECONDS}"
    DEFER_SECONDS=3600
fi

if [[ -z "$VPN_VERSION" ]]; then
    logMe "ERROR: No target ${VPN_CLIENT_NAME} version was provided in Jamf parameter 7."
    cleanup_and_exit 1
fi

reset_deferrals_for_new_version || cleanup_and_exit 1

upgrade_is_required
upgrade_required_result=$?

case "$upgrade_required_result" in
    0)
        ;;
    1)
        logMe "${VPN_CLIENT_NAME} already meets the required version."
        clearDeferrals
        cleanup_and_exit 0
        ;;
    *)
        logMe "ERROR: Unable to determine whether an upgrade is required."
        cleanup_and_exit 1
        ;;
esac

if deferralIsActive; then
    logMe "A previous user deferral is still active."
    cleanup_and_exit 0
fi

initialize_user_context
user_context_result=$?

get_vpn_connection_state
vpn_connection_result=$?

case "$vpn_connection_result" in
    0)
        if (( user_context_result == 0 )); then
            check_swift_dialog_install || cleanup_and_exit 1
            check_support_files || cleanup_and_exit 1
            showUpgradeMessage
            dialog_result=$?

            case "$dialog_result" in
                0)
                    ;;
                2)
                    logMe "${VPN_CLIENT_NAME} update deferred by the user."
                    cleanup_and_exit 0
                    ;;
                *)
                    logMe "ERROR: Unable to complete the ${VPN_CLIENT_NAME} update notification."
                    cleanup_and_exit 1
                    ;;
            esac
        else
            logMe "WARNING: VPN is connected, but no interactive user is available."
            logMe "The upgrade will be retried during the next policy execution."
            cleanup_and_exit 0
        fi
        ;;

    1)
        logMe "VPN is not active. No user notification is required."
        ;;

    *)
        logMe "ERROR: Unable to determine the VPN connection state."
        cleanup_and_exit 1
        ;;
esac

performUpgrade
upgrade_result=$?

if (( upgrade_result != 0 )); then
    logMe "ERROR: ${VPN_CLIENT_NAME} upgrade failed."
    cleanup_and_exit "$upgrade_result"
fi

logMe "${VPN_CLIENT_NAME} upgrade workflow completed successfully."
cleanup_and_exit 0