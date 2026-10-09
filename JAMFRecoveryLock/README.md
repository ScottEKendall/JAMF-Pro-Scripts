## Set / Clear Recovery Lock

Nice GUI method of setting or clearing the recovery lock.  *This only works for Apple Silicon Macs*.  It prevents the users from going into the recovery mode and changing options or reinstalling the OS

Initial Welcome screen

![](./JAMFRecoveryLock_Welcome.png)

Successful lock for device.

![](./JAMFRecoveryLock_Complete_Set.png)

Successful clear for device

![](./JAMFRecoveryLock_Complete_Clear.png)

Error screen for no device found

![](./JAMFRecoveryLock_Failure.png)

Details of JAMF Parameter(s)

![](./JAMFRecoveryLock_Parameters.png)

If you are using the Modern JAMF API credentials, you need to set:

* ```View MDM command information in Jamf Pro API```
* ```View Recovery Lock```

Kudos to Karthikeyan Marappan for coming up with the concept.  I just put a nice GUI frontend to it.  
Original source: https://gist.github.com/karthikeyan-mac/185bf8319fa9560f300ed26553a7a54d

## History ##

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial
| 1.1 | Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
| 1.2 | Reworked top section for better idea of what can be modified
||       renamed all JAMF functions to begin with JAMF_
| 1.3 | Verified working against JAMF API 11.20
||       Added option to detect which SS/SS+ we are using and grab the appropriate icon
||       Now works with JAMF Client/Secret or Username/password authentication
||       Change variable declare section around for better readability
||       Bumped Swift Dialog to v2.5.0
| 1.4 | Fixed invalid function call to invalidate JAMF token
||       Fixed determination of which SS/SS+ the script should be using
||      Added function to check and make sure the JAMF credentials are passed
||      Renamed utility to JAMFRecoveryLock.sh
| 1.5 | Added option to view recovery password
||       new APIs for set/clear recovery Lock
||       Show http results after set/clear command
| 1.6 | Had to increase window height for Tahoe & SD v3.0
| 1.7 | Changed JAMF 'policy -trigger' to 'JAMF policy -event'
||       Optimized "Common" section for better performance
||       Fixed variable names in the defaults file section
| 2.0 | Updated SD Version requirements to 3.1.0
||       Added ability to set subtitle, color, and padding from defaults file
| 2.1 | Verified compatibility with Jamf Pro 11.30
||       Updated Recovery Lock workflows to use current Jamf Pro API endpoints
||       Improved API token handling and validation for both OAuth Client Credentials and Classic API authentication
||       Added automatic token renewal logic when tokens approach expiration
||       Improved Jamf Pro connection validation and error handling
||       Added additional API response validation to prevent unexpected processing failures
||       Enhanced computer lookup logic to ensure a single unique device match before executing Recovery Lock actions
||       Improved Recovery Lock password retrieval handling when no password is stored in Jamf Pro
||       Added validation for Set Recovery Lock operations when no Recovery Lock password is supplied
||       Improved temporary file security by applying restricted permissions to API response files
||       Enhanced cleanup routines to properly invalidate and remove API tokens at script completion
||       Improved logging consistency throughout the workflow
||       Improved SwiftDialog response validation and error handling
||       Enhanced support file and banner image detection logic
||       General code cleanup, optimization, and stability improvements
