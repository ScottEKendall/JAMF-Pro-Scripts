#!/bin/zsh
#
# ClearBrowserCache
#
# by: Scott Kendall
#
# Written: 09/01/2023
# Last updated: 05/28/2025
#
# Script Purpose: Clear all cache/cookies from all browsers currently installed
#
# 1.0 - Initial
# 1.1 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...

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

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

JSON_OPTIONS=$(mktemp /var/tmp/ClearBrowserCache.XXXXX)
   
chrome_cache="${USER_DIR}/Library/Application Support/Google/Chrome/Default"
firefox_cache="${USER_DIR}/Library/Application Support/Firefox/Profiles"
safari_cache="${USER_DIR}/Library/Caches/com.apple.Safari"
edge_cache="${USER_DIR}/Library/Application Support/Microsoft Edge/Default"

chrome_tmp_dir=$(mktemp -d /var/tmp/ClearBrowserChromeCache.XXXXX)
edge_tmp_dir=$(mktemp -d /var/tmp/ClearBrowserChromeCache.XXXXX)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Clear Browser Cache(s)"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/CleanBrowserCache.log"
SD_ICON_FILE=$ICON_FILES"GenericNetworkIcon.icns"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=$3                          # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

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
    echo "${1}" 1>&2
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
}

function create_infobox_message()
{
	################################
	#
	# Swift Dialog InfoBox message construct
	#
	################################

	SD_INFO_BOX_MSG="## System Info ##\n"
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
	exit 0
}

function display_welcome_message()
{

    app_safari="/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
    app_firefox="/Applications/Firefox.app"
    app_chrome="/Applications/Google Chrome.app"
    app_edge="/Applications/Microsoft Edge.app"

    # Construct the JSON blob

    WelcomeMsg="This utility will clear the cache, history & cookies for the browsers that "
    WelcomeMsg+="are installed on your Mac.  Please choose which browser(s) you want to perform "
    WelcomeMsg+="this action on.<br><br>NOTE: Each browser will be quit during this process, and any open tabs will not be preserved."

    echo '{
        "checkbox" : [
            { "label" : "Safari", "checked" : true, "disabled" : false, "icon" : "'${app_safari}'"},' > ${JSON_OPTIONS}

    [[ -e ${app_firefox} ]] && echo '{ "label" : "Firefox", "checked" : true, "disabled" : false, "icon" : "'${app_firefox}'"},' >> ${JSON_OPTIONS}
    [[ -e ${app_chrome} ]] && echo '{ "label" : "Google Chrome", "checked" : true, "disabled" : false, "icon" : "'${app_chrome}'"},' >> ${JSON_OPTIONS}
    [[ -e ${app_edge} ]] && echo '{ "label" : "Microsoft Edge", "checked" : true, "disabled" : false, "icon" : "'${app_edge}'"},' >> ${JSON_OPTIONS}

    echo ']}' >>  "${JSON_OPTIONS}"
    chmod 644 "${JSON_OPTIONS}"

    # Display the message and offer them options

    MainDialogBody=(
        --message "${WelcomeMsg}"
        --icon "${SD_ICON_FILE}"
        --overlayicon computer
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --moveable
        --height 550
        --width 920
        --ontop
        --button1text "Ok"
        --button2text "Cancel"
        --checkboxstyle switch,regular
        --quitkey 0
        --json
        --jsonfile "${JSON_OPTIONS}"
    )
    browser_choice=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
}

function clear_firefox()
{

    declare -a delete_files=(places.sqlite places.sqlite-shm places.sqlite-wal downloads.sqlite formhistory.sqlite search-metadata.json search.json search.sqlite cookies.sqlite cookies.sqlite-shm cookies.sqlite-wal signons.sqlite sessionstore.bak sessionstore.js)
    declare -a delete_dir=(Cache OfflineCache datareporting)

    # Quit the browser
    if [[ $( /usr/bin/pgrep -f "Firefox") ]]; then
        osascript -e 'quit app "Firefox"'
        sleep 0.2 # Wait for the browser to shutdown before clearing the cache
    fi
    logMe "Clearing Firefox cache"

    # enable for loops over items with spaces
    IFS=$'\n'

    # loop through browser profiles and delete certain files
    for dir in $( ls "${firefox_cache}/" ); do
        if [[ ! -d "$firefox_cache/$dir" ]]; then
            continue
        fi
        for item in "${delete_files[@]}"; do
            if [[ -e "${firefox_cache}/${dir}/${item}" ]]; then
                /bin/rm "${firefox_cache}/${dir}/${item}"
                logMe "deleting: ${firefox_cache}/${dir}/${item}"
            fi
        done
        for item in "${delete_dir[@]}"; do
            if [[ -e "${firefox_cache}/${dir}/${item}" ]]; then
               /bin/rm -r "${firefox_cache}/${dir}/${item}"
               logMe "deleting: ${firefox_cache}/${dir}/${item}"
            fi
        done
    done
}

function clear_safari()
{
    declare -a Safari_files=("${safari_cache}/History.db" 
        "${safari_cache}/History-db-lock.db" 
        "${safari_cache}/History.db-shm" 
        "${safari_cache}/History.db-wal" 
        "${safari_cache}/CloudTabs.db" 
        "${safari_cache}/CloudTabs.db-shm" 
        "${safari_cache}/CloudTabs.db-wal" 
        "${safari_cache}/PerSitePreferences.db" 
        "${safari_cache}/PerSitePreferences.db-shm" 
        "${safari_cache}/PerSitePreferences.db-wal" 
        "${safari_cache}/Downloads.plist" 
        "${safari_cache}/SearchDescriptions.plist" 
        "${safari_cache}/LocalStorage" 
        "${safari_cache}/Favicon Cache" 
        "${safari_cache}/Touch Icons Cache" 
        "${safari_cache}/SearchDescriptions.plist" 
        "${USER_DIR}/Library/Cookies")

    logMe "Clearing Safari cache"
    if [[ $( /usr/bin/pgrep -f "Safari") ]]; then
        osascript -e 'quit app "Safari"'
        sleep 0.2 # Wait for the browser to shutdown before clearing the cache
    fi

    for item in "${Safari_files[@]}"; do
        if [[ -e "${item}" ]]; then
            logMe "Clearing ${item}"
            /bin/rm -rf "${item}"
        fi
    done
}

function clear_chrome()
{

    declare -a keep_list=(Preferences Bookmarks Bookmarks.bak Favicons)
    declare -a keep_dir=(Extensions)

    logMe "Clearing Google Chrome cache"
    
    # Move the files that we want to save into a tmp folder

    for item in "${keep_list[@]}"; do
        [[ -e "${chrome_cache}/${item}" ]] && mv "${chrome_cache}/${item}" "${chrome_tmp_dir}"
    done

    # Move any directories that need saved

        for dir_name in "${keep_dir[@]}"; do
            mkdir -p "${chrome_tmp_dir}/${dir_name}"
            cd "${chrome_cache}/${dir_name}"
            for files in *; do
                logMe "Backup file: ${files}"
                cp -r "${chrome_cache}/${dir_name}/${files}" "${chrome_tmp_dir}/${dir_name}/${files}"
            done
        done

    if [[ $( /usr/bin/pgrep -f "Google Chrome") ]]; then
        osascript -e 'quit app "Chrome"'
        sleep 0.2 # Wait for the browser to shutdown before clearing the cache
    fi

    # Delete the current cache files

    /bin/rm -rf "${chrome_cache}"

    # and restore the files
    
    logMe "Restoring Google Chrome files"
    mkdir -p "${chrome_cache}"
    cd "${chrome_tmp_dir}"
    for files in *; do
        logMe "Restoring "${files}
        cp -r "${files}" "${chrome_cache}"
    done
    chown -R ${LOGGED_IN_USER} "${chrome_cache}"
}    

function clear_edge()
{

    declare -a keep_list=(Preferences Bookmarks Bookmarks.bak Favicons)
    declare -a keep_dir=(Extensions 'Managed Extension Settings' 'Local Extension Settings')

    logMe "Clearing Microsoft Edge cache"

    # Move the files that we want to save into a tmp folder

    for item in "${keep_list[@]}"; do
        [[ -e "${edge_cache}/${item}" ]] && mv "${edge_cache}/${item}" "${edge_tmp_dir}"
    done

    # Move any directories that need saved

        for dir_name in "${keep_dir[@]}"; do
            mkdir -p "${edge_tmp_dir}/${dir_name}"
            cd "${edge_cache}/${dir_name}"
            for files in *; do
                logMe "Backup file: ${files}"
                cp -r "${edge_cache}/${dir_name}/${files}" "${edge_tmp_dir}/${dir_name}/${files}"
            done
        done
    if [[ $( /usr/bin/pgrep -f "Microsoft Edge") ]]; then
        osascript -e 'quit app "Microsoft Edge"'
        sleep 0.2 # Wait for the browser to shutdown before clearing the cache
    fi

    # Teams must be closed down as well since it uses the edge browser 

    if [[ $( /usr/bin/pgrep -f "Microsoft Teams (for work or school)") ]]; then
        osascript -e 'quit app "Microsoft Teams" (for work or school)'
        sleep 0.2 # Wait for teams to shutdown before clearing the cache
    fi

    /bin/rm -rf "${edge_cache}"

    # and restore the files
    
    logMe "Restoring Mirosoft Edge files"
    mkdir -p "${edge_cache}"
    cd "${edge_tmp_dir}"
    for files in *; do
        logMe "Restoring "${files}
        cp -r "${files}" "${edge_cache}"
    done
    chown -R ${LOGGED_IN_USER} "${edge_cache}"

}

############################
#
# Start of Main Script
#
############################

declare browser_choice
autoload 'is-at-least'

check_swift_dialog_install
check_support_files
create_infobox_message
display_welcome_message

# evalute responses

[[ $(echo $browser_choice | grep "Chrome" | awk -F " : " '{print $NF}' | tr -d ',') == "true" ]] && clear_chrome
[[ $(echo $browser_choice | grep "Safari" | awk -F " : " '{print $NF}' | tr -d ',') == "true" ]] && clear_safari
[[ $(echo $browser_choice | grep "Firefox" | awk -F " : " '{print $NF}' | tr -d ',') == "true" ]] && clear_firefox
[[ $(echo $browser_choice | grep "Edge" | awk -F " : " '{print $NF}' | tr -d ',') == "true" ]] && clear_edge

cleanup_and_exit
