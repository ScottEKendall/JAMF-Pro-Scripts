## App Delete

This script is designed to allow non-admin users the ability to remove applications and folders from the /Applications folder. 

You can control what applications they are not allowed to remove by putting items into the ```MANAGED_APPS``` array.  

You can also inlcude folders that are allowed to be deleted, by putting them into the ```ALLOWED_FOLDERS``` array.

It automaticaly excludes the preinstalled items that come with the OS _[SIP Protected]_.

### Screenshots ###
Picture of what the end users see when they run it:

![User's View](/AppDelete/AppDelete-Welcome.png)

The script will have them confirm their choices before the actual deletion occurs

![](/AppDelete/AppDelete-Confirm.png)

and give them an option to do it again (and again)

![](/AppDelete/AppDelete-Results.png)


##### _v1.0 - Initial Commit_

##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_

##### _v2.0 - NEW: Added option to allow folders to be deleted / Bumped Swift Dialog min version to 2.5.0 / Put shadows in the banner text / Reordered sections to better show what can be modified_
