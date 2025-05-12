#!/bin/zsh
#
# RemoveAdobeApps.sh
#
# by: Scott Kendall
#
# Written: 04/29/2025
# Last updated: 05/12/2025
#
# Script Purpose: Selectively remove Adobe apps from a users system
#
# 1.0 - Initial
# 1.1 - Changed buttons to "Next" and "Remove" on the appropriate screens
# 1.2 - Change find command to exclude Adobe Experience Manager and Adobe Acrobat DC
# 1.3 - Add option for "silent" remove (no prompt) and which apps than can be removed 3D & CC or CC only
#

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

OS_PLATFORM=$(/usr/bin/uname -p)

[[ "$OS_PLATFORM" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_SERIAL_NUMBER=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.serial_number' 'raw' -)
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_HADWARE_CLASS=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.machine_name' 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_VERSION=$( sw_vers -productVersion | xargs)

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="${SUPPORT_DIR}/logs"

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
JQ_FILE_INSTALL_POLICY="install_jq"
ADOBE_UNINSTALLER="/usr/local/bin/AdobeUninstaller"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Remove Adobe Apps"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/RemoveAdobeApps.log"
SD_ICON_FILE="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
OVERLAY_ICON="SF=trash.fill, color=black, weight=light"
TMP_FILE_STORAGE=$(mktemp /var/tmp/RemoveAdobeApps.XXXXX)
JSON_OPTIONS=$(mktemp /var/tmp/RemoveAdobeApps.XXXXX)
JSON_DIALOG_BLOB=$(mktemp /var/tmp/RemoveAdobeApps.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/RemoveAdobeApps.XXXXX)
chmod 666 ${JSON_OPTIONS}
chmod 666 ${JSON_DIALOG_BLOB}
chmod 666 ${DIALOG_COMMAND_FILE}

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
ADOBE_SUPPORT_FILE="install_adobeuninstaller"

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
ADOBE_CURRENT_YEAR=$4
SCRIPT_METHOD="${5:-"Prompt"}"                  # 'Silent' or 'Prompt'
REMOVAL_METHOD="${6:-"All"}"                    # 'All' or 'CConly'
HELP_DESK_TICKET="https://gianteagle.service-now.com/ge?id=sc_cat_item&sys_id=227586311b9790503b637518dc4bcb3d"

####################################################################################################
#
# Functions
#
####################################################################################################

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions
	[[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
	/bin/chmod 755 "${LOG_DIR}"

	# If the log file does not exist - create it and set the permissions
	[[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
	/bin/chmod 644 "${LOG_FILE}"
}

function logMe () 
{
    # Basic two pronged logging function that will log like this:
    #
    # 20231204 12:00:00: Some message here
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    #
    # RETURN: None
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
}

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None

    logMe "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$( ${SW_DIALOG} --version)        
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else    
        logMe "Swift Dialog is currently running: ${SD_VERSION}"
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
    [[ $(which AdobeUninstaller) == *"not found"* ]] && /usr/local/bin/jamf policy -trigger ${ADOBE_SUPPORT_FILE}
    [[ $(which jq) == *"not found"* ]] && /usr/local/bin/jamf policy -trigger ${JQ_INSTALL_POLICY}
}

function create_infobox_message ()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="${MAC_SERIAL_NUMBER}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="macOS ${MACOS_VERSION}<br>"
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
    [[ -f ${JSON_DIALOG_BLOB} ]] && /bin/rm -rf ${JSON_DIALOG_BLOB}
    exit 0
}

function update_display_list ()
{
    # setopt -s nocasematch
    # This function updates the Swift Dialog list display with easy to implement parameter passing...
    # The Swift Dialog native structure is very strict with the command structure...this routine makes
    # it easier to implement
    #
    # Param list
    #
    # $1 - Action to be done ("Create", "Add", "Change", "Clear", "Info", "Show", "Done", "Update")
    # ${2} - Affected item (2nd field in JSON Blob listitem entry)
    # ${3} - Icon status "wait, success, fail, error, pending or progress"
    # ${4} - Status Text
    # $5 - Progress Text (shown below progress bar)
    # $6 - Progress amount
            # increment - increments the progress by one
            # reset - resets the progress bar to 0
            # complete - maxes out the progress bar
            # If an integer value is sent, this will move the progress bar to that value of steps
    # the GLOB :l converts any inconing parameter into lowercase

    
    case "${1:l}" in
 
        "create" | "show" )
 
            # Display the Dialog prompt
            "${SW_DIALOG}" --progress --jsonfile "${JSON_DIALOG_BLOB}" & sleep .1
            ;;
     
        "add" )
  
            # Add an item to the list
            #
            # $2 name of item
            # $3 Icon status "wait, success, fail, error, pending or progress"
            # $4 Optional status text
  
            /bin/echo "listitem: add, title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonaction" )

            # Change button 1 action
            /bin/echo 'button1action: "'${2}'"' >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "buttonchange" )

            # change text of button 1
            /bin/echo "button1text: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttondisable" )

            # disable button 1
            /bin/echo "button1: disable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "buttonenable" )

            # Enable button 1
            /bin/echo "button1: enable" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "change" )
          
            # Change the listitem Status
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
             
            /bin/echo "listitem: title: ${2}, status: ${3}, statustext: ${4}" >> "${DIALOG_COMMAND_FILE}"
            if [[ ! -z $5 ]]; then
                /bin/echo "progresstext: $5" >> "${DIALOG_COMMAND_FILE}"
                /bin/echo "progress: $6" >> "${DIALOG_COMMAND_FILE}"
            fi
            ;;
  
        "clear" )
  
            # Clear the list and show an optional message  
            /bin/echo "list: clear" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "message: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "delete" )
  
            # Delete item from list  
            /bin/echo "listitem: delete, title: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
 
        "destroy" )
     
            # Kill the progress bar and clean up
            /bin/echo "quit:" >> "${DIALOG_COMMAND_FILE}"
            ;;
 
        "done" )
          
            # Complete the progress bar and clean up  
            /bin/echo "progress: complete" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: $5" >> "${DIALOG_COMMAND_FILE}"
            ;;
          
        "icon" )
  
            # set / clear the icon, pass <nil> if you want to clear the icon  
            [[ -z ${2} ]] && /bin/echo "icon: none" >> "${DIALOG_COMMAND_FILE}" || /bin/echo "icon: ${2}" >> $"${DIALOG_COMMAND_FILE}"
            ;;
  
  
        "image" )
  
            # Display an image and show an optional message  
            /bin/echo "image: ${2}" >> "${DIALOG_COMMAND_FILE}"
            [[ ! -z ${3} ]] && /bin/echo "progresstext: $5" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "infobox" )
  
            # Show text message  
            /bin/echo "infobox: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;

        "infotext" )
  
            # Show text message  
            /bin/echo "infotext: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "show" )
  
            # Activate the dialog box
            /bin/echo "activate:" >> $"${DIALOG_COMMAND_FILE}"
            ;;
  
        "title" )
  
            # Set / Clear the title, pass <nil> to clear the title
            [[ -z ${2} ]] && /bin/echo "title: none:" >> "${DIALOG_COMMAND_FILE}" || /bin/echo "title: ${2}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
        "progress" )
  
            # Increment the progress bar by static amount ($6)
            # Display the progress bar text ($5)
            /bin/echo "progress: ${6}" >> "${DIALOG_COMMAND_FILE}"
            /bin/echo "progresstext: ${5}" >> "${DIALOG_COMMAND_FILE}"
            ;;
  
    esac
}

