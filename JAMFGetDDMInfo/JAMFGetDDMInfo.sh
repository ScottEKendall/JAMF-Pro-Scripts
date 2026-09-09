#!/bin/zsh
#
# GetDDMInfo.sh
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 09/01/2026
#
# Script Purpose: Retrieve the DDM info for Jamf devices
#
# 0.1 - Initial
# 0.2 - had to add "printf '%s' $1" before each of the jq commands to strip out non-ascii characters (it would cause jq to crash) - Thanks @RedShirt
#       Script can now perform functions based on SmartGroups
# 0.3 - Put error trap in Jamf API calls to see if returns "INVALID_PRIVILEGE""
# 0.4 - Optimized some loop routines and put in more error trapping.  Add feature to include DDM Software Failures in CSV report / Optimized Jamf functions for faster processing
# 0.5 - Added support for both smart & static groups (had to use the Classic API to do this)
#       Added Verbal description of Blueprint activation failures
#       Took advantage of some AI Tools to optimize the "common" section and optimize more Jamf functions
#       Removed the extra verbiage at the end of the Blueprint IDs
#       Added button to open the Blueprint links in your browser
# 0.6 - Add more safety net around the JQ command to make sure it won't error out.
#       More detailed reporting in CSV file
#       Reported if DDM is not enabled on a system.
# 0.7 - Background processing!  Major speed improvement
#       Progress during list items to show actual progress
# 0.8	Preliminary support for blueprints
#       Several GUI enhancements, including verbiage and typos
#       Ability to choose export location for Individual systems
#       Report on more DDM fields
# 0.9 - Got the scan for blueprints feature working (fully multitasking aware)
#       Added option to show success and/or failed on blueprint scan
#       Made minor GUI changes
#       Show dialog notification during long inventory retrievals
# 1.0RC1 - Added more DDM reporting details (current Model #, Current OS, Security Certificates)
#       More JQ error trapping
# 1.0RC2 - more JQ error trapping
#       Added Current OS to CSV reports
#       Moved Jamf Token process inside of main loop to make sure it gets renewed after each selection
#       Added BP Name (optional) so you can name your CSV file
#       Cleaned up the output TXT file for individual systems
# 1.0RC3 - Added more Jamf error trapping
#       Add option to Force Sync DDM commands
#       Converted the output of the DDM Supported Payloads into a more readable format
# 1.0RC4 - Fixed reporting for blueprint not found when scanning for blueprint IDs
#       Add invalid blueprint information to system display and CSV output file
#       Significant rework of logic to determine valid, invalid or unknown deployments
# 1.0RC5 - Fixed issue of failed blueprints not returning correct results when doing a blueprint scan
#       Added option for cross reference file so you can associate Blueprint IDs to Names and it will show the name results during scans
#       Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 1.0RC6 - Added extensive logging and comments
#       Added centralized cleanup traps
#       Added thread-safe CSV writes
#       Added thread-safe SwiftDialog command writes
#       Added background worker failure tracking
#       Added reliable dialog process waiting
#       Added HTTP and JSON validation for DDM API calls
#       Added Force Sync support
#       Added Blueprint friendly-name cross-reference support
#       Added Failed, Invalid, Active, Inactive, Mixed, and Not Found result classifications
#       Added result-specific Blueprint filtering
#       Added display-only-matching behavior
#       Added consistent CSV and display classifications
#       Added CSV field escaping
#       Improved Jamf group dropdown construction
#       Corrected initial SwiftDialog list-item status values
#       Prevented empty progress commands during list updates
#       Improved handling of missing DDM data and management IDs
# 1.0 - Production release
#       Finalized Blueprint Active, Inactive, Mixed, Failed, Invalid, and Not Found classifications
#       Finalized Blueprint and group filtering
#       Finalized thread-safe CSV and SwiftDialog output
#       Finalized result counters, API validation, cleanup, and error handling
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
umask 022
typeset -g DIALOG_PROCESS=""
MAIN_PID=$$
SCRIPT_NAME="GetDDMInfo"
SCRIPT_VERSION="1.0"

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | grep "Free Space" | awk '{print $6}' | cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"

# jq requirements

JQ_BINARY="/usr/local/bin/jq"
MIN_JQ_REQUIRED_VERSION="1.6"
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

# Configuration is resolved in this order, highest priority first:
#
#   1. An environment variable      SUPPORT_DIR="/path" ./JAMFGetDDMInfo.sh ...
#   2. A key in the managed preference domain located below
#   3. The built-in default listed in this block
#
# To run against a different tenant, either export SCRIPT_DEFAULTS_DOMAIN (a domain
# name or a full plist path) or add that tenant's domain to the candidate list below.
# The first candidate that exists on disk wins.

typeset -ga DEFAULTS_DOMAIN_CANDIDATES=(
    "com.gianteaglescript.defaults"
)

