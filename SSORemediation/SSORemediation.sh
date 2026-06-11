#!/bin/zsh
#
# SSO Results
#
# by: Scott Kendall
#
# Written: 06/11/2026
# Last updated: 06/11/2026
#
# Script Purpose: Detemrine the results of Apple SSO and Jamf Conditional Access checks for Microsoft Entra ID device registration and compliance status, 
# and provide detailed analysis and remediation steps based on the combined results.
#

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

function runAsUser ()
{
   # 1. Run the launchctl command in the background
   /bin/launchctl asuser $userUID sudo -iu $currentUser "$@"
}

get_appsso_status()
{
    local status_output=$(/usr/bin/app-sso platform -s | awk -F'"' '/"state"/ {print $4}' | awk -F'[()]' '{print $2}'2>/dev/null)
    if [[ -z "$status_output" ]]; then
        echo 0 
        return 0
    fi
    
    case "$status_output" in
     "2" )
        # POUserStateNeedsRegistration (2)
        # Meaning: The device is managed, but this specific local user has not yet gone through the registration process.
        # Status: Action required. The user must click the registration banner or notification to link their local account with their cloud IdP credentials
        echo 2
        ;;
    "1" )
        # POUserStateNeedsNewKeys (1)
        # Meaning: The user's secure authentication keys are missing, expired, or out of sync.
        # Status: Action required. The user will typically see a prompt or menu bar notification to sign in again to regenerate their Secure Enclave keys.
        echo 1
        ;;
    "0" )    
        # POUserStateNormal (0)
        # Meaning: The user is successfully registered with the Identity Provider (IdP).
        # Status: Healthy. Authentication tokens are active, and no further user action is required.
        echo 0 
        ;;
    esac

}

get_jamf_ca_status()
{
    local jamfCA="/Library/Application Support/JAMF/Jamf.app/Contents/MacOS/Jamf Conditional Access.app/Contents/MacOS/JAMF Conditional Access"
    local caState=$(runAsUser $jamfCA getPSSOStatus | head -n 1)
    # Check standard Jamf Device Compliance plist for Entra ID integration
    
    case "$caState" in
        "2" )
        # Registered and Compliant (2)
        # Meaning: The device is successfully registered in Entra ID and meets all compliance policies set by the organization.
        # Status: Healthy. The device should have full access to Entra ID protected resources without any issues.
        echo 2
        ;;
        "1" )
        # Enabled but Non-Compliant (1)
        # Meaning: The device is registered in Entra ID but fails to meet one or more compliance policies (e.g., missing encryption, outdated OS, disabled firewall).
        # Status: Warning. The user may have limited access to resources, and remediation of compliance issues is needed to restore full access.
        echo 1
        ;;
        "0" )
        # Not Registered (0)
        # Meaning: The device is not registered in Entra ID, which could be due to a failure in the registration process or because the device has not yet attempted to register.
        # Status: Critical. The device will be blocked from accessing Entra ID protected resources until it successfully registers and meets compliance requirements.
        echo 0
        ;;
        *)
        # Unknown or Unreachable Status
        # Meaning: The script was unable to retrieve a valid status from the Jamf Conditional Access tool, which could indicate a problem with the local Jamf agent, network connectivity issues, or an unexpected error in the command execution.
        # Status: Unknown. Further investigation is needed to determine the root cause of the issue and to verify the device's actual registration and compliance status in Entra ID.
        echo 0
        ;;
    esac
}

####################################################################################################
#
# Main Script
#
####################################################################################################

# Ensure script is run with appropriate local user privileges
currentUser=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}')
userUID=$(/usr/bin/id -u $currentUser)

if [[ -z "$currentUser" || "$currentUser" == "root" ]]; then
    echo "[-] Error: No active console user detected. Run this in a user session."
    exit 1
fi

echo "[*] Initializing Microsoft Entra ID Diagnostics for User: $currentUser"
echo "------------------------------------------------------------"

# Extract native Apple Platform SSO status & JAMF CA status for the current user session

APP_SSO_STATUS=$(get_appsso_status)
JAMF_CA_STATUS=$(get_jamf_ca_status)

# Combine and analyze the status codes to determine overall health and remediation steps

echo "[+] Apple Platform SSO Status       : $APP_SSO_STATUS"
echo "[+] Jamf / Entra ID CA Status       : $JAMF_CA_STATUS"
echo "------------------------------------------------------------"

