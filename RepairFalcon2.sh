#!/bin/zsh
#
# Written by: Scott Kendall
# Date Created: 01/21/2025
# Date Last Revised: 01/23/2025
# 
# Borrowed heavily from @Snelson: source code @ https://snelson.us/2023/03/crowdstrike-falcon-kickstart-0-0-2/
#
######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin

SUPPORT_DIR="/Library/Application Support/GiantEagle"

LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/FalcanSensor.log"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

falconBinary="/Applications/Falcon.app/Contents/Resources/falconctl"
falcanJAMFtrigger="crowdstrike"

exitCode="0"

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

function preflight_check ()
{
    # Pre-flight Check: Confirm script is running as root

    [[ $(id -u) -ne 0 ]] && {logMe "PRE-FLIGHT CHECK: This script must be run as root; exiting."; exit 1}


    # Pre-flight Check: Confirm CrowdStrike Falcon System Extension is running

    systemExtensionTest=$( systemextensionsctl list | grep -o "com.crowdstrike.falcon.Agent.*" | cut -f2- -d" " )
    if [[ -n "${systemExtensionTest}" ]]; then
        systemExtensionStatus="${systemExtensionTest}"
    else
        systemExtensionStatus="Not Found"
        logMe "Falcon not installed: Loading policy from JAMF"  
    fi

    logMe "CrowdStrike Falcon System Extension Status: ${systemExtensionStatus}"

    ###################################################
    # Pre-flight Check: Complete
    ###################################################

    logMe "PRE-FLIGHT CHECK: Complete"
}

function log_sensor_updates()
{
        logMe "Falcon Sensor Operational: ${1}"
        logMe "Updating inventory …"
        jamf recon
}

function connection_test()
{
    test=$("nc -vz ts01-b.cloudsink.net 443")
    [["${test}" == *"succedded!"* ]] && echo "true" || echo "false" 
}

function load_sensor()
{
    echo $( ${falconBinary} load --verbose) 
}

function load_jamf_policy ()
{
    jamf policy -trigger "${falcanJAMFtrigger}"
}

function get_agent_info ()
{
     echo $( $falconBinary stats agent_info 2>&1 )
}
function uninstall_reinstall ()
{
        falconKickStartUninstall=$( ${falconBinary} uninstall -t <<< 00345e4e1ce6372bdb2477afac6fd5fac39a074e9a3761bae509a895b2cf1c4e )
        log_sensor_updates "${falconKickStartUninstall}"

        logMe "Re-installing CrowdStrike Falcon …"
        load_jamf_policy
}

####################################################################################################
#
# Program
#
####################################################################################################

create_log_directory
preflight_check
exitCode="0"

###################################################
# Process CrowdStrike Falcon System Extension Status
###################################################

logMe "Processing System Extension Status …"

systemExtensionStatus=$(systemextensionsctl list | grep -o "com.crowdstrike.falcon.Agent.*" | cut -f2- -d" ")

# Check the extension status first and evaluate 
systemExtensionStatus="uninstall on reboot"

case ${systemExtensionStatus} in

    *"[activated enabled]"* )

        logMe "CrowdStrike Falcon System Extension enabled"
        logMe "Validating Sensor Operation …"
        sensorOperationalStatus=$( get_agent_info ) #| awk '/Sensor operational:/{print $3}')

        # check for specific issues in regards to the status

        case ${sensorOperationalStatus:l} in

            *"true"* )
                # sensors are loaded and functioning correclty
                log_sensor_updates "${sensorOperationalStatus}"
                ;;

            *"sensor has not loaded."* | *"sensor is unknown."* | *"sensor is unloaded."* )
                # Sensors are not loaded properly
                sensorOperationalStatus=$( load_sensor)
                logMe "Attempting to Load the Falcon Sensor"
                log_sensor_updates "${sensorOperationalStatus}"
                ;;

            *"not licensed"* )
                # product is not licensed...perform a license command and then make sure that the sensors are loaded
                logMe "Attempting to License the Falcon Sensor"
                falconKickStartLicense=$( $falconBinary license "$( defaults read /Library/Managed\ Preferences/com.crowdstrike.falcon.plist ccid )" --noload --verbose)
                log_sensor_updates "${falconKickStartLicense}"

                logMe "Attempting to Load the Falcon Sensor"
                sensorOperationalStatus=$( load_sensor)
                log_sensor_updates "${sensorOperationalStatus}"
                ;;

        esac
        ;;

    *"uninstall on reboot"* )

        # It looks like a restart might be in order
        # Lets try to uninstall it first and then do a reinstall
        uninstall_reinstall 
        ;;
    
    *"waiting for user"* )
        # it appears that everything is working OK, but the user needs to start doing "something"
        log_sensor_updates "${sensorOperationalStatus}"
        ;;

    "Not Found" )
        # Crowdstrike not found, so lets try to remove any previous install and try to reinstall it
        
        logMe "CrowdStrike Falcon System Extension NOT found: Attempting Re-installation"
        uninstall_reinstall 

        exitCode="1"
        ;;
    * )
        # Catch all if we got a different error

        logMe "Attempting to kickstart Falcon Sensor …"

        falconKickStartLicense=$( ${falconBinary} license )
        logMe "Falcon Kickstart License Result: ${falconKickStartLicense}"

        falconKickStartLoad=$( load_sensor )
        logMe "Falcon Kickstart Load Result: ${falconKickStartLoad}"

        if [[ "${falconKickStartLoad}" == "Falcon sensor is loaded" ]]; then
            sensorOperationalStatus=$( get_agent_info )
            [[ "${sensorOperationalStatus}" == "true" ]] && logMe "Falcon Sensor Status: ${sensorOperationalStatus}"
        else
            exitCode="1"
        fi
esac

logMe "Exit Code: ${exitCode}"
exit "${exitCode}"