## PPPC Nudge

This script allows you to display a dialog informing the user what to do if a particular setting is not set properly in the System Settings > Privacy & Security pane.

This can be modified to handle any TCC Key value that is present on the system.  The JSON Blob ```tccJSONarray``` contains the information to search & retreive for any given TCC Key

*This script is designed to test/evaluate the current condition of the PPPC Key.  If everything seems OK (enabled), it will exit quietly with no user interaction, so theoretically you could scope this to all users...*


**Exmaple screen for Screen & Audio recording**

![](/PPPCNudge/PPPCNudge-Screen.png)

Example screen using the "mini" mode

![](/PPPCNudge/PPPCNudge-Screen-mini.png)



**Example screen for accessability**

![](/PPPCNudge/PPPCNudge-Accessibility.png)

Example screen using the "mini" mode

![](/PPPCNudge/PPPCNudge-Accessibility-mini.png)

**Script Parameters**

![](/PPPCNudge/PPPCNudge-Parameters.png)


I developed this script from the one found on this site:
https://www.macosadventures.com/2023/03/07/screennudge-v1-7/

## What is the TCC Database? ##

The Apple TCC database, short for Transparency, Consent, and Control database, is a critical component of macOS's privacy protection system. It's a SQLite database that stores user-granted permissions for applications accessing sensitive data and system resources. This ensures that applications only access what the user has explicitly allowed, enhancing user privacy and control. 

**TCC Database locations**

A user-specific TCC database is located at ```~/Library/Application Support/com.apple.TCC/TCC.db```

a system-wide TCC database is located at ```/Library/Application Support/com.apple.TCC/TCC.db. ```

**TCC for the User**

From a user’s perspective, they see TCC in action when an application wants access to one of the features protected by TCC. When this happens the user is prompted with a dialog asking them whether they want to allow access or not. This response is then stored in the TCC database.

![](/PPPCNudge/PPPCNudge-Consent.png)

To get visibility into TCC permissions, users can navigate to their System Settings, and click into Privacy & Security. In this pane, you can see the vast majority of TCC permissions. This includes, but is not limited to, applications that have requested access to the camera or microphone, location data, and specific files and folders such as the Desktop or Documents.

![](/PPPCNudge/PPPCNudge-System%20Settings.png)

**Accessing the TCC Database**

You can access the contents of the TCC database using several methods.  If you want to view the available keys:

```
cd /System/Library/PrivateFrameworks/TCC.framework/Support
strings tccd | grep -iEo "^kTCCService.*" | sort
```

you can also access the service data from SQL

```
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db"
SQLite version 3.43.2 2023-10-10 13:08:14
Enter ".help" for usage hints.
sqlite> select DISTINCT service from access;
kTCCServiceAccessibility
kTCCServiceDeveloperTool
kTCCServiceListenEvent
kTCCServicePostEvent
kTCCServiceScreenCapture
kTCCServiceSystemPolicyAllFiles
sqlite> 
```

List of apps based on access rights

```
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
'select client from access where auth_value and service = "kTCCServiceSystemPolicyAllFiles"'
```
will produce an output like this:

```
/usr/libexec/sshd-keygen-wrapper
com.ninxsoft.mist
com.runningwithcrayons.Alfred
```

To print out the schema of the database you can run ```.schema```


## Jamf Workflow ##

An example JAMF workflow to notify users if access is not set properly

**Extension Attribute**


Name: Disabled System TCC Values
```
#!/bin/zsh

#Extension Attribute reports disabled system level TCC values
#Report Machine's disabled TCC values (Note, this does not include user level TCC results, i.e. Camera and Microphone)

service_name="kTCCServiceScreenCapture"
disabledValues=$(sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" 'SELECT client FROM access WHERE service like "'$service_name'" and auth_value = "0"')

echo "<result>$disabledValues</result>"
```
**Smart Group:**
Name: &lt;AppName&gt; ScreenSharing Disabled

Criteria:

**Disabled System TCC Values** is not &lt;Leave Blank&gt;

And **Disabled System TCC Values** like ```com.google.Chrome```

**Policy**

Name: Prompt User to enable &lt;AppName&gt; ScreenSharing

Frequency: Once every day

Trigger: Check-in

Scope: AppName ScreenSharing Disabled

Script: PPPCNudge.sh




## MDM Overrides ##

One odd caveat of TCC is the MDMOverrides.plist located in the same com.apple.TCC directory. This binary property list contains MDM-specific TCC permissions. Via MDMs, administrators can deploy payloads, called PPPC payloads, that get added to the System Settings > Profiles. Here, admins can specify TCC permissions they want enabled or not. This is paramount in allowing admins to deploy software silently, run commands on the endpoint, and lots more. 

