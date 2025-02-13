#!/bin/zsh
#
# App Delete
# Purpose: Allow end users to delete apps using Swift Dialog
#
# Written: Sept 3, 2024
# Last updated: Feb 13, 2025
#
# This script should detect the names of any present specified network ports and
# configure the search domains settings accordingly.
#
# Based loosely off the JAMF script that does the same thing for policy compatibility reasons.
#
# Parm #4: Name of a Network Service
# Parm #5: First search domain address. (eg. arts.local)
# Parm #6: Second search domain address. (eg. arts.ac.uk)
#
# v1.0 - Initial Release
# v1.1 - Major code cleanup & documentation
#		 Structured code to be more inline / consistent across all apps
######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################

searchNetwork="${1:-""}"
searchDomain1="${2:-""}"
searchDomain2="${3:-""}"
PrimaryDNS="${4:-""}"
SecondaryDNS="${5:-""}"

LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/SetDomain.log"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

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

# Let's check to see if we've been passed the Search Domain details in field 4, 5 & 6.

if [[ -z "${searchNetwork}" ]]; then
    logMe "Error:  No network service name in parameter 4 was specified."
    exit 1
fi
# Read the output of the networksetup command
# Grep that output through the specified service name and process

while read networkService; do
	printf "%s\n" "${networkService}"
	logMe "Network Service name to be configured - ${networkService}"

    if [[ ! -z "${searchDomain1}" || ! -z "${searchDomain2}" ]]; then
        logMe "Setting Search Domain(s) to: ${searchDomain1} ${searchDomain2}"
    	networksetup -setsearchdomains "${networkService}" $searchDomain1 $searchDomain2
    fi

    if [[ ! -z "${PrimaryDNS}" || ! -z "${SecondaryDNS}" ]]; then
        logMe "Specified DNS server addresses - ${PrimaryDNS} ${SecondaryDNS}"
    	networksetup -setdnsservers "${networkService}" $PrimaryDNS $SecondaryDNS
    fi

done < <( networksetup -listallnetworkservices | grep -E "$searchNetwork" )

exit 0