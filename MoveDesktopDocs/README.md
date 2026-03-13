## Move Desktop & Documents ##

We have several multi-user macs in our environment, and we need to make sure that documents from all users are in a common location so that everyone can have access to them.  This script will copy the currently logged in user's Desktop & Documents into /Users/Shared, verify that they are copied successfully, and then make an alias to their migrated documents.

![](./MoveDesktopDocs.png)

## History ##

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial Release |
| 1.1 | Fixed window layout for Tahoe & SD v3.0
| 1.2 | Changed JAMF 'policy -trigger' to JAMF 'policy -event'
||       Optimized "Common" section for better performance
||       Fixed variable names in the defaults file section

