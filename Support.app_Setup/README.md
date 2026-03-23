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
* Employee ID
* Groups
* Admin Privleges

These scripts can all be found [here](https://github.com/ScottEKendall/JAMF-Pro-System-Scripts/tree/main)

## Battery Info

For laptops, I have the support.app extensin to show the battery level.  I also show an alert if the threshold is below 80% capacity.  Here is the code for that:
```
#!/bin/zsh

# Support App Extension - Show Battery Health

arch=$(/usr/bin/arch)
model=$(system_profiler SPHardwareDataType | grep "Model Name:" | cut -d ' ' -f 9)

if [[ ! "$model" =~ "Book" ]]; then
    retval "Not A Laptop"
else
    if [[ "$arch" == "arm64" ]]; then
        capacity="$(system_profiler SPPowerDataType | grep "Maximum Capacity:" | sed 's/.*Maximum Capacity: //')"
        retval="$(system_profiler SPPowerDataType | grep "Condition:" | sed 's/.*Condition: //') ($capacity)"
    else
        retval="$(system_profiler SPPowerDataType | grep "Condition:" | sed 's/.*Condition: //')"
    fi
fi

extensionID="BatteryHealth"
# Show the battery health condition and capacity (if Apple Silicon) in the Support App
defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}" -string "${retval}"

# Trigger an orange warning notification for the user if their battery health is not good or if the capacity is below 80%
if [[ $capacity -lt 80 ]]; then
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_alert" -bool true
else
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_alert" -bool false
fi
```

## Show Active IP Address

I have developed a small extension script to reflect the IP address of the active adapter.  I follow this hierarchy (VPN > Ethernet > Wi-Fi).  Which ever active adapter is highest in the hierachy then I display that information.  Very handy for remote support calls.  Also displays an alert badge if there are no active addresses.

```
#!/bin/zsh

# Support App Extension - Show Password Age
#
#
# Support App Extension to show the IP address of the active netork adapter (VPN -> Ethernet -> Wi-Fi)
#
#set -x
function get_nic_info() {
    local vpn_ip eth_ip wifi_ip wifi_name dev port
    local secure_client="/opt/cisco/secureclient/bin/vpn"
    local anyconnect="/opt/cisco/anyconnect/bin/vpn"

    # 1. Check VPN (Highest Priority)
    local vpn_bin=""
        # Check which version is installed
    if [[ -f "$secure_client" ]]; then
        vpn_bin="$secure_client"
    elif [[ -f "$anyconnect" ]]; then
        vpn_bin="$anyconnect"
    fi
    
    if [[ -n "$vpn_bin" ]]; then
        vpn_ip=$($vpn_bin stats 2>/dev/null | awk -F': ' '/Client Address \(IPv4\)/ {print $2}' | xargs)
        if [[ ! "$vpn_ip" == "Not Available" ]]; then
            echo "VPN: $vpn_ip"
            return
        fi
    fi
    # 2. Check Hardware Interfaces (Ethernet then Wi-Fi)
    # Get all active interfaces with IPs
    while IFS=: read -r port dev; do
        local ip=$(ipconfig getifaddr "$dev" 2>/dev/null)
        [[ -z "$ip" ]] && continue

        if [[ "$port" =~ "Ethernet" || "$port" =~ "LAN" ]]; then
            eth_ip="$ip"
            # If we find Ethernet, we can stop looking at hardware (Ethernet > Wi-Fi)
            break 
        elif [[ "$port" == "Wi-Fi" ]]; then
            wifi_ip="$ip"
        fi
    done < <(networksetup -listallhardwareports | awk -F': ' '/Hardware Port/ {p=$2} /Device/ {print p ":" $2}')

    # Output based on priority
    if [[ -n "$eth_ip" ]]; then
        echo "ENet: $eth_ip"
    elif [[ -n "$wifi_ip" ]]; then
        echo "Wi-Fi: $wifi_ip"
    else
        echo "No active adapter found"
    fi
}

extensionID="NetworkInfo"

# Start spinning indicator
defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_loading" -bool true

# Keep loading effect active for 0.5 seconds
sleep 0.5

# Get the active network adapter and its IP address
retval=$(get_nic_info)
# Write output to Support App preference plist
defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}" -string "${retval}"

# Stop spinning indicator
defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_loading" -bool false
if [[ $retval =~ "No active" ]]; then
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_alert" -bool true
else
    defaults write /Library/Preferences/nl.root3.support.plist "${extensionID}_alert" -bool false
fi
```

Some sample output:

![](IP_Adresses.png)


## JAMF Checkin

This one came with the sample scripts from the support.app site, but I found it useful, so I am putting it into my setup

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

# ---------------------    do not edit below this line    ----------------------

# Support App preference plist
preference_file_location="/Library/Preferences/nl.root3.support.plist"

# Start spinning indicator
defaults write "${preference_file_location}" "${extension_id}_loading" -bool true

# Replace value with placeholder while loading
defaults write "${preference_file_location}" "${extension_id}" -string "Checking in..."

# Perform a Jamf Pro check-in
/usr/local/bin/jamf policy

# Run script to populate new values in Extension
/private/var/db/ManagedConfigurationFiles/BackgroundTaskServices/Services/nl.root3.support/jamf_last_check-in_time.zsh
```
