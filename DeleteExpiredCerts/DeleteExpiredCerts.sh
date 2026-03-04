#!/bin/zsh
#
# DeleteExpiredCerts
#
# by: Scott Kendall
#
# Written: 03/03/2026
# Last updated: 03/03/2026
#
# Script Purpose: Remove any expired certificates from the current users mac, can be run in prompt or silent mode
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
SCRIPT_NAME="DeleteExpiredCerts"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
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
MIN_SD_REQUIRED_VERSION="2.5.0"
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
    SPACING=5 #5 spaces to accommodate for icon offset
fi
BANNER_TEXT_PADDING="${(j::)${(l:$SPACING:: :)}}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Delete Expired Certificates"
SD_ICON_FILE="/System/Applications/Utilities/Keychain access.app"

OVERLAY_ICON="SF=trash.fill,color=black"

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
JQ_FILE_INSTALL_POLICY="install_jq"

LOGIN_KEYCHAIN="$USER_DIR/Library/Keychains/login.keychain-db"
BACKUP_DIR="$USER_DIR/Desktop/Expired_Certs_Backup_$(date +%Y%m%d_%H%M%S)"
KEYCHAIN_CERTS=""
TOTAL_EXPIRED_CERTS=0
#EXCLUDE_PATTERNS=("Apple" "Root CA" "Self-Signed" "Intermediate")
EXCLUDE_PATTERNS=("Apple")

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"  
ACTION_MODE=${4:-"VERBOSE"}   #Verbose mode turned on by default 

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
    # PURPOSE: Make sure there is a logged in user
    # RETURN: None
    # EXPECTED: $LOGGED_IN_USER
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in, exiting"
        cleanup_and_exit 0
    else
        logMe "INFO: User $LOGGED_IN_USER is logged in"
    fi
}

function cleanup_and_exit ()
{
  [[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
  [[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
  [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
  exit $1
}

####################################################################################################
#
# Script Specific Functions
#
####################################################################################################

function welcomemsg ()
{
  local actionButton
  KEYCHAIN_CERTS=$(printf "**%-30s | %-12s | %s**<br><br>" "SHA-1 HASH" "EXPIRED ON" "SUBJECT/CN")
  parse_keychain "view"
  message="If you have any expired certificates in your keychain, they will be shown here.  If you choose to delete them, a backup of those certs will be made before deletion.<br><br>"
  message+=$KEYCHAIN_CERTS
  [[ $TOTAL_EXPIRED_CERTS == 0 ]] && actionButton="Done" || actionButton="Remove"

  MainDialogBody=(
    --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
    --messagefont size=16
    --titlefont shadow=1
    --icon "${SD_ICON_FILE}"
    --overlayicon "${OVERLAY_ICON}"
    --bannerimage "${SD_BANNER_IMAGE}"
    --bannertitle "${SD_WINDOW_TITLE}"
    --infobox "${SD_INFO_BOX_MSG}"
    --helpmessage ""
    --width 920
    --height 480
    --quitkey 0
    --button1text "$actionButton"
    --button2text "Cancel"
    --moveable
    --ontop
    --ignorednd
  )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

    temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ "$returnCode" == "2" ]] && cleanup_and_exit 0
    [[ $actionButton == "Remove" ]] && parse_keychain "delete"
}

function parse_keychain () 
{
    # PURPOSE: Read in the entire contents of the users keychain file and evaluate each cert
    # RETURN: None
    # PARAMS: $1 - "view" or "delete"
    # EXPECTED: $LOGIN_KEYCHAIN
    local mode="$1"
    local certs_with_hashes=$(security find-certificate -a -Z -p "$LOGIN_KEYCHAIN" 2>/dev/null)
    local current_pem="" current_hash=""

    echo "$certs_with_hashes" | while read -r line; do
      # Process each line coming in...
      if [[ "$line" =~ "^SHA-1 hash: " ]]; then
        # if we hit the end of the current certificate then see if it should be processed
        [[ -n "$current_pem" ]] && process_certificate "$mode" "$current_pem" "$current_hash"
        # Erase the current one in memory and start reading in the new cert
        current_hash=$(echo "${line#SHA-1 hash: }" | tr -d '[:space:]')
        current_pem=""
      elif [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        # Start of a new certificate
        current_pem="$line"$'\n'
      elif [[ -n "$current_pem" ]]; then
        # Keep adding lines to the current certificate
        current_pem+="$line"$'\n'
      fi
    done
    [[ -n "$current_pem" ]] && process_certificate "$mode" "$current_pem" "$current_hash"
}

function process_certificate () 
{
    # PURPOSE: Read in the entire contents of the users keychain file and evaluate each cert
    # RETURN: None
    # PARAMS: $1 - "view" or "delete"
    # EXPECTED: $LOGIN_KEYCHAIN
    local mode="$1" pem="$2" hash="$3"
    if should_process_cert "$pem"; then
      ((TOTAL_EXPIRED_CERTS++))
      # Extract the details of the cert
      local not_after=$(echo "$pem" | openssl x509 -noout -enddate | cut -d= -f2)
      local subject=$(echo "$pem" | openssl x509 -noout -subject | sed 's/^subject=//')
      
      # Shorten hash for display
      local short_hash="${hash:0:16}..."

      if [[ "$mode" == "view" ]]; then
        cert=$(printf "%-20s | %-12s | %-30.50s" "$short_hash" "$(echo $not_after | awk '{print $1,$2,$4}')" "$subject")
        KEYCHAIN_CERTS+="$cert<br>"
        logMe "Found Expired Cert: "$cert
      else
        mkdir -p "$BACKUP_DIR"
        echo "$pem" > "$BACKUP_DIR/${hash}.pem"
        logMe "Storing $hash into $BACKUP_DIR"
        security delete-certificate -Z "$hash" "$LOGIN_KEYCHAIN" >/dev/null 2>&1
        logMe "DELETED: $short_hash"
      fi
    fi
}

function should_process_cert () 
{
    # PURPOSE: Determine if the cert is expired or not
    # RETURN: 0 if active / 1 if expired
    # PARAMS: $1 - Certificate Hash
    # EXPECTED: $EXCLUDE_PATTERNS 
    local pem="$1"
    local cert_info
    cert_info=$(echo "$pem" | openssl x509 -noout -subject -issuer 2>/dev/null) || return 1
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
      [[ "${cert_info:l}" == *"${pattern:l}"* ]] && return 1
    done

    local not_after=$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    local iso_now=$(date +%s)
    local iso_exp=$(date -j -f "%b %e %T %Y %Z" "$not_after" "+%s" 2>/dev/null) || return 1

    [[ "$iso_exp" -lt "$iso_now" ]] && return 0 || return 1
}

####################################################################################################
#
# Main Script
#
####################################################################################################
local certs_with_hashes
local currentPem
local currentHash

autoload 'is-at-least'

if is-at-least "15" "$(sw_vers -productVersion | xargs)"; then    #File location change in Sequoia and higher
  SD_ICON_FILE="/System/Library/CoreServices/Applications/Keychain Access.app"
fi

check_for_sudo
create_log_directory
check_swift_dialog_install
check_support_files
create_infobox_message

# Determine if we should prompt or run silently
[[ "${ACTION_MODE:l}" == "verbose" ]] && welcomemsg || parse_keychain "delete"
cleanup_and_exit 0
