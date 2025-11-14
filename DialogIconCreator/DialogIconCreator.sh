#!/bin/zsh
#
# Dialog Icon Creator
#
# by: Scott Kendall
#
# Written: 10/05/2025
# Last updated: 10/13/2025
#
# Script Lightweight script to create icons with overlays using SwiftDialog
#
# 1.0 - Initial
# 1.1 - Added option for custom app file locations to be scanned in

######################################################################################################
#
# Global "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="DialogIconCreator"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

# Make some temp files for this app

JSON_DIALOG_BLOB=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
JSON_DIALOG_BLOB_ICON=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
DIALOG_COMMAND_FILE_ICON=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
/bin/chmod 666 $JSON_DIALOG_BLOB
/bin/chmod 666 $JSON_DIALOG_BLOB_ICON
/bin/chmod 666 $DIALOG_COMMAND_FILE_ICON

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
    SD_BANNER_IMAGE=$SUPPORT_DIR$(defaults read $DEFAULTS_DIR "BannerImage")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
fi

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Dialog Icon Creator"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE=$ICON_FILES"/ToolbarCustomizeIcon.icns"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

# Misc app variables

ICON_SIZE=512
ICON_ALPHA_CHANNEL=1.0
SD_ICON_URL="https://beta.swiftdialog.app/basic-use/icon/"
HELP_MESSAGE="When using the icon fields, this is the display priority:<br><br>1.  String (SF/Text)<br>2.  Built-in<br>3.  Application Icon<br><br>The 'String' fields allow you to use the SF fonts (SF=) or text symbols (text=) with various options for colors, weights, etc.  Icon display options & variations can be found at $SD_ICON_URL"
HELP_IMAGE="qr=$SD_ICON_URL"

####################################################################################################
#
# Functions
#
####################################################################################################

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None

    echo "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${SW_DIALOG}" ]]; then
        echo "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$( ${SW_DIALOG} --version)        
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        echo "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else    
        echo "Swift Dialog is currently running: ${SD_VERSION}"
    fi
}

function install_swift_dialog ()
{
    # Install Swift dialog From JAMF
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
    #
    # RETURN: None

	/usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
}

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="**256x256 Icon Preview**<br><br>Use the options on the right to change display options.  Changes will be reflected in the preview windows."
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_DIALOG_BLOB} ]] && /bin/rm -rf ${JSON_DIALOG_BLOB}
	[[ -f ${JSON_DIALOG_BLOB_ICON} ]] && /bin/rm -rf ${JSON_DIALOG_BLOB_ICON}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE_ICON} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE_ICON}    
    kill $dialog_icon_PID
	exit $1
}

#######################################################################################################
# 
# Functions to create textfields, listitems, checkboxes & dropdown lists
#
#######################################################################################################

