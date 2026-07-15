#!/bin/zsh
#
# MountNetworkDrive.sh
#
# by: Scott Kendall
#
# Written: 12/23/2025
# Last updated: 04/01/2026
#
# Script Purpose:Mount network drives based on user group membership.  
# This script is meant to be used in conjunction with a Jamf Pro policy that populates a plist file with the appropriate drive mappings for the user,
#  and then this script reads that file and mounts the appropriate drives.
#
# 1.0 - Initial
# 1.1 - Add more checking against the plist file...make sure it is intact and correct keys are present
# 1.2 - Cleaned up code to be more constant with my other apps
# 2.0 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x 
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
PLIST_SUPPORT_DIR="/Users/$LOGGED_IN_USER/Library/Application Support"
SW_DIALOG="/usr/local/bin/dialog"

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
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="GE_SD_BannerImage.png"
    BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
    BANNER_SUBTITLE=""
fi
[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

SD_WINDOW_TITLE="Connect to Network Drives"

FQDN="corp.gianteagle.com"
SD_FIRST_NAME="${(C)${LOGGED_IN_USER%%.*}}"
JSS_FILE="$PLIST_SUPPORT_DIR/com.GiantEagleEntra.plist"
HELPDESK_URL="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

# Put the path to your VPN client here if you want to use the VPN button in the dialog.  If left blank or if the file doesn't exist, the button will not be shown.
VPN_APP="/Applications/Cisco/Cisco Secure Client.app"

# JAMF Self Service Policy to execute
CHECK_GROUPS_POLICY="jamfselfservice://content?entity=policy&id=492&action=execute"

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
        ${SW_DIALOG} --bannerimage "${SD_BANNER_IMAGE}" \
        --bannertitle "${SD_WINDOW_TITLE}" \
        --subtitle "${BANNER_SUBTITLE}" \
        --icon computer \
        --overlayicon warning \
        --width 700 \
        --message "Your Mac is currently unable to determine what network drives are available. Click on 'Check my Drives' to verify drive info." \
        --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button." \
        --infobuttontext "Get Help" \
        --infobuttonaction "$HELPDESK_URL" \
        --button1text "Check My Drives" \
        --ontop \
        --ignorednd \
        --iconsize 128 \
        --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"

        returnCode=$?
        [[ "$returnCode" == "0" ]] && open "$CHECK_GROUPS_POLICY"
        sleep 30
    fi

    # check for the existing of the appropriate key inside the plist file

    /usr/libexec/PlistBuddy -c "Print :DriveMappings" "${JSS_FILE}" 1>/dev/null
    if [[ $? -ne 0 ]]; then
        ${SW_DIALOG} --bannerimage "${SD_BANNER_IMAGE}" \
        --bannertitle "${SD_WINDOW_TITLE}" \
        --subtitle "${BANNER_SUBTITLE}" \
        --icon computer \
        --overlayicon warning \
        --width 700 \
        --message "The appropriate keys were not found in the mappings file. Click on 'Check my Drives' to verify drive info." \
        --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button." \
        --infobuttontext "Get Help" \
        --infobuttonaction "$HELPDESK_URL" \
        --button1text "Check My Drives" \
        --ontop \
        --ignorednd \
        --iconsize 128 \
        --titlefont shadow=1, color="${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"

        returnCode=$?
        [[ "$returnCode" == "0" ]] && open "$CHECK_GROUPS_POLICY"
    fi
}

function test_connection ()
{
    # Purpose: Test the PING command to make sure we are on corp network (on-prem or VPN)
    # Results: None
    # Params: None

    # Use a ping test of your FQDN to see if it can be reached
    # If you need to change the test or failure logic, these two lines are what needs to be changed

    results=$(ping -c 1 -W 5 $FQDN | grep "PING" | awk -F '[()]' '{print $2}')
    ${SW_DIALOG} --notification --identifier "connection" --remove
    if [[ $results == "127.0.0.1" ]]; then
        WelcomeMsg="${SD_DIALOG_GREETING} ${SD_FIRST_NAME}.  In order to access your network drives, you need to connect to the corporate network (either On-Premise or VPN) first, and then try again."
        [[ -x "${VPN_APP}" ]] && WelcomeMsg+="<br><br>Click on 'Open VPN' to launch the Cisco Secure VPN client."

        MainDialogBody=(
            --message "${WelcomeMsg}"
            --bannerimage "${SD_BANNER_IMAGE}"
            --bannertitle "${SD_WINDOW_TITLE}"
            --subtitle "${BANNER_SUBTITLE}"
            --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button." \
            --infobuttontext "Get Help" \
            --infobuttonaction "$HELPDESK_URL" \
            --overlayicon "${SD_ICON}"
            --icon computer
            --overlayicon warning
            --quitkey 0
            --titlefont "shadow=1, color=${BANNER_TEXT_COLOR}, offset=${BANNER_TEXT_PADDING}"
            --messagefont size=18
            --helpmessage "If you need assistance, please contact the TSD using the 'Get Help' button."
            --infobuttontext "Get Help" \
            --infobuttonaction "$HELPDESK_URL" \
            --width 700
            --button1text "Ok"
            --moveable 
            --ontop
            )

        [[ -x "${VPN_APP}" ]] && MainDialogBody+=(--button2text "Open VPN") || MainDialogBody+=(--button2text "Cancel")
        temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
        returnCode=$?

        [[ -x "${VPN_APP}" ]] && [[ $returnCode = 2 ]] && open "${VPN_APP}"
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

function show_test_message ()
{
    # Purpose: Show a test message to the user to let them know the script is running
    # Results: None
    # Params: None

    ${SW_DIALOG} --notification --style alert --identifier "connection" --title "Testing network connection" --message "Please be patient" --button1text "Dismiss"
}

##################
#
# Main Script
#
##################

declare -a drive_mappings

show_test_message
test_plist_config
test_connection
read_in_drive_mappings
mount_drives
exit 0

