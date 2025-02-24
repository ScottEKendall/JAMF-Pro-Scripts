## MigrateUserAccount

This script is designed to do (basically) a "rename" of the users home folder, but it isn't as simple as just a simple rename.  It actually creates a new account and migrates the data to the new account to make sure that it follows the Apple process for creating accounts, which will allow the use FileVault if necessary.

**This migration process cannot migrate the account from the current logged in user!**

Initial Welcome Screen

![](/MigrateUserAccount/MigrateUserAccount_Conversion.png)

Various sanity checks & errors

![](/MigrateUserAccount/MigrateUserAccount_Failure.png)

Successful transfer of user accounts (restart is necessary if successful)

![](/MigrateUserAccount/MigrateUserAccount_Success.png)



##### _v1.0 - Initial Commit_
##### _v1.1 - Major code cleanup & documentation / Structred code to be more inline / consistent across all apps_