function create_radio_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - item name (interal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem heders / footers

    declare line && line=""

    [[ "$3:l" == "first" ]] && line+='"selectitems" :[ {"title" : "'$2'", { "values" : ['
    [[ ! -z $1 ]] && line+='"'$1'",'
    [[ "$3:l" == "last" ]] && line+='], "style" : "radio"}]'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_dropdown_list ()
{
    # PURPOSE: Create the dropdown list for the dialog box
    # RETURN: None
    # EXPECTED: JSON_DIALOG_BLOB should be defined
    # PARMS: $1 - message to be displayed on the window
    #        $2 - tyoe of data to parse XML or JSON
    #        #3 - key to parse for list items
    #        $4 - string to parse for list items
    # EXPECTED: None
    declare -a array

    construct_dialog_header_settings $1 > "${JSON_DIALOG_BLOB}"
    create_dropdown_message_body "" "" "first"

    # Parse the XML or JSON data and create list items
    
    if [[ "$2:l" == "json" ]]; then
        # If the second parameter is XML, then parse the XML data
        xml_blob=$(echo -E $4 | jq -r '.results[]'$3)
    else
        # If the second parameter is JSON, then parse the JSON data
        xml_blob=$(echo $4 | xmllint --xpath '//'$3 - 2) #>/dev/null)
    fi
    
    echo $xml_blob | while IFS= read -r line; do
        # Remove the <name> and </name> tags from the line and trailing spaces
        line="${${line#*<name>}%</name>*}"
        line=$(echo $line | sed 's/[[:space:]]*$//')
        array+='"'$line'",'
    done
    # Remove the trailing comma from the array
    array="${array%,}"
    create_dropdown_message_body "Select Groups:" "$array" "last"

    #create_dropdown_message_body "" "" "last"
    update_display_list "Create"
}

function create_checkbox_message_body ()
{
    # PURPOSE: Construct a checkbox style body of the dialog box
    #"checkbox" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - name (intenral reference)
    #        $3 - icon
    #        $4 - Default Checked (true/false)
    #        $5 - disabled (true/false)
    #        $6 - first or last - construct appropriate listitem heders / footers

    declare line && line=""
    [[ "$6:l" == "first" ]] && line+=' "checkbox" : ['
    [[ ! -z $1 ]] && line+='{"name" : "'$2'", "label" : "'$1'", "icon" : "'$3'", "checked" : "'$4'", "disabled" : "'$5'"},'
    [[ "$6:l" == "last" ]] && line+='] ' #,"checkboxstyle" : {"style" : "switch", "size"  : "small"}'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function create_dropdown_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title (Display)
    #        $2 - values (comma separated list)
    #        $3 - default item
    #        $4 - first or last - construct appropriate listitem heders / footers
    #        $5 - Trailing closure commands
    #        $6 - Name of dropdown item

    declare line && line=""
  
    [[ "$4:l" == "first" ]] && line+=' "selectitems" : ['
    [[ ! -z $1 ]] && line+='{"title" : "'$1'", "values" : ['$2']'
    [[ ! -z $3 ]] && line+=', "default" : "'$3'"'
    [[ ! -z $6 ]] && line+=', "name" : "'$6'"'
    [[ ! -z $5 ]] && line+="$5"
    [[ "$4:l" == "last" ]] && line+='],'
    echo $line >> ${JSON_DIALOG_BLOB}
}

function construct_dropdown_list_items ()
{
    # PURPOSE: Construct the list of items for the dropdowb menu
    # RETURN: formatted list of items
    # EXPECTED: None
    # PARMS: $1 - JSON variable to parse
    #        $2 - JSON Blob name

    declare line
    for item in $1
        
    # Remove the trailing comma from the array
    array="${array%,}"
    echo $array
}

function create_textfield_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    # "listitem" : [
    #			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - item name (interal reference) 
    #        $2 - title (Display)
    #        $3 - first or last - construct appropriate listitem heders / footers
    #        $4 - Default Vaule
    #        $5 - Trailing closure commands


    declare line && line=""

    [[ "$3:l" == "first" ]] && line+='"textfield" : ['
    [[ ! -z $1 ]] && line+='{"name" : "'$1'", "title" : "'$2'"'
    [[ ! -z $4 ]] && line+=', "value" :"'$4'"'
    [[ ! -z $5 ]] && line+="$5"
    [[ "$3:l" == "last" ]] && line+=']' #|| line+=','
    echo $line >> ${JSON_DIALOG_BLOB}
}

###########################
#
# App functions
#
###########################