function display_welcome_message ()
{
    message="The below listed Adobe applications are installed on your system.  You can remove any of previously installed products. _NOTE: You cannot remove the most recently installed version._<br>"
    [[ $ADOBE_CURRENT_YEAR -ne $adobeLatestYearFound ]] && message+="<br><br>**NOTE:  Creative Cloud $ADOBE_CURRENT_YEAR is available at this time for installation.**"

	MainDialogBody=(
        --message "$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --messagefont size=18
        --width 900
        --height 700
        --ignorednd
        --moveable
        --json
        --jsonfile "${JSON_OPTIONS}"
        --quitkey 0
        --button1text "Next"
        --button2text "Cancel"
        --infobutton 
        --infobuttontext "Get Help" 
        --infobuttonaction "${HELP_DESK_TICKET}" 
    )

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$?
    [[ $buttonpress = 2 ]] && cleanup_and_exit

    # Store the "yes" results into a temp file so we can work on just this list
    echo $temp | grep -v ": false" | tr -d "{},"> "${TMP_FILE_STORAGE}"

}   

function confirm_removal ()
{
    message="Are you sure you want to delete the following apps? <br><br>"
    while read -r app; do
        [[ -z $app ]] && continue
	    app=$( echo "${app}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
        message+=" * $app<br>"
	done < "${TMP_FILE_STORAGE}"

    MainDialogBody=(
        --message "$message"
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --messagefont size=18
        --width 900
        --height 700
        --ignorednd
        --moveable
        --json
        --quitkey 0
        --button1text "Remove"
        --button2text "Cancel"
    )

	temp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$?
    [[ $buttonpress = 2 ]] && cleanup_and_exit
}

function create_file_list ()
{
    # PURPOSE: Find all of the Adobe apps installed on the system, but don't allow the latest installed year products to be removed
    # RETURN: formatted JSON_OPTIONS file
    # EXPECTED: None

    # Step 1: Store the macOS directory list in a temp file

    # If you want to remove all files (3D & CC) then use first find, otherwise find only CC apps
    if [[ "${REMOVAL_METHOD:l}" == "all" ]]; then
        find /Applications -name "Adobe*" -type d -maxdepth 1 | sed 's|^/Applications/||'| grep -v "^Adobe Creative Cloud$" | grep -v "^Adobe XD$" | grep -v "^Adobe Experience Manager*" | grep -v "^Adobe Digital Edition*" | grep -v "^Adobe Acrobat DC*" | sort > $TMP_FILE_STORAGE
    else
        find /Applications -name "Adobe*" -type d -maxdepth 1 | sed 's|^/Applications/||'| grep -E '[0-9]{4}$' | sort > $TMP_FILE_STORAGE
    fi

    # Step 2: Find the latest "year" of the installed apps

    cat $TMP_FILE_STORAGE | awk '{print $NF}' | while read app; do
        [[ $app -ge $adobeLatestYearFound ]] && adobeLatestYearFound=$app
    done

    # Step 3: Create the checkbox list from the file list and disable the current year files from being selected

    create_checkbox_message_body "" "" "" "" "first"
    cat $TMP_FILE_STORAGE | while read app; do
        # Get the full path of the application
        appPath=$(resolve_app_path $app)

        # get the baseCode & SAPCode for this app
        baseCode=$(extract_base_code_from_json $app)
        version=$(extract_version_code $appPath $baseCode)

        # Don't allow the last found year to be removed
        [[ $app == *$adobeLatestYearFound* ]] && {checked="false"; disabled="true"; } || {checked="true"; disabled="false"; }

        create_checkbox_message_body "$app" "$appPath" "$checked" "$disabled"
        # If you want to show the baseCode & version # found, the uncomment this line

        #create_checkbox_message_body "$app [$version - $baseCode]" "$icon" "$checked" "$disabled"
    done
    if [[ "${SCRIPT_METHOD}" == "prompt" ]]; then
        # If we are going to show this list to the user (prompt) then we need to properly complete the JSON array
        create_checkbox_message_body "" "" "" "" "last"
    fi
}

function create_checkbox_message_body ()
{
    # PURPOSE: Construct a checkbox style body of the dialog box
    #"checkbox" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title 
    #        $2 - icon
    #        $3 - Default Checked (true/false)
    #        $4 - disabled (true/false)
    #        $5 - first or last - construct appropriate listitem heders / footers

    declare line && line=""
    if [[ "$5:l" == "first" ]]; then
        line='{"checkbox" : ['
    elif [[ "$5:l" == "last" ]]; then
        line='], "checkboxstyle" : {"style" : "switch", "size"  : "small"}}'
    else
        line='{"label" : "'$1'", "icon" : "'$2'", "checked" : "'$3'", "disabled" : "'$4'"},'
    fi
    echo $line >> ${JSON_OPTIONS}
}

function create_listitem_message_body ()
{
    # PURPOSE: Construct the List item body of the dialog box
    #"listitem" : [
	#			{"title" : "macOS Version:", "icon" : "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FinderIcon.icns", "status" : "${macOS_version_icon}", "statustext" : "$sw_vers"},

    # RETURN: None
    # EXPECTED: message
    # PARMS: $1 - title 
    #        $2 - icon
    #        $3 - listitem
    #        $4 - status
    #        $5 - first or last - construct appropriate listitem heders / footers
    declare line && line=""

    if [[ "$5:l" == "first" ]]; then
        line='{"listitem" : ['
    elif [[ "$5:l" == "last" ]]; then
        line=']}'
    else
        line='{"title" : "'$1':", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    fi
    echo $line >> ${JSON_OPTIONS}
}

####################################################################################################
#
# Extract / Resolve functions (App Path, Base Code, SAP Version)
#
####################################################################################################

function resolve_app_path ()
{
    # Function: Resolve the correct path for the app
    #
    # RETURN: full path of .app
	# EXPECTATIONS: None
	# PARMS Passed: $1 is Adobe app name (not full path)
    local fullPath
    fullPath="/Applications/$1/$1.app"
    # If the file (icon) doesn't exist, then remove everything after the last space to fix the filename
    if [[ ! -e $fullPath ]]; then
        icon_base=$(echo $1 | sed 's/ [^ ]*$//')
        fullPath="/Applications/$1/$icon_base.app"
    fi
    # get the baseCode & SAPCode for this app
    echo $fullPath
}

function extract_base_code_from_json ()
{
    # PURPOSE: Find the baseCode in the JSON array for the appllication
    # RETURN: baseCode for the application
    # PARMS: $1 - Application title
    # EXPECTED: None

    appname=$(echo $1 | sed 's/Adobe //; s/ [0-9]\{4\}//')
    baseCode=$(echo $adobeJSONarray | jq -r '.applications[] | select(.name == "'$appname'") | .code')
    echo $baseCode
}

function extract_version_code ()
{
    # PURPOSE: Extract the SAPversion from the application
    # RETURN: SAPversion
    # PARMS: $1 - Application title
    #        $2 - Application Base Code
    # EXPECTED: None
    #
    appName=$1
    baseCode=$2

    version=$(plutil -extract "CFBundleShortVersionString" raw "$appName/Contents/Info.plist" | awk -F '.' '{print $1}').0
    # Special cases (such as Lightroom/Classic, Premiere Rush, XD & Bridge)
    case "${appName}" in
        *"Lightroom.app"* )
            version="1.0"
            ;;
        *"Lightroom Classic.app"* )
            version="8.3"
            ;;
        *"Premiere Rush 2.0"* )
            version="2.0"
            ;;
        *"Premiere Rush"* )
            version="1.5" 
            ;;
        *"XD"* )
            version="18.0.12"
            ;;
        *"Bridge 2024"* )
            version="14.0.0"
            ;;
        *"Bridge 2025"* )
            version="14.0.0"
            ;;
        *"3D Sampler"* )
            version="3.0.0"
            ;;
        *"3D Designer"* )
            version="11.2.0"
            ;;
        *"3D Painter"* )
            version="7.2.0"
            ;;
        *"3D Stager"* )
            version="1.0.0"
            ;;
    esac
    echo $version
}

