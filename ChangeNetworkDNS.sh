#!/bin/zsh

# This script should detect the names of any present specified network ports and
# configure the search domains settings accordingly.

# Based loosely off the JAMF script that does the same thing for policy compatibility reasons.

# Set variables up here
# Casper reserves $1 to 3 for itself, so we have to use $4 onwards.
# So when calling this script, use the following fields of information:
# Field 4: Name of a Network Service
# Field 5: First search domain address. (eg. arts.local)
# Field 6: Second search domain address. (eg. arts.ac.uk)

searchNetwork="${1:-""}"
searchDomain1="${2:-""}"
searchDomain2="${3:-""}"
PrimaryDNS="${4:-""}"
SecondaryDNS="${5:-""}"

logDir="/Library/Application Support/GiantEagle/logs"
logStamp=$(echo $(date +%Y%m%d))
logFile="${logDir}/SetDefaultDomain.log"

###########
# Functions
###########

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions
	if [[ ! -d "${logDir}" ]]; then
		mkdir -p "${logDir}"
		chmod 755 "${logDir}"
	fi

	# If the log file does not exist - create it and set the permissions
	if [[ ! -f "${logFile}" ]]; then
		touch "${logDir}"
		chmod 644 "${logDir}"
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
    #
    # RETURN: None
    echo "${1}" 1>&2
    echo "$(date '+%Y%m%d %H:%M:%S'): ${1}" >> "${logFile}"
}

# Let's check to see if we've been passed the Search Domain details in field 4, 5 & 6.

if [[ -z "${searchNetwork}" ]]; then
    echo "Error:  No network service name in parameter 4 was specified."
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