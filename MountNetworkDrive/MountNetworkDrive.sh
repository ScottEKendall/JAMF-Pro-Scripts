#!/bin/zsh
#
# Script: MountNetworkDrive.sh
#
# by: Scott Kendall
#
# Written: 12/23/2025
# Last updated: 12/24/2025
#
# Script Purpose: Mount the network drives for a user if they are on VPN or OnPrem
# The drive mappings are read in from the plist file stored in the users ~/Library/Application Support folder
# The format of the plist file is as follows:
#
# <dict>
#        <key>DriveMappings</key>
#        <array>
#                <string>smb://<unc path to server></string>
#                <string>smb://<unc path to server></string>
# </dict>
# this is designed to be run from the JAMF Connect Actions menu

# 1.0 - Initial
# 1.1 - Add more checking against the plist file...make sure it is intact and correct keys are present

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
SUPPORT_DIR="/Users/$LOGGED_IN_USER/Library/Application Support"
SW_DIALOG="/usr/local/bin/dialog"
SCRIPT_NAME="/Library/Application Support/GiantEagle/Scripts/MountNetworkDrive.sh"

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e "${DEFAULTS_DIR}" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SD_BANNER_IMAGE=$(defaults read "${DEFAULTS_DIR}" "BannerImage")
    spacing=$(defaults read "${DEFAULTS_DIR}" "BannerPadding")
else
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Connect to Network Drives"

FQDN="corp.gianteagle.com"
JSS_FILE="$SUPPORT_DIR/com.GiantEagleEntra.plist"
HELPDESK_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

# JAMF Self Service Policy to execute
CHECK_GROUPS_COMMAND="jamfselfservice://content?entity=policy&id=492&action=execute"

####################################################################################################
#
# Functions
#
####################################################################################################

function test_plist_config ()
{
    # Purpose: Test the presence of the necessary plist entries
    # Results: None
    # Params: None

    if [[ ! -e "${JSS_FILE}" ]]; then
        ${SW_DIALOG} --bannertitle "${SD_WINDOW_TITLE}" \
        --icon computer \
        --overlayicon warning \
        --width 700 \
        --message "Your Mac is currently unable to determine what network drives are available. Click on 'Check my Drives' to verify drive info." \
        --bannerimage /Library/Application\ Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png \
        --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button." \
        --infobuttontext "Get Help" \
        --infobuttonaction "$HELPDESK_URL" \
        --button1text "Check My Drives" \
        --ontop \
        --ignorednd \
        --iconsize 128 \
        --titlefont shadow=1

        returnCode=$?
        [[ "$returnCode" == "0" ]] && open "$CHECK_GROUPS_COMMAND"
        sleep 30
    fi

    # check for the existing of the appropriate key inside the plist file

    /usr/libexec/PlistBuddy -c "Print :DriveMappings" "${JSS_FILE}" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        ${SW_DIALOG} --bannertitle "${SD_WINDOW_TITLE}" \
        --icon computer \
        --overlayicon warning \
        --width 700 \
        --message "The appropriate keys were not found in the mappings file. Click on 'Check my Drives' to verify drive info." \
        --bannerimage /Library/Application\ Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png \
        --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button." \
        --infobuttontext "Get Help" \
        --infobuttonaction "$HELPDESK_URL" \
        --button1text "Check My Drives" \
        --ontop \
        --ignorednd \
        --iconsize 128 \
        --titlefont shadow=1

        returnCode=$?
        [[ "$returnCode" == "0" ]] && open "$CHECK_GROUPS_COMMAND"
    fi
}

function test_connection ()
{
    # Purpose: Test the PING command to make sure we are on corp network (on-prem or VPN)
    # Results: None
    # Params: None

    # Use a ping test of your FQDN to see if it can be reached
    # If you need to change the test or failure logic, these two lines are what needs to be changed

    results=$(ping -c 1 $FQDN | grep "PING" | awk -F '[()]' '{print $2}')
    if [[ $results == "127.0.0.1" ]]; then
        ${SW_DIALOG} --bannertitle "${SD_WINDOW_TITLE}" \
            --icon computer \
            --overlayicon warning \
            --width 700 \
            --message "In order to access your network drives, you need to connect to the corporate network (either On-Premise or VPN) first, and then try again." \
            --bannerimage /Library/Application\ Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png \
            --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button." \
            --infobuttontext "Get Help" \
            --infobuttonaction "$HELPDESK_URL" \
            --ontop \
            --ignorednd \
            --iconsize 128 \
            --titlefont shadow=1
        exit 0
    fi
}

function read_in_drive_mappings ()
{
    # Use PlistBuddy to extract the DriveMappings array
    # Count the number of items in the array
    local count=$(/usr/libexec/PlistBuddy -c "Print DriveMappings" "$JSS_FILE" | grep -c "smb://")
    
    # Read each item from the array
    for ((i=0; i<count; i++)); do
        local mapping=$(/usr/libexec/PlistBuddy -c "Print DriveMappings:$i" "$JSS_FILE")
        drive_mappings+=("$mapping")
    done
}

function mount_drives
{
    # Iterate through the array and mount the drive
    for drive in "${drive_mappings[@]}"; do
        echo "Mounting: $drive"
        open $drive
    done
}

##################
#
# Main Script
#
##################

declare -a drive_mappings

test_plist_config
test_connection
read_in_drive_mappings
mount_drives
exit 0