function file_list_no_prompt ()
{
    # This function will use the data in the JSON_BLOB variable since it has already been populated correctly
    # but, we need to reomve the last , from the JSON blob and add the correct closure brackets to the end
    # and then extract the "selected" files (true) and format the results into the TMP_FILE_STORAGE file
    rm -r $TMP_FILE_STORAGE
    sed -i '' '$s/.$//' $JSON_OPTIONS
    echo "]}" >> $JSON_OPTIONS
    cat $JSON_OPTIONS | jq -r '.checkbox[] | select(.checked == "true") | .label' | while read label; do
        echo "\"$label\" : \"true\"" >> $TMP_FILE_STORAGE
    done
}

####################################################################################################
#
# Removal functions
#
####################################################################################################

function remove_cs6 () 
{
    # remove any CS6 products that might be installed
    #
	# VARIABLES expected: USER_LOG_FILE is the location of the migration log output
	# PARMS Passed: None
	# RETURN: None

    CS6itemsToDelete=( "/Applications/Adobe After Effects CS6/" \
                    "/Applications/Adobe Audition CS6/" \
                    "/Applications/Adobe Bridge CS6/" \
                    "/Applications/Adobe Dreamweaver CS6/" \
                    "/Applications/Adobe Encore CS6/" \
                    "/Applications/Adobe Extension Manager CS6/" \
                    "/Applications/Adobe Fireworks CS6/" \
                    "/Applications/Adobe Flash Builder 4.6/" \
                    "/Applications/Adobe Flash CS6/" \
                    "/Applications/Adobe Illustrator CS6/" \
                    "/Applications/Adobe InDesign CS6/" \
                    "/Applications/Adobe Media Encoder CS6/" \
                    "/Applications/Adobe Photoshop CS6/" \
                    "/Applications/Adobe Prelude CS6/" \
                    "/Applications/Adobe Premiere Pro CS6/" \
                    "/Applications/Adobe SpeedGrade CS6/" \
                    "/Applications/Adobe Muse CC 2018/" \
                    "/Library/Application Support/Macromedia/" \
                    "/Library/LaunchAgents/com.AdobeAAM.Updater-1.0.plist" \
                    "/Library/Application Support/Macromedia" \
                    "/Library/LaunchDaemons/com.AdobeSwitchBoard.plist" \
                    "/Library/Preferences/com.AdobeCSXS.3.plist" \
                    "/Library/Preferences/com.AdobeFireworks.12.0.0.plist" \
                    "/Library/Preferences/com.Adobeheadlights.apip.plist" \
                    "/private/etc/mach_init_per_user.d/com.AdobeSwitchBoard.monitor.plist" \
                    "/Library/Application Support/regid.1986-12.com.adobe" \
                    "/Applications/Utilities/Adobe AIR Application Installer.app" \
                    "/Applications/Utilities/Adobe AIR Uninstaller.app" \
                    "/Applications/Utilities/Adobe Utilities-CS6.localized" )


    # Remove the CS6 versions by looping through the array

    for i in "${CS6itemsToDelete[@]}"; do
        [[ -e "${i}" ]] && {logMe "Removing "${i}; /bin/rm -rf "${i}"; }
    done

    # Run the uninstaller for the CS6 thru 2019 script (app provided by Adobe)

    #/usr/local/bin/AdobeCCUninstaller > /dev/null

}

