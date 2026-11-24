## Battery Info

This dialog can display either the current battery status or the critial warning depending on the results of the battery inspection

_If the battery condition is normal_

![Normal Battery](./BatteryHealth.png)

_and if the battery is bad (critical)_

![Critical Battery](./BatteryCritical.png
)

| **Version**|**Notes**|
|:--------:|-----|
| 1.0 | Initial
| 1.1 | Code cleanup to be more consistent with all apps
| 1.2 | fix the SD_ICON reference in the display prompt
| 1.3 | Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
| 1.4 | Changed the icon(s) and wording / Add Help Desk button if battery critical
| 1.5 | Swift dialog min requirements now 2.5.0 / Changed wording on critical message / New icons / Added display item for currently charging.
| 1.6 | Code cleanup
||       Added feature to read in defaults file
||       removed unnecessary variables.
||       Bumped min version of SD to 2.5.0
||       Fixed typos
| 1.7 | Had to increase window height for Tahoe & SD v3.0
| 1.8 | Changed JAMF 'policy -trigger' to JAMF 'policy -event'
| 2.0 | Updated SD Version requirements to 3.1.0
||       Added ability to set subtitle, color, and offset from defaults file
| 2.1 | Improved battery information retrieval and parsing
||       Improved detection of AC charger connection, wattage, and charging state
||      Added validation for the Jamf battery condition parameter
||      Improved SwiftDialog installation, version validation, and failure handling
||      Improved support file validation and error handling
||      Removed unused variables and dependencies
||      General code cleanup and reliability improvements
