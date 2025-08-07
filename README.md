# JAMF-Pro-Scripts
Scripts that I have developed over the years working with JAMF Pro

The information below is a summary of how I have consructed my support folders and what the variables are:

### Application Variables ###
```
###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

JSS_FILE="/Library/Managed Preferences/com.gianteagle.jss.plist"
SD_TIMER="240"

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_FILE="${SUPPORT_DIR}/PasswordExpireNotice.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Password Expiration Notice"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
SD_IMAGE_TO_DISPLAY="${SUPPORT_DIR}/SupportFiles/PasswordChange.png"
OVERLAY_ICON="/Applications/Self Service.app"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SD_IMAGE_POLICY="install_passwordSS"```
```

The ```SUPPORT_DIR``` is the starting directory of where you want to store all of your logs, images, screenshots, etc.  Currently this is how I format my stucture

![](/README-FileStructure.png)

```LOG_FILES```: location & name of the file you want to store your log files

```BANNER_TEXT_PADDING```: I create window banners with a logo in the left corner, so I need to offset the text so it looks centered.

```SD_WINDOW_TITLE```: Title of the window that you are displaying

```SD_BANNER_IMAGE```: Location & name of the banner that you want to display

```OVERLAY_ICON```: Location a PNG, JPG or ICNS file that you want to display.  You can also use Font Symbols as well: (ie.  SF=apple.fill). see https://developer.apple.com/sf-symbols/

### Trigger Installs ###

All of my scripts will check for specific items (Swift Dialog, Banner Images, jq, etc).  If those items are not present before the script runs, it will call the trigger.  The is a custom name that you give a JAMF policy that will install a piece of software for you.  For example, this is what I have if SwiftDialog is not installed already:

(NOTE: Some of the scripts using a binary executable called "jq".  This is insalled with macOS Sequoia and higher, but you have to manually install it for OSes prior to macOS Sequoia)

The policy listing for Swift Dialog: (Make sure to scope it to all users)

![](/README-JAMFPolicy.png)

The details of the policy itself.  Notice the trigger name in the "Custom" seciton

![](/JAMF-Pro-Scripts/README-JAMFTrigger.png)

And what gets installed during the policy execution.  

![](/JAMF-Pro-Scripts/README_JAMFPackage.png)


### Passed in Variables ###
```
##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

SD_WELCOME_MSG="${5:-"Information Message"}"
SD_WELCOME_MSG_ALT="${6:-""}"
SD_BUTTON1_PROMPT="${7:-"OK"}"
SD_IMAGE_TO_DISPLAY="${8:-""}"
SD_IMAGE_POLCIY="${9:-""}"
SD_ICON_PRIMARY="${10:-"AlertNoteIcon.icns"}"
SD_TIMER="${11-120}"
SD_ICON_PRIMARY="${ICON_FILES}${SD_ICON_PRIMARY}"
```

Some of my scripts will used passed in variables from the script paramter page, you can also set defaults on variables if they are not passed in (this is referred to as ZSH Parameter Expansion)

The above example is taken from the DialogMsg script:

```JAMF_LOGGED_IN_USER```: JAMF automatically passes in some items for you. Param #3 is user name

```SD_WELCOME_MSG```: Will default to "Information Message", it nothing is passed in

```SD_ICON_PRIMARY```: will use the AlertNote icon if nothing is passed in

```SD_TIMER```: will default to 120 seconds if nothing is passed in