function remove_pdf_viewer ()
{
    # Remove the PDF viewer plugin if it is found
    #
	# VARIABLES EXPECTED: None
	# PARMS Passed: None
	# RETURN: None
    #

    if [[ -d "/Library/Internet Plug-Ins/AdobePDFViewer.plugin" ]]; then
        logMe "Removing Adobe PDF Viewer Plugin"
        /bin/rm -rf "/Library/Internet Plug-Ins/AdobePDFViewer.plugin"
        /bin/rm -rf "/Library/Internet Plug-Ins/AdobePDFViewerNPAPI.plugin"
    fi

}

function remove_flash ()
{
    # Check to see if Adobe Flash sofware is installed by locating either the Flash NPAPI or PPAPI browser
    # plug-ins in /Library/Internet Plug-Ins or the Adobe Flash Player Install Manager.app in /Applications/Utilities
    # Credit to: https://github.com/rtrouton/rtrouton_scripts/tree/main/rtrouton_scripts/uninstallers/adobe_flash_uninstall for the flash portion of this script
    #
	# VARIABLES EXPECTED: None
	# PARMS Passed: None
	# RETURN: None
    #


    if [[ -e "/Library/Internet Plug-Ins/Flash Player.plugin" ]] || [[ -e "/Library/Internet Plug-Ins/PepperFlashPlayer/PepperFlashPlayer.plugin" ]] || [[ -e "/Applications/Utilities/Adobe Flash Player Install Manager.app" ]]; then
        

        logMe "Uninstalling Adobe Flash software..."

        # kill the Adobe Flash Player Install Manager

        killall "Adobe Flash Player Install Manager"

        if [[ -f "/Library/LaunchDaemons/com.adobe.fpsaud.plist" ]]; then
            logMe "Stopping Adobe Flash update process."
            /bin/launchctl bootout system "/Library/LaunchDaemons/com.adobe.fpsaud.plist"
        fi

        if [[ -f "/Library/Application Support/Macromedia/mms.cfg" ]]; then
            logMe "Deleting Adobe Flash update preferences."
            /bin/rm "/Library/Application Support/Macromedia/mms.cfg"
        fi

        if [[ -e "/Library/Application Support/Adobe/Flash Player Install Manager/fpsaud" ]]; then
            logMe "Deleting Adobe software update app and support files."
            /bin/rm "/Library/LaunchDaemons/com.adobe.fpsaud.plist"
            /bin/rm "/Library/Application Support/Adobe/Flash Player Install Manager/FPSAUConfig.xml"
            /bin/rm "/Library/Application Support/Adobe/Flash Player Install Manager/fpsaud"
        fi

        if [[ -e "/Library/Internet Plug-Ins/Flash Player.plugin" ]]; then
            logMe "Deleting NPAPI browser plug-in files."
            /bin/rm -Rf "/Library/Internet Plug-Ins/Flash Player.plugin"
            /bin/rm -Rf "/Library/Internet Plug-Ins/Flash Player Enabler.plugin"
            /bin/rm "/Library/Internet Plug-Ins/flashplayer.xpt"
        fi

        if [[ -e "/Library/Internet Plug-Ins/PepperFlashPlayer/PepperFlashPlayer.plugin" ]]; then
            logMe "Deleting PPAPI browser plug-in files."
            /bin/rm -Rf "/Library/Internet Plug-Ins/PepperFlashPlayer/PepperFlashPlayer.plugin"
            /bin/rm "/Library/Internet Plug-Ins/PepperFlashPlayer/manifest.json"
        fi

        if [[ -e "/Library/PreferencePanes/Flash Player.prefPane" ]]; then
            logMe "Deleting Flash Player preference pane from System Preferences."
            /bin/rm -Rf "/Library/PreferencePanes/Flash Player.prefPane"
        fi

        # Remove Adobe Flash Player Install Manager.app

        if [[ -e "/Applications/Utilities/Adobe Flash Player Install Manager.app" ]]; then
            logMe "Deleting the Adobe Flash Player Install Manager app."
            /bin/rm -Rf "/Applications/Utilities/Adobe Flash Player Install Manager.app"
        fi

        logMe "Flash Uninstall completed successfully."

    fi
    update_display_list "change" "Remove Flash" "success" "Done"
}

