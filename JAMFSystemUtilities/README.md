## JAMF System Utilities    

This script is designed to extract all of several items from your JAMF server.  Why do you want to do this?

1.  Make a backup of your scripts & icons in case your existing backup files is missing/corrupted (or you don't have one!)
2.  You inhereited a JAMF server from another person, and this can do a "brain dump" so you can review the scripts.
3.  Why not?  It is another example of what you can do with API scripts..

The following items are available to be backed up:

1.  System Scripts - Everything that is stored in Settings > Scripts
2.  Self Service Icons - Great to have a back when JAMF starts showing generic icons in Self Service.
3.  Export Emails to VCF - Export all of the email addresses to a VCF file, which can be imported into Contacts.app or other applications.

Welcome Screen

![Welcome](/JAMFSystemUtilities/JAMFSystemUtilities-Welcome.png)

Backup SS Icons Process

![](/JAMFSystemUtilities/JAMFSystemUtilities-BackupIcons.png)

Backup System Scripts Process

![](/JAMFSystemUtilities/JAMFSystemUtilities-Script-Progress.png)

Export Emails Process

![](/JAMFSystemUtilities/JAMFSystemUtilities-Email-Progress.png)

##### _v1.0 - Initial Commit_
