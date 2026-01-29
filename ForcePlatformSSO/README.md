## Force Platform SSO Prompt

This script is designed to force the prompt for Platform SSO on the users desktop. It does this by: 

* Determining if the Platform SSO profile is installed on their Mac
* Removing the user out of the MDM profile group for the Platform SSO (if necessary)
* Re-adding the user to the same Platform SSO group again
  
 The script is focus mode aware and can display the apropriate message accordingly.

_This is designed to use JAMF static groups for Configuration Profile deployment_

It should force the pSSO register prompt to reappear.  Once the prompt reappears, it will display a nicely formatted Swift Dialog prompt informing the user what to do.

Script was inspired by the work done by Howie Canterbury.


![](./ForcePlatformSSO.png)

If the user has focus mode turned on, they will get a slightly different message

![](./ForcePlatformSSO-Focus.png)

If you are using the Modern JAMF API credentials, you need to set:

* `Update Static Computer Groups`

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial
| 1.1 | Made MDM profile and JAMF group name passed in variables vs hard coded
||      Make sure that all exit processes go thru the cleanup_and_exit function
||      Made the psso command run as current user (Thanks Adam N)
||      Perform a gatherAADInfo command after successful registration
| 1.2 | Put in the --silent flag for the curl commands to not clutter the log
||      changed logic in the detection of SS+...it was not returning expected value
||      Change the gatherAADInfo to RunAsUser vs root
| 1.3 | removed the app-sso -l command...wasn't really needed 
| 1.4 | Added feature to check for focus status and change the alert message accordingly
| 1.5 | Used modern JAMF API wherever possible
||      More logging of events
||      More error trapping of failures
||      Reworked Common section to be more inline with the rest of my apps
||      Fixed Typos
