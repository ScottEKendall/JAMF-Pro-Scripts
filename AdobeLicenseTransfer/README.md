## Adobe License Transfer

This was born out of necessity.  In our environment, we have to transfer license between users as we cannot have a "site license" per facility.  This script will take the pertanent info and compose the message that can be used to submit a HelpDesk ticket for the transfer.

Inital Welcome screen

![](/AdobeLicenseTransfer/AdobeLicenseTransfer_Welcome.png)

Results message after form

![](/AdobeLicenseTransfer/AdobeLicenseTransfer_Done.png)

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial commit
| 1.1 | more concise model name ("2023 Macbook Pro") vs ("MacBook Pro (14-inch, Nov 2023)")
| 1.2 | Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
| 1.3 | Code cleanup / Added feature to read in defaults file / removed unnecessary variables.
| 1.4 | Fixed window layout for Tahoe & SD v3.0
| 1.5 | Changed JAMF 'policy -trigger' to JAMF 'policy -event'

