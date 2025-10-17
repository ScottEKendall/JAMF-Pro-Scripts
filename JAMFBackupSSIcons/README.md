## Backup Self Service Icons

This script is designed to extract all of the icons from all Self Service policies and store them on a local folder.  Great for when Self Service starts to display generic icons...you can restore them with your backup.

Welcome Screen

![Welcome](./BackupSSIcons_welcome.png)

Process Screen

![](./BackupSSIcons_process.png)

Script Parameters

![](./BackupSSIcons_parameters.png)

The is a heavily modified version from Der Flounder's website: https://derflounder.wordpress.com/2022/01/12/backing-up-self-service-icon-graphic-files-from-jamf-pro/.  Just updated with the ability to call it from JAMF, modified for ZSH, and show a status screen during operation.

If you are using the Modern JAMF API credentials, you need to set:

* Read Policies

##### _v1.0 - Initial Commit_