function locate_defaults_domain ()
{
    # Find the managed preference plist to read configuration from.
    #
    # PARMS Expected: SCRIPT_DEFAULTS_DOMAIN (optional), DEFAULTS_DOMAIN_CANDIDATES
    #
    # RETURN: prints the plist path, 1 if no candidate exists

    local candidate plist

    for candidate in ${SCRIPT_DEFAULTS_DOMAIN:+"$SCRIPT_DEFAULTS_DOMAIN"} "${DEFAULTS_DOMAIN_CANDIDATES[@]}"; do

        [[ -n "$candidate" ]] || continue

        # A candidate may be a full plist path or a bare domain name

        if [[ "$candidate" == /* ]]; then
            [[ -r "$candidate" ]] && { print -r -- "$candidate" ; return 0 ; }
            continue
        fi

        for plist in "/Library/Managed Preferences/${candidate}.plist" "/Library/Preferences/${candidate}.plist"; do
            [[ -r "$plist" ]] && { print -r -- "$plist" ; return 0 ; }
        done
    done

    return 1
}

function read_config ()
{
    # Resolve one configuration value: environment override, then managed preference,
    # then the built-in default. An empty preference value is treated as unset, which
    # a bare "defaults read" exit-status check does not catch.
    #
    # PARMS Expected: $1 - preference key, $2 - environment variable name, $3 - default
    #
    # RETURN: prints the resolved value

    local key="$1" env_var="$2" fallback="$3" value

    value="${(P)env_var}"
    [[ -n "$value" ]] && { print -r -- "$value" ; return 0 ; }

    if [[ -n "$DEFAULTS_DIR" ]]; then
        value=$(defaults read "$DEFAULTS_DIR" "$key" 2>/dev/null)
        [[ -n "$value" ]] && { print -r -- "$value" ; return 0 ; }
    fi

    print -r -- "$fallback"
    return 0
}

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR=$(locate_defaults_domain) || DEFAULTS_DIR=""
echo "Setting Default values"
SUPPORT_DIR=$(read_config SupportFiles SUPPORT_DIR "/Library/Application Support/GiantEagle")
SD_BANNER_IMAGE=$(read_config BannerImage SD_BANNER_IMAGE "GE_SD_BannerImage.png")
BANNER_TEXT_PADDING=$(read_config BannerPadding BANNER_TEXT_PADDING 10)
BANNER_SUBTITLE=$(read_config BannerSubtitle BANNER_SUBTITLE "")
BANNER_TEXT_COLOR=$(read_config TitleFontColor BANNER_TEXT_COLOR "white")

# Used when the banner image cannot be found. swiftDialog 3.1.0 and later accept a
# colour or gradient in place of a file, so the window keeps a branded banner bar
# instead of a blank strip. check_swift_dialog_install already enforces 3.1.0.
#
#   gradient=<colour>,<colour>[,...][:angle=<degrees>]   0 = bottom-to-top,
#                                                        90 = left-to-right (default),
#                                                        180 = top-to-bottom
#   colour=<name|#hex>[,nogradient]                      "accent" tracks the system accent
#
# Set BannerFallback to "none" to keep the missing-file behaviour instead.

SD_BANNER_FALLBACK=$(read_config BannerFallback SD_BANNER_FALLBACK "gradient=#1f2933,#3e5c76:angle=135")
[[ "${SD_BANNER_FALLBACK:l}" == (none|off) ]] && SD_BANNER_FALLBACK=""

# Resolve a bare filename against the support directory, whether or not the file is
# present yet, so later existence checks test the real location instead of the CWD.
# Absolute paths, URLs and swiftDialog colour/gradient specs are left alone.

[[ "$SD_BANNER_IMAGE" == (/*|http://*|https://*|colour=*|color=*|gradient=*) ]] || SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Retrieve Jamf DDM Info"
SD_ICON_FILE="https://images.crunchbase.com/image/upload/c_pad,h_170,w_170,f_auto,b_white,q_auto:eco,dpr_1/vhthjpy7kqryjxorozdk"
OVERLAY_ICON="SF=list.bullet.circle,color=orange,weight=heavy,bgcolor=none"
#OVERLAY_ICON="/System/Applications/App Store.app"

# Policy triggers used to fetch support files and dependencies. These are tenant
# specific -- override them the same way as everything else in the block above.

SUPPORT_FILE_INSTALL_POLICY=$(read_config SupportFilePolicy SUPPORT_FILE_INSTALL_POLICY "install_SymFiles")
DIALOG_INSTALL_POLICY=$(read_config DialogInstallPolicy DIALOG_INSTALL_POLICY "install_SwiftDialog")
JQ_INSTALL_POLICY=$(read_config JQInstallPolicy JQ_INSTALL_POLICY "install_jq")

# Setting the support-file trigger to "none" skips the policy entirely, for tenants that
# ship the banner by other means. The dialog and jq triggers are fallback installers and
# are always attempted, so they have no equivalent opt-out.

[[ "${SUPPORT_FILE_INSTALL_POLICY:l}" == (none|off) ]] && SUPPORT_FILE_INSTALL_POLICY=""

# Jamf Pro server to query. Left empty by default, in which case the script falls back to
# the server this Mac is enrolled with. Set JamfProURL here, or pass script parameter 6,
# to point the script at a test tenant or run it from a Mac enrolled somewhere else.

JAMF_PRO_URL=$(read_config JamfProURL JAMF_PRO_URL "")

# Multitasking items

BACKGROUND_TASKS=10                 # Number of background tasks to run in parallel
JAMF_INVENTORY_PAGE_SIZE=100        # Jamf records to return at once from the API inventory lookup

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
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}"
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
    # Install / update SwiftDialog directly from the swiftDialog GitHub releases page,
    # falling back to the Jamf policy trigger if the direct download cannot be verified.
    #
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from Jamf (fallback only)
    #
    # RETURN: 0 on success, 1 on failure

    local EXPECTED_TEAM_ID="PWA5E9TQ59"
    local DIALOG_URL TEMP_DIR TEAM_ID

    DIALOG_URL=$(/usr/bin/curl -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" 2>/dev/null | \
        /usr/bin/awk -F '"' '/browser_download_url/ && /pkg"/ { print $4; exit }')

    if [[ -z "$DIALOG_URL" ]]; then
        logMe "WARNING: Unable to determine the latest SwiftDialog download URL; falling back to Jamf policy." >&2
        install_swift_dialog_from_jamf
        return $?
    fi

    TEMP_DIR=$(/usr/bin/mktemp -d "/private/tmp/${SCRIPT_NAME}.dialog.XXXXXX") || {
        logMe "ERROR: Unable to create a temporary directory for the SwiftDialog installer." >&2
        return 1
    }

    logMe "Downloading SwiftDialog from ${DIALOG_URL}"

    if ! /usr/bin/curl --location --silent --fail "$DIALOG_URL" -o "${TEMP_DIR}/Dialog.pkg"; then
        logMe "WARNING: SwiftDialog download failed; falling back to Jamf policy." >&2
        /bin/rm -Rf "$TEMP_DIR"
        install_swift_dialog_from_jamf
        return $?
    fi

    # Verify the package is signed by the expected developer before installing it

    TEAM_ID=$(/usr/sbin/spctl -a -vv -t install "${TEMP_DIR}/Dialog.pkg" 2>&1 | /usr/bin/awk '/origin=/ {print $NF}' | /usr/bin/tr -d '()')

    if [[ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
        logMe "ERROR: SwiftDialog package Team ID '${TEAM_ID}' does not match expected '${EXPECTED_TEAM_ID}'; not installing." >&2
        /bin/rm -Rf "$TEMP_DIR"
        install_swift_dialog_from_jamf
        return $?
    fi

    if ! /usr/sbin/installer -pkg "${TEMP_DIR}/Dialog.pkg" -target / >/dev/null 2>&1; then
        logMe "ERROR: SwiftDialog installer failed." >&2
        /bin/rm -Rf "$TEMP_DIR"
        return 1
    fi

    /bin/rm -Rf "$TEMP_DIR"

    if [[ ! -x "$SW_DIALOG" ]]; then
        logMe "ERROR: SwiftDialog installed but ${SW_DIALOG} is missing." >&2
        return 1
    fi

    logMe "SwiftDialog installed successfully."
    return 0
}

function install_swift_dialog_from_jamf ()
{
    # Fallback installer: use the Jamf policy trigger
    #
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from Jamf
    #
    # RETURN: 0 if the dialog binary is present afterwards, 1 if not

    [[ -x /usr/local/bin/jamf ]] || { logMe "ERROR: jamf binary not found; cannot install SwiftDialog." >&2 ; return 1; }

    logMe "Attempting SwiftDialog install via Jamf policy '${DIALOG_INSTALL_POLICY}'"
    /usr/local/bin/jamf policy -event "${DIALOG_INSTALL_POLICY}"

    [[ -x "$SW_DIALOG" ]] || { logMe "ERROR: SwiftDialog still missing after Jamf policy run." >&2 ; return 1; }
    return 0
}

function check_support_files ()
{
    # Only reach for the Jamf policy when a support-file install could actually supply the
    # banner: it has to be a local image path that is missing, and jamf has to be present.

    if [[ "$SD_BANNER_IMAGE" == /* ]] && [[ ! -e "$SD_BANNER_IMAGE" ]] && [[ "$SD_BANNER_IMAGE" =~ \.(jpg|png|heic)$ ]]; then

        if [[ -z "$SUPPORT_FILE_INSTALL_POLICY" ]]; then
            logMe "${SD_BANNER_IMAGE} is missing and no support-file policy is configured."
        elif [[ ! -x /usr/local/bin/jamf ]]; then
            logMe "WARNING: ${SD_BANNER_IMAGE} is missing and the jamf binary is unavailable." >&2
        elif ! /usr/local/bin/jamf policy -event "$SUPPORT_FILE_INSTALL_POLICY"; then
            logMe "WARNING: Support-file installation failed." >&2
        elif [[ ! -e "$SD_BANNER_IMAGE" ]]; then
            logMe "WARNING: ${SD_BANNER_IMAGE} is still missing after the '${SUPPORT_FILE_INSTALL_POLICY}' policy." >&2
        fi

        # Nothing supplied the image, so fall back to a colour/gradient banner rather
        # than handing swiftDialog a path that is not there.

        if [[ ! -e "$SD_BANNER_IMAGE" ]] && [[ -n "$SD_BANNER_FALLBACK" ]]; then
            logMe "Falling back to the '${SD_BANNER_FALLBACK}' banner."
            SD_BANNER_IMAGE="$SD_BANNER_FALLBACK"
        fi
    fi

    if ! check_jq_install; then
        return 1
    fi

    return 0
}

function check_jq_install ()
{
    # Ensure a usable jq is present, installing or updating it if required.
    # Every jq call site in this script uses a bare "jq", so it must be on PATH.
    #
    # RETURN: 0 if jq is available and current, 1 if not

    local JQ_VERSION

    logMe "Ensuring that jq is installed..."

    if ! command -v jq >/dev/null 2>&1; then
        logMe "jq is missing. Attempting installation."

        if ! install_jq || ! command -v jq >/dev/null 2>&1; then
            logMe "ERROR: jq installation failed." >&2
            return 1
        fi
    fi

    # jq reports itself as "jq-1.8.2" -- strip the prefix before comparing

    JQ_VERSION=$(jq --version 2>/dev/null)
    JQ_VERSION="${JQ_VERSION#jq-}"

    if [[ -z "$JQ_VERSION" ]]; then
        logMe "ERROR: Unable to determine the installed jq version." >&2
        return 1
    fi

    if ! is-at-least "$MIN_JQ_REQUIRED_VERSION" "$JQ_VERSION"; then
        logMe "jq ${JQ_VERSION} is outdated. Attempting update."

        if ! install_jq; then
            logMe "ERROR: jq update failed." >&2
            return 1
        fi

        JQ_VERSION=$(jq --version 2>/dev/null)
        JQ_VERSION="${JQ_VERSION#jq-}"

        if ! is-at-least "$MIN_JQ_REQUIRED_VERSION" "$JQ_VERSION"; then
            logMe "ERROR: jq remains below the required version ${MIN_JQ_REQUIRED_VERSION}." >&2
            return 1
        fi
    fi

    logMe "jq version ${JQ_VERSION} is available."
    return 0
}

function install_jq ()
{
    # Install / update jq directly from the jqlang GitHub releases page, falling back to
    # the Jamf policy trigger if the download cannot be completed or verified.
    #
    # The published macOS jq binaries are ad-hoc (linker) signed with no Developer ID, so a
    # Team ID check is not possible the way it is for SwiftDialog. Each release does publish a
    # sha256sum.txt, so the download is verified against that instead.
    #
    # PARMS Expected: JQ_INSTALL_POLICY - policy trigger from Jamf (fallback only)
    #
    # RETURN: 0 on success, 1 on failure

    local ASSET_NAME TEMP_DIR RELEASE_JSON JQ_URL SHA_URL EXPECTED_SHA ACTUAL_SHA

    case "$(/usr/bin/uname -m)" in
        arm64)  ASSET_NAME="jq-macos-arm64" ;;
        x86_64) ASSET_NAME="jq-macos-amd64" ;;
        *)
            logMe "WARNING: Unrecognised architecture; falling back to Jamf policy for jq." >&2
            install_jq_from_jamf
            return $?
            ;;
    esac

    RELEASE_JSON=$(/usr/bin/curl -L --silent --fail "https://api.github.com/repos/jqlang/jq/releases/latest" 2>/dev/null)

    JQ_URL=$(printf '%s' "$RELEASE_JSON" | /usr/bin/awk -F '"' -v asset="$ASSET_NAME" '$0 ~ ("browser_download_url") && $4 ~ (asset "$") { print $4; exit }')
    SHA_URL=$(printf '%s' "$RELEASE_JSON" | /usr/bin/awk -F '"' '/browser_download_url/ && /sha256sum\.txt"/ { print $4; exit }')

    if [[ -z "$JQ_URL" || -z "$SHA_URL" ]]; then
        logMe "WARNING: Unable to determine the latest jq download URL; falling back to Jamf policy." >&2
        install_jq_from_jamf
        return $?
    fi

    TEMP_DIR=$(/usr/bin/mktemp -d "/private/tmp/${SCRIPT_NAME}.jq.XXXXXX") || {
        logMe "ERROR: Unable to create a temporary directory for the jq download." >&2
        return 1
    }

    logMe "Downloading jq from ${JQ_URL}"

    if ! /usr/bin/curl --location --silent --fail "$JQ_URL" -o "${TEMP_DIR}/jq" || \
       ! /usr/bin/curl --location --silent --fail "$SHA_URL" -o "${TEMP_DIR}/sha256sum.txt"; then
        logMe "WARNING: jq download failed; falling back to Jamf policy." >&2
        /bin/rm -Rf "$TEMP_DIR"
        install_jq_from_jamf
        return $?
    fi

    # Verify the download against the checksum published with the release

    EXPECTED_SHA=$(/usr/bin/awk -v asset="$ASSET_NAME" '$2 == asset { print $1; exit }' "${TEMP_DIR}/sha256sum.txt")
    ACTUAL_SHA=$(/usr/bin/shasum -a 256 "${TEMP_DIR}/jq" | /usr/bin/awk '{print $1}')

    if [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
        logMe "ERROR: jq checksum mismatch (expected '${EXPECTED_SHA}', got '${ACTUAL_SHA}'); not installing." >&2
        /bin/rm -Rf "$TEMP_DIR"
        install_jq_from_jamf
        return $?
    fi

    if ! /bin/mkdir -p "$(/usr/bin/dirname "$JQ_BINARY")"; then
        logMe "ERROR: Unable to create $(/usr/bin/dirname "$JQ_BINARY")" >&2
        /bin/rm -Rf "$TEMP_DIR"
        return 1
    fi

    if ! /bin/mv -f "${TEMP_DIR}/jq" "$JQ_BINARY"; then
        logMe "ERROR: Unable to install jq to ${JQ_BINARY}" >&2
        /bin/rm -Rf "$TEMP_DIR"
        return 1
    fi

    /usr/sbin/chown root:wheel "$JQ_BINARY" 2>/dev/null
    /bin/chmod 755 "$JQ_BINARY"
    /usr/bin/xattr -d com.apple.quarantine "$JQ_BINARY" 2>/dev/null

    /bin/rm -Rf "$TEMP_DIR"

    if ! "$JQ_BINARY" --version >/dev/null 2>&1; then
        logMe "ERROR: jq installed to ${JQ_BINARY} but will not execute." >&2
        return 1
    fi

    # zsh caches command lookups; clear it so the new binary is found on PATH

    rehash

    logMe "jq installed successfully to ${JQ_BINARY}."
    return 0
}

function install_jq_from_jamf ()
{
    # Fallback installer: use the Jamf policy trigger
    #
    # PARMS Expected: JQ_INSTALL_POLICY - policy trigger from Jamf
    #
    # RETURN: 0 if jq is on PATH afterwards, 1 if not

    [[ -x /usr/local/bin/jamf ]] || { logMe "ERROR: jamf binary not found; cannot install jq." >&2 ; return 1; }

    logMe "Attempting jq install via Jamf policy '${JQ_INSTALL_POLICY}'"
    /usr/local/bin/jamf policy -event "${JQ_INSTALL_POLICY}"

    rehash

    command -v jq >/dev/null 2>&1 || { logMe "ERROR: jq still missing after Jamf policy run." >&2 ; return 1; }
    return 0
}

function make_temp_files ()
{
    
    JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog JSON file" >&2
        return 1
    }

    DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX") || {
        logMe "ERROR: Unable to create SwiftDialog command file" >&2
        return 1
    }

    TMP_FILE_STORAGE=$(mktemp "/var/tmp/${SCRIPT_NAME}_storage.XXXXX") || {
        logMe "ERROR: Unable to create temporary storage file" >&2
        return 1
    }

    RESULTS_DIR=$(mktemp -d "/var/tmp/${SCRIPT_NAME}_results.XXXXX") || {
        logMe "ERROR: Unable to create results counter directory" >&2
        return 1
    }

    chmod 700 "$RESULTS_DIR" || {
    logMe "ERROR: Unable to secure results counter directory" >&2
    return 1
    }

    CSV_LOCK_DIR="/var/tmp/${SCRIPT_NAME}.${MAIN_PID}.csv.lock"
    DIALOG_LOCK_DIR="/var/tmp/${SCRIPT_NAME}.${MAIN_PID}.dialog.lock"

    if ! /usr/sbin/chown "$USER_UID" \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"
    then
        logMe "ERROR: Unable to set temporary dialog-file ownership" >&2
        return 1
    fi

    if ! chmod 600 \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE"
    then
        logMe "ERROR: Unable to secure temporary dialog files" >&2
        return 1
    fi

    if ! /usr/sbin/chown root:wheel "$TMP_FILE_STORAGE"; then
        logMe "ERROR: Unable to set temporary storage ownership" >&2
        return 1
    fi

    if ! chmod 600 "$TMP_FILE_STORAGE"; then
        logMe "ERROR: Unable to secure temporary storage file" >&2
        return 1
    fi

    return 0
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

    Jamf_LOGGED_IN_USER="${Jamf_PARAMETER_USER:-$LOGGED_IN_USER}"
    SD_FIRST_NAME="${(C)${Jamf_LOGGED_IN_USER%%.*}}"

    CSV_PATH="${USER_DIR}/Desktop/DDM Data Dump for "
    DDM_CROSS_REF_FILE="${USER_DIR}/Documents/DDMCrossRef.csv"

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
	SD_INFO_BOX_MSG+="${MACOS_NAME} ${MACOS_VERSION}<br>"
}

function cleanup_files ()
{
    # Perform a clean-up on all of the temp files that were created at run-time
    (( ZSH_SUBSHELL == 0 )) || return 0
    [[ "$$" == "$MAIN_PID" ]] || return 0
    local file

    for file in \
        "$JSON_DIALOG_BLOB" \
        "$DIALOG_COMMAND_FILE" \
        "$TMP_FILE_STORAGE"
    do
        [[ -n "$file" && -e "$file" ]] && rm -f -- "$file"
    done

    [[ -n "$RESULTS_DIR" && -d "$RESULTS_DIR" ]] && rm -rf -- "$RESULTS_DIR"
    [[ -n "$CSV_LOCK_DIR" && -d "$CSV_LOCK_DIR" ]] && rmdir "$CSV_LOCK_DIR" 2>/dev/null
    [[ -n "$DIALOG_LOCK_DIR" && -d "$DIALOG_LOCK_DIR" ]] && rmdir "$DIALOG_LOCK_DIR" 2>/dev/null
}

function cleanup_and_exit ()
{
    local exit_code="${1:-0}"

    trap - EXIT
    cleanup_files
    exit "$exit_code"
}

trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM
trap 'cleanup_files' EXIT

function check_for_sudo ()
{
	# Ensures that script is run as ROOT
    if ! admin_user; then
        print -u2 "ERROR: ${SCRIPT_NAME} must be run as root."
		cleanup_and_exit 1
	fi
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
    # the GLOB :l converts any incoming parameter into lowercase

    
    case "${1:l}" in
 
        "create" )
            # Remove commands from any previous progress dialog.
            if ! : > "$DIALOG_COMMAND_FILE"; then
                logMe "ERROR: Unable to reset SwiftDialog command file" >&2
                return 1
            fi

            DIALOG_PROCESS=""
            if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
                logMe "ERROR: Constructed SwiftDialog JSON is invalid" >&2
                return 1
            fi
            "$SW_DIALOG" --progress --jsonfile "$JSON_DIALOG_BLOB" --commandfile "$DIALOG_COMMAND_FILE" &

            DIALOG_PROCESS=$!

            if [[ -z "$DIALOG_PROCESS" ]]; then
                logMe "ERROR: Unable to capture the SwiftDialog process ID" >&2
                return 1
            fi

            return 0
            ;;
     
        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            dialog_cmd "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" 
            ;;

        "buttonaction" )

            # Change button 1 action
            dialog_cmd 'button1action: "'${2}'"'
            ;;
  
        "buttonchange" )

            # change text of button 1
            dialog_cmd "button1text: ${2}"
            ;;

        "buttondisable" )

            # disable button 1
            dialog_cmd "button1: disable"
            ;;

        "buttonenable" )

            # Enable button 1
            dialog_cmd "button1: enable"
            ;;

        "update" | "change" )

            #
            # Increment the progress bar by ${2} amount
            #

            # change the list item status and increment the progress bar

            dialog_cmd "listitem: title: ${3}, status: ${5}, statustext: ${4}"
            [[ -n "$6" ]] && dialog_cmd "progress: ${6}"
            ;;

  
        "clear" )
  
            # Clear the list and show an optional message  
            dialog_cmd "list: clear"
            dialog_cmd "message: ${2}"
            ;;
  
        "delete" )
  
            # Delete item from list  
            dialog_cmd "listitem: delete, title: ${2}"
            ;;
 
        "destroy" )
     
            # Kill the progress bar and clean up
            dialog_cmd "quit:"
            ;;
 
        "done" )
          
            # Complete the progress bar and clean up  
            dialog_cmd "progress: complete"
            dialog_cmd "progresstext: $5"
            ;;
          
        "icon" )
  
            # set / clear the icon, pass <nil> if you want to clear the icon  
            [[ -z ${2} ]] && dialog_cmd "icon: none" || dialog_cmd "icon: ${2}"
            ;;
  
  
        "image" )
  
            # Display an image and show an optional message  
            dialog_cmd "image: ${2}"
            [[ -n ${3} ]] && dialog_cmd "progresstext: $5"
            ;;
  
        "infobox" )
  
            # Show text message  
            dialog_cmd "infobox: ${2}"
            ;;

        "infotext" )
  
            # Show text message  
            dialog_cmd "infotext: ${2}"
            ;;
  
        "show" )
  
            # Activate the dialog box
            dialog_cmd "activate:"
            ;;
  
        "title" )
  
            # Set / Clear the title, pass <nil> to clear the title
            [[ -z ${2} ]] && dialog_cmd "title: none:" || dialog_cmd "title: ${2}"
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            dialog_cmd "progress: ${6}"
            dialog_cmd "progresstext: ${5}"
            ;;
  
    esac
}

function construct_dialog_header_settings ()
{
    # Construct the basic Swift Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Window variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "message" : "'$1'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "subtitledetail" : "'${BANNER_SUBTITLE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : true,
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1,color='${BANNER_TEXT_COLOR}',offset='${BANNER_TEXT_PADDING}'",
        "button1text" : "OK",
        "button2text" : "Cancel",
        "infotext": "'$SCRIPT_VERSION'",
        "height" : 700,
        "width" : 900,
        "moveable" : true,
        "resizeable" : true,
        "json" : true,
        "quitkey" : "0",
        "messageposition" : "top",'
}

function create_listitem_list ()
{
    # PURPOSE: Create the display list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined

    local xml_blob
    local line

    if ! construct_dialog_header_settings "$1" > "$JSON_DIALOG_BLOB"; then
        logMe "ERROR: Unable to initialize SwiftDialog JSON" >&2
        return 1
    fi

    if ! create_listitem_message_body "" "" "" "" "first"; then
        return 1
    fi

    if [[ "${2:l}" == "json" ]]; then
        # Parse the JSON data using jq and extract the relevant information
        if ! xml_blob=$(printf '%s' "$4" | jq -r "$3"); then
            logMe "ERROR: Unable to parse list-item JSON" >&2
            return 1
        fi
    else
        # Parse the XML data using xmllint and extract the relevant information
        if ! xml_blob=$(printf '%s' "$4" | xmllint --xpath "//$3" - 2>/dev/null); then
            logMe "ERROR: Unable to parse list-item XML" >&2
            return 1
        fi
    fi

    while IFS= read -r line; do
        line="${${line#*<name>}%</name>*}"
        line="${line%%[[:space:]]#}"

        if ! create_listitem_message_body "$line" "$5" "pending" "Pending..."; then
            return 1
        fi
    done <<< "$xml_blob"

    if ! create_listitem_message_body "" "" "" "" "last"; then
        return 1
    fi

    if ! update_display_list "Create"; then
        return 1
    fi

    return 0
}

function create_listitem_message_body ()
{
    if [[ "${5:l}" == "first" ]]; then
        printf '%s\n' '"button1disabled":true,"listitem":[' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ "${5:l}" == "last" ]]; then
        sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']}' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    [[ -z "$1" ]] && return 0

    if ! jq -cn --arg title "$1" --arg icon "$2" --arg status "$3" --arg statustext "$4" \
        '{
            title: $title,
            icon: $icon,
            status: $status,
            statustext: $statustext
        }' |
        sed '$s/$/,/' >> "$JSON_DIALOG_BLOB"
    then
        logMe "ERROR: Unable to append list item for ${1}" >&2
        return 1
    fi
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
    #        $3 - default option
    #        $4 - first or last - construct appropriate listitem headers / footers

    local line && line=""

    [[ "$4:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2'], "default" : "'$3'"},'
    if [[ "${4:l}" == "last" ]]; then
        sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']' >> "$JSON_DIALOG_BLOB"
        return 0
    fi
    printf '%s\n' "$line" >> "$JSON_DIALOG_BLOB"
}

function construct_dropdown_list_items ()
{
    local input_json="$1"
    local jq_path="$2"
    local line
    local -a values=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        values+=("$(jq -Rn --arg value "$line" '$value')")
    done < <(printf '%s' "$input_json" | jq -r "${jq_path} | \"\\(.id) - \\(.name)\"")

    printf '%s' "${(j:,:)values}"
}

function create_checkbox_message_body ()
{
    # PURPOSE: Construct a checkbox style body of the dialog box
    #"checkbox" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - name (internal reference)
    #        $3 - icon
    #        $4 - Default Checked (true/false)
    #        $5 - disabled (true/false)
    #        $6 - first or last - construct appropriate listitem headers / footers
    local line=""

    if [[ "${6:l}" == "first" ]]; then
        printf '%s\n' '"checkbox" : [' >> "$JSON_DIALOG_BLOB"
        return 0
    fi

    if [[ -n "$1" ]]; then
        printf '%s\n' '{"name":"'"$2"'","label":"'"$1"'","icon":"'"$3"'","checked":'"${4:-false}"',"disabled":'"${5:-false}"'},' >> "$JSON_DIALOG_BLOB"
    fi

    if [[ "${6:l}" == "last" ]]; then
        sed -i '' -e '$ s/,$//' "$JSON_DIALOG_BLOB"
        printf '%s\n' ']' >> "$JSON_DIALOG_BLOB"
    fi
}

function display_failure_message ()
{
     MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --message "**Problems retrieving Jamf Info**<br><br>Error Message: $1"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?

}

function dialog_cmd ()
{
    # Serialize SwiftDialog command-file writes from background workers.
    local command="$1"
    local attempts=0

    while ! mkdir "$DIALOG_LOCK_DIR" 2>/dev/null; do
        sleep 0.02
        (( attempts++ ))

        if (( attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for dialog command lock" >&2
            return 1
        fi
    done

    {
        if ! printf '%s\n' "$command" >> "$DIALOG_COMMAND_FILE"; then
            logMe "ERROR: Unable to write SwiftDialog command: $command" >&2
            return 1
        fi
    } always {
        rmdir "$DIALOG_LOCK_DIR" 2>/dev/null
    }

    return 0
}

###########################
#
# Jamf functions
#
###########################

function Jamf_check_credentials ()
{
    if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
        logMe "ERROR: Client ID or secret is missing." >&2
        return 1
    fi

    logMe "Valid credentials passed."
    return 0
}

function Jamf_check_connection ()
{
    # PURPOSE: Function to check connectivity to the Jamf Pro server
    # RETURN: None
    # EXPECTED: None

    # The jamf binary only ever checks the server this Mac is enrolled with, so it can
    # answer for us only when that is also the server we are about to query.

    if [[ "$JAMF_URL_SOURCE" == "enrolled" ]]; then

        if ! /usr/local/bin/jamf -checkjssconnection -retry 5; then
            logMe "Error: JSS connection not active."
            return 1
        fi

        logMe "JSS connection active!"
        return 0
    fi

    local http_status

    http_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "${jamfpro_url}/api/v1/jamf-pro-version" 2>/dev/null)

    # 401 is a healthy answer here -- the endpoint requires a token we do not have yet

    if [[ "$http_status" == "200" || "$http_status" == "401" ]]; then
        logMe "Jamf Pro server at ${jamfpro_url} is reachable."
        return 0
    fi

    logMe "ERROR: No Jamf Pro server responded at ${jamfpro_url} (HTTP ${http_status:-none})." >&2
    return 1
}

function normalize_jamf_url ()
{
    # Tidy up a URL that may have been typed or pasted by hand.
    #
    # PARMS Expected: $1 - the URL to clean up
    #
    # RETURN: prints the normalised URL, 1 if it is not usable

    setopt localoptions extendedglob

    local url="$1"

    # Trim surrounding whitespace only -- internal spaces mean it is not a URL at all

    url="${url##[[:space:]]#}"
    url="${url%%[[:space:]]#}"

    [[ -n "$url" ]] || return 1

    # A bare hostname is the usual shorthand, so assume https rather than rejecting it

    [[ "$url" == (http://*|https://*) ]] || url="https://${url}"

    url="${url%%\?*}"
    url="${url%%\#*}"

    while [[ "$url" == */ ]]; do
        url="${url%/}"
    done

    [[ "$url" =~ '^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/.*)?$' ]] || return 1

    print -r -- "$url"
    return 0
}

