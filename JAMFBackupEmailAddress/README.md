## Export JAMF emails to VCF Cards

This one grew out of necessity in my current role. I needed to export a list of email addresses from JAMF Pro and import them into outlook for a DL. I couldn't find a way to do this in JAMF, so I wrote this script to do it.

Welcome Screen

![](./BackupJAMFEmailAddress-Welcome.png)

Progress Screen

![](./BackupJAMFEmailAddress-Progress.png)

## JAMF API Information ##

If you are using the Modern JAMF API credentials, you need to set:

```Read Users```

## History ##

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial
| 1.1 | Created a few new functions to reduce complexity / document function details / renamed all JAMF functions to start with JAMF......
| 1.2 | Verified working agains JAMF API 11.20
||       Added option to detect which SS/SS+ we are using a grab the appropriate icon
||       Now works with JAMF Client/Secret or Username/password authentication
||       Change variable declare section around for better readability
||       Changed to using JSON blobs vs XML Blobs
||       Bumped Swift Dialog to v2.5.0
| 1.3 | Add function to check for passed JAMF credentials
| 2.0 | Added better error handling and display of error messages to the user.
||       Had to increase window height for Tahoe & SD v3.0
||       Changed JAMF 'policy -trigger' to JAMF 'policy -event'
||       Optimized "Common" section for better performance
||       Added option to read in the defaults file
||       Fixed function to check which SS/SS+ is being used (again)
||       Fully multitasking enabled for faster processing of large user counts
| 2.1 | Updated SD Version requirements to 3.1.0
||       Added ability to set subtitle, color, and padding from defaults file
