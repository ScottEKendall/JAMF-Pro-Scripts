If your environment has multi-user (shared) macs, then these scripts might come in handy. 
The following post is designed for Micosoft EntraID based environments, but could probably be adapted easily for other environments.  I will will point out the specific EntraID code in this document.

The first thing that I have to deal with is what state each user is in regards to their EntraID status:

EA's used for InTune Registration

[EA for Registration](https://github.com/ScottEKendall/JAMF-Pro-EAs/blob/main/InTune%20Registration%20Status.sh)

From there you can create Smart Groups based off of registration status and take appropriate actions.  A Sample output might be:

![](/Single-User%20Registration.png)

The next thing that I do is to retreive (from inTune) the users last password change date (the field is `LastPasswordChangedDateTime` from the MS Graph API)

(*This is code is inTune specific*).  You MUST pass in the follow items to the script:
- inTune Client ID
- inTune Client Secret
- inTune Client Tenant

The code to retrieve the password info is located here.  I also calculate the password Age as well.  That is used later on... 

[Script to retreive Password Change Date](https://github.com/ScottEKendall/JAMF-Pro-System-Scripts/blob/main/Maintenance%20-%20Passwords%20-%20Populate%20Plist%20File%20(inTune).sh)

A few things to note here:
 - I store these keys in each users `~/Library/Application Support/*.plist`.  These two variables control where the file is located and the plist file name
    - `SUPPORT_DIR="/Users/$LOGGED_IN_USER/Library/Application Support"`
    - `JSS_FILE="$SUPPORT_DIR/com.GiantEagleEntra.plist"`
- Both password last change date andd password age are stored in this file
- I decided to put this in each users folder, so if the user gets removed from the system, their password info gets removed as well
- You can put anything in this file you want...espcially handy if you need to stored server related items that could be used later, it is a simple .plist file

This script is run once a day to populate the file in the users folder.  If the file doesn't exisst, it will be created automatically

The next thing I need to do create EAs for the users password last change date & password Age.  those scripts can be found here:

Password Last Change Date:

[](/JAMF-Pro-EAs/Password%20Plist%20Entry.sh)

Password Age:

[](/JAMF-Pro-EAs/Password%20Age.sh)

Here is what a sample out of a single user mac would show:

![](/JAMF-Pro-Scripts/Multi-User%20Macs/Single-User%20Password.png)

and this is a sample output of a shared mac: (it will show the user name as well as their password info)

![](/JAMF-Pro-Scripts/Multi-User%20Macs/Multi-User%20Password.png)

At the beginning of each EA is where to find the plist file:

`SUPPORT_DIR="/Users/$LOGGED_IN_USER/Library/Application Support"`
`JSS_FILE="$SUPPORT_DIR/com.GiantEagleEntra.plist"`