function prompt_for_jamf_url ()
{
    # Last resort when nothing else supplies a URL and the Mac is not enrolled.
    #
    # RETURN: prints the URL entered, 1 if cancelled or left blank

    local dialog_output buttonpress url

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext "$SCRIPT_VERSION"
        --message "**Jamf Pro server**<br><br>This Mac is not enrolled with a Jamf Pro server and no Jamf Pro URL has been configured.<br><br>Enter the URL of the server you want to query."
        --messagefont name=Arial,size=17
        --textfield "Jamf Pro URL",name=JamfURL,required,prompt="your-instance.jamfcloud.com"
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 340
        --json
        --moveable
    )

    dialog_output=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$?

    if (( buttonpress != 0 )); then
        logMe "Jamf Pro URL prompt cancelled by the user." >&2
        return 1
    fi

    url=$(jq -r '.JamfURL // empty' <<< "$dialog_output")

    [[ -n "$url" ]] || { logMe "ERROR: No Jamf Pro URL was entered." >&2 ; return 1 ; }

    print -r -- "$url"
    return 0
}

function Jamf_get_server ()
{
    # Work out which Jamf Pro server to query. An explicit setting beats the server this
    # Mac happens to be enrolled with, so the script is not tied to one instance.
    #
    # PARMS Expected: JAMF_URL_PARAMETER (script parameter 6), JAMF_PRO_URL (env / managed pref)
    #
    # RETURN: 0 with jamfpro_url and JAMF_URL_SOURCE set, 1 if no usable URL was found

    local candidate

    JAMF_URL_SOURCE="override"

    if [[ -n "$JAMF_URL_PARAMETER" ]]; then

        candidate="$JAMF_URL_PARAMETER"
        logMe "Using the Jamf Pro URL passed as script parameter 6."

    elif [[ -n "$JAMF_PRO_URL" ]]; then

        candidate="$JAMF_PRO_URL"
        logMe "Using the configured Jamf Pro URL."

    elif candidate=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url 2>/dev/null) && [[ -n "$candidate" ]]; then

        JAMF_URL_SOURCE="enrolled"
        logMe "Using the Jamf Pro URL this Mac is enrolled with."

    else

        logMe "No Jamf Pro URL is configured and this Mac is not enrolled."

        candidate=$(prompt_for_jamf_url) || return 1
    fi

    if ! jamfpro_url=$(normalize_jamf_url "$candidate"); then
        logMe "ERROR: '${candidate}' is not a usable Jamf Pro URL." >&2
        return 1
    fi

    logMe "Jamf Pro server is: $jamfpro_url"
    return 0
}

function Jamf_get_classic_api_token ()
{
    local response_file
    local http_status
    local curl_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create Classic token response file" >&2
        return 1
    }

    {
        http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' -X POST -u "${CLIENT_ID}:${CLIENT_SECRET}" -H "Accept: application/json" "${jamfpro_url}/api/v1/auth/token")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Classic token request failed, curl exit ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: Classic token request returned HTTP ${http_status}" >&2
            return 1
        fi

        if ! jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Classic token response was not valid JSON" >&2
            return 1
        fi

        if ! token=$(jq -er '.token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: Classic response did not contain a bearer token" >&2
            return 1
        fi

        api_token="$token"
        logMe "Classic bearer token successfully obtained."
        return 0

    } always {
        rm -f -- "$response_file"
    }
}

function Jamf_validate_token () 
{
     # Verify that API authentication is using a valid token by running an API command
     # which displays the authorization details associated with the current API user. 
     # The API call will only return the HTTP status code.

    local http_status
    http_status=$(curl -sS --write-out '%{http_code}' --output /dev/null --request GET --header "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth") || return 1
    [[ "$http_status" == "200" ]]
}

function Jamf_get_access_token ()
{
    local response_file
    local http_status
    local curl_status
    local token

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.token.XXXXX") || {
        logMe "ERROR: Unable to create OAuth response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -X POST -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "client_id=${CLIENT_ID}" --data-urlencode "grant_type=client_credentials" --data-urlencode "client_secret=${CLIENT_SECRET}" "${jamfpro_url}/api/oauth/token")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: OAuth token request failed, curl exit ${curl_status}" >&2
            return 1
        fi

        if [[ "$http_status" != "200" ]]; then
            logMe "ERROR: OAuth token request returned HTTP ${http_status}" >&2
            return 1
        fi

        if ! jq -e . "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: OAuth token response was not valid JSON" >&2
            return 1
        fi

        if ! token=$(jq -er '.access_token | strings | select(length > 0)' "$response_file"); then
            logMe "ERROR: OAuth response did not contain an access token" >&2
            return 1
        fi

        api_token="$token"
        logMe "OAuth access token successfully obtained."
        return 0
    } always {
        rm -f -- "$response_file"
    }
}

function Jamf_invalidate_token ()
{
    local returnval
    local curl_status

    if [[ -z "$api_token" ]]; then
        logMe "INFO: No Jamf token is available to invalidate."
        return 0
    fi
    returnval=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${api_token}" -X POST "${jamfpro_url}/api/v1/auth/invalidate-token")
    curl_status=$?

    if (( curl_status != 0 )); then
        logMe "ERROR: Token invalidation failed, curl exit ${curl_status}" >&2
        api_token=""
        return 1
    fi

    case "$returnval" in
        204)
            logMe "Token successfully invalidated"
            ;;

        401)
            logMe "Token already invalid"
            ;;

        *)
            logMe "ERROR: Unexpected token invalidation response: HTTP ${returnval}" >&2
            api_token=""
            return 1
            ;;
    esac

    api_token=""
    return 0
}

function Jamf_retrieve_data_blob ()
{
    local endpoint="$1"
    local format="${2:-xml}"
    local jq_filter="${3:-}"
    local response_file
    local http_status
    local curl_status

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/${format}" "${jamfpro_url%/}/${endpoint}")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving ${endpoint}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if [[ "$format" == "json" ]]; then
                    if ! jq -e . "$response_file" >/dev/null 2>&1; then
                        logMe "ERROR: Invalid JSON returned by ${endpoint}" >&2
                        cat "$response_file" >&2
                        return 1
                    fi

                    if [[ -n "$jq_filter" ]]; then
                        if ! jq "$jq_filter" "$response_file"; then
                            logMe "ERROR: Unable to apply jq filter to ${endpoint}: ${jq_filter}" >&2
                            return 1
                        fi
                    else
                        cat "$response_file"
                    fi
                else
                    cat "$response_file"
                fi
                ;;

            401)
                logMe "ERROR: Authentication failed retrieving ${endpoint}, HTTP 401" >&2
                cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege retrieving ${endpoint}, HTTP 403" >&2
                cat "$response_file" >&2
                return 1
                ;;

            404)
                logMe "ERROR: Resource not found: ${endpoint}, HTTP 404" >&2
                cat "$response_file" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response for ${endpoint}, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
    } always {
        rm -f -- "$response_file"
        }
}

function Jamf_get_bulk_inventory_record ()
{
    # PURPOSE: Uses the Jamf modern API to retrieve inventory info
    # NOTE: You can change the JAMF_INVENTORY_PAGE_SIZE to control how many results are return in a single API call.
    #       This can be adjusted to suit your environment / performance results
    # RETURN: JSON blob of inventory records
    # PARMS:  None
    # EXPECTED: jamfpro_url, api_token

    local results
    local results_count
    local line
    local response_file
    local http_status
    local curl_status
    local JAMF_API_KEY="api/v3/computers-inventory"
    local page=0
    local first_item=true

    "$SW_DIALOG" --notification --style banner --identifier "inventory" --title "Retrieving Jamf Inventory Records" --message "Please be patient" --button1text "Dismiss" >/dev/null 2>&1

    printf '[\n' > "$TMP_FILE_STORAGE" || {
        logMe "ERROR: Unable to initialize inventory storage file" >&2
        return 1
    }

    while :; do
        response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.inventory.XXXXX") || {
            logMe "ERROR: Unable to create inventory response file" >&2
            return 1
        }

        {
            http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
            "${jamfpro_url}/${JAMF_API_KEY}?page=${page}&page-size=${JAMF_INVENTORY_PAGE_SIZE}")
            curl_status=$?

            if (( curl_status != 0 )); then
                logMe "ERROR: Inventory page ${page} failed, curl exit ${curl_status}" >&2
                return 1
            fi

            if [[ "$http_status" != "200" ]]; then
                logMe "ERROR: Inventory page ${page} returned HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
            fi

            if ! jq -e '.results | arrays' "$response_file" >/dev/null 2>&1; then
                logMe "ERROR: Invalid inventory response on page ${page}" >&2
                return 1
            fi

            results=$(<"$response_file")
        } always {
            rm -f -- "$response_file"
        }

        results_count=$(jq -r '.results | length' <<< "$results") || {
            logMe "ERROR: Unable to count inventory page ${page}" >&2
            return 1
        }

        (( results_count == 0 )) && break

        while IFS= read -r line; do
            if [[ "$first_item" == true ]]; then
                printf '  %s\n' "$line" >> "$TMP_FILE_STORAGE"
                first_item=false
            else
                printf '  ,%s\n' "$line" >> "$TMP_FILE_STORAGE"
            fi
        done < <(jq -c '.results[] | {id: .id, name: .general.name, managementId: .general.managementId}' <<< "$results")

        (( page++ ))
    done

    printf ']\n' >> "$TMP_FILE_STORAGE"

    if ! jq -e 'arrays' "$TMP_FILE_STORAGE" >/dev/null 2>&1; then
        logMe "ERROR: Constructed inventory data is not valid JSON" >&2
        return 1
    fi

    cat "$TMP_FILE_STORAGE"
}