case "${APP_SSO_STATUS}${JAMF_CA_STATUS}" in

    "00")
        # Meaning: Apple SSO shows success, but JAMF CA shows unregistered. This likely means the user has a valid SSO token cached locally, but the device is not properly registered in Entra ID, which could be due to a failure in the registration process or because the device has not yet attempted to register.
        # Action: User needs to run /Library/Application Support/JAMF/Jamf.app/Contents/MacOS/Jamf Conditional Access.app/Contents/MacOS/JAMF Conditional Access registerWithIntune
        echo "[CRITICAL] Status Code Combo: (0,0)"
        echo "Analysis   : Complete management disconnect. Missing Microsoft Enterprise SSO configuration profile and Entra CA link."
        echo "Remediation Steps:"
        echo "  1. Verify the Mac is scoped to the 'Extensible SSO Profile' targeting the bundle ID 'com.microsoft.CompanyPortalMac.ssoextension'."
        echo "  2. Ensure the latest version of Microsoft Company Portal app is installed locally."
        echo "  3. Force profile enforcement: 'sudo jamf manage'."
        ;;

    "01")
        # Meaning: Apple SSO shows success, but JAMF CA shows registered but non-compliant. This likely means the user has a valid SSO token cached locally, and the device is registered in Entra ID, but it fails to meet one or more compliance policies (e.g., missing encryption, outdated OS, disabled firewall).
        # Action: Run "/Library/Application Support/JAMF/Jamf.app/Contents/MacOS/Jamf Conditional Access.app/Contents/MacOS/JAMF Conditional Access" gatherAADInfo
        echo "[CRITICAL] Status Code Combo: (0,1)"
        echo "Analysis   : Machine is registered in Entra via Jamf but failing compliance, and lacks the Platform SSO profile entirely."
        echo "Remediation Steps:"
        echo '  1. Run "/Library/Application Support/JAMF/Jamf.app/Contents/MacOS/Jamf Conditional Access.app/Contents/MacOS/JAMF Conditional Access" gatherAADInfo'
        ;;

    "02")
        # Meaning: Both Apple SSO and JAMF CA show success, which indicates that the user has a valid SSO token cached locally, and the device is properly registered in Entra ID and meets all compliance policies. This is the ideal state for a device in an Entra ID environment, as it means the user should have seamless access to Entra ID protected resources without any issues.
        # Action: No action needed. The device is healthy and properly configured for Entra ID access.
        echo "[HEALTHY] Status Code Combo: (0,2)"
        echo "Analysis   : Entra ID CA is compliant, add the local pSSO is configured properly"
        ;;

    "10")
        echo "[ATTENTION] Status Code Combo: (1,0)"
        echo "Analysis   : Platform SSO profile is present but the user has not completed registration, and Jamf CA is not yet linked."
        echo "Remediation Steps:"

        ;;

    "11")
        echo "[WARNING] Status Code Combo: (1,1)"
        echo "Analysis   : Profile exists, but both user cryptographic registration and Jamf compliance criteria are failing."
        echo "Remediation Steps:"
        ;;

    "12")
        echo "[ATTENTION] Status Code Combo: (1,2)"
        echo "Analysis   : Configuration Profile deployed, but the user hasn't triggered Entra PSSO registration."
        echo "Remediation Steps:"
        ;;
    "20")
        echo "[CRITICAL] Status Code Combo: (2,0)"
        echo "Analysis   : Token conflict. App-SSO is registered locally, but Jamf Device Compliance is disconnected from Entra."
        echo "Remediation Steps:"
        ;;

    "21")
        echo "[WARNING] Status Code Combo: (2,1)"
        echo "Analysis   : Entra Platform SSO token is valid, but Jamf evaluates the device hardware/OS as Non-Compliant."
        echo "Remediation Steps:"
        ;;

    "22")
        echo "[NORMAL] Status Code Combo: (2,2)"
        echo "Analysis   : Apple SSO is not registered properly, but Jamf CA shows compliant. This could indicate a reporting error or a token caching issue where the local SSO status is not accurately reflecting the device's true state in Entra ID, which is confirmed as compliant by Jamf CA."
        echo "Remediation Steps:"
        echo "Navigate to Apple Menu > System Settings > Users & Groups > Network Account Server and click on the Repair button next to Mac SSO Extension and follow the prompts to re-register"
        ;;

    *)
        echo "[?] Unknown Matrix State: ($APP_SSO_STATUS,$JAMF_CA_STATUS)"
        echo "Remediation: Force reload management policies via 'sudo jamf policy' and restart the Mac."
        ;;
esac

echo "------------------------------------------------------------"
echo "[*] Diagnostics Completed."
exit 0
