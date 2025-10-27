## Plaform SSO Repository ##

This section is designed to accomodate everything Micdrosoft Platform SSO related.  My goal is to try and consolidate everything that an admin needs to be aware of when migrating users to Platform SSO for macOS Sequoia and higher.  I am hoping for other contributors in this repo to make this a central repository for everything related to this extension.  I will be posting the information that I have concerning JAMF MDM, but others are welcome to post about coniguration files for other MDMs.

### JAMF Configuration ###

In order to prepare for Platform SSO deployment, you must perform the following:

* Deploy Microsoft Company Portal version 5.2404.0 and newer in your prestage enrollment (for new enrollments) or install via policy (to existing users).  Company Portal can be found [here](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-company-portal-macos)