However, because these permissions are added to the MDMOverrides.plist, as opposed to the TCC.db, they sometimes go unreflected in the UI. This can make triage of deployment issues tedious while attempting to cross reference files. In the meantime, most users cannot assist since the UI goes unchanged. 


## Complete service listing for Sequoia ##
This is what I have found so far for Sequoia...I will post any changes in here for Tahoe

| **TCC Service**                                | **Description**                                               | **System Settngs Location**                              | 
| ---------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------- |
| kTCCService                                    | General TCC service identifier.                               |                                                          |
| kTCCServiceAccessibility                       | Allows client to control computer.                            | Privacy & Security > Accessibility                       |
| kTCCServiceAddressBook                         | Allows access to the address book (contacts).                 | Contacts                                                 |
| kTCCServiceAll                                 | Provides access to all TCC services.                          |                                                          |
| kTCCServiceAppleEvents                         | Grants access to send Apple Events.                           | Apple Events                                             |
| kTCCServiceAudioCapture                        | Allows capturing audio input.                                 |                                                          |
| kTCCServiceBluetoothAlways                     | Allows Bluetooth access at all times.                         |                                                          |
| kTCCServiceBluetoothPeripheral                 | Grants access to Bluetooth peripherals.                       |                                                          |
| kTCCServiceBluetoothWhileInUse                 | Allows Bluetooth access only while in use.                    |                                                          |
| kTCCServiceCalendar                            | Grants access to the calendar.                                | Calendar                                                 |
| kTCCServiceCalls                               | Provides access to call-related features.                     |                                                          |
| kTCCServiceCamera                              | Client would like to access the camera.                       | Camera                                                   |
| kTCCServiceContactlessAccess                   | Allows access to contactless device features.                 |                                                          |
| kTCCServiceContactsFull                        | Grants full access to contacts.                               | Full Access to Contacts                                  |
| kTCCServiceContactsLimited                     | Allows limited access to contacts.                            | Limited Access to Contacts                               |
| kTCCServiceCrashDetection                      | Provides access to crash detection features.                  |                                                          |
| kTCCServiceDeveloperTool                       | Access to developer tools and debugging features.             | Privacy & Security > Developer Tools                     |
| kTCCServiceEndpointSecurityClient              | Allows access to endpoint security services.                  |                                                          |
| kTCCServiceExposureNotification                | Grants access to exposure notifications (e.g., COVID alerts). |                                                          |
| kTCCServiceExposureNotificationRegion          | Region-specific exposure notification services.               |                                                          |
| kTCCServiceFSKitBlockDevice                    | Access to block device management in FSKit.                   |                                                          |
| kTCCServiceFaceID                              | Allows access to FaceID services.                             |                                                          |
| kTCCServiceFacebook                            | Provides integration with Facebook services.                  | Share via Facebook                                       |
| kTCCServiceFallDetection                       | Grants access to fall detection features.                     |                                                          |
| kTCCServiceFileProviderDomain                  | Allows access to file provider domains.                       | Files managed by Apple Events                            |
| kTCCServiceFileProviderPresence                | Provides access to file provider presence data.               | See when files managed by the client are in use          |
| kTCCServiceFinancialData                       | Grants access to financial data.                              |                                                          |
| kTCCServiceFocusStatus                         | Allows checking the user’s Focus Status.                      |                                                          |
| kTCCServiceGameCenterFriends                   | Grants access to Game Center friends.                         |                                                          |
| kTCCServiceKeyboardNetwork                     | Allows keyboard network access.                               |                                                          |
| kTCCServiceLinkedIn                            | Provides integration with LinkedIn services.                  | Share via LinkedIn                                       |
| kTCCServiceListenEvent                         | Access to listen to system-level events.                      | Monitor input from the keyboard                          |
| kTCCServiceLiverpool                           | Internal service identifier related to Liverpool feature.     | Location services                                        |
| kTCCServiceMSO                                 | Grants access to mobile service operator features.            |                                                          |
| kTCCServiceMediaLibrary                        | Access to the user’s media library.                           | Apple Music, music and video activity, and media library |
| kTCCServiceMicrophone                          | Client would like to access the microphone.                   | Microphone                                               |
| kTCCServiceMotion                              | Provides access to motion sensors and data.                   | Motion & Fitness Activity                                |
| kTCCServiceNearbyInteraction                   | Grants access to nearby interaction services.                 |                                                          |
| kTCCServicePasteboard                          | Allows access to the clipboard (pasteboard) data.             |                                                          |
| kTCCServicePhotos                              | Client would like to access the photos library.               | Read Photos                                              |
| kTCCServicePhotosAdd                           | Allows adding photos to the library.                          | Add to Photos                                            |
| kTCCServicePostEvent                           | Provides ability to post events to the system.                | Send keystrokes                                          |
| kTCCServicePrototype3Rights                    | Internal service identifier for prototype rights (version 3). | Authorization Test Service Proto3Right                   |
| kTCCServicePrototype4Rights                    | Internal service identifier for prototype rights (version 4). | Authorization Test Service Proto4Right                   |
| kTCCServiceReminders                           | Grants access to reminders.                                   | Reminders                                                |
| kTCCServiceRemoteDesktop                       | Allows access to remote desktop features.                     |                                                          |
| kTCCServiceScreenCapture                       | Provides access to screen capture capabilities.               | Privacy & Security > Screen & System Audio Recording     |
| kTCCServiceSecureElementAccess                 | Grants access to secure element (e.g., NFC) functions.        |                                                          |
| kTCCServiceSensorKitAmbientLightSensor         | Provides access to ambient light sensor data.                 |                                                          |
| kTCCServiceSensorKitBedSensing                 | Allows access to bed sensing data.                            |                                                          |
| kTCCServiceSensorKitBedSensingWriting          | Grants ability to write bed sensing data.                     |                                                          |
| kTCCServiceSensorKitDeviceUsage                | Provides access to device usage data.                         |                                                          |
| kTCCServiceSensorKitElevation                  | Grants access to elevation sensor data.                       |                                                          |
| kTCCServiceSensorKitFacialMetrics              | Allows access to facial metrics data.                         |                                                          |
| kTCCServiceSensorKitForegroundAppCategory      | Grants access to foreground app category data.                |                                                          |
| kTCCServiceSensorKitHistoricalCardioMetrics    | Allows access to historical cardio metrics.                   |                                                          |
| kTCCServiceSensorKitHistoricalMobilityMetrics  | Grants access to historical mobility metrics.                 |                                                          |
| kTCCServiceSensorKitKeyboardMetrics            | Provides access to keyboard metrics.                          |                                                          |
| kTCCServiceSensorKitLocationMetrics            | Allows access to location metrics data.                       |                                                          |
| kTCCServiceSensorKitMessageUsage               | Grants access to message usage data.                          |                                                          |
| kTCCServiceSensorKitMotion                     | Provides access to motion sensor data.                        |                                                          |
| kTCCServiceSensorKitMotionHeartRate            | Grants access to heart rate metrics via motion sensors.       |                                                          |
| kTCCServiceSensorKitOdometer                   | Allows access to odometer data.                               |                                                          |
| kTCCServiceSensorKitPedometer                  | Grants access to pedometer data.                              |                                                          |
| kTCCServiceSensorKitPhoneUsage                 | Provides access to phone usage data.                          |                                                          |
| kTCCServiceSensorKitSoundDetection             | Allows access to sound detection services.                    |                                                          |
| kTCCServiceSensorKitSpeechMetrics              | Grants access to speech metrics.                              |                                                          |
| kTCCServiceSensorKitStrideCalibration          | Allows stride calibration via sensors.                        |                                                          |
| kTCCServiceSensorKitWatchAmbientLightSensor    | Provides access to watch’s ambient light sensor data.         |                                                          |
| kTCCServiceSensorKitWatchFallStats             | Grants access to fall statistics via the watch.               |                                                          |
| kTCCServiceSensorKitWatchForegroundAppCategory | Allows access to the foreground app category on watch.        |                                                          |
| kTCCServiceSensorKitWatchHeartRate             | Grants access to heart rate metrics via the watch.            |                                                          |
| kTCCServiceSensorKitWatchMotion                | Provides access to watch motion sensor data.                  |                                                          |
| kTCCServiceSensorKitWatchOnWristState          | Allows access to the on-wrist state of the watch.             |                                                          |
| kTCCServiceSensorKitWatchPedometer             | Grants access to watch pedometer data.                        |                                                          |
| kTCCServiceSensorKitWatchSpeechMetrics         | Provides access to speech metrics via the watch.              |                                                          |
| kTCCServiceSensorKitWristTemperature           | Allows access to wrist temperature sensor data.               |                                                          |
| kTCCServiceShareKit                            | Grants access to ShareKit services for content sharing.       | Share features                                           |
| kTCCServiceSinaWeibo                           | Provides integration with Sina Weibo services.                | Share via Sina Weibo                                     |
| kTCCServiceSiri                                | Grants access to Siri-related services.                       | Use Siri                                                 |
| kTCCServiceSpeechRecognition                   | Allows access to speech recognition features.                 | Speech Recognition                                       |
| kTCCServiceSystemPolicyAllFiles                | Grants access to all system files.                            | Privacy & Security > Full disk Access                    |
| kTCCServiceSystemPolicyAppBundles              | Allows access to application bundles.                         |                                                          |
| kTCCServiceSystemPolicyAppData                 | Grants access to app-specific data.                           |                                                          |
| kTCCServiceSystemPolicyDesktopFolder           | Allows access to the desktop folder.                          | Desktop folder                                           |
| kTCCServiceSystemPolicyDeveloperFiles          | Grants access to developer-related files.                     | Files in Software Development                            |
| kTCCServiceSystemPolicyDocumentsFolder         | Allows access to the documents folder.                        | Files in Documents folder                                |
| kTCCServiceSystemPolicyDownloadsFolder         | Provides access to the downloads folder.                      | Files in Downloads folder                                |
| kTCCServiceSystemPolicyNetworkVolumes          | Grants access to network volumes.                             | Files on a network volume                                |
| kTCCServiceSystemPolicyRemovableVolumes        | Allows access to removable volumes.                           | Files on a removable volume                              |
| kTCCServiceSystemPolicySysAdminFiles           | Grants access to system administration files.                 | Administer the computer                                  |
| kTCCServiceTencentWeibo                        | Provides integration with Tencent Weibo services.             | Share via Tencent Weibo                                  |
| kTCCServiceTwitter                             | Allows integration with Twitter services.                     | Share via Twitter                                        |
| kTCCServiceUbiquity                            | Grants access to iCloud ubiquity services.                    | iCloud                                                   |
| kTCCServiceUserAvailability                    | Allows access to user availability information.               |                                                          |
| kTCCServiceUserTracking                        | Provides access to user tracking services.                    |                                                          |
| kTCCServiceVirtualMachineNetworking            | Grants access to virtual machine networking services.         |                                                          |
| kTCCServiceVoiceBanking                        | Allows access to voice banking services.                      |                                                          |
| kTCCServiceWebBrowserPublicKeyCredential       | Grants access to public key credentials for web browsers.     |                                                          |
| kTCCServiceWebKitIntelligentTrackingPrevention | Provides WebKit intelligent tracking prevention services.     |                                                          |
| kTCCServiceWillow                              | Internal service identifier related to Willow feature.        | Home data                                                |

