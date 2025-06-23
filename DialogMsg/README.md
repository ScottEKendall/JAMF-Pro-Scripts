## Dialog Message

I created a "generic" dialog message that can be used to send out message to JAMF users.  Great for annoucning items like upcoming OS releases... The timer was put it to make sure that the dialog gets dismissed and doesn't hang up any policies from being run.  



![](/DialogMsg/DialogMsg_Example.png)

The parameters page of the system script allows for a wide variety of customization

![](/DialogMsg/DialogMsg_Script_Parameters.png)


##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_
##### _v1.2 - the JAMF_LOGGED_IN_USER will default to LOGGED_IN_USER if there is no name present_
#####       - Added -ignorednd to make sure that the message is displayed regardless of focus setting
#####       - Will display the infobox items if you can the function first
#####       - Minimum version of SwiftDialog is now 2.5.0