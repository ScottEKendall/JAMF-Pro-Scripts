## Plaform SSO Repository ##

This section is designed to accomodate everything Micdrosoft Platform SSO related.  My goal is to try and consolidate everything that an admin needs to be aware of when migrating users to Platform SSO for macOS Sequoia and higher.  I am hoping for other contributors in this repo to make this a central repository for everything related to this extension.  I will be posting the information that I have concerning JAMF MDM, but others are welcome to post about coniguration files for other MDMs.

### JAMF Configuration ###

In order to prepare for Platform SSO deployment, you must perform the following:

* [Deploy Microsoft Company Portal](#company-portal)
* [Create the Platform SSO Configuration Profile](#ceate-psso-configuration-profile)
* [Configure ADE for Simplified Setup](#configure-ade-for-simplied-setup)
* Deliver the PlatformSSO Configuration Profile
* Remove any existing SSO Extension Profile
* Enable access to the System Settings -> Users & Groups.  Inside of there are options to repair the SSO extension for users
* Make sure touchID is enabled for users if you are using the Secure Enclave for pSSO

#### Company Portal ####

* You need to install v5.2404.0 or newer in your prestage enrollment (for new enrollments) or install via policy (to existing users).  Company Portal can be downloaded [here](https://go.microsoft.com/fwlink/?linkid=853070)

#### Ceate pSSO Configuration Profile ####

You need to have a configuration profile for the Platform SSO that can be deployed.  *IMPORTANT!*  You CANNOT have both SSO Extension and Platform SSO Extension deployed to all users simultaneously.  The best way to do this is to create groupings and deploy the pSSO to the users in the group, while simultenously excluding them from the SSO Extension group.  Screenshot for exxample:

![](./JAMF_Configuration_Policy_Groupings.png)

When setting up the Configuration Profile, you can use either the Microsoft [docs](https://learn.microsoft.com/en-us/intune/intune-service/configuration/use-enterprise-sso-plug-in-macos-with-intune?tabs=prereq-jamf-pro%2Ccreate-profile-jamf-pro) or JAMF [docs](https://learn.jamf.com/en-US/bundle/technical-articles/page/Platform_SSO_for_Microsoft_Entra_ID.html#ariaid-title9).  I have included screenshots of my setup for easier reference:

![](./JAMF_Configuration_Policy_Summary.png)
![](./JAMF_Configuration_Poicy_SSO_Payload1.png)
![](./JAMF_Configuration_Poicy_SSO_Payload2.png)
![](./JAMF_Configuration_Poicy_SSO_Payload3.png)

Please note: you must configure an Associate Domain payload, but it does NOT need to have anything in it, just configure it... 

#### Configure ADE for Simplied Setup ####

You will need to make some changes to your ADE (Automated Device Enrollment) setup to take advantage of pSSO:

1. Navigate to JAMF > Computers > Prestage Enrollment
2. In the General section, you need to "Enable Simplified setup" and add "com.microsoft.CompanyPortalMac" in the field

![](./JAMF_ADE_General.png)

3. In the Configuration Profiles section, make sure that your Platform SSO group is checked, so it will get pushed down during new enrollments

![](./JAMF_ADE_ConfigProfiles.png)

4. Make sure to add the Company Portal app in the Enrollment Packages section

#### Deliver the pSSO Config Profile ####

Once you have setup your smart/static group for deployment, you can push it to all of the users...once the profile gets installed on their mac, they will see the following in their notification center.

![](https://learn.microsoft.com/en-us/intune/intune-service/configuration/media/platform-sso-macos/platform-sso-macos-registration-required.png)

And the user will need to proceed with the registration prompts.

In case the users do not see the notification center prompt (or they dismiss it), it will reappear after a period of time (I think around 15 mins), but you can "force" the prompt to reappear again.  You can either have the user logout/login, or you can use a script I created (found [here](/JAMF-Pro-Scripts/ForcePlatformSSO/README.md)) that will force the propmt to reappear and show a nice GUI screen so the users (hopefully) don't miss it again.

JAMF Docs
* Platform SSO can be found [here](https://learn.jamf.com/en-US/bundle/technical-articles/page/Platform_SSO_for_Microsoft_Entra_ID.html)
* Configuration Profiles can be found [here](https://learn.jamf.com/en-US/bundle/technical-articles/page/Platform_SSO_for_Microsoft_Entra_ID.html#ariaid-title9)

Microsoft Links:
[Company Portal](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-company-portal-macos)