function Jamf_get_deviceID ()
{
    local search_type="$1"
    local search_value="$2"
    local jq_filter="$3"
    local type
    local response_file
    local http_status
    local curl_status
    local total
    local id

    case "$search_type" in
        "Hostname")         type="general.name" ;;
        "Serial Number")    type="hardware.serialNumber" ;;
        *)
            display_failure_message "Unsupported search type: ${search_type}"
            logMe "ERROR: Unsupported device search type: ${search_type}" >&2
            return 1
            ;;
    esac

    if [[ -z "$search_value" ]]; then
        display_failure_message "A device name or serial number was not provided."
        return 1
    fi

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.device.XXXXX") || {
        logMe "ERROR: Unable to create device lookup response file" >&2
        return 1
        }

    {
        local escaped_search_value

        escaped_search_value="${search_value//\\/\\\\}"
        escaped_search_value="${escaped_search_value//\'/\\\'}"

        http_status=$(curl -sS -L -o "$response_file" -w '%{http_code}' --get -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" \
            --data-urlencode "section=GENERAL" --data-urlencode "filter=${type}=='${escaped_search_value}'" "${jamfpro_url%/}/api/v3/computers-inventory")

        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: Device lookup failed, curl exit ${curl_status}" >&2
            display_failure_message "Failed to contact Jamf Pro."
            return 1
        fi

        case "$http_status" in
            200)
                ;;

            400)
                logMe "ERROR: Jamf rejected the device lookup filter, HTTP 400" >&2
                cat "$response_file" >&2
                display_failure_message "Jamf rejected the device search criteria."
                return 1
                ;;

            401)
                logMe "ERROR: Device lookup authentication failed, HTTP 401" >&2
                display_failure_message "Jamf authentication failed."
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege for device lookup, HTTP 403" >&2
                display_failure_message "The API client cannot read computer inventory."
                return 1
                ;;

            *)
                logMe "ERROR: Device lookup returned HTTP ${http_status}" >&2
                cat "$response_file" >&2
                display_failure_message "Jamf returned HTTP ${http_status}."
                return 1
                ;;
        esac

        if ! jq -e '(.totalCount | numbers) and (.results | arrays)' "$response_file" >/dev/null 2>&1; then
            logMe "ERROR: Invalid device lookup JSON structure" >&2
            display_failure_message "Jamf returned an invalid inventory response."
            return 1
        fi

        if ! total=$(jq -er '.totalCount' "$response_file"); then
            logMe "ERROR: Unable to read totalCount from device lookup" >&2
            display_failure_message "Unable to parse the Jamf inventory response."
            return 1
        fi

        if (( total == 0 )); then
            logMe "INFO: No inventory record found for ${search_value}"
            display_failure_message "Inventory record '${search_value}' was not found."
            return 1
        fi

        if (( total > 1 )); then
            logMe "ERROR: Multiple inventory records matched ${search_value}" >&2
            display_failure_message "More than one inventory record matched '${search_value}'."
            return 1
        fi

        if ! id=$(jq -er "$jq_filter // empty" "$response_file"); then
            logMe "ERROR: Matching device did not contain a management ID" >&2
            display_failure_message "The matching inventory record did not contain a management ID."
            return 1
        fi

        if [[ -z "$id" || "$id" == "null" ]]; then
            logMe "ERROR: Empty management ID returned for ${search_value}" >&2
            display_failure_message "The matching inventory record did not contain a management ID."
            return 1
        fi

        printf '%s\n' "$id"
        return 0

    } always {
        rm -f -- "$response_file"
    }
}

function Jamf_get_DDM_info ()
{
    # PURPOSE: Retrieve DDM status items using the management ID.
    # RETURN:
    #   0 and JSON on stdout when successful
    #   1 on API, HTTP, or transport failure
    # PARMS:
    #   $1 - Management ID

    local management_id="$1"
    local response_file
    local http_status
    local curl_status

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary DDM response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url%/}/api/v1/ddm/${management_id}/status-items")
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed retrieving DDM data for management ID ${management_id}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            200)
                if ! jq -e . "$response_file" >/dev/null 2>&1; then
                    logMe "ERROR: Jamf returned invalid JSON for management ID ${management_id}" >&2
                    cat "$response_file" >&2
                    return 1
                fi

                cat "$response_file"
                return 0
                ;;

            401)
                logMe "ERROR: Jamf authentication failed retrieving DDM data, HTTP 401" >&2
                cat "$response_file" >&2
                return 41
                ;;

            403)
                logMe "ERROR: Insufficient privilege to retrieve DDM data, HTTP 403" >&2
                cat "$response_file" >&2
                return 43
                ;;

            404)
                printf 'INFO: DDM %s not found. Is DDM enabled on that Mac?\n' "$management_id" >&2
                return 44
                ;;

            *)
                logMe "ERROR: Unexpected Jamf response, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
        } always {
           rm -f "$response_file"
        }
}

function Jamf_force_ddm_sync ()
{
    # PURPOSE: Request a DDM status sync for a management ID.
    # RETURN:
    #   0 for HTTP 204
    #   1 for transport or HTTP failure
    # PARMS:
    #   $1 - Management ID

    local management_id="$1"
    local response_file
    local http_status
    local curl_status

    response_file=$(mktemp "/var/tmp/${SCRIPT_NAME}.response.XXXXX") || {
        logMe "ERROR: Unable to create temporary DDM sync response file" >&2
        return 1
    }

    {
        http_status=$(curl -s -S -L -o "$response_file" -w '%{http_code}' -X 'POST' -H "Authorization: Bearer ${api_token}" -H "accept: */*" "${jamfpro_url%/}/api/v1/ddm/${management_id}/sync" -d '')
        curl_status=$?

        if (( curl_status != 0 )); then
            logMe "ERROR: curl failed sending DDM sync for management ID ${management_id}, exit code ${curl_status}" >&2
            return 1
        fi

        case "$http_status" in
            204)
                logMe "DDM sync successfully requested for management ID ${management_id}"
                return 0
                ;;

            400)
                logMe "ERROR: Jamf rejected the DDM sync request, HTTP 400" >&2
                cat "$response_file" >&2
                return 1
                ;;

            401)
                logMe "ERROR: Jamf authentication failed sending DDM sync, HTTP 401" >&2
                cat "$response_file" >&2
                return 1
                ;;

            403)
                logMe "ERROR: Insufficient privilege to send DDM sync, HTTP 403" >&2
                cat "$response_file" >&2
                return 1
                ;;

            404)
                logMe "ERROR: DDM client ${management_id} was not found, HTTP 404" >&2
                return 1
                ;;

            500)
                logMe "ERROR: Jamf server error sending DDM sync, HTTP 500" >&2
                cat "$response_file" >&2
                return 1
                ;;

            *)
                logMe "ERROR: Unexpected Jamf DDM sync response, HTTP ${http_status}" >&2
                cat "$response_file" >&2
                return 1
                ;;
        esac
    } always {
        rm -f "$response_file"
    }
}

function Jamf_retrieve_ddm_blueprint_statuses ()
{
    # PURPOSE:
    #   Retrieve and classify Blueprint UUIDs found in the
    #   management.declarations.configurations status value.
    #
    # NOTES:
    #   Jamf appends values such as:
    #     _s1_c1_sys_cfg1
    #     _s2_c1_sys_cfg8
    #     _s2_c1_sys_act9
    #
    #   Only the embedded UUID is retained.
    #
    # RETURN:
    #   0 - Parsing completed
    #   1 - Unable to extract the configuration value
    local json="$1"
    local value_str
    local blueprintID
    local record

    DDMBlueprintSuccess=()
    DDMBlueprintInactive=()
    DDMBlueprintInvalid=()
    DDMBlueprintFailed=()

    if ! value_str=$(printf '%s' "$json" | jq -r '.value // empty'); then
        logMe "WARNING: Unable to extract blueprint configuration value" >&2
        return 1
    fi

    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        blueprintID=$(printf '%s\n' "$record" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)

        [[ -z "$blueprintID" ]] && continue
        blueprintID="${blueprintID:l}"

        # These are intentionally independent tests.
        # One blueprint can have multiple state indicators.

        if [[ "$record" == *"status=failed"* ]]; then
            DDMBlueprintFailed+=("$blueprintID")
        fi

        if [[ "$record" == *"valid=invalid"* ]]; then
            DDMBlueprintInvalid+=("$blueprintID")
        fi

        if [[ "$record" == *"active=true"* ]]; then
            DDMBlueprintSuccess+=("$blueprintID")
        fi

        if [[ "$record" == *"active=false"* ]] ||
            [[ "$record" == *"valid=unknown"* ]]
        then
            DDMBlueprintInactive+=("$blueprintID")
        fi

    done < <(printf '%s' "$value_str" | tr '{}' '\n' )
    return 0
}

function Jamf_retrieve_ddm_softwareupdate_info () 
{
    # PURPOSE: extract the DDM Software update info from the computer record
    # RETURN: array of the DDM software update information
    # PARMS: $1 - DDM JSON blob of the computer
    local results
    results=$(jq -r '[.statusItems[]? | select(.key | startswith("softwareupdate.pending-version.")) | select(.value != null) | (.key | ltrimstr("softwareupdate.pending-version.")) + ":" + (.value | tostring)] +
        [.statusItems[]? | select(.key | startswith("softwareupdate.install-")) | .value] | join("\n")' <<< "$1")
    DDMSoftwareUpdateActive=("${(f)results}")
}

function Jamf_retrieve_ddm_softwareupdate_failures ()
{
    # PURPOSE: Extract the Software Updates failures from the system
    local input_json="$1"
    local results

    DDMSoftwareUpdateFailures=()

    if ! jq -e . >/dev/null 2>&1 <<< "$input_json"; then
        logMe "WARNING: Invalid DDM JSON while parsing software update failures" >&2
        return 1
    fi

    results=$(jq -r '.statusItems[]? | select((.key | type == "string") and (.key | startswith("softwareupdate.failure-reason.")) and (.value != null))
            | "\(.key | ltrimstr("softwareupdate.failure-reason.")):\(.value)" ' <<< "$input_json") || return 1

    [[ -n "$results" ]] && DDMSoftwareUpdateFailures=("${(@f)results}")
    return 0
}

function Jamf_retrieve_ddm_blueprint_invalid_reason ()
{
    local json="$1"
    local value_str
    local results

    DDMBlueprintInvalidReason=()

    if ! value_str=$(printf '%s' "$json" | jq -er '.value // empty'); then
        return 0
    fi

    results=$(printf '%s\n' "$value_str" | tr '{}' '\n' | sed -nE 's/.*Error=([^}]+).*/\1/p')
    [[ -n "$results" ]] && DDMBlueprintInvalidReason=("${(@f)results}")
    return 0
}

function Jamf_retrieve_ddm_keys ()
{
    local input_json="$1"
    local requested_key="$2"

    printf '%s' "$input_json" | jq -r --arg requested_key "$requested_key" '.statusItems[]? | select(.key == $requested_key)'
}

function Jamf_which_self_service ()
{
    # PURPOSE: Function to see which Self service to use (SS / SS+)
    # RETURN: None
    # EXPECTED: None
    local retval=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>&1)
    [[ $retval == *"does not exist"* || -z $retval ]] && retval=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path)
    printf '%s\n' "$retval"
}

###########################
#
# Application functions
#
###########################


function welcomemsg ()
{
    helpmessageurl="https://support.apple.com/guide/deployment/intro-to-declarative-device-management-depb1bab77f8/web"
    helpmessage="Apple's Declarative Device Management (DDM) is a modern, autonomous management framework that allows Apple devices (iOS, iPadOS, macOS) to proactively apply settings, enforce security policies, and report status changes without constant,"
    helpmessage+="synchronous polling from an MDM server. It enhances performance and scalability by enabling devices to act independently based on predefined, locally stored declarations.<br><br>"
    helpmessage+="Apple's official documentation:<br><br>"$helpmessageurl

    message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}, You can choose to search all of your computers for a Blueprint ID, a single computer's Declarative Device Management (DDM) status, or a smart/static group "
    message+="for each computer's DDM status.<br><br>After your selection, another menu will appear with more options."

    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext "$SCRIPT_VERSION"
        --message "$message"
        --messagefont name=Arial,size=17
        --selecttitle "DDM Action (Read / Sync):",radio --selectvalues "Scan Blueprint ID, View Single System, Scan Smart/Static Group, Force Sync Single System, Populate Cross Reference File"
        --helpmessage "$helpmessage"
        --helpimage "qr="$helpmessageurl
        --button1text "Continue"
        --button2text "Quit"
        --ontop
        --height 480
        --json
        --moveable
    )

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" ) #)2>/dev/null )

    buttonpress=$?
    case "$buttonpress" in
        0)
            if ! DDMOption=$(printf '%s' "$message" | plutil -extract SelectedOption raw - 2>/dev/null); then
                logMe "ERROR: Unable to parse the selected DDM action" >&2
                DDMOption="quit"
            fi
            ;;

        2)
            DDMOption="quit"
            ;;

        *)
            logMe "WARNING: Welcome dialog exited with code ${buttonpress}" >&2
            DDMOption="quit"
            ;;
    esac
    logMe "${DDMOption} was chosen"
}

