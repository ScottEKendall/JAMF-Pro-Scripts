## EntraID Registration

We are use Azure/Entra ID & JAMF exclusively in our environmnet, so this script is designed to show the end user the status of their EntraID Registration on their Mac

The user will get the following screens depending on their registration status

If successfull

![](/EntraIDRegistration/Entra_Success.png)

User registered (WPJ Key in Keychains), but no AAD Plist found

![](/EntraIDRegistration/EntraID_Plist_missing.png)

User Registered (WPJ Key in Keychiains), but AAD ID Not Accquired

![](/EntraIDRegistration/EntraID_No_AAD.png)

User not registered at all

![](/EntraIDRegistration/Entra_Failure.png)


##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_
##### _v1.2 - Fix problem of Register button not running Policy ID_
##### _v1.3 - Removed debug code and fix incorrect message on success dialog_