function remove_reader ()
{
    # Removes the Reader DC app
    #
	# VARIABLES EXPECTED: None
	# PARMS Passed: None
	# RETURN: None
    #
    declare AdobeAcrobatReaderPrev="/Applications/Adobe Acrobat Reader DC.app"

    if [[ -d "${AdobeAcrobatReaderPrev}" ]]; then
        logMe "Removing Reader DC - "${AdobeAcrobatReaderPrev}
        /bin/rm -rf "${AdobeAcrobatReaderPrev}"

    fi
}

function remove_acrobat_pro ()
{
    # Remove all versions of Adobe Acrobat below 2021
    #
	# VARIABLES EXPECTED: None
	# PARMS Passed: None
	# RETURN: None
    #
    declare AdobeAcrobatXIPrev="/Applications/Adobe Acrobat XI Pro"
    declare AdobeAcrobatDCPrev="/Applications/Adobe Acrobat DC"
    declare AcrobatDCInfo="/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Info.plist"

    # Acrobat XI (11)

    if [[ -d "${AdobeAcrobatXIPrev}" ]]; then
        logMe "Removing "${AdobeAcrobatXIPrev}
        "/Applications/Adobe Acrobat XI Pro/Adobe Acrobat Pro.app/Contents/Support/Acrobat Uninstaller.app/Contents/MacOS/Acrobat Uninstaller"
        /bin/rm -rf "${AdobeAcrobatXIPrev}"
    fi

    # Acrobat DC (2019-2021)

    if [[ -d "${AdobeAcrobatDCPrev}" ]]; then
        echo "progresstext: Checking for old Acrobat Pro installs" >> ${DIALOG_COMMAND_FILE}

        InstalledAppVersion=$(defaults read "${AcrobatDCInfo}" "CFBundleVersion")
        
        # found Acrobat so make sure it is the 2019 - 2021 verion...if so, delete it
        if [[ -n $( echo "${InstalledAppVersion}" | grep "19.0") ]]; then
            logMe "Removing Acrobrat v19 - "${AdobeAcrobatDCPrev}
            /bin/rm -rf  "${AdobeAcrobatDCPrev}"

        elif [[ -n $( echo "${InstalledAppVersion}" | grep "20.0") ]]; then
            logMe "Removing Acrobat v20 - "${AdobeAcrobatDCPrev}
            /bin/rm -rf  "${AdobeAcrobatDCPrev}"

        elif [[ -n $( echo "${InstalledAppVersion}" | grep "21.0") ]]; then
            logMe "Removing Acrobat v21 - "${AdobeAcrobatDCPrev}
            "/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Helpers/Acrobat Uninstaller.app/Contents/Library/LaunchServices/com.adobe.Acrobat.RemoverTool"
        fi
    fi
}

