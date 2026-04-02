## Support.app Setup

I make heavy use of the excellent Support.app [found here](https://github.com/root3nl/SupportApp) for my users.  Several of the items that I use it for are:

- [Password Age](#password-age)
- [Show Battery Info](#battery-info)
- [Show Active IP address](#show-active-ip-address)
- [JAMF checkin](#jamf-checkin)

## Password Age
In our environment we use Entra / JAMF and no Kerberos.  What I was trying to accomplish for the end users is to give them some kind of idea of when their paswswords are about ready to expire.  There are couple of ways that you can do this:

1.  You can use the local login password reset date, but that might not have the same time sync as the Entra server
    ````
    passwordAge=$(expr $(expr $(date +%s) - $(dscl . read /Users/${LOGGED_IN_USER} | grep -A1 passwordLastSetTime | grep real | awk -F'real>|</real' '{print $2}' | awk -F'.' '{print $1}')) / 86400)

2.  Or you can get the information from the Entra server using the MS Graph API.  I have the script for that [here](https://github.com/ScottEKendall/JAMF-Pro-System-Scripts/blob/main/Maintenance%20-%20InTune%20-%20Passwords.sh)

## Password retrieval

>Disclaimer: This may not be the best method to retrieve / store network passwords, but this has been working flawlessly for me for the past year.  I welcome any recommendations on a better idea.

1.  Use this script from my repo [found here](https://github.com/ScottEKendall/JAMF-Pro-System-Scripts/blob/main/Maintenance%20-%20InTune%20-%20Passwords.sh) and have it run Once a Day.  You will need to provide your Entra credentials for the script.

![](./InTune_Password_Parms.png)

2.  When that runs, it will update and/or create the .plist file and store it in the User's personal library  `~/Library/Application Support/<filename.plist>`. I do this location as I have multi-user macs in my environment.

Here is the structure of that file

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DriveMappings</key>
	<array>
		<string>smb://dfs11inf2/clientserver</string>
		<string>smb://dfs10INF1/common</string>
	</array>
	<key>EntraAdminRights</key>
	<string>Yes</string>
	<key>EntraGroups</key>
	<array>
		<string>CLIENT TECHNOLOGIES</string>
	</array>
	<key>PasswordAge</key>
	<string>218</string>
	<key>PasswordLastChanged</key>
	<string>2025-08-13T18:16:13Z</string>
</dict>
</plist>
```

The key fields that we are going to use are `<PasswordAge>` and `<PasswordLastChanged>`.

>NOTE: I create the local file so I don't have to constantly log into the server to get password info.  Saves time and I believe it offers more flexibility for local scripting on the machine

3.  If you want to retreieve the PasswordAge field (or any field) use the `defaults read` to retrieve the data:

```
plistFile="<file location>"
PasswordAge=$(defaults read "$plistFile" "PasswordAge")
LastPasswordChange=$(defaults read "$plistFile" "PasswordLastChanged")
```
4.  With this new found information, I do a couple of things with it:

    1.  I have a daily script that will determine if the user's password is about to expire (within two weeks) and show them a dialog message on the screen.  Script for that can be [found here](https://github.com/ScottEKendall/JAMF-Pro-Scripts/tree/main/PasswordExpire).  A sample of what that looks llie:

    ![](https://github.com/ScottEKendall/JAMF-Pro-Scripts/blob/main/PasswordExpire/PasswordExpire.png?raw=true)

    2.   Since I also want to show this information to the end users, I use the Support.app utility and setup custom extensions for this app.  Here is what that screen looks like

    ![](Support.app_Screenshot.png)

    and here is the Extension script to produce that output:

    ```
    #!/bin/zsh
    # Support App Extension - Show Password Age
    #
    #
    # Support App Extension to show the age of the current user's password and how many days are left until it expires.
    #
    # get the currently logged in user and their home directory
    LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
    USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )


    extensionID="GetPasswordAge"
    passwordLimit=365
    plistFile="<yourplistlocation>" #ex. $USER_DIR/Library/Application Support/EntraInfo.plist

    # Retrieve password age from the user's .plist file and write it to the Support App preference plist
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_loading" -bool true
    sleep .5

    # Get password age and calculate days left until password expires
    PasswordAge=$(defaults read "$plistFile" "PasswordAge")
    LastPasswordChange=$(defaults read "$plistFile" "PasswordLastChanged")
    dayleft=$((passwordLimit - PasswordAge))

    LastPasswordChangeDate=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" $LastPasswordChange +"%x")
    # Write output to Support App preference plist
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}" -string "Changed: ${LastPasswordChangeDate}\n${dayleft} Days Left"
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_loading" -bool false

    # Trigger an orange warning notification for the user if their password is set to expire within 14 days
    if [[ $dayleft -le 14 ]]; then
        defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_alert" -bool true
    else
        defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_alert" -bool false
    fi```

>IMPORTANT!  Do not use the $HOME variable to determine the user's home drive as this extension runs with elevated privleges, so it will return the wrong home drive if you use the $HOME variable.

I also like the fact that I can set an "alert" symbol" when the user's password is within the 14 day limit, so not only do they see the symbol in their menubar, but they also get a dialog prompt showing what to do to change it as well

## Other Entra Scripts
I also have other MS Entra scripts in my repo that can retrieve the following:

* Last Password Change
* Employee ID Photo
* Groups
* Admin Privleges

These scripts can all be found [here](https://github.com/ScottEKendall/JAMF-Pro-System-Scripts/tree/main)

## Battery Info

For laptops, I have the support.app extensin to show the battery level.  I also show an alert if the threshold is below 80% capacity.  Here is the code for that:
```
#!/bin/zsh

# Support App Extension - Show Battery Health & Charge-based Icon
#set -x

# --- Configuration ---
readonly PREF_FILE="/Library/Preferences/nl.root3.support.plist"
readonly EXT_ID="BatteryHealth"
readonly COLOR_INDICATORS="true"

# Variables to be written to defaults
typeset -g symbol="battery.100"
typeset -g retval=""
typeset -g is_alert=false

function get_battery_info() {
    # 1. Check if it's a laptop
    if [[ ! "$(system_profiler SPHardwareDataType | grep "Model Name:" | cut -d ' ' -f 9)" =~ "Book" ]]; then
        retval="Not A Laptop"
        symbol="desktopcomputer"
        return
    fi

    # 2. Get Current Charge Percentage (for the Icon)
    local current_charge=$(pmset -g batt | awk -F'[\t%]' '/InternalBattery/ {print $2}')
    [[ -z "$current_charge" ]] && current_charge=100

    # Map charge to SF Symbols
    if (( current_charge > 87 )); then symbol="battery.100"
    elif (( current_charge > 62 )); then symbol="battery.75"
    elif (( current_charge > 37 )); then symbol="battery.50"
    elif (( current_charge > 12 )); then symbol="battery.25"
    else symbol="battery.0"; fi

    # 3. Get Health/Condition logic
    local arch=$(arch)
    local health_cond=$(system_profiler SPPowerDataType | awk -F': ' '/Condition/ {print $2}' | xargs)
    local max_cap="100"

    if [[ "$arch" == "arm64" ]]; then
        max_cap=$(system_profiler SPPowerDataType | awk -F': ' '/Maximum Capacity/ {print $2}' | tr -d '% ' )
        retval="$health_cond ($max_cap%)"
    else
        retval="$health_cond"
    fi

    # 4. Set Alert if Health is bad or Capacity < 80%
    if [[ "$health_cond" != "Normal" || "$max_cap" -lt 80 ]]; then
        is_alert=true
    fi
}

# --- Execution ---
defaults write "$PREF_FILE" "${EXT_ID}_loading" -bool true
sleep 0.25

get_battery_info

# Apply color circles
local indicator=""
if [[ "$COLOR_INDICATORS" == "true" ]]; then
    [[ "$is_alert" == "true" ]] && indicator="🔴 " || indicator="🟢 "
fi

# Final Writes
defaults write "$PREF_FILE" "${EXT_ID}_alert" -bool "$is_alert"
defaults write "$PREF_FILE" "${EXT_ID}" -string "${indicator}${retval}"
defaults write "$PREF_FILE" "${EXT_ID}_symbol" -string "${symbol}"
defaults write "$PREF_FILE" "${EXT_ID}_loading" -bool false

```

## Show Active IP Address

I have developed a small extension script to reflect the IP address of the active adapter.  I follow this hierarchy (VPN > Ethernet > Wi-Fi).  Which ever active adapter is highest in the hierachy then I display that information.  Very handy for remote support calls.  Also displays an alert badge if there are no active addresses.

```
#!/bin/zsh

# Support App Extension - Optimized Network Info
#set -x

# --- Configuration ---
readonly PREF_FILE="/Library/Preferences/nl.root3.support.plist"
readonly EXT_ID="NetworkInfo"
readonly COLOR_INDICATORS="true"

# Global variables updated by the function
typeset -g symbol="network"
typeset -g retval=""

function get_nic_info() {
    local ip vpn_bin
    
    # 1. Check VPN (Highest Priority)
    # Use -e (exists) and find the first match quickly
    for bin in "/opt/cisco/secureclient/bin/vpn" "/opt/cisco/anyconnect/bin/vpn"; do
        [[ -f "$bin" ]] && vpn_bin="$bin" && break
    done

    if [[ -n "$vpn_bin" ]]; then
        ip=$($vpn_bin stats 2>/dev/null | awk -F': ' '/Client Address \(IPv4\)/ {print $2}' | xargs)
        if [[ -n "$ip" && "$ip" != "Not Available" ]]; then
            retval="${ip}\n(VPN)"
            symbol="lock.icloud"
            return
        fi
    fi

    # 2. Check Ethernet (Prioritize wired)
    # Find active services and filter for Ethernet-like names
    local eth_dev=$(networksetup -listnetworkserviceorder | awk -F'Device: ' '/Ethernet|LAN/ {print $2}' | tr -d ')')
    for dev in ${(f)eth_dev}; do
        ip=$(ipconfig getifaddr "$dev" 2>/dev/null)
        if [[ -n "$ip" ]]; then
            retval="${ip}\n(Ethernet)"
            symbol="network"
            return
        fi
    done

    # 3. Check Wi-Fi
    local wifi_dev=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')
    ip=$(ipconfig getifaddr "$wifi_dev" 2>/dev/null)
    if [[ -n "$ip" ]]; then
        retval="${ip}\n(Wi-Fi)"
        symbol="wifi"
        return
    fi

    retval="No active adapter found"
    symbol="network"
}

# --- Execution ---

# Setup UI indicators
local circle=""
[[ "$COLOR_INDICATORS" == "true" ]] && { green="🟢 "; red="🔴 "; }

# Start loading state
defaults write "$PREF_FILE" "${EXT_ID}_loading" -bool true
sleep 0.25

# Fetch info (modifies globals)
get_nic_info

# Determine status and alert level
local is_alert=false
if [[ "$retval" == "No active"* ]]; then
    is_alert=true
    nic_status="${red}${retval}"
else
    nic_status="${green}${retval}"
fi

# Batch write to defaults
defaults write "$PREF_FILE" "${EXT_ID}_alert" -bool "$is_alert"
defaults write "$PREF_FILE" "${EXT_ID}" -string "${nic_status}"
defaults write "$PREF_FILE" "${EXT_ID}_symbol" -string "${symbol}"
defaults write "$PREF_FILE" "${EXT_ID}_loading" -bool false

```

Some sample output:

![](IP_Adresses.png)


## JAMF Checkin

This one came with the sample scripts from the support.app site, but I modified it slightly to show status icons:

```
#!/bin/zsh --no-rcs

# Support App Extension - Jamf Pro Last Check-In Time
#
#
# Copyright 2025 Root3 B.V. All rights reserved.
#
# Support App Extension to get the Jamf Pro Last Check-In Time
#
# REQUIREMENTS:
# - Jamf Pro Binary
#
# THE SOFTWARE IS PROVIDED BY ROOT3 B.V. "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
# EVENT SHALL ROOT3 B.V. BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
# IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# ------------------    edit the variables below this line    ------------------

# Enable 24 hour clock format. 12 hour clock enabled by default
twenty_four_hour_format="false"

# Extension ID
extension_id="last_check_in"
color_indicators="true"  # Set to "true" to use the color circle emojis, "false" or anything else for no emojis
if [[ "$color_indicators" == "true" ]]; then
    green_circle="🟢 "
    yellow_circle="🟡 "
    red_circle="🔴 "
else
    green_circle=""
    yellow_circle=""
    red_circle=""
fi

# ---------------------    do not edit below this line    ----------------------

# Support App preference plist
preference_file_location="/Library/Preferences/nl.root3.support.plist"

# Start spinning indicator
defaults write "${preference_file_location}" "${extension_id}_loading" -bool true

# Replace value with placeholder while loading
defaults write "${preference_file_location}" "${extension_id}" -string "KeyPlaceholder"

# Keep loading effect active for 0.5 seconds
sleep 0.5

# Get last Jamf Pro check-in time from jamf.log
last_check_in_time=$(grep "Checking for policies triggered by \"recurring check-in\"" "/private/var/log/jamf.log" | tail -n 1 | awk '{ print $2,$3,$4 }')

# Convert last Jamf Pro check-in time to epoch
last_check_in_time_epoch=$(date -j -f "%b %d %T" "${last_check_in_time}" +"%s")

# Convert last Jamf Pro epoch to something easier to read
if [[ "${twenty_four_hour_format}" == "true" ]]; then
  # Outputs 24 hour clock format
  last_check_in_time_human_reable=$(date -r "${last_check_in_time_epoch}" "+%A %H:%M")
else
  # Outputs 12 hour clock format
  last_check_in_time_human_reable=$(date -r "${last_check_in_time_epoch}" "+%A %I:%M %p")
fi

# Write output to Support App preference plist
defaults write "${preference_file_location}" "${extension_id}" -string "${last_check_in_time_human_reable}"
# Calculate the difference in seconds
now_epoch=$(date +%s)
diff_seconds=$(( now_epoch - last_check_in_time_epoch ))

# Define time thresholds in seconds
four_hours=14400
eight_hours=28800

# Determine the status symbol based on age
if [[ $diff_seconds -ge $eight_hours ]]; then
  # Red circle for over 8 hours
  status_symbol=$red_circle
elif [[ $diff_seconds -ge $four_hours ]]; then
  # Yellow circle for over 4 hours
  status_symbol=$yellow_circle
else
  # Green circle for recent check-in
  status_symbol=$green_circle
fi

# Update the human readable string to include the status symbol
final_output="${status_symbol} ${last_check_in_time_human_reable}"

# Write the final output with the circle to the plist
defaults write "${preference_file_location}" "${extension_id}" -string "${final_output}"

# Stop spinning indicator
defaults write "${preference_file_location}" "${extension_id}_loading" -bool false
```
