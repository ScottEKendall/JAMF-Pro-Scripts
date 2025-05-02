## Remove Adobe Apps (User Interaction)
This process will display a dialog that will allow the users to choose which Adobe apps that they want to remove.  It will NOT let them remove the highest "level" product version installed. (see the selection screenshots).  This process wil also remove any CS apps as well as Safari Flash plugin, outdated Reader and Acrobat apps as well.

**Selection Screen**

(An optional JAMF variable can be passed in to show the current CC year.)  If the user does not have that version already installed, it will display the notice that a newer version is available).  I used the 2026 as a reference to show the availability prompt

![Selection Screen](/RemoveAdobeApps/RemoveAdobe_selection.png)

**Confirmation Screen**

![Confirmation Screen](/RemoveAdobeApps/RemoveAdobe_confirm.png)

**Removal Process**

![Removal](/RemoveAdobeApps/RemoveAdobe_removal.png)

I have tested this against several years worth of apps, but I have not tested anything prior to 2021

![finder list](/RemoveAdobeApps/RemoveAdobe_FinderTests.png)

Results of the```AdobeCCUninstaller --list``` command to show the BASE Codes and SAPCodes

![](/RemoveAdobeApps/RemoveAdobe_Terminal_Base_codes.png)

The two critial functions for this process are noted here:

```extract_version_code()```: (This handles any "descrepencies" from Adobe's BaseVersion naming convention).  I use the ```CFBundleShortVersionString``` plist entry to determine the Baseversion number, but Adobe is not 100% consistent with their numbering scheme, so editng the CASE statement in this function can allow for changes to the version string.

```adobeJSONarray```:  This handles the Application name and its SAPCode.

Feel free to change those two areas to accomodate anything that I might have missed during testing!

## Adobe Uninstallers ##

NOTE! The terminal binaries "AdobeUninstaller" and the files inside the folder Adobe_CC_and_below, must be installed in /usr/local/bin for this to work properly.

I packaged up both of these apps and the script will request the JAMF install if they are missing.

##### _v1.0 - Initial Commit_
##### _1.1 - Changed buttons to "Next" and "Remove" on the appropriate screens_
##### _1.2 - Change find command to exclude Adobe Experience Manager and Adobe Acrobat DC_