function execute_in_parallel ()
{
    # PURPOSE: Execute items in parallel for faster processing
    local process_type="$1"
    shift

    local -a ids=("$@")
    local -a worker_pids=()
    local ID
    local pid
    local completed_pid
    local numberOfComputers=${#ids[@]}
    local completed_count=0
    local progress=0
    local worker_failures=0

    (( numberOfComputers == 0 )) && return 0

    for ID in "${ids[@]}"; do
        if [[ "$process_type" == "blueprint" ]]; then
            process_blueprint_computer "$ID" &
        else
            process_group_computer "$ID" &
        fi

        worker_pids+=("$!")
        # Record the worker PIDs so we know when everything is done
        if (( ${#worker_pids[@]} >= BACKGROUND_TASKS )); then
            completed_pid="${worker_pids[1]}"

            if ! wait "$completed_pid"; then
                (( worker_failures++ ))
            fi

            worker_pids[1]=()

            (( completed_count++ ))
            progress=$(( completed_count * 100 / numberOfComputers ))

            update_display_list "progress" "" "" "" "Processed ${completed_count} of ${numberOfComputers}" "$progress"
        fi
    done

    # Wait for all of the work PIDs to finish
    for pid in "${worker_pids[@]}"; do
        if ! wait "$pid"; then
            (( worker_failures++ ))
        fi

        (( completed_count++ ))
        progress=$(( completed_count * 100 / numberOfComputers ))

        update_display_list "progress" "" "" "" "Processed ${completed_count} of ${numberOfComputers}" "$progress"
    done

    # If something failed, then record it
    if (( worker_failures > 0 )); then
        logMe "WARNING: ${worker_failures} background worker(s) failed" >&2
        return 1
    fi

    return 0
}

function initialize_csv_file ()
{
    local file="$1"

    if ! : > "$file"; then
        logMe "ERROR: Unable to create CSV file: ${file}" >&2
        return 1
    fi

    if ! /usr/sbin/chown root:wheel "$file"; then
        logMe "ERROR: Unable to set temporary CSV ownership: ${file}" >&2
        return 1
    fi

    if ! chmod 600 "$file"; then
        logMe "ERROR: Unable to secure CSV file: ${file}" >&2
        return 1
    fi

    if ! printf '%s\n' "$CSV_HEADER" > "$file"; then
        logMe "ERROR: Unable to write CSV header: ${file}" >&2
        return 1
    fi

    return 0
}

function csv_escape ()
{
    local value="$1"

    value=${value//$'\r'/ }
    value=${value//$'\n'/\\n}
    value=${value//\"/\"\"}

    printf '"%s"' "$value"
}

function append_csv_row ()
{
    # PURPOSE:
    #   Construct, escape, lock, and append one CSV record.
    #
    # PARAMETERS:
    #   $1  - System name
    #   $2  - Management ID
    #   $3  - Current OS
    #   $4  - Last update
    #   $5  - Status
    #   $6  - Failed Blueprint IDs
    #   $7  - Inactive Blueprint IDs
    #   $8 - Mixed Blueprint IDs
    #   $9 - Inactive reason
    #   $10 - Invalid Blueprint IDs
    #   $11 - Invalid reason
    #   $12 - Software update failures
    #
    # RETURN:
    #   0 - Record written
    #   1 - Lock or write failure

    local attempts=0
    local csv_line

    if (( $# != 12 )); then
        logMe "ERROR: append_csv_row expected 12 fields but received $#" >&2
        return 1
    fi

    csv_line="$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
        "$(csv_escape "$1")" \
        "$(csv_escape "$2")" \
        "$(csv_escape "$3")" \
        "$(csv_escape "$4")" \
        "$(csv_escape "$5")" \
        "$(csv_escape "$6")" \
        "$(csv_escape "$7")" \
        "$(csv_escape "$8")" \
        "$(csv_escape "$9")" \
        "$(csv_escape "${10}")" \
        "$(csv_escape "${11}")" \
        "$(csv_escape "${12}")")"

    while ! mkdir "$CSV_LOCK_DIR" 2>/dev/null; do
        sleep 0.02
        (( attempts++ ))

        if (( attempts >= 500 )); then
            logMe "ERROR: Timed out waiting for CSV lock" >&2
            return 1
        fi
    done

    {
        if ! printf '%s\n' "$csv_line" >> "$CSV_OUTPUT"; then
            logMe "ERROR: Unable to append CSV record for: $1" >&2
            return 1
        fi
    } always {
        rmdir "$CSV_LOCK_DIR" 2>/dev/null
    }

    return 0
}

function sanitize_filenames ()
{
    local value="$1"

    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\//-}"
    value="${value//:/-}"
    value="${value//../.}"
    value="${value##[[:space:]]#}"
    value="${value%%[[:space:]]#}"

    [[ -n "$value" ]] || value="Unnamed"

    printf '%s' "${value[1,150]}"
}

function set_file_ownership ()
{
    local file="$1"
    [[ -f "$file" ]] || return 1
    /usr/sbin/chown "${USER_UID}" "$file" || {logMe "ERROR: Unable to assign ${file} to ${LOGGED_IN_USER}"; return 1;}
    chmod 600 "$file" || {logMe "ERROR: Unable to secure ${file}"; return 1;}
}

function get_result_count ()
{
    local -a result_files

    [[ -d "$RESULTS_DIR" ]] || {
        printf '0'
        return 0
    }

    result_files=("$RESULTS_DIR"/*(N))
    printf '%d' "${#result_files[@]}"
}

function reset_result_count ()
{
    local -a result_files

    if [[ ! -d "$RESULTS_DIR" ]]; then
        logMe "ERROR: Results directory is unavailable" >&2
        return 1
    fi

    result_files=("$RESULTS_DIR"/*(N))

    if (( ${#result_files[@]} > 0 )); then
        rm -f -- "${result_files[@]}" || {
            logMe "ERROR: Unable to reset result counter" >&2
            return 1
        }
    fi

    return 0
}

###########################
#
# Populate Cross Reference functions
#
##########################

function welcomemsg_crossreference ()
{
    DDMCrossRef=$(read_crossref_file)

    message="**Populate Cross Reference File**<br><br>Jamf does not support viewing of Blueprints by Name. Follow the below instructions to create a cross reference file"
    message+=" that will display the name of the Blueprint with the ID:<br><br>"
    message+="1.  Enter just the blueprint ID and the name of your blueprint separated by a comma<br>"
    message+="    _ex: 8bb536f0-140a-44e5-8e88-fe88523e9742,OS | Sequoia | Minor | Update_<br>"
    message+="2.  Make sure to put a return at the end of each line.<br>"
    message+="3.  The file will be saved here: **$DDM_CROSS_REF_FILE**<br>"
    message+="4.  The Blueprint Name will be included when possible in tasks & reports.<br>"
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext "$SCRIPT_VERSION"
        --message "$message"
        --messagefont name=Arial,size=17
        --textfield "DDM Cross Reference,editor",value="$DDMCrossRef",name=crossref
        --button1text "Continue"
        --button2text "Cancel"
        --width 950
        --height 720
        --moveable
    )
    retval=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    [[ $buttonpress -eq 0 ]] && write_crossref_file "$retval"

}

function read_crossref_file ()
{
    local CSV_CONTENT
    if [[ ! -f "$DDM_CROSS_REF_FILE" ]]; then
        logMe "INFO: Cross-reference file does not exist yet; starting with an empty editor." >&2
        printf ''
    return 0
    fi
    # Read file, replace newlines with spaces to maintain single-line# then remove trailing spaces.
    CSV_CONTENT=$(cat "$DDM_CROSS_REF_FILE") # | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    logMe "File '$DDM_CROSS_REF_FILE' loaded into the editor" 1>&2
    printf '%s\n' "$CSV_CONTENT"
}

function write_crossref_file ()
{
    local input_data="$1"
    local clean_string
    local clean_line
    local line
    clean_string="${input_data#crossref : }"
    # Initialize the file
    if ! : > "$DDM_CROSS_REF_FILE"; then
        logMe "ERROR: Unable to create cross-reference file: $DDM_CROSS_REF_FILE" >&2
        display_failure_message "Unable to create the Blueprint cross-reference file."
        return 1
    fi
    if ! /usr/sbin/chown "$USER_UID" "$DDM_CROSS_REF_FILE"
    then
        logMe "WARNING: Unable to assign cross-reference file ownership to ${LOGGED_IN_USER}" >&2
    fi
    if ! chmod 600 "$DDM_CROSS_REF_FILE"; then
        logMe "WARNING: Unable to secure permissions on ${DDM_CROSS_REF_FILE}" >&2
    fi
    # Write each nonempty entry as an LF-terminated line.
    for line in "${(f)clean_string}"; do
        clean_line=$(printf '%s\n' "$line")
        if [[ -n "$clean_line" ]]; then
            printf '%s\n' "$clean_line" >> "$DDM_CROSS_REF_FILE"
        fi
    done
    logMe "Contents written out to: $DDM_CROSS_REF_FILE" 1>&2
}

function crossref_lookup ()
{
    local -a target_list=("$@")
    reply=()
    local uuid name rest item line
    local -A xref
    [[ -f "$DDM_CROSS_REF_FILE" ]] || { echo "File not found: $DDM_CROSS_REF_FILE"; return 1; }

    # Read CSV lines; split on first comma only
    while IFS= read -r line; do
        [[ -z $line ]] && continue

        uuid=${line%%,*}
        rest=${line#*,}
        name=${rest%%,*}   # keep only field 2; ignore extra columns

        # trim leading/trailing whitespace
        uuid=${uuid##[[:space:]]#}; uuid=${uuid%%[[:space:]]#}
        name=${name##[[:space:]]#}; name=${name%%[[:space:]]#}

        [[ -n $uuid ]] && xref[$uuid]=$name
    done < "$DDM_CROSS_REF_FILE"

    # export results
    for item in "${target_list[@]}"; do
        if [[ -n ${xref[$item]-} ]]; then
            reply+=("$item (${xref[$item]})")
        else
            reply+=("$item")
        fi
    done
}

###########################
#
# Blueprint functions
#
##########################

function array_contains ()
{
    # PURPOSE: Scan an array for a "key" match
    local match="$1"
    shift

    local item
    for item in "$@"; do
        [[ "$item" == "$match" ]] && return 0
    done
    return 1
}

function welcomemsg_blueprint ()
{
    message="**View DDM info from Blueprints**<br><br>You have selected to view information from a Blueprint ID.  Please paste the entire URL of your Jamf blueprint, and all systems "
    message+="will be scanned for the existence of the blueprint (regardless of status).<br><br>*NOTE: If you choose to export the data to a CSV file, it will be created to show the data with more details.*"
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext "$SCRIPT_VERSION"
        --message "$message"
        --messagefont name=Arial,size=17
        --vieworder "textfield,dropdown"
        --selecttitle "CSV results" --selectvalues "Everything, Failed Only, Invalid Only, Active Only, Inactive Only, Mixed Only, Not Found Only" --selectdefault "Everything"
        --textfield "Blueprint URL",name=BPUrl,required
        --textfield "Blueprint Name (optional)",name=BPName
        --checkbox "Export CSV file",name="exportCSV"
        --checkbox "Display only matching systems",name="filterDisplay"
        --checkboxstyle switch
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )

    buttonpress=$?

    case "$buttonpress" in
        0)
            ;;

        2)
            logMe "Blueprint scan canceled by the user."
            return 0
            ;;

        *)
            logMe "WARNING: Blueprint dialog exited with code ${buttonpress}" >&2
            return 1
            ;;
    esac
    local blueprint_url

    blueprint_url=$(jq -r '.BPUrl // empty' <<< "$message")
    blueprint_url="${blueprint_url%%\?*}"
    blueprint_url="${blueprint_url%%\#*}"
    blueprint_url="${blueprint_url%/}"
    blueprintID="${blueprint_url##*/}"

    if [[ -z "$blueprintID" ]]; then
        display_failure_message "A valid Blueprint URL or Blueprint ID was not provided."
        return 1
    fi
    if [[ ! "$blueprintID" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]]; then
        display_failure_message "A valid Blueprint UUID was not provided."
        return 1
    fi
    blueprintID="${blueprintID:l}"
    writeCSVFile=$(printf '%s' "$message" | jq -r '.exportCSV // false')
    blueprintName=$(printf '%s' "$message" | jq -r '.BPName // empty')
    displayResults=$(printf '%s' "$message" | jq -r '."CSV results".selectedValue // "Everything"')
    filterDisplay=$(printf '%s' "$message" | jq -r '.filterDisplay // false')
    process_blueprint "$blueprintID"
}

function process_blueprint ()
{
    # PURPOSE: Display the blueprint screen and get options from the user
    # RETURN: None
    # EXPECTED: None

    # zsh uses dynamic scoping. This local blueprintID remains visible to
    # execute_in_parallel and the background worker functions called beneath it.
    local blueprintID="$1"
    local computerList
    local numberOfComputers
    local CSVfile
    local result_count
    local -a ids
    local ids_output

    if ! reset_result_count; then
        display_failure_message "Unable to initialize the results counter."
        return 1
    fi

    # Initialize CSV if needed    
    [[ -n $blueprintName ]] && CSVfile=$blueprintName || CSVfile=$blueprintID
    if [[ "$writeCSVFile" == true ]]; then
        local safe_csv_name
        safe_csv_name=$(sanitize_filenames "$CSVfile") || return 1
        CSV_OUTPUT="${CSV_PATH}${safe_csv_name} ($(sanitize_filenames "$displayResults")).csv"
        if ! initialize_csv_file "$CSV_OUTPUT"; then
            display_failure_message "Unable to create the CSV output file."
             return 1
        fi
        logMe "Creating file: $CSV_OUTPUT"
    fi

    logMe "Retrieving DDM Info for Blueprint: $CSVfile"

    # Read in the computer inventory for all systems, capture, the ID, name & managementID of each computer
    # by using the modern API with the inventory pagination method, we are going to use as little RAM as possible
    
    if ! computerList=$(Jamf_get_bulk_inventory_record); then
        display_failure_message "Unable to retrieve Jamf inventory records."
        return 1
    fi
    if ! numberOfComputers=$(jq -er 'arrays | length' <<< "$computerList"); then
        display_failure_message "Jamf returned an invalid computer list."
        return 1
    fi
    if (( numberOfComputers == 0 )); then
        logMe "INFO: Jamf returned no computers to scan."
        display_failure_message "Jamf returned no computers to scan."
        return 0
    fi
    logMe "INFO: There are $numberOfComputers Computers to scan for $CSVfile"

    if ! create_listitem_list "Displaying all systems that have Blueprint:<br>$CSVfile for ($displayResults)" "json" ".[].name" "$computerList" "SF=desktopcomputer.and.macbook"; then
        display_failure_message "Unable to create the Blueprint progress dialog."
        return 1
    fi
 
     # Get the list of IDs
     if ! ids_output=$(jq -er '.[] | .id | select(. != null)' <<< "$computerList"); then
        display_failure_message "Unable to extract computer IDs."
        return 1
    fi

    ids=("${(@f)ids_output}")

    if (( ${#ids[@]} != numberOfComputers )); then
        logMe "ERROR: Expected ${numberOfComputers} inventory IDs but extracted ${#ids[@]}" >&2
        display_failure_message "One or more inventory records did not contain a valid computer ID."
        return 1
    fi
    #ids=($(jq -r '.[].id' <<< "$computerList"))

    # Execute parallel tasks

    local parallel_status=0

    execute_in_parallel "blueprint" "${ids[@]}" || parallel_status=$?

    result_count=$(get_result_count)

    if (( parallel_status != 0 )); then
        logMe "WARNING: One or more blueprint workers failed" >&2

        update_display_list "progress" "" "" "" "Processed ${numberOfComputers} systems | Matching results: ${result_count} | Some workers failed" 100
    else
        update_display_list "progress" "" "" "" "Processed ${numberOfComputers} of ${numberOfComputers} | Matching results: ${result_count}" 100 
    fi

    # all done, so enable the button and wait for a keypress
    update_display_list "buttonenable"
    [[ -n "$DIALOG_PROCESS" ]] && wait "$DIALOG_PROCESS"
    if [[ "$writeCSVFile" == true && -n "$CSV_OUTPUT" && -f "$CSV_OUTPUT" ]]; then
        if ! set_file_ownership "$CSV_OUTPUT"; then
            logMe "WARNING: Unable to finalize ownership of ${CSV_OUTPUT}" >&2
        fi
    fi

}

function process_blueprint_computer () 
{
    # PURPOSE: perform the actual processing of each system, show the blueprint status for the requested type
    # RETURN: None
    # EXPECTED: None

    local JAMF_API_KEY2="api/v2/computers-inventory"
    local ID="$1"
    local statusmessage="BP Installed (Active)"
    local DDMDeviceCurrentOSName
    local sanitized_clean_swu=""
    local sanitized_bpfailed=""
    local sanitized_bpinactive=""
    local sanitized_bpinactive_reason=""
    local sanitized_bpinvalid=""
    local sanitized_bpinvalid_reason=""
    local sanitized_bpmixed=""
    local DDMInfo DDMKeys
    local JSONblob
    local name managementId lastUpdateTime canWrite liststatus
    local blueprintIsActive=false
    local blueprintIsInactive=false
    local blueprintIsInvalid=false
    local blueprintHasErrors=false
    local DDMInactiveReason
    local -aU DDMBlueprintMixed=()
    local mixed_item
    local -aU inactiveOnlyBlueprints=()
    local item
    liststatus="success"

    # Extract info from Computer Inventory

    if ! JSONblob=$(Jamf_retrieve_data_blob "$JAMF_API_KEY2/$ID?section=GENERAL" "json"); then
        logMe "ERROR: Unable to retrieve inventory record for computer ID ${ID}" >&2
        #update_display_list "Update" "" "$display_name" "Unable to retrieve inventory" "error"
        return 1
    fi

    if [[ -z "$JSONblob" ]]; then
        logMe "ERROR: Empty inventory response for computer ID ${ID}" >&2
        return 1
    fi

    # DDM works by using the Management ID to retrieve the DDM info, so we need to extract that from the inventory record first
    name=$(printf "%s" "$JSONblob" | jq -r '.general.name // empty')
    [[ -n "$name" ]] || name="Computer ID ${ID}"

    managementId=$(printf '%s' "$JSONblob" | jq -r '.general.managementId // empty')
    if [[ -z "$managementId" ]]; then
        logMe "ERROR: No management ID returned for ${name}" >&2
        update_display_list "Update" "" "$name" "Management ID unavailable" "error"
        return 1
    fi

    # Retrieve the DDM info for this computer using the Management ID
    DDMInfo=$(Jamf_get_DDM_info "$managementId")
    local ddm_status=$?

    case "$ddm_status" in
        0)
            ;;

        41)
            logMe "ERROR: Jamf authentication failed while retrieving DDM information for ${name}" >&2
            update_display_list "Update" "" "$name" "Jamf authentication failed" "error"
            return 1
            ;;

        43)
            logMe "ERROR: Insufficient privilege to retrieve DDM information for ${name}" >&2
            update_display_list "Update" "" "$name" "Insufficient API privilege" "error"
            return 1
            ;;

        44)
            logMe "INFO: DDM information was not found for ${name}"
            update_display_list "Update" "" "$name" "DDM may not be active" "error"
            return 0
            ;;

        *)
            logMe "ERROR: Unable to Retrieve DDM information for ${name} status ${ddm_status}" >&2
            update_display_list "Update" "" "$name" "Unable to retrieve DDM info" "error"
            return 1
            ;;
    esac

    # Extract the relevant DDM keys and information
    DDMKeys=$(jq -r '.statusItems[]? |  select(.key == "management.declarations.configurations")' <<< "$DDMInfo")
    lastUpdateTime=$(jq -r 'first(.statusItems[]? | select(.key == "softwareupdate.failure-reason.reason") | .lastUpdateTime) // "N/A"' <<< "$DDMInfo")
    DDMDeviceCurrentOSName=$(jq -r 'first(.statusItems[]? | select(.key == "device.operating-system.marketing-name") | .value) // "N/A"' <<< "$DDMInfo")

    if ! Jamf_retrieve_ddm_blueprint_statuses "$DDMKeys"; then
        logMe "ERROR: Unable to parse blueprint status for $name" >&2
        update_display_list "Update" "" "$name" "Unable to parse BP status" "error"
        return 1
    fi
    Jamf_retrieve_ddm_softwareupdate_failures "$DDMInfo"
    Jamf_retrieve_ddm_blueprint_invalid_reason "$DDMKeys"

    # Determine the status of the blueprint for this system, check for failed, then check for not found, then check for invalid.  If none of those, it is active.
    array_contains "$blueprintID" "${DDMBlueprintSuccess[@]}" && blueprintIsActive=true
    array_contains "$blueprintID" "${DDMBlueprintInactive[@]}" && blueprintIsInactive=true
    array_contains "$blueprintID" "${DDMBlueprintInvalid[@]}" && blueprintIsInvalid=true
    array_contains "$blueprintID" "${DDMBlueprintFailed[@]}" && blueprintHasErrors=true

    # Determine the displayed status.
    #
    # Precedence:
    #   1. Invalid
    #   2. Failed
    #   3. Active and Inactive
    #   4. Active
    #   5. Inactive
    #   6. Not found

    local blueprintClassification="BP Not Found"

    if [[ "$blueprintIsInvalid" == true ]]; then
        blueprintClassification="Invalid"
        liststatus="error"
        statusmessage="BP Installed (Invalid)"

    elif [[ "$blueprintHasErrors" == true ]]; then
        blueprintClassification="Failed"
        liststatus="fail"
        statusmessage="BP Installed (Failed)"

    elif [[ "$blueprintIsActive" == true && "$blueprintIsInactive" == true ]]; then
        blueprintClassification="Mixed"
        liststatus="pending"
        statusmessage="BP Installed (Mixed)"

    elif [[ "$blueprintIsActive" == true ]]; then
        blueprintClassification="Active"
        liststatus="success"
        statusmessage="BP Installed (Active)"

    elif [[ "$blueprintIsInactive" == true ]]; then
        blueprintClassification="Inactive"
        liststatus="fail"
        statusmessage="BP Installed (Inactive)"

    else
        blueprintClassification="Not Found"
        liststatus="fail"
        statusmessage="BP not found"
    fi

    # See if it is in both Inactive and active...if so, then add it to the "mixed" array

    for mixed_item in "${DDMBlueprintSuccess[@]}"; do
        if array_contains "$mixed_item" "${DDMBlueprintInactive[@]}"; then
            DDMBlueprintMixed+=("$mixed_item")
        fi
    done

    # Eval criteria

    canWrite=false

    case "$displayResults" in
        "Everything")           canWrite=true ;;
        "Failed Only")          [[ "$blueprintClassification" == "Failed" ]] && canWrite=true ;;
        "Invalid Only")         [[ "$blueprintClassification" == "Invalid" ]] && canWrite=true ;;
        "Active Only")          [[ "$blueprintClassification" == "Active" ]] && canWrite=true ;;
        "Inactive Only")        [[ "$blueprintClassification" == "Inactive" ]] && canWrite=true ;;
        "Mixed Only")           [[ "$blueprintClassification" == "Mixed" ]] && canWrite=true ;;
        "Not Found Only")       [[ "$blueprintClassification" == "Not Found" ]] && canWrite=true ;;
        *)                      logMe "WARNING: Unknown blueprint display filter: $displayResults" >&2 ;;
    esac

    # Either show or delete the item based on the mainmenu options
    if [[ "$filterDisplay" == true && "$canWrite" != true ]]; then
        update_display_list "delete" "$name"
    else
        update_display_list "Update" "" "$name" "$statusmessage" "$liststatus"
    fi

    # Count every matching result, regardless of CSV export.
    if [[ "$canWrite" == true ]]; then
        if ! : > "${RESULTS_DIR}/${ID}"; then
        logMe "ERROR: Unable to record matching result for ${name}" >&2
        return 1
        fi
    fi

    # Early exit if we don't need to write out the CSV file
    if [[ "$writeCSVFile" != true ]]; then
        logMe "System: $name - ManagementID: $managementId - Status: $statusmessage"
        return 0
    else
        logMe "$statusmessage on system: $name"
    fi
    
    # Sanitize the output to be CSV save and then write it out
    if [[ "$canWrite"  == true ]]; then

        for item in "${DDMBlueprintInactive[@]}"; do
            if ! array_contains "$item" "${DDMBlueprintMixed[@]}"; then
                inactiveOnlyBlueprints+=("$item")
            fi
        done

        sanitized_bpinactive="${(j: | :)inactiveOnlyBlueprints}"
        sanitized_clean_swu="${(j: | :)DDMSoftwareUpdateFailures}"
        sanitized_bpfailed="${(j: | :)DDMBlueprintFailed}"
        sanitized_bpinvalid="${(j: | :)DDMBlueprintInvalid}"
        sanitized_bpinvalid_reason="${(j: | :)DDMBlueprintInvalidReason}"
        sanitized_bpmixed="${(j: | :)DDMBlueprintMixed}"

        if (( ${#inactiveOnlyBlueprints[@]} > 0 )); then
            DDMInactiveReason=$(printf '%s' "$DDMKeys" | perl -ne 'print "$1\n" if /code=([^},]+)/')
            [[ -n "$DDMInactiveReason" ]] || DDMInactiveReason="None"
            sanitized_bpinactive_reason="${DDMInactiveReason//,/;}"
        fi

        # Write out this info to the CSV file
        if ! append_csv_row "$name" "$managementId" "$DDMDeviceCurrentOSName" "$lastUpdateTime" "$blueprintClassification" "$sanitized_bpfailed" "$sanitized_bpinactive" "$sanitized_bpmixed" "$sanitized_bpinactive_reason" "$sanitized_bpinvalid" \
            "$sanitized_bpinvalid_reason" "$sanitized_clean_swu"; then
                logMe "ERROR: Failed writing CSV row for $name" >&2
                return 1
        fi
    fi
}

###########################
#
# View Individual computer functions
#
##########################

function welcomemsg_individual ()
{
    message="**View Individual System**<br><br>Please enter the serial or hostname of the device you wish to see the DDM information for.  The results for Software Updates, Active & Failed Blueprints, as well as any error messages will be displayed.<br><br>"
    message+="*NOTE: If you choose to export the data, a TXT file will be created at your chosen location.  Leave the TXT Folder location empty if you do not want to export data*."
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext "$SCRIPT_VERSION"
        --message "$message"
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --selecttitle "Search By,required"
        --textfield "TXT folder location,fileselect,filetype=folder,prompt=$CSV_PATH,name=writeTXTFile"
        --checkboxstyle switch
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    case "$buttonpress" in
        0)
            ;;

        2)
            logMe "Individual system lookup canceled by the user."
            return 0
            ;;

        *)
            logMe "WARNING: Individual-system dialog exited with code ${buttonpress}" >&2
            return 1
            ;;
    esac
    search_type=$(printf '%s' "$message" | jq -r '.SelectedOption')
    computer_id=$(printf '%s' "$message" | jq -r '.Device')
    writeTXTFile=$(printf '%s' "$message" | jq -r '.writeTXTFile // empty')
    process_individual "$search_type" "$computer_id" "View"
}

