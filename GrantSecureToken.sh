#!/bin/zsh
#
# GrantSecureToken.sh
#
# by: Scott Kendall
#
# Written: 02/11/25
# Last updated: 02/18/25
#
# Script Purpose: GUI Prompt to set the Secure Token to any user
#
# Credit to: Sam Mills
# Taken from: https://mostlymac.blog/2021/06/09/using-a-self-service-policy-to-grant-end-users-a-secure-token/
#
# 1.0 - Initial

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
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
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

JSON_OPTIONS=$(mktemp /var/tmp/ClearBrowserCache.XXXXX)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

JSON_OPTIONS=$(mktemp /var/tmp/SecureToken.XXXXX)

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Grant Secure Token"

SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/GrantSecureToken.log"
SD_ICON="${ICON_FILES}UserIcon.icns"

USERS_ON_SYSTEM=$( dscl . ls /Users | grep -v '_' | grep -v 'root' | grep -v 'daemon'| grep -v 'nobody' | tr '\n' ',' )
USERS_ON_SYSTEM=${USERS_ON_SYSTEM:0:-1} # remove the last , from the list so it doesn't create a blank SD entry

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
    echo "${1}" 1>&2
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

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##\n"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function display_msg ()
{
    # Expected Parms
    #
    # Parm $1 - Message to display
    # Parm $2 - Type of dialog (message, input, password)
    # Parm $3 - Button text
    # Parm $4 - Overlay Icon to display
    # Parm $5 - Welcome message (Yes/No)

    [[ "${5}" == "welcome" ]] && message="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}. $1" || message="$1"

	MainDialogBody=(
        --message "${message}"
		--ontop
		--icon "$SD_ICON"
		--overlayicon "$4"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --height 445
		--width 760
		--quitkey 0
        --moveable
		--button1text "$3"
    )

    # Add items to the array depending on what info was passed

    if [[ "$2" == "input" ]]; then
        MainDialogBody+=(--selecttitle "Choose the account that already has a Secure Token",required --selectvalues ${TOKEN_USER_PICK_LIST})
        MainDialogBody+=(--selecttitle "Select the user that will needs a Secure Token",required --selectvalues ${USERS_ON_SYSTEM})

    elif [[ "$2" == "password" ]]; then
        MainDialogBody+=(--textfield "Enter the password for "$adminUser,secure,required)
        MainDialogBody+=(--textfield "Enter the password for "$newTokenUser,secure,required)
    fi

    [[ "${3}" == "OK" ]] && MainDialogBody+=(--button2text Cancel)

	returnval=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    returnCode=$?

    [[ $returnCode == 2 || $returnCode == 10 ]] && cleanup_and_exit

    if [[ "$2" == "input" ]]; then
        adminUser=$(echo $returnval | grep "has" | grep -v "index" | awk -F ":" '{print $2}' | tr -d '"' | xargs )
        newTokenUser=$(echo $returnval | grep "needs" | grep -v "index" | awk -F ":" '{print $2}' | tr -d '"' | xargs )

    elif [[ "$2" == "password" ]]; then
        adminPassword=$(echo $returnval | grep "$adminUser" | awk -F ":" '{print $2}' | tr -d '"' | tr -d "," | xargs )
        userPassword=$(echo $returnval | grep "$newTokenUser" | awk -F ":" '{print $2}' | tr -d '"' | tr -d "," | xargs )
    fi
}

function get_token_users ()
{
    declare -a tmp
    tmp=$(echo $( fdesetup list | awk -F ',' '{print $1}' | awk '$1=$1","' | tr -d "\n"))
    TOKEN_USER_PICK_LIST=${tmp:0:-1}
}

function get_admin_users ()
{
    declare -a tmp
    tmp=$(dscl . read /Groups/admin GroupMembership | cut -d " " -f 2-)
    current_admin_users=( ${(z)tmp} )
}

