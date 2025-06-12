## JAMF System Utilities    

This script is designed to extract all of several items from your JAMF server.  Why do you want to do this?

1.  Make a backup of your scripts, configurations & icons in case your existing backup files is missing/corrupted (or you don't have one!)
2.  You inhereited a JAMF server from another person, and this can do a "brain dump" so you can review the settings.
3.  Why not?  It is another example of what you can do with API scripts..

The following items are available to be backed up:

1.  Self Service Icons - Great to have a back when JAMF starts showing generic icons in Self Service.
2.  Failed MDM Commands - Export systems that have failed MDM commands so you can review them and optionally clear the failures
3.  System Scripts - Everything that is stored in Settings > Scripts
4.  Computer Extension Attributes - Export all of the computer extension attributes
5.  Configuration Profiles - Export all of the configuration profiles to .mobileconfig files
6.  Export Emails to VCF - Export all of the email addresses to a VCF file, which can be imported into Contacts.app or other applications.
7.  Smart / Static Computer Groups - Export all of the smart and static computer groups:
   - Smart Computer Groups will export the paramaters and criteria to a .txt file
   - Static Computer Groups will export the members to a .txt file
8.  Export VCF cards of the members of a Smart / Static Computer Group.
9.  Compose an email to the members of a Smart / Static Computer Group.


This script is fully multitasked, so will execute each task pretty quickly.  It will create the folder structure for you and then download the items to the appropriate folders. 

**File Formats**

1. Icons have a .png extension.
2. Scripts have a .sh extension.
3. Computer Extension Attributes have a .sh extension.
4. Configuration Profiles have a .mobileconfig extension.
5. Emails have a .vcf extension.
6. Smart / Static Computer Groups have a .txt extension.

**Folder Structure**

The subfolder locations can be customized by editing the ```function check_directories```

------------------------------------

Welcome Screen
![Welcome](/JAMFSystemUtilities/JAMFSystemUtilities-Welcome.png)

Backup SS Icons Process
![](/JAMFSystemUtilities/JAMFSystemUtilities-BackupIcons.png)

Export Failed MDM Commands Process
![](/JAMFSystemUtilities/JAMFSystemUtilities-failedmdm.png)

Backup System Scripts Process
![](/JAMFSystemUtilities/JAMFSystemUtilities-Scripts.png)

Backup Computer Extension Attributes Process
![](/JAMFSystemUtilities/JAMFSystemUtilities-ComputerEA.png)

Backup Configuration Profiles Process
![](/JAMFSystemUtilities/JAMFSystemUtilities-Profiles.png)

VCF (Emails) options

![](/JAMFSystemUtilities/JAMFSystemUtilities-VCFOptions.png)

Export Emails Process
![](/JAMFSystemUtilities/JAMFSystemUtilities-Contacts.png)

##### _v1.0 - Initial Commit_
