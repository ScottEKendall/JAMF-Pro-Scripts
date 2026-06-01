## WhatMyIP

Nice GUI to display all of the IPv4 address on a user's system (will find Cisco AnyConnet IP address if connected)

![](./WhatsMyIP.png)

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial
| 1.1 | Code cleanup to be more consistent with all apps
| 1.2 | Reworked logic for all physical adapters to accommodate for older macs
| 1.3 | Included logic to display Wifi name if found
| 1.4 | Changed logic for Wi-Fi name to accommodate macOS 15.6 changes
||       Reworked top section for better idea of what can be modified
| 1.5 | Code cleanup
||      Added feature to read in defaults file
||       removed unnecessary variables.
||       Fixed typos
| 1.6 | Changed JAMF 'policy -trigger' to 'JAMF policy -event'
||       Optimized "Common" section for better performance
||       Fixed variable names in the defaults file section
| 1.7 | Reworked logic to get all active physical adapters.  This allows for better support of older macs with multiple Ethernet ports and Thunderbolt adapters.
||       Rename any adapter with "Ethernet" or "LAN" in the name to just "Ethernet"
||       Check for both Cisco Secure Client and AnyConnect for VPN IP collection
| 1.8 | Fixed logic to check for VPN IP to look for "Not Available" instead of just checking if the variable is empty.
| 1.9 | # 1.9 - Added logic to display the Wi-Fi network name next to the IP address for Wi-Fi connections.  
||       This will help users identify which network they are connected to, especially if they have multiple Wi-Fi networks with different IP addresses.
||       Reworked VPN logic detection (put inside of a do...while loop) to be more efficient and to accommodate for any VPN client that may be installed in the future (instead of just checking for specific clients). 