function remove_apps_prompt ()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

    declare -i total_apps=0
    declare -i app_count=0
	echo '{
        "icon" : "'${SD_ICON_FILE}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "message" : "'The follow items are being removed from your system:'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "shadow=1",
        "button1text" : "OK",
        "height" : "675",
        "width" : "920",
        "moveable" : "true",
        "messageposition" : "top",
        "button1disabled" : "true",
        "commandfile" : "'${DIALOG_COMMAND_FILE}'",
        "listitem" : [' > "${JSON_DIALOG_BLOB}"

    echo '{"title" : "Remove CS6", "status" : "pending", "statustext" : "Pending..."},'>> "${JSON_DIALOG_BLOB}"
    echo '{"title" : "Remove Flash", "status" : "pending", "statustext" : "Pending..."},'>> "${JSON_DIALOG_BLOB}"
    echo '{"title" : "Remove PDF Viewer", "status" : "pending", "statustext" : "Pending..."},'>> "${JSON_DIALOG_BLOB}"
    echo '{"title" : "Remove Acrobat Reader", "status" : "pending", "statustext" : "Pending..."},'>> "${JSON_DIALOG_BLOB}"
    echo '{"title" : "Remove old Acrobat Pro", "status" : "pending", "statustext" : "Pending..."},'>> "${JSON_DIALOG_BLOB}"

    total_apps=5 #Start counting how many apps are going to be removed...used later to show progress bar
	while read -r app; do
        [[ -z $app ]] && continue
	    app=$( echo "${app}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
        ((total_apps++))
 		echo '{"title" : "Remove '"${app}"'", "status" : "pending", "statustext" : "Pending..."},'>> "${JSON_DIALOG_BLOB}"
	done < "${TMP_FILE_STORAGE}"

	echo "]}" >> "${JSON_DIALOG_BLOB}"

    update_display_list "show"
    logMe "Removing Adobe CS6 items"
    update_display_list "change" "Remove CS6" "wait" "Working..." "Remove any CS6 or older items.." $((100*1/total_apps))
    remove_cs6
    update_display_list "change" "Remove CS6" "success" "Done"
    logMe "Removing Adobe Flash items"
    update_display_list "change" "Remove Flash" "wait" "Working..." "Remove Safari Flash plugin..." $((100*2/total_apps))
    remove_flash
    update_display_list "change" "Remove Flash" "success" "Done"
    logMe "Removing Safari PDF Viewer Plugin"
    update_display_list "change" "Remove PDF Viewer" "wait" "Working..." "Remove outdated PDF Viewer..." $((100*3/total_apps))
    remove_pdf_viewer
    update_display_list "change" "Remove PDF Viewer" "success" "Done"
    logMe "Removing outdated Reader versions"
    update_display_list "change" "Remove Acrobat Reader" "wait" "Working..." "Remove older version of Acrobat Reader..." $((100*4/total_apps))
    remove_reader
    update_display_list "change" "Remove Acrobat Reader" "success" "Done"
    logMe "Removing outdated Acrobat versions"
    update_display_list "change" "Remove old Acrobat Pro" "wait" "Working..." "Remove older version of Acrobat Pro..." $((100*5/total_apps))
    remove_acrobat_pro
    update_display_list "change" "Remove old Acrobat Pro" "success" "Done"

    app_count=5
    cat $TMP_FILE_STORAGE | while read app; do
        [[ -z $app ]] && continue
        app=$( echo "${app}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
        # Resvole the app path, baseCode and SAP Code
        appPath=$(resolve_app_path $app)
        baseCode=$(extract_base_code_from_json $app)
        version=$(extract_version_code $appPath $baseCode)
        echo $version
        update_display_list "change" "Remove $app" "wait" "Working..." "Removing $app" $((100*app_count/total_apps))
        logMe "Removing $app [$baseCode#$version]"

        # Adobe command to perform the actual removal
        ${ADOBE_UNINSTALLER} --products=$baseCode#$version 2>&1

        update_display_list "change" "Remove $app" "success" "Done"
        ((app_count++))
    done
    update_display_list "progress" "" "" "" "All Done!" 100
    update_display_list "buttonenable"
    wait

}

function remove_apps_no_prompt ()
{
    logMe "Removing Adobe CS6 items"
    remove_cs6
    logMe "Removing Adobe Flash items"
    remove_flash
    logMe "Removing Safari PDF Viewer Plugin"
    remove_pdf_viewer
    logMe "Removing outdated Reader versions"
    remove_reader
    logMe "Removing outdated Acrobat versions"
    remove_acrobat_pro
    [[ ! -e $TMP_FILE_STORAGE ]] && cleanup_and_exit
     
    cat $TMP_FILE_STORAGE | while read app; do
        [[ -z $app ]] && continue
        app=$( echo "${app}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
        # Resvole the app path, baseCode and SAP Code
        appPath=$(resolve_app_path $app)
        baseCode=$(extract_base_code_from_json $app)
        version=$(extract_version_code $appPath $baseCode)
        logMe "Removing $app [$baseCode#$version]"

        # Adobe command to perform the actual removal
        ${ADOBE_UNINSTALLER} --products=$baseCode#$version 2>&1
    done

}

####################################################################################################
#
# Main Script
#
####################################################################################################

typeset adobeLatestYearFound=""
typeset AdobeUninstallerList=""

autoload 'is-at-least'

adobeJSONarray='{
    "applications": [
        {"name": "After Effects", "code": "AEFT" },
        {"name": "Animate", "code": "FLPR" },
        {"name": "Audition", "code": "AUDT" },
        {"name": "Bridge", "code": "KBRG" },
        {"name": "Character Animator", "code": "CHAR" },
        {"name": "Dimension", "code": "ESHR" },
        {"name": "Dreamweaver", "code": "DRWV" },
        {"name": "Illustrator", "code": "ILST" },
        {"name": "InCopy", "code": "AICY" },
        {"name": "InDesign", "code": "IDSN" },
        {"name": "Lightroom CC", "code": "LRCC"},
        {"name": "Lightroom Classic", "code": "LTRM" },
        {"name": "Media Encoder", "code": "AME" },
        {"name": "Photoshop", "code": "PHSP" },
        {"name": "Prelude", "code": "PRLD" },
        {"name": "Premiere Pro", "code": "PPRO" },
        {"name": "Premiere Rush", "code": "RUSH" },
        {"name": "Premiere Rush 2.0", "code": "RUSH" },
        {"name": "Substance 3D Designer", "code": "SBSTD" },
        {"name": "Substance 3D Painter", "code": "SBSTP" },
        {"name": "Substance 3D Sampler", "code": "SBSTA" },
        {"name": "Substance 3D Stager", "code": "STGR" },
        {"name": "XD", "code": "SPRK"}
    ]}'
AdobeUninstallerList=$( ${ADOBE_UNINSTALLER} --list | grep -v -e "\-----" -e "AdobeUninstaller" -e '^$' -e "Version" | awk '{CODE=NF-2 ; VER=NF-1 ; print $CODE "#" $VER}')

create_log_directory
create_file_list

# Two options - Silent removal (no prompts)
if [[ ${SCRIPT_METHOD:l} = "silent" ]]; then
    file_list_no_prompt
    remove_apps_no_prompt
else
    # Or allow the user to choose
    check_swift_dialog_install
    check_support_files
    create_infobox_message
    display_welcome_message
    confirm_removal
    remove_apps_prompt
fi
cleanup_and_exit
exit 0
