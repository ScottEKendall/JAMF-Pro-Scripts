## Dialog Message

I created a "generic" dialog message that can be used to send out message to JAMF users.  Great for annoucning items like upcoming OS releases... The timer was put it to make sure that the dialog gets dismissed and doesn't hang up any policies from being run.  



![](/DialogMsg/DialogMsg_Example.png)

The parameters page of the system script allows for a wide variety of customization

![](/DialogMsg/DialogMsg_Script_Parameters.png)


Language Support

This script will now support a 2nd display language.  If you are going to use a dual language notfication, then you will need to do the following:

Paramater 5 message should be formatted as such "[2 Character country code] | (message)"<br>
Parameter 6 will be your alternate language with the same format

for example:

```EN | Apple has released macOS Sequoia for installation at this time.  Your system will prompt you to upgrade to Sequoia after it has downloaded the installer to your Mac.```

```DE | Apple hat macOS Sequoia zur Installation freigegeben. Nach dem Herunterladen des Installationsprogramms auf Ihren Mac werden Sie aufgefordert, auf Sequoia zu aktualisieren.```

The script will determine the country code of the local Mac and display the appropriate message...if it cannot find the appropriate langauge text to display, it will default to EN, but that can be changed with the variable ```SD_DEFAULT_LANGUAGE```

##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_
##### _v1.2 - the JAMF_LOGGED_IN_USER will default to LOGGED_IN_USER if there is no name present_
#####       - Added -ignorednd to make sure that the message is displayed regardless of focus setting
#####       - Will display the infobox items if you can the function first
#####       - Minimum version of SwiftDialog is now 2.5.0
##### _v1.3 - supports a 2nd language._