function read_applications ()
{
	# PURPOSE: Build the Array of items that can be removed, delete the items that are not allowed and then add in the folders
    # PARAMS: None
    # RETURN: None

	declare -a tmp_array
	declare saved_IFS=$IFS

	IFS=$'\n'

    # Iterate over each directory in APP_LOCATIONS
    for dir in "${APP_LOCATIONS[@]}"; do
        # Look for .app files and .icns files as well
    	FILES_LIST+=( $(/usr/bin/find ${dir}/* -maxdepth 0 -type d -iname '*.app' ! -ipath '*Contents*' | /usr/bin/sort -f | /usr/bin/awk -F '/' '{print $NF}' )) 2>/dev/null
        FILES_LIST+=( $(/usr/bin/find ${dir}/*.icns -maxdepth 0 -type f -iname '*.icns' | /usr/bin/sort -f | /usr/bin/awk -F '/' '{print $NF}' )) 2>/dev/null
    done
	IFS=$saved_IFS

	# Add only the non-empty items into the tmp_array

	for i in "${FILES_LIST[@]}"; do [[ -n "$i" ]] && tmp_array+=('"'${i}'",') ; done
    # We need to add a blank entry so that the user can "De-select" an application

    tmp_array+=('" ",')
	# And finally sort the array alphabetically

    FILES_LIST=("${(f)$(printf '%s\n' "${tmp_array[@]}" | sort)}")
}

function construct_dialog_icon_window ()
{
    # Construct the basic Switft Dialog screen preview screen
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
    "icon" : "'${SD_ICON_FILE}'",
    "overlayicon" : "'${OVERLAY_ICON}'",
    "message" : "'$1'",
    "centericon" : "true",
    "title" : "'$ICON_SIZE'x'$ICON_SIZE' Icon Preview",
    "height" : 580,
    "width" : 700,
    "position" : "topleft",
    "iconsize" : "'$ICON_SIZE'",
    "infotext" : "You can copy the above code and paste it into your script",
    "titlefont" : "shadow=1",
    "button1text" : "none",
    "moveable" : "true",
    }'
}

function construct_dialog_header_settings ()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window
	echo '{
    "icon" : "'${SD_ICON_FILE}'",
    "overlayicon" : "'${OVERLAY_ICON}'",
    "message" : "'$1'",
    "bannerimage" : "'${SD_BANNER_IMAGE}'",
    "bannertitle" : "'${SD_WINDOW_TITLE}'",
    "infobox" : "'${SD_INFO_BOX_MSG}'",
    "iconsize" : "256",
    "iconalpha" : "'${ICON_ALPHA_CHANNEL}'",
    "titlefont" : "shadow=1",
    "button1text" : "OK",
    "button2text" : "Quit",
    "position" : "bottomright", 
    "helpmessage" : "'$HELP_MESSAGE'",
    "helpimage" : "'$HELP_IMAGE'",
    "infobuttontext" : "Take Screenshot",
    "moveable" : "true",
    "quitkey" : "0",
    "ontop" : "true",
    "vieworder" : "dropdown, textfield",
    "width" : 900,
    "height" : 540,
    "json" : "true",'
}

function welcomemsg ()
{
    construct_dialog_icon_window "Dialog Construct appears here" > "${JSON_DIALOG_BLOB_ICON}"
    # Capture the PID of the window so it can be closed when we are done
    dialog_icon_PID=$!

    ${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB_ICON}" --commandfile ${DIALOG_COMMAND_FILE_ICON} &

    while true; do
        message="Use this window to make your icon selection / changes.  Once you are done, click on  'Take Screenshot' and it will allow you to capture the icon preview, and put it on the clipboard."
        construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"
        create_dropdown_message_body "" "" "" "first"
        create_dropdown_message_body "🄿 Primary Icon" "$FILES_LIST" "$primaryApp" "" "}," "primaryicon"
        create_dropdown_message_body "🄿 -or- Primary Built-in" '"", "info", "caution", "warning", "computer"' "$primaryBuiltIn" "" "}," "primarybuiltin"
        create_dropdown_message_body "Transparency" '" ","0.0","0.1","0.2","0.3","0.4","0.5","0.6","0.7","0.8","0.9","1.0"' "$primaryAlpha" "" "},"
        create_dropdown_message_body "🄾 Overlay Icon" "$FILES_LIST" "$SecondaryApps" "" "}," "overlayicon"
        create_dropdown_message_body "🄾 -or- Overlay Built-in" '"", "info", "caution", "warning", "computer"' "$secondaryBuiltIn" "" "}," "overlaybuiltin"
        create_dropdown_message_body "" "" "" "last"
        create_textfield_message_body "PrimaryIconString" "🄿 -or- Primary String (SF / Text)" "first" "$primaryTextString" "},"
        create_textfield_message_body "OverlayIconString" "🄾 -or- Overlay String (SF / Text)" "" "$secondaryTextString" "}]}"

        # Show the screen and get the results
        temp=$(${SW_DIALOG} --json --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null)
        buttonpress=$?

        # Test for button presses
        [[ ${buttonpress} -eq 2 ]] && cleanup_and_exit 0
        if [[ ${buttonpress} -eq 3 ]]; then
            screencapture -ci
            osascript -e 'tell application "Preview" to activate' -e 'tell application "System Events" to tell process "Preview" to click menu item "New from Clipboard" of menu "File" of menu bar 1'
            osascript -e 'tell application "Preview" to activate'
        fi
        # Store the results
        primaryApp=$(echo $temp |  jq -r '."primaryicon".selectedValue')
        primaryBuiltIn=$(echo $temp |  jq -r '."primarybuiltin".selectedValue')
        primaryAlpha=$(echo $temp |  jq -r '."Transparency".selectedValue')
        SecondaryApps=$(echo $temp |  jq -r '."overlayicon".selectedValue')
        secondaryBuiltIn=$(echo $temp |  jq -r '."overlaybuiltin".selectedValue')
        primaryTextString=$(echo $temp | jq -r '."PrimaryIconString"')
        secondaryTextString=$(echo $temp | jq -r '."OverlayIconString"')

        [[ ! -z "${primaryApp}" ]] || [[ ! -z "{$primaryBuiltIn}" ]] || [[ ! -z "{$primaryTextString}" ]] && change_icon_window
    done
}

function change_icon_window ()
{
        primaryIcon=""
        secondaryIcon=""

        # Several cases to test here...
        # Primary App        
        if [[ ! -z $primaryTextString ]]; then #textstring first
            primaryIcon=$primaryTextString
            echo "Primary Text: "$primaryIcon
        elif [[ ! -z $primaryBuiltIn ]]; then #SD Built-in
            primaryIcon=$primaryBuiltIn
        elif [[ ! -z $primaryApp ]]; then #Application
            for dir in "${APP_LOCATIONS[@]}"; do
                [[ -e "${dir}/${primaryApp}" ]] && appPath=$dir
                primaryIcon=$appPath/$primaryApp
            done
        fi

        primaryPreviewMessage="--icon '$primaryIcon'"
        echo "icon: $primaryIcon" >> $DIALOG_COMMAND_FILE_ICON

        # Next, Check the icon transparency
        [[ -z $primaryAlpha ]] && primaryAlpha="1.0"
        primaryIconAlpha="--iconalpha $primaryAlpha"
        echo "iconalpha: $primaryAlpha" >> $DIALOG_COMMAND_FILE_ICON

        # Next, Chck the overlay icon
        if [[ -n $secondaryTextString ]]; then #textstring first
            secondaryIcon=$secondaryTextString
        elif [[ -n $secondaryBuiltIn ]]; then #SD Built-in
            secondaryIcon=$secondaryBuiltIn
        elif [[ -n $SecondaryApps ]]; then #Application
            for dir in "${APP_LOCATIONS[@]}"; do
                [[ -e "${dir}/${SecondaryApps}" ]] && appPath=$dir
                secondaryIcon="$appPath/$SecondaryApps"
            done
        fi

        # Send the info the dispalay icon box
        [[ -z $secondaryIcon ]] && secondaryPreviewMessage="" || secondaryPreviewMessage="--overlayicon '$secondaryIcon'"
        echo "overlayicon: $secondaryIcon" >> $DIALOG_COMMAND_FILE_ICON
        echo "message: $primaryPreviewMessage $primaryIconSize $primaryIconAlpha<br>$secondaryPreviewMessage" >> $DIALOG_COMMAND_FILE_ICON

        # Change the primary window icons to mach (256 pixel size)
        SD_ICON_FILE=$primaryIcon
        OVERLAY_ICON=$secondaryIcon
        ICON_ALPHA_CHANNEL=$primaryAlpha
}

####################################################################################################
#
# Main Script
#
####################################################################################################
autoload 'is-at-least'

declare -a FILES_LIST
declare -a APP_LOCATIONS
declare dialog_icon_PID

# Locations of your (app) files to be scanned.

APP_LOCATIONS=("/Applications" 
        "/System/Applications" 
        "/System/Applications/Utilities")
# There is a vast number of icns files located in the ICON_FILES path (Resources folder), uncomment the following line if you want to scan those in
APP_LOCATIONS+="${ICON_FILES}"

check_swift_dialog_install
check_support_files
create_infobox_message
read_applications
welcomemsg
exit 0