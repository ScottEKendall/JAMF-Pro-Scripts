#!/bin/zsh
#
# enableARD
#
# by: Scott Kendall
#
# Written: 11/03/2024
# Last updated: 02/17/2025
#
# Script Purpose: 
#
# 1.0 - Initial
# 1.1 - Code cleanup to be more consistant with all apps

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/EnableARD.log"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

LOCAL_ADMIN="localmgr"
KICKSTART_COMMAND=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/KICKSTART_COMMAND

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

logMe "Configuring Remote Management"
if [[ -z $(id -u ${LOCAL_ADMIN} 2>/dev/null )  ]] ; then
    logMe "--- ERROR: The $LOCAL_ADMIN account does not exist on this system."
    exit 1
fi
logMe "Defined local admin account exists"

# Deactivate ARD agent, deny all access
logMe "Deactivating ARD agent for all accounts"
$KICKSTART_COMMAND -deactivate -configure -access -off
defaults write /Library/Preferences/com.apple.RemoteManagement ARD_AllLocalUsers -bool FALSE

# Remove 'naprivs' key from users configured by ARD's -specifiedUSers flag

logMe "Removing naprivs key from local users"

RemoteManagementUsers=$(dscl . list /Users naprivs | awk '{print $1}')
    for EnabledUser in $RemoteManagementUsers; do
        logMe "--- naprivs removed from $EnabledUser"
        dscl . delete /Users/$EnabledUser naprivs
    done
# Turn ARD back on and enable only the specified LOCAL_ADMIN
logMe "Reconfiguring ARD for only specified users"
$KICKSTART_COMMAND -configure -allowAccessFor -specifiedUsers

logMe "Setting specified local admin account as sole ARD user"
$KICKSTART_COMMAND -configure -users $LOCAL_ADMIN -access -on -privs -all

logMe "Restarting ARD agent"
$KICKSTART_COMMAND -activate -restart -agent

logMe "--- Remote management reset; user ${LOCAL_ADMIN} configured for access"
exit 0