function process_individual ()
{
    local search_type=$1
    local computer_id=$2
    local action_type=$3
    local DDMInfo
    local DDMKeys
    local DDMDevicename
    local DDMDeviceModel
    local DDMDeviceCurrentOSBuild
    local DDMDeviceCurrentOSName
    local DDMDeviceSecurityCertificates
    local DDMBatteryHealth
    local DDMClientSupportedPayload
    local DDMClientSupportedVersions
    local message
    local logMessage
    local clean
    local active_display
    local failed_display
    local invalid_display
    local inactive_display
    local DDMInactiveReason="None"

    # First we have to get the Jamf ManagementID of the machine
    echo "Searching for $search_type: $computer_id"

    #ID=$(Jamf_get_deviceID "${search_type}" "${computer_id}" ".results[].general.managementId")
    local ID

    if ! ID=$(Jamf_get_deviceID "$search_type" "$computer_id" 'first(.results[]?.general.managementId)'); then
        logMe "ERROR: Unable to resolve management ID for ${computer_id}" >&2
        return 1
    fi

    if [[ -z "$ID" ]]; then
        logMe "ERROR: Device lookup returned an empty management ID for ${computer_id}" >&2
        display_failure_message "No management ID was returned for ${computer_id}."
        return 1
    fi

    # Second is to extract the DDM info for the machine
    DDMInfo=$(Jamf_get_DDM_info "$ID")
    local ddm_status=$?

    case "$ddm_status" in
        0)
            ;;

        41)
            logMe "ERROR: Jamf authentication failed while retrieving DDM information for ${computer_id}" >&2
            display_failure_message "Jamf authentication failed."
            return 1
            ;;

        43)
            logMe "ERROR: Insufficient privilege to retrieve DDM information for ${computer_id}" >&2
            display_failure_message "The API client does not have permission to retrieve DDM information."
            return 1
            ;;

        44)
            logMe "INFO: DDM information was not found for ${computer_id}"
            display_failure_message "No DDM information was found for ${computer_id}.<br><br>DDM may not be enabled on this Mac."
            return 1
            ;;

        *)
            logMe "ERROR: Unable to retrieve DDM information for ${computer_id}, status ${ddm_status}" >&2
            display_failure_message "Unable to retrieve DDM information for ${computer_id}."
            return 1
            ;;
    esac

    # Third, extract all the DDM info from this JSON blob

    DDMDevicename=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.model.marketing-name").value')
    DDMDeviceModel=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.model.identifier").value')
    DDMDeviceCurrentOSName=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.operating-system.marketing-name").value')
    DDMDeviceCurrentOSBuild=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.operating-system.build-version").value')
    DDMBatteryHealth=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "device.power.battery-health").value')
    DDMClientSupportedPayload=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "management.client-capabilities.supported-payloads.declarations.configurations").value' | tr ',' '\n')
    DDMDeviceSecurityCertificates=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "security.certificate.list").value')
    [[ -z $DDMDeviceSecurityCertificates ]] && DDMDeviceSecurityCertificates="None"
    DDMClientSupportedVersions=$(printf '%s' "$DDMInfo" | jq -r '.statusItems[]? |  select(.key == "management.client-capabilities.supported-versions").value')

    logMe "INFO: Device Name: $DDMDevicename"
    logMe "INFO: Device Model: $DDMDeviceModel"
    logMe "INFO: Current OS Name: $DDMDeviceCurrentOSName"
    logMe "INFO: Current OS Build: $DDMDeviceCurrentOSBuild"
    logMe "INFO: Battery Health: $DDMBatteryHealth"
    logMe "INFO: Client Supported Payloads: $DDMClientSupportedPayload"
    logMe "INFO: Security Certificates: $DDMDeviceSecurityCertificates"
    logMe "INFO: Client Supported Versions: $DDMClientSupportedVersions"

    # Fourth, extract the DDM Software Update info for the machine
    Jamf_retrieve_ddm_softwareupdate_info "$DDMInfo"
    logMe "INFO: Software Update Info: $DDMSoftwareUpdateActive"

    # Fifth, see if there are any software update failures
    Jamf_retrieve_ddm_softwareupdate_failures "${DDMInfo}"
    (( ${#DDMSoftwareUpdateFailures[@]} == 0 )) && DDMSoftwareUpdateFailures=("None")
    logMe "INFO: Software Update Failures: $DDMSoftwareUpdateFailures"

    # Sixth, extract the DDM blueprint IDs assigned to the machine
    DDMKeys=$(Jamf_retrieve_ddm_keys "$DDMInfo" "management.declarations.configurations")
    if ! Jamf_retrieve_ddm_blueprint_statuses "$DDMKeys"; then
        logMe "ERROR: Unable to parse blueprint status for $DDMDevicename" >&2
        return 1
    fi
    
    # For each of the following arrays, we will cross reference the blueprint ID with the cross reference file to get the name of the blueprint if it exists
    #
    # BlueprintSuccess
    # BlueprintFailed
    # BlueprintInvalid
    # BlueprintInactive
    if [[ -f "$DDM_CROSS_REF_FILE" ]]; then
        local item
        crossref_lookup "${DDMBlueprintSuccess[@]}"
        DDMBlueprintSuccess=("${reply[@]}")
        for item in "${DDMBlueprintSuccess[@]}"; do
            [[ -n "$item" ]] || continue
            logMe "INFO: Active Blueprint: $item"
        done

        crossref_lookup "${DDMBlueprintFailed[@]}"
        DDMBlueprintFailed=("${reply[@]}")
        for item in "${DDMBlueprintFailed[@]}"; do
            [[ -n "$item" ]] || continue
            logMe "INFO: Failed Blueprint: $item"
        done

        crossref_lookup "${DDMBlueprintInvalid[@]}"
        DDMBlueprintInvalid=("${reply[@]}")
        for item in "${DDMBlueprintInvalid[@]}"; do
            [[ -n "$item" ]] || continue
            logMe "INFO: Invalid Blueprint: $item"
        done

        crossref_lookup "${DDMBlueprintInactive[@]}"
        DDMBlueprintInactive=("${reply[@]}")
        for item in "${DDMBlueprintInactive[@]}"; do
            [[ -n "$item" ]] || continue
            logMe "INFO: Inactive Blueprint: $item"
        done
    fi

    if (( ${#DDMBlueprintSuccess[@]} > 0 )); then
        active_display="${(j:<br>:)DDMBlueprintSuccess}"
    else
        active_display="None"
    fi

    if (( ${#DDMBlueprintFailed[@]} > 0 )); then
        failed_display="${(j:<br>:)DDMBlueprintFailed}"
    else
        failed_display="None"
    fi

    if (( ${#DDMBlueprintInvalid[@]} > 0 )); then
        invalid_display="${(j:<br>:)DDMBlueprintInvalid}"
    else
        invalid_display="None"
    fi

    if (( ${#DDMBlueprintInactive[@]} > 0 )); then
        inactive_display="${(j:<br>:)DDMBlueprintInactive}"
        DDMInactiveReason=$(printf '%s' "$DDMKeys" | perl -ne 'print "$1\n" if /code=([^},]+)/')
        [[ -n "$DDMInactiveReason" ]] || DDMInactiveReason="None"

    else
        inactive_display="None"
    fi
    # Lastly, see if there are any invalid blueprints
    Jamf_retrieve_ddm_blueprint_invalid_reason "$DDMKeys"
    (( ${#DDMBlueprintInvalidReason[@]} == 0 )) && DDMBlueprintInvalidReason=("None")

    logMe "INFO: Invalid Blueprints: ${(j:; :)DDMBlueprintInvalid}"
    logMe "INFO: Invalid Blueprint Reasons: ${(j:; :)DDMBlueprintInvalidReason}"

    #Show the results and log it
    message="**Device name:** <br>$computer_id<br><br>**Jamf Management ID:**<br>$ID<br><br><br>"
    message+="**Device Info**<br>$DDMDevicename ($DDMDeviceModel)<br>Running: $DDMDeviceCurrentOSName ($DDMDeviceCurrentOSBuild)<br>Battery Health: $DDMBatteryHealth<br>"
    message+="<br><br>**DDM Client Supported Version**<br>$DDMClientSupportedVersions"
    message+="<br><br>**DDM Blueprints Active**<br>${active_display}<br>"
    message+="<br><br>**DDM Blueprints Failed**<br>${failed_display}<br>"
    message+="<br><br>**DDM Blueprint Inactive**<br>${inactive_display}<br>"
    message+="<br><br>**DDM Blueprint Inactive Reason**<br>$DDMInactiveReason<br>"
    message+="<br><br>**DDM Blueprint Invalid**<br>${invalid_display}<br>"
    message+="<br><br>**DDM Blueprint Invalid Reason**<br>${(j:<br>:)DDMBlueprintInvalidReason}<br>"
    message+="<br><br>**DDM Software Update Info**<br>${(j:<br>:)DDMSoftwareUpdateActive}<br>"
    message+="<br><br>**DDM Software Update Failures**<br>${(j:<br>:)DDMSoftwareUpdateFailures}<br>"
    message+="<br><br>**DDM Client Supported Payload**<br>$DDMClientSupportedPayload"
    message+="<br><br>**DDM Security Certificates**<br>$DDMDeviceSecurityCertificates"
    display_results "$message" "$ID" "$action_type" "$computer_id"
 
 
    if [[ -n "$writeTXTFile" ]]; then
        local safe_computer_name
        safe_computer_name=$(sanitize_filenames "$computer_id") || {
            logMe "ERROR: Unable to sanitize export filename for ${computer_id}" >&2
            return 1
        }

        CSV_OUTPUT="${writeTXTFile}/DDM Results for ${safe_computer_name}.txt"
        logMessage="${message//<br>/\\n}"
        clean="${logMessage//\*\*/--}"

        logMe "Export file: $CSV_OUTPUT"

        if ! /usr/bin/printf '%s\n' "$clean" > "$CSV_OUTPUT"; then
            logMe "ERROR: Unable to write TXT export: ${CSV_OUTPUT}" >&2
            return 1
        fi

        if ! set_file_ownership "$CSV_OUTPUT"; then
            logMe "WARNING: Unable to finalize ownership of ${CSV_OUTPUT}" >&2
            return 1
        fi
    fi
}

function display_results ()
{
    local message=$1
    local computer_id=$2
    local action_type=$3
    local ComputerName=$4
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --message "Here are the results of the DDM info for this mac:<br><br>$message"
        --messagefont name=Arial,size=14
        --helpmessage "Add this URL prefix to the Blueprint ID to find the Blueprint details<br>${jamfpro_url}/view/mfe/blueprints/"
        --button1text "OK"
        --ontop
        --width 900
        --height 750
        --moveable
    )

    [[ $extractRAWData == "true" ]] && MainDialogBody+=(--infotext "The CSV file will be stored in $USER_DIR/Desktop") || MainDialogBody+=(--infotext "$SCRIPT_VERSION")
    if [[ "$action_type" == "View" ]] && blueprint_links_available; then
        MainDialogBody+=(--button2text "Open BP Links")
    elif [[ "$action_type" == "Sync" ]]; then
        MainDialogBody+=(--button2text "Force Sync")
    fi

    "$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
    case "$buttonpress" in
        0)
            return 0
            ;;

        2)
            if [[ "$action_type" == "View" ]]; then
                open_blueprint_links
            elif [[ "$action_type" == "Sync" ]]; then
                logMe "Forcing DDM Sync on system: $computer_id"

                if Jamf_force_ddm_sync "$computer_id"; then
                    message="Sync command successful for system ${ComputerName} (${computer_id}).<br><br>The next time the system checks in, you can view the updated results."

                    "$SW_DIALOG" \
                        --message "$message" \
                        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}" \
                        --bannerimage "${SD_BANNER_IMAGE}" \
                        --bannertitle "${SD_WINDOW_TITLE}" \
                        --icon "${SD_ICON_FILE}" \
                        --overlayicon "${OVERLAY_ICON}" \
                        --ontop
                else
                    display_failure_message "The DDM sync request failed for ${ComputerName}."
                    return 1
                fi
            fi
            ;;

        *)
            logMe "WARNING: Results dialog exited with code ${buttonpress}" >&2
            return 1
            ;;
    esac
}

function blueprint_links_available ()
{
    local item

    for item in "${DDMBlueprintSuccess[@]}" "${DDMBlueprintFailed[@]}" "${DDMBlueprintInactive[@]}" "${DDMBlueprintInvalid[@]}"; do
        [[ -n "$item" && "$item" != "None" ]] && return 0
    done
    return 1
}

function open_blueprint_links ()
{
    local item
    local blueprint_id
    local -aU all_blueprints

    all_blueprints=("${DDMBlueprintSuccess[@]}" "${DDMBlueprintFailed[@]}" "${DDMBlueprintInactive[@]}" "${DDMBlueprintInvalid[@]}")

    for item in "${all_blueprints[@]}"; do
        [[ -n "$item" && "$item" != "None" ]] || continue

        blueprint_id="${item%% \(*}"
        [[ -n "$blueprint_id" ]] && open "${jamfpro_url%/}/view/mfe/blueprints/${blueprint_id}"
    done
}

###########################
#
# Smart/Static group functions
#
##########################

function welcomemsg_group ()
{
    # PURPOSE: Export Application Usage for a users / group
    # RETURN: None
    # EXPECTED: None
    local GroupList
    local xml_blob
    local -a array
    local JAMF_API_KEY="JSSResource/computergroups"

    message="**View DDM info from groups**<br><br>You have selected to view information from Smart/Static Groups.<br>Please select the group and display results from the options below:<br><br>"
    message+="*NOTE: If you choose to export the data to a CSV file, it will be created to show the data with more details.*"
    construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"

    # Read in the Jamf groups and create a dropdown list of them
    if ! tempArray=$(Jamf_retrieve_data_blob "$JAMF_API_KEY" "json"); then
        display_failure_message "Unable to retrieve the Jamf computer group list."
        return 1
    fi
    if ! GroupList=$(jq -c '.computer_groups // empty' <<< "$tempArray"); then
        display_failure_message "Unable to parse the Jamf computer group list."
        return 1
    fi

    if [[ -z "$GroupList" ]]; then
        display_failure_message "Jamf returned an empty computer group list."
        return 1
    fi
    create_dropdown_message_body "" "" "" "first"
    array=$(construct_dropdown_list_items "$GroupList" '.[]')
    create_dropdown_message_body "Select Groups:" "$array"


    create_dropdown_message_body "Display results" '"Everything", "Failed Only", "Inactive Only", "Mixed Only", "Invalid Only", "No Errors Only"' "Everything"
    create_dropdown_message_body "" "" "" "last"
    echo ',' >> "${JSON_DIALOG_BLOB}"
    create_checkbox_message_body "" "" "" "" "" "first"
    create_checkbox_message_body "Export all data to CSV File" "exportcsv" "" "true" "false"
    create_checkbox_message_body "Display only matching systems" "filterDisplay" "" "false" "false"
    create_checkbox_message_body "Include SW Update failures in CSV File" "includeSWUFail" "" "true" "false" "last"
    printf '%s\n' '}' >> "$JSON_DIALOG_BLOB"

    if ! jq -e . "$JSON_DIALOG_BLOB" >/dev/null 2>&1; then
        logMe "ERROR: Constructed group selection JSON is invalid" >&2
        display_failure_message "Unable to construct the group selection dialog."
        return 1
    fi
	message=$("$SW_DIALOG" --vieworder "dropdown, checkbox" --json --jsonfile "${JSON_DIALOG_BLOB}") 2>/dev/null
    buttonpress=$?
    case "$buttonpress" in
        0)
            ;;

        2)
            logMe "Group scan canceled by the user."
            return 0
            ;;

        *)
            logMe "WARNING: Group dialog exited with code ${buttonpress}" >&2
            return 1
            ;;
    esac

    #jamfGroup=$(printf '%s' "$message" | jq '."Select Groups:" .selectedValue')
    jamfGroup=$(printf '%s' "$message" | jq -r '."Select Groups:".selectedValue // empty')
    displayResults=$(printf '%s' "$message" | jq -r '."Display results".selectedValue // "Everything"')
    writeCSVFile=$(printf '%s' "$message" | jq -r '.exportcsv // false')
    includeSWUFail=$(printf '%s' "$message" | jq -r '.includeSWUFail // false')
    filterDisplay=$(printf '%s' "$message" | jq -r '.filterDisplay // false')
    if [[ -z "$jamfGroup" ]]; then
        display_failure_message "No Jamf computer group was selected."
        return 1
    fi
    process_group "$jamfGroup" "$displayResults"
}

function process_group ()
{
    local group_selection="${1//\"/}"
    local GroupID="${group_selection%% - *}"
    local GroupName="${group_selection#* - }"
    local JAMF_API_KEY="JSSResource/computergroups/id"
    local computerList
    local numberOfComputers
    local ids_output
    local -a ids
    local result_count
    local parallel_status=0
 
    if ! reset_result_count; then
        display_failure_message "Unable to initialize the results counter."
        return 1
    fi

    GroupID="${GroupID//[[:space:]]/}"

    if [[ "$writeCSVFile" == true ]]; then
        local safe_csv_name
        safe_csv_name=$(sanitize_filenames "$GroupName") || return 1
        CSV_OUTPUT="${CSV_PATH}${safe_csv_name} ($(sanitize_filenames "$displayResults")).csv"

        if ! initialize_csv_file "$CSV_OUTPUT"; then
            display_failure_message "Unable to create the CSV output file."
             return 1
        fi
        logMe "Creating file: $CSV_OUTPUT"
    fi

    logMe "Retrieving DDM Info for group: ${GroupName} (ID: ${GroupID})"

    if ! computerList=$(Jamf_retrieve_data_blob "${JAMF_API_KEY}/${GroupID}" "json"); then
        display_failure_message "Unable to retrieve group ${GroupName}."
        return 1
    fi

    if ! numberOfComputers=$(jq -er '.computer_group.computers | arrays | length' <<< "$computerList"); then
        display_failure_message "The selected group returned an invalid computer list."
        return 1
    fi

    if (( numberOfComputers == 0 )); then
        logMe "INFO: Group ${GroupName} contains no computers."
        display_failure_message "The selected group contains no computers."
        return 0
    fi

    if ! ids_output=$(jq -er '.computer_group.computers[] | .id | select(. != null)' <<< "$computerList"); then
        display_failure_message "Unable to extract computer IDs from ${GroupName}."
        return 1
    fi

    ids=("${(@f)ids_output}")

    if (( ${#ids[@]} != numberOfComputers )); then
        display_failure_message "One or more computers in ${GroupName} did not contain a valid ID."
        return 1
    fi

    logMe "INFO: There are ${numberOfComputers} computers in ${GroupName}"

    if ! create_listitem_list "Retrieving DDM Info from computers that are in group:<br> ${GroupName} ($displayResults)." \
        "json" ".computer_group.computers[].name" "$computerList" "SF=desktopcomputer.and.macbook"
    then
        display_failure_message "Unable to create the group progress dialog."
        return 1
    fi

    # Execute parallel tasks

    execute_in_parallel "group" "${ids[@]}" || parallel_status=$?

    result_count=$(get_result_count)

    if (( parallel_status != 0 )); then
        logMe "WARNING: One or more group workers failed" >&2
        update_display_list "progress" "" "" "" "Processed ${numberOfComputers} systems | Matching results: ${result_count} | Some workers failed" 100
    else
        update_display_list "progress" "" "" "" "Processed ${numberOfComputers} of ${numberOfComputers} | Matching results: ${result_count}" 100 
    fi

    update_display_list "buttonenable"

    [[ -n "$DIALOG_PROCESS" ]] && wait "$DIALOG_PROCESS"
    if [[ "$writeCSVFile" == true && -n "$CSV_OUTPUT" && -f "$CSV_OUTPUT" ]]; then
        if ! set_file_ownership "$CSV_OUTPUT"; then
            logMe "WARNING: Unable to finalize ownership of ${CSV_OUTPUT}" >&2
        fi
    fi

    return 0
}

function process_group_computer () 
{
    local JAMF_API_KEY2="api/v2/computers-inventory"
    local ID="$1"
    local statusmessage="No BP errors found"
    local DDMInfo
    local DDMKeys
    local sanitized_bpmixed=""
    local sanitized_clean_swu=""
    local sanitized_bpfailed=""
    local sanitized_bpinactive=""
    local sanitized_inactive_reason=""
    local sanitized_bpinvalid=""
    local sanitized_bpinvalid_reason=""
    local JSONblob
    local csvBlueprintStatus
    local canWrite=false
    local name managementId 
    local lastUpdateTime 
    local liststatus
    local DDMDeviceCurrentOSName
    local DDMInactiveReason
    local -aU DDMBlueprintMixed=()
    local -aU inactiveOnlyBlueprints=()
    local item
    liststatus="success"

    # Extract info from Computer Inventory

    if ! JSONblob=$(Jamf_retrieve_data_blob "$JAMF_API_KEY2/$ID?section=GENERAL" "json"); then
        logMe "ERROR: Unable to retrieve inventory record for computer ID ${ID}" >&2
        return 1
    fi

    if [[ -z "$JSONblob" ]]; then
        logMe "ERROR: Empty inventory response for computer ID ${ID}" >&2
        return 1
    fi

    name=$(printf "%s" "$JSONblob" | jq -r '.general.name // empty')
    [[ -n "$name" ]] || name="Computer ID ${ID}"

    managementId=$(printf '%s' "$JSONblob" | jq -r '.general.managementId // empty')

    if [[ -z "$managementId" ]]; then
        logMe "ERROR: No management ID returned for ${name}" >&2
        update_display_list "Update" "" "$name" "Management ID unavailable" "error"
        return 1
    fi

    DDMInfo=$(Jamf_get_DDM_info "$managementId")
    local ddm_status=$?

    case "$ddm_status" in
        0)
            ;;

        41)
            logMe "ERROR: Jamf authentication failed while retrieving DDM information for ${name}" >&2
            update_display_list "Update" "" "$name" "Jamf authentication failed" "error"
            return 1
            ;;

        43)
            logMe "ERROR: Insufficient privilege to retrieve DDM information for ${name}" >&2
            update_display_list "Update" "" "$name" "Insufficient API privilege" "error"
            return 1
            ;;

        44)
            logMe "INFO: DDM information was not found for ${name}"
            update_display_list "Update" "" "$name" "DDM may not be active" "error"
            return 0
            ;;

        *)
            logMe "ERROR: Unable to Retrieve DDM information for ${name} status ${ddm_status}" >&2
            update_display_list "Update" "" "$name" "Unable to retrieve DDM info" "error"
            return 1
            ;;
    esac
    DDMKeys=$(jq -r '.statusItems[]? |  select(.key == "management.declarations.configurations")' <<< "$DDMInfo")
    lastUpdateTime=$(jq -r 'first(.statusItems[]? | select(.key == "softwareupdate.failure-reason.reason") | .lastUpdateTime) // "N/A"' <<< "$DDMInfo")
    DDMDeviceCurrentOSName=$(jq -r 'first(.statusItems[]? | select(.key == "device.operating-system.marketing-name") | .value) // "N/A"' <<< "$DDMInfo")

    if ! Jamf_retrieve_ddm_blueprint_statuses "$DDMKeys"; then
        logMe "ERROR: Unable to parse blueprint status for $name" >&2
        update_display_list "Update" "" "$name" "Unable to parse BP status" "error"
        return 1
    fi
    Jamf_retrieve_ddm_softwareupdate_failures "$DDMInfo"
    Jamf_retrieve_ddm_blueprint_invalid_reason "$DDMKeys"

    # A Blueprint found in both Active and Inactive is Mixed.
 
    for item in "${DDMBlueprintSuccess[@]}"; do
        if array_contains "$item" "${DDMBlueprintInactive[@]}"; then
            DDMBlueprintMixed+=("$item")
        fi
    done
    

    # Build a separate array containing only truly inactive Blueprints.
    for item in "${DDMBlueprintInactive[@]}"; do
        if ! array_contains "$item" "${DDMBlueprintMixed[@]}"; then
            inactiveOnlyBlueprints+=("$item")
        fi
    done

    local -a status_parts=()

    (( ${#DDMBlueprintInvalid[@]} > 0 )) && status_parts+=("Invalid: ${#DDMBlueprintInvalid[@]}")
    (( ${#DDMBlueprintFailed[@]} > 0 )) && status_parts+=("Failed: ${#DDMBlueprintFailed[@]}")
    (( ${#DDMBlueprintMixed[@]} > 0 )) && status_parts+=("Mixed: ${#DDMBlueprintMixed[@]}")
    (( ${#inactiveOnlyBlueprints[@]} > 0 )) && status_parts+=("Inactive: ${#inactiveOnlyBlueprints[@]}")

    if (( ${#status_parts[@]} == 0 )); then
        liststatus="success"
        statusmessage="No BP errors found"
    else
        statusmessage="${(j:, :)status_parts}"
        if (( ${#DDMBlueprintInvalid[@]} > 0 )); then
            liststatus="error"
        elif (( ${#DDMBlueprintFailed[@]} > 0 )); then
            liststatus="fail"
        elif (( ${#inactiveOnlyBlueprints[@]} > 0 )); then
            liststatus="fail"
        else
            # Mixed-only is deployed, but contains mixed declaration states.
            liststatus="pending"
        fi
    fi

    # Eval criteria

    canWrite=false

    case "$displayResults" in
        "Failed Only")          (( ${#DDMBlueprintFailed[@]} > 0 )) && canWrite=true ;;
        "Inactive Only")        (( ${#inactiveOnlyBlueprints[@]} > 0 )) && canWrite=true ;;
        "Mixed Only")           (( ${#DDMBlueprintMixed[@]} > 0 )) && canWrite=true ;;
        "Invalid Only")         (( ${#DDMBlueprintInvalid[@]} > 0 )) && canWrite=true ;;
        "No Errors Only")
            if (( ${#DDMBlueprintFailed[@]} == 0 &&
                ${#DDMBlueprintInvalid[@]} == 0 &&
                ${#inactiveOnlyBlueprints[@]} == 0 &&
                ${#DDMBlueprintMixed[@]} == 0 ))
            then
                canWrite=true
            fi
            ;;
        "Everything")           canWrite=true ;;
        *)                      logMe "WARNING: Unknown group display filter: ${displayResults}" >&2 ;;
    esac
    # Either show or delete the item based on the selected criteria.

    if [[ "$filterDisplay" == true && "$canWrite" != true ]]; then
        update_display_list "delete" "$name"
    else
        update_display_list "Update" "" "$name" "$statusmessage" "$liststatus"
    fi

    logMe "$statusmessage on system: $name"

    # Count every matching result, regardless of CSV export.
    if [[ "$canWrite" == true ]]; then
        if ! : > "${RESULTS_DIR}/${ID}"; then
            logMe "ERROR: Unable to record matching result for ${name}" >&2
            return 1
        fi
    fi

    # Stop here when CSV export is not requested.
    if [[ "$writeCSVFile" != true ]]; then
        if [[ "$canWrite" == true ]]; then
            printf 'INFO: System: %s - ManagementID: %s - Status: %s\n' "$name" "$managementId" "$statusmessage"
        fi
        return 0
    fi

    [[ "$includeSWUFail" == false ]] && DDMSoftwareUpdateFailures=()

    sanitized_clean_swu="${(j: | :)DDMSoftwareUpdateFailures}"
    sanitized_bpfailed="${(j: | :)DDMBlueprintFailed}"
    sanitized_bpinactive="${(j: | :)inactiveOnlyBlueprints}"
    sanitized_bpinvalid="${(j: | :)DDMBlueprintInvalid}"
    sanitized_bpinvalid_reason="${(j: | :)DDMBlueprintInvalidReason}"
    sanitized_bpmixed="${(j: | :)DDMBlueprintMixed}"

    if (( ${#inactiveOnlyBlueprints[@]} > 0 )); then
        DDMInactiveReason=$(printf '%s' "$DDMKeys" | perl -ne 'print "$1\n" if /code=([^},]+)/' )
        [[ -n "$DDMInactiveReason" ]] || DDMInactiveReason="None"
        sanitized_inactive_reason="${DDMInactiveReason//,/;}"
    fi

    local -a csv_status_parts=()

    (( ${#DDMBlueprintInvalid[@]} > 0 )) && csv_status_parts+=("Invalid")
    (( ${#DDMBlueprintFailed[@]} > 0 )) && csv_status_parts+=("Failed")
    (( ${#DDMBlueprintMixed[@]} > 0 )) && csv_status_parts+=("Mixed")
    (( ${#inactiveOnlyBlueprints[@]} > 0 )) && csv_status_parts+=("Inactive")
    if (( ${#csv_status_parts[@]} == 0 )); then
        csvBlueprintStatus="No BP errors found"
    else
        csvBlueprintStatus="${(j:;:)csv_status_parts}"
    fi

    # Write out this info to the CSV file
    if [[ "$canWrite" == true ]]; then
        if ! append_csv_row "$name" "$managementId" "$DDMDeviceCurrentOSName" "$lastUpdateTime" "$csvBlueprintStatus" "$sanitized_bpfailed" "$sanitized_bpinactive" "$sanitized_bpmixed" "$sanitized_inactive_reason" "$sanitized_bpinvalid" \
        "$sanitized_bpinvalid_reason" "$sanitized_clean_swu"; then
            logMe "ERROR: Failed writing CSV row for $name" >&2
            return 1
        fi
    fi
}

###########################
#
# Force Sync functions
#
##########################

function welcomemsg_forcesync ()
{
    message="**Force Sync Individual System**<br><br>Please enter the serial or hostname of the device you wish to see the DDM information for.  The results for Software Updates, Active & Failed Blueprints, as well as any error messages will be displayed.<br><br>"
    message+="There will be an option to force sync DDM data to the machine on the next screen."
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1,color=${BANNER_TEXT_COLOR},offset=${BANNER_TEXT_PADDING}"
        --icon "${SD_ICON_FILE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --overlayicon "${OVERLAY_ICON}"
        --iconsize 128
        --infotext "$SCRIPT_VERSION"
        --message "$message"
        --messagefont name=Arial,size=17
        --vieworder "dropdown,textfield"
        --textfield "Device,required"
        --selecttitle "Search By,required"
        --checkboxstyle switch
        --selectvalues "Serial Number, Hostname"
        --selectdefault "Hostname"
        --button1text "Continue"
        --button2text "Cancel"
        --ontop
        --height 520
        --json
        --moveable
    )

    message=$("$SW_DIALOG" "${MainDialogBody[@]}" 2>/dev/null )
    buttonpress=$?
    case "$buttonpress" in
        0)
            ;;

        2)
            logMe "Force Sync lookup canceled by the user."
            return 0
            ;;

        *)
            logMe "WARNING: Force Sync dialog exited with code ${buttonpress}" >&2
            return 1
            ;;
    esac
    search_type=$(printf '%s' "$message" | jq -r '.SelectedOption')
    computer_id=$(printf '%s' "$message" | jq -r '.Device')
    process_individual "$search_type" "$computer_id" "Sync"
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload -Uz is-at-least
zmodload zsh/parameter

typeset -g api_token
typeset -g jamfpro_url
typeset -g computer_id
typeset -gaU DDMSoftwareUpdateActive
typeset -gaU DDMSoftwareUpdateFailures
typeset -gaU DDMBlueprintInactive
typeset -gaU DDMBlueprintSuccess
typeset -gaU DDMBlueprintInvalid
typeset -gaU DDMBlueprintFailed
typeset -gaU DDMBlueprintInvalidReason
typeset -g LOGGED_IN_USER=""
typeset -g USER_DIR=""
typeset -g USER_UID=""
typeset -g SD_FIRST_NAME=""
typeset -g JSON_DIALOG_BLOB=""
typeset -g DIALOG_COMMAND_FILE=""
typeset -g TMP_FILE_STORAGE=""
typeset -g CSV_LOCK_DIR=""
typeset -g DIALOG_LOCK_DIR=""
typeset -g DDM_CROSS_REF_FILE=""
typeset -g CSV_PATH=""
typeset -g Jamf_PARAMETER_USER="${3:-}"
typeset -g CLIENT_ID="${4:-}"
typeset -g CLIENT_SECRET="${5:-}"
typeset -g JAMF_URL_PARAMETER="${6:-}"
typeset -g JAMF_URL_SOURCE=""
typeset -g CSV_OUTPUT=""
typeset -g RESULTS_DIR=""
typeset -g blueprintID=""
typeset -g blueprintName=""
typeset -g displayResults=""
typeset -g filterDisplay=false
typeset -g includeSWUFail=false
typeset -g writeCSVFile=false
typeset -g writeTXTFile=""
typeset -ga reply=()

#typeset -g CSV_HEADER="System,ManagementID,Current OS,SW Update Failure Last Update,Status,Blueprint Failed IDs,Blueprint Inactive IDs,Inactive Reason,Blueprint Invalid IDs,Invalid Reason,Software Update Failures"
typeset -g CSV_HEADER="System,ManagementID,Current OS,SW Update Failure Last Update,Status,Blueprint Failed IDs,Blueprint Inactive IDs,Blueprint Mixed IDs,Inactive Reason,Blueprint Invalid IDs,Invalid Reason,Software Update Failures"

check_for_sudo

if ! initialize_user_context; then
    cleanup_and_exit 0
fi

if ! create_log_directory; then
    cleanup_and_exit 1
fi

if ! check_swift_dialog_install; then
    cleanup_and_exit 1
fi

if ! check_support_files; then
    cleanup_and_exit 1
fi

if ! make_temp_files; then
    cleanup_and_exit 1
fi

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic" #Determine with Jamf credentials we are using
create_infobox_message

# Resolve the server first -- the connection check needs to know what to test

if ! Jamf_get_server; then
    cleanup_and_exit 1
fi

if ! Jamf_check_connection; then
    cleanup_and_exit 1
fi

if ! Jamf_check_credentials; then
    cleanup_and_exit 1
fi
OVERLAY_ICON=$(Jamf_which_self_service)

# Show the welcome message and give the user some options
while true; do
    computer_id=""
    DDMOption=""
    message=""
    buttonpress=0

    blueprintID=""
    blueprintName=""
    displayResults=""
    filterDisplay=false
    includeSWUFail=false
    writeCSVFile=false
    writeTXTFile=""
    CSV_OUTPUT=""

    DDMSoftwareUpdateActive=()
    DDMSoftwareUpdateFailures=()
    DDMBlueprintInvalid=()
    DDMBlueprintInactive=()
    DDMBlueprintSuccess=()
    DDMBlueprintFailed=()
    DDMBlueprintInvalidReason=()

    welcomemsg
    [[ "$DDMOption" == "quit" ]] && cleanup_and_exit 0

    if [[ "$DDMOption" == *"Populate"* ]]; then
        welcomemsg_crossreference
        continue
    fi
    # Check if the Jamf Pro server is using the new API or the classic API
    # If the client ID is longer than 30 characters, then it is using the new API 
    case "$JAMF_TOKEN" in
        new)
            if ! Jamf_get_access_token; then
                display_failure_message "Unable to obtain a Jamf OAuth access token."
                continue
            fi
            ;;

        classic)
            if ! Jamf_get_classic_api_token; then
                display_failure_message "Unable to obtain a Jamf bearer token."
                continue
            fi
            ;;

        *)
            logMe "ERROR: Unknown Jamf authentication mode: ${JAMF_TOKEN}" >&2
            display_failure_message "The Jamf authentication mode is invalid."
            continue
            ;;
    esac

    typeset -i operation_status=0

    case "$DDMOption" in
        *"Force Sync"*)     welcomemsg_forcesync || operation_status=$? ;;
        *"View Single"*)    welcomemsg_individual || operation_status=$? ;;
        *"Group"*)          welcomemsg_group || operation_status=$? ;;
        *"Blueprint"*)      welcomemsg_blueprint || operation_status=$? ;;
        *)
            logMe "ERROR: Invalid option selected: ${DDMOption}" >&2
            cleanup_and_exit 1
            ;;
    esac

    if ! Jamf_invalidate_token; then
        logMe "WARNING: Unable to invalidate the Jamf token" >&2
    fi

    if (( operation_status != 0 )); then
        logMe "WARNING: Selected operation ended with status ${operation_status}" >&2
    fi
done
