# JAMF Pro Scripts

A collection of macOS administration, remediation, inventory, migration, security, and Jamf Pro API tools developed over the years while working with Jamf Pro.

Many of these projects use [SwiftDialog](https://github.com/swiftDialog/swiftDialog) to provide polished graphical workflows for Mac administrators and end users.

> **Note:** Many of these scripts were originally built for a specific production environment. Review each project's requirements, Jamf Pro privileges, policy triggers, paths, branding, and configurable values before deploying in your environment.

## Browse by Category

<table>
<tr>
<td width="33%" valign="top">

### 👤 End User & Self Service

User-facing tools, notifications, and guided workflows.

- [Adobe License Transfer](./AdobeLicenseTransfer)
- [Clear Browser Cache](./ClearBrowserCache)
- [Delete Printers](./DeletePrinters)
- [Dialog Message](./DialogMsg)
- [Dialog Progress](./DialogProgress)
- [Force Platform SSO](./ForcePlatformSSO)
- [Mount Network Drive](./MountNetworkDrive)
- [Password Expiration](./PasswordExpire)
- [Reset Keychain](./ResetKeychain)
- [Restart Zscaler](./RestartzScaler)
- [Set Default Apps](./SetDefaultApps)
- [Speed Test](./SpeedTest)
- [Wallpaper Picker](./WallpaperPicker)
- [What's My IP](./WhatsMyIP)

</td>
<td width="33%" valign="top">

### 🩹 First Aid & Remediation

Repair, cleanup, recovery, and troubleshooting workflows.

- [App Delete](./AppDelete)
- [Change FileVault Key](./ChangeFVKey)
- [Delete Expired Certificates](./DeleteExpiredCerts)
- [Escrow Bootstrap Token](./EscrowBootStrap)
- [Fix Profile Owner](./FixProfileOwner)
- [Grant Secure Token](./GrantSecureToken)
- [Low Disk Space](./LowDiskSpace)
- [Nuke Adobe Creative Cloud](./NukeAdobeCC)
- [Nuke Microsoft Office](./NukeOffice)
- [PPPC Nudge](./PPPCNudge)
- [Remove Adobe Apps](./RemoveAdobeApps)
- [SSO Remediation](./SSORemediation)
- [Windows Filename Fix](./WindowsFileNameFix)

</td>
<td width="33%" valign="top">

### 🛡️ Security, Identity & Compliance

FileVault, Recovery Lock, secure token, SSO, compliance, and security tools.

- [Change FileVault Key](./ChangeFVKey)
- [Device Compliance](./DeviceCompliance)
- [Entra ID Registration](./EntraIDRegistration)
- [Escrow Bootstrap Token](./EscrowBootStrap)
- [Force Platform SSO](./ForcePlatformSSO)
- [Grant Secure Token](./GrantSecureToken)
- [Inspect CrowdStrike](./InspectCrowdstrike)
- [JAMF Recovery Lock](./JAMFRecoveryLock)
- [JAMF Retrieve FileVault](./JAMFRetrieveFV)
- [Password Expiration](./PasswordExpire)
- [SSO Remediation](./SSORemediation)

</td>
</tr>
<tr>
<td width="33%" valign="top">

### ⚙️ Jamf Pro Administration

API-driven administration, backup, reporting, search, and device-management utilities.

- [JAMF Backup Email Address](./JAMFBackupEmailAddress)
- [JAMF Backup Self Service Icons](./JAMFBackupSSIcons)
- [JAMF Backup Scripts](./JAMFBackupScripts)
- [JAMF Binary Redeploy](./JAMFBinaryRedeploy)
- [JAMF Branding Manager](./JAMFBrandingManager)
- [JAMF Clear Failed MDM](./JAMFClearFailedMDM)
- [JAMF Config Profile Search](./JAMFConfigProfileSearch)
- [JAMF Get DDM Info](./JAMFGetDDMInfo)
- [JAMF Recovery Lock](./JAMFRecoveryLock)
- [JAMF Retrieve Expiration Dates](./JAMFRetrieveExpireDates)
- [JAMF Retrieve FileVault](./JAMFRetrieveFV)
- [JAMF Static Group Utility](./JAMFStaticGroupUtility)
- [JAMF System Utilities](./JAMFSystemUtilities)

</td>
<td width="33%" valign="top">

### 🔎 Inventory & Diagnostics

Inventory, device health, logs, networking, and troubleshooting information.

- [Architecture Scan](./ArchitectureScan)
- [Battery Info](./BatteryInfo)
- [Device Compliance](./DeviceCompliance)
- [Dialog Inventory](./DialogInventory)
- [Disk Usage](./DiskUsage)
- [Inspect CrowdStrike](./InspectCrowdstrike)
- [Read DDM Software Update](./ReadDDMSoftwareUpdate)
- [Speed Test](./SpeedTest)
- [UpTime](./UpTime)
- [View Inventory](./ViewInventory)
- [View Logs](./ViewLogs)
- [What's My IP](./WhatsMyIP)

</td>
<td width="33%" valign="top">

### 🚚 Migration & Provisioning

Account migration, device setup, shared Mac, and data-movement workflows.

- [Entra ID Registration](./EntraIDRegistration)
- [Migrate User Account](./MigrateUserAccount)
- [Migration Wizard](./MigrationWizard)
- [Move Desktop and Documents](./MoveDesktopDocs)
- [Multi-User Macs](./Multi-User%20Macs)
- [Set Default Apps](./SetDefaultApps)

</td>
</tr>
<tr>
<td width="33%" valign="top">

### 📦 Application Management

Install, remove, inspect, and manage applications and packages.

- [Adobe Detect Multiple](./AdobeDetectMultiple)
- [Adobe License Transfer](./AdobeLicenseTransfer)
- [App Delete](./AppDelete)
- [Brew Package Removal](./BrewPkgRemoval)
- [Nuke Adobe Creative Cloud](./NukeAdobeCC)
- [Nuke Microsoft Office](./NukeOffice)
- [Remove Adobe Apps](./RemoveAdobeApps)
- [Set Default Apps](./SetDefaultApps)

</td>
<td width="33%" valign="top">

### 🧰 Admin & Developer Utilities

Tools for administrators, script authors, packaging, and SwiftDialog development.

- [Dialog Icon Creator](./DialogIconCreator)
- [Get Bundle ID](./GetBundleID)
- [Text File Search](./TextFileSearch)
- [Default Postflight Script](./Default_post.sh)
- [Main Library](./MainLibrary.sh)

</td>
<td width="33%" valign="top">

### 🎨 SwiftDialog Examples

Reusable examples demonstrating notifications, progress, inventory, icons, and branded workflows.

- [Dialog Icon Creator](./DialogIconCreator)
- [Dialog Inventory](./DialogInventory)
- [Dialog Message](./DialogMsg)
- [Dialog Progress](./DialogProgress)
- [JAMF Branding Manager](./JAMFBrandingManager)
- [Wallpaper Picker](./WallpaperPicker)

</td>
</tr>
</table>

## Featured Jamf Pro Tools

A few of the larger utilities in the repository:

| Project | What it does |
| --- | --- |
| [JAMF Get DDM Info](./JAMFGetDDMInfo) | Investigates Declarative Device Management status, Blueprint information, software updates, and device-reported DDM data. |
| [JAMF Static Group Utility](./JAMFStaticGroupUtility) | View and modify static group membership, including bulk and migration-style operations. |
| [JAMF Retrieve Expiration Dates](./JAMFRetrieveExpireDates) | Audits expiration dates for Jamf Pro certificates, tokens, invitations, and related services. |
| [JAMF Recovery Lock](./JAMFRecoveryLock) | Provides a graphical workflow to view, set, and clear Recovery Lock on Apple silicon Macs. |
| [JAMF Branding Manager](./JAMFBrandingManager) | Manage Jamf Self Service branding records and banner images through SwiftDialog. |
| [JAMF Clear Failed MDM](./JAMFClearFailedMDM) | Review and clear failed MDM commands from managed devices. |
| [JAMF Config Profile Search](./JAMFConfigProfileSearch) | Search Jamf Pro configuration profiles for specific keys or configuration data. |
| [JAMF Backup Scripts](./JAMFBackupScripts) | Export and back up scripts stored in Jamf Pro. |

## Getting Started

1. Choose a category above or browse the repository folders.
2. Open the project you want to use.
3. Review its README, source comments, version history, parameters, and dependencies.
4. Configure any environment-specific paths, Jamf Pro custom events, API credentials, branding, or other required values.
5. Test in a non-production environment before broad deployment.

## Common Technologies

Depending on the project, these scripts may use:

- [Jamf Pro](https://www.jamf.com/products/jamf-pro/)
- [SwiftDialog](https://github.com/swiftDialog/swiftDialog)
- macOS `zsh`
- `jq`
- Jamf Pro APIs
- OAuth client credentials or other Jamf Pro API authentication
- Jamf Pro policies and custom event triggers

## About the Repository

These scripts have been developed over the years while working with Jamf Pro and macOS. Many started as solutions to specific support or administration problems and evolved into reusable SwiftDialog-based workflows.

The repository includes both end-user tools and administrator-focused utilities. Some scripts may require adaptation before they are appropriate for another environment, particularly those involving API credentials, internal paths, Jamf Pro policy names, branding resources, or organization-specific defaults.

## Documentation

More detailed notes, screenshots, and supporting documentation can be maintained in the repository Wiki, while this README serves as the main directory for the projects in the repository.

## Support the Projects

If you find these scripts useful, consider supporting the caffeine fund. ☕

## License

This repository is licensed under the [GNU General Public License v3.0](./LICENSE).


<a href="https://www.buymeacoffee.com/scottekendall" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