function MissingSecureTokenCheck()
{
    # Purpose: checks to see if the current user has a secure token assigned
    # Returns: YES if secure token assign, NO if no token assigned, "" if anything else

	if [[ -n "${LOGGED_IN_USER}" && "${LOGGED_IN_USER}" != "root" ]]; then

		# Get the Secure Token status.
		token_status=$(/usr/sbin/sysadminctl -secureTokenStatus "${LOGGED_IN_USER}" 2>&1 | /usr/bin/grep -ic enabled)

		[[ "$token_status" -eq 0 ]] && result="NO" # No token found
		[[ "$token_status" -eq 1 ]] && result="YES" # Yes token found
	fi
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

# Start by setting result to UNDEFINED
declare result && result="UNDEFINED"
declare -a TOKEN_USER_PICK_LIST
declare -a CURRENT_LOCAL_USERS
declare -a current_admin_users
declare adminUser
declare newTokenUser
declare adminPassword
declare userPassword

check_swift_dialog_install
check_support_files
create_infobox_message
MissingSecureTokenCheck

# do some quick tests on the results

[[ "$result" == "UNDEFINED" ]] && { display_msg "I am unable to determine the status of your secure token.  Please create a ticket with the TSD so this can be investigated" "message" "Done" "warning" "welcome"; exit 0; }
[[ "$result" == "YES" ]] && { display_msg "Congratulatons!  Your account already has a secure token assigned to it.  No further action is necessary." "message" "Done" "SF=checkmark.circle.fill, color=green,weight=heavy"; exit 0; }

# if we made it this far, the user doesn't have a token on their account

get_token_users
get_admin_users
# For each user, check if they have a secure token

for EachUser in ${current_admin_users[@]}; do    
    TokenValue=$(sysadminctl -secureTokenStatus $EachUser 2>&1)
    [[ $TokenValue = *"ENABLED"* ]] && SecureTokenUsers+=($EachUser)    
done

# If there are no valid users, then show the error

if [[ -z "${SecureTokenUsers[@]}" ]]; then
    display_msg "There are no users on this computer that have a Secure Token already.  Please create a ticket with the TSD so this can be investigated" "message" "Done" "warning" 
    cleanup_and_exit 0
fi

# Have user select a secure token user they know the password for

display_msg "You are seeing this prompt, becuase you don't have what is called a 'Secure Token' on your computer.  A Secure Token allows you to login after the computer has been restarted, or to install software udpates." "input" "OK" "computer" "welcome"
display_msg "Enter the passwords for the following users" "password" "OK" "caution"
    

# Test the entered admin password
passCheck=$(dscl /Local/Default -authonly ${adminUser} "${adminPassword}")

# If the credentials pass, continue, if not, tell user password is incorrect and exit.
[[ -z "$passCheck" ]] && logMe "Password Verified" || display_msg "Password verification failed for $adminUser.  Please try again" "password" "Retry" "warning"
    
logMe "Granting secure token."

# Grant the token

eval "sysadminctl -secureTokenOn ${newTokenUser} -password '${userPassword}' -adminUser ${adminUser} -adminPassword '${adminPassword}'" 2> $JSON_OPTIONS

message=$(more $JSON_OPTIONS | awk -F "]" '{print $2}')

if [[ ${message} != *"Done"* ]]; then
    logMe "Errors encounted: "$message
    display_msg "An error has occured!  Results: "$message "Done" "Done" "warning"
    cleanup_and_exit 1

fi

# Check for bootstrap token escrowed with Jamf Pro
bootstrap=$(profiles status -type bootstraptoken)

if [[ $bootstrap == *"escrowed to server: YES"* ]]; then
    message+="  Secure Token & Bootstrap token verified with JAMF Pro."
    logMe "Bootstrap token already escrowed with Jamf Pro!"
else
    # Escrow bootstrap token with Jamf Pro
    message+="  Secure Token & Bootstrap Token have been created & escrowed to JAMF Pro."
    logMe "No Bootstrap token present. Escrowing with Jamf Pro now..."
    sudo profiles install -type bootstraptoken -user "${adminUser}" -pass "${adminPassword}"
fi

display_msg $message "message" "Done" "SF=checkmark.circle.fill, color=green,weight=heavy"
cleanup_and_exit 0