The per-user `TCC.db` file has the same schema but will commonly have different service types.

Some service types are saved per-user (e.g. camera access) and some are global and will therefore persist in the system-wide `TCC.db` (e.g. Full Disk Access).

Here are some common types:

- `kTCCServiceLiverpool`: Location services access, saved in the user-specific TCC database.
- `kTCCServiceUbiquity`: iCloud access, saved in the user-specific TCC database.
- `kTCCServiceSystemPolicyDesktopFolder`: Desktop folder access, saved in the user-specific TCC database.
- `kTCCServiceCalendar`: Calendar access, saved in the user-specific TCC database.
- `kTCCServiceReminders`: Access to reminders, saved in the user-specific TCC database.
- `kTCCServiceMicrophone`: Microphone access, saved in the user-specific TCC database.
- `kTCCServiceCamera`: Camera access, saved in the user-specific TCC database.
- `kTCCServiceSystemPolicyAllFiles`: Full disk access capabilities, saved in the system-wide TCC database.
- `kTCCServiceScreenCapture`: Screen capture capabilities, saved in the system-wide TCC database.

## Accessing System Settings panels from Terminal ##

You can use the `strings` command to show you a list of all the privacy settings that can be accessed via terminal:

```
strings "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension" | grep "Privacy_"

Privacy_AppleIntelligenceReport
Privacy_DevTools
Privacy_Automation
Privacy_NudityDetection
Privacy_Location
Privacy_LocationServices
Privacy_SystemServices
Privacy_ScreenCapture
Privacy_AudioCapture
Privacy_Advertising
Privacy_Analytics
Privacy_FilesAndFolders
Privacy_DesktopFolder
Privacy_DocumentsFolder
Privacy_DownloadsFolder
Privacy_NetworkVolume
Privacy_RemovableVolume
Privacy_Accessibility
Privacy_Microphone
Privacy_Calendars
Privacy_Pasteboard
Privacy_Camera
Privacy_Photos
```

You can display individual settings by using this command: 
```
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )

function runAsUser () 
{  
  if [ "$LOGGED_IN_USER" != "loginwindow" ]; then
    launchctl asuser "$UID" sudo -u "$LOGGED_IN_USER" "$@"
  else
    echo "no user logged in"
    # uncomment the exit command to make the function exit with an error when no user is logged in
    # exit 1
  fi
}

runAsUser open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

All System settings panes can be opened via terminal, here is a complete article on it:

https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751

Some more good info here: 

https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751

https://github.com/AtlasGondal/macos-pentesting-resources/blob/main/tccd/kTCCService.md#tcc-services-and-descriptions