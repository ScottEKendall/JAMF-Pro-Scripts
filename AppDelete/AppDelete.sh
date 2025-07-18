#!/bin/zsh
#
# App Delete
# Purpose: Allow end users to delete apps / folders using Swift Dialog
#
# Written: 8/3/2022
# Last updated: 07/18/2025
#
# 1.0 - Initial Release
# 1.1 - Major code cleanup & documentation
#		Structred code to be more inline / consistent across all apps
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 2.0 - Bumped Swift Dialog min version to 2.5.0
#		NEW: Added option to allow folders to be deleted (ALLOWED_FOLDERS)
#		Put shadows in the banner text
# 		Reordered sections to better show what can be modified
######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

[[ "$(/usr/bin/uname -p)" == 'i386' ]] && HWtype="SPHardwareDataType.0.cpu_type" || HWtype="SPHardwareDataType.0.chip_type"

SYSTEM_PROFILER_BLOB=$( /usr/sbin/system_profiler -json 'SPHardwareDataType')
MAC_CPU=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract "${HWtype}" 'raw' -)
MAC_RAM=$( echo $SYSTEM_PROFILER_BLOB | /usr/bin/plutil -extract 'SPHardwareDataType.0.physical_memory' 'raw' -)
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.5.0"

# Make some temp files for this app

JSON_OPTIONS=$(mktemp /var/tmp/AppDelete.XXXXX)
TMP_FILE_STORAGE=$(mktemp /var/tmp/AppDelete.XXXXX)
/bin/chmod 666 $JSON_OPTIONS
/bin/chmod 666 $TMP_FILE_STORAGE

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

# Support / Log files location

SUPPORT_DIR="/Library/Application Support/GiantEagle"
LOG_FILE="${SUPPORT_DIR}/logs/AppDelete.log"

# Display items (banner / icon)

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Delete Applications"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE="SF=trash.fill, color=black, weight=light"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

# The follow array lists the apps that the users are not allowed to remove.  If the apps show up in the list, they do not appear in the list of apps that can be deleted
NOT_ALLOWED_APPS=(
    "Company Portal" 
	"Falcon"
    "Jamf Connect"
	"Self Service"
	"Self Service+"
    "ZScaler")

# This list of items is for folders that are allowed to be deleted.  Some applications install themselves into a subfolder underneath /Applications, so you can hardcode which folders are allowed.
# Include just the folder names in this array (ie. Utilities), not the entire path
ALLOWED_FOLDERS=(
	"Zscaler Copy"
	"Utilities copy"
	"Cisco copy")

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

####################################################################################################
#
# Global Functions
#
####################################################################################################

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions (using zsh paramter expansion to get directory)
	LOG_DIR=${LOG_FILE%/*}
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
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
	exit 0
}

function create_infobox_message()
{
    # PURPOSE: Construct the infobox dialog msg
    # PARMS: None
    # RETURN: None

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="{serialnumber}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="{osname} {osversion}<br>"
}

####################################################################################################
#
# Functions
#
####################################################################################################

function build_file_list_array ()
{
	# PURPOSE: Build the Array of items that can be removed, delete the items that are not allowed and then add in the folders
    # PARMS: None
    # RETURN: None

	declare -a tmp_array
	declare saved_IFS=$IFS

	IFS=$'\n'
	FILES_LIST=( $(/usr/bin/find /Applications/* -maxdepth 0 -type d -iname '*.app' ! -ipath '*Contents*' | /usr/bin/sort -f | /usr/bin/awk -F '/' '{print $NF}' | /usr/bin/awk -F '.app' '{print $1}') )
	IFS=$saved_IFS

	# remove the items from array that are in the Managed apps array

	for i in "${NOT_ALLOWED_APPS[@]}"; do FILES_LIST=("${FILES_LIST[@]/$i}") ; done

	# Add only the non-empty items into the tmp_array

	for i in "${FILES_LIST[@]}"; do [[ -n "$i" ]] && tmp_array+=("${i}") ; done

	# copy the newly created array back into the working array

	FILES_LIST=(${tmp_array[@]})

	# Add in any allowed folders into the array

	for i in "${ALLOWED_FOLDERS[@]}"; do [[ -e "/Applications/${i}" ]] && FILES_LIST+=("${i}") ; done
}

function construct_display_list ()
{
	# PURPOSE: Construct the Swift Dialog JSON blob for the listitem
    # PARMS: None
    # RETURN: None

	echo '{"checkboxstyle" : {
		"style" : "switch",
		"size" : "regular" },' > ${JSON_OPTIONS}

	# Construct the Swift Dialog list item display list based on files that can be deleted

	if [[ ${#FILES_LIST[@]} -ne 0 ]]; then

		# Construct the fils(s) list

		echo ' "checkbox" : [' >> ${JSON_OPTIONS}
		for i in "${FILES_LIST[@]}"; do
			if [[ -f "/Applications/${i}.app/Contents/Info.plist" ]]; then
				echo '{"label" : "'"${i}"'", "checked" : false, "disabled" : false, "icon" : "/Applications/'${i}'.app" },' >> "${JSON_OPTIONS}"
			elif [[ -d "/Applications/${i}" ]]; then
				echo '{"label" : "'"${i}"'", "checked" : false, "disabled" : false, "icon" : "'${ICON_FILES}/ApplicationsFolderIcon.icns'" },' >> "${JSON_OPTIONS}"
			fi
		done
		echo ']}' >> "${JSON_OPTIONS}"
		chmod 644 "${JSON_OPTIONS}"
	fi

}

function choose_files_to_delete ()
{
	MainDialogBody=(
		--message "$SD_DIALOG_GREETING $SD_FIRST_NAME. Please choose the application(s) and/or folder(s) that you want to remove from your system.  Applications can be installed again from Self Service."
		--messageposition top
		--icon "${SD_ICON_FILE}"
		--overlayicon "${OVERLAY_ICON}"
		--moveable
		--bannerimage "${SD_BANNER_IMAGE}"
		--titlefont shadow=1
		--bannertitle "${SD_WINDOW_TITLE}"
		--helpmessage "Choose which applications you want to remove. <br>They can be installed again from Self Service."
		--width 920
		--height 750
		--ontop
		--buttonstyle center
		--infobox "${SD_INFO_BOX_MSG}"
		--jsonfile "${JSON_OPTIONS}"
		--quitkey 0
		--button1text "Next"
		--button2text "Cancel"
		--json
    )

	tmp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$?

	# User hit cancel so exit the app safely

	[[ ${buttonpress} -eq 2 || ${buttonpress} -eq 10 ]] && cleanup_and_exit

	# Strip out the files that they did not choose
	echo $tmp | grep -v ": false" > "${TMP_FILE_STORAGE}"
}

function read_in_file_contents ()
{
	# PURPOSE: Read in the file list of the options that the user chose to remove
    # PARMS: None
    # RETURN: None

	messagebody=""
	while read -r line; do
		name=$( echo "${line}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
		if [[ -e "/Applications/${name}.app" ]]; then
			messagebody+="- ${name}  \n"
		elif [[ -d "/Applications/${name}" ]]; then
			messagebody+="- Folder: ${name}  \n"
		fi
	done < "${TMP_FILE_STORAGE}"
}

function show_final_delete_prompt ()
{
	MainDialogBody=(
		--message "Are you sure you want to delete these applications?\n\n${messagebody}"
		--icon "${SD_ICON_FILE}"
		--overlayicon warning
		--height 500
		--bannerimage "${SD_BANNER_IMAGE}"
		--titlefont shadow=1
		--bannertitle "${SD_WINDOW_TITLE}"
		--button1text "Delete"
		--button2text "Cancel"
		--buttonstyle center
	)

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?

	# Evaluate the choice

	[[ ${buttonpress} -eq 0 ]] && delete_files
	[[ ${buttonpress} -eq 2 ]] && cleanup_and_exit
}

function delete_files () 
{
	while read -r line; do
		name=$( echo "${line}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
		if [[ -n "${name}" ]] && [[ -e "/Applications/${name}.app" ]]; then
			/bin/rm -rf "/Applications/${name}.app"
			logMe "Removed application: ${name}"
		elif [[ -d "/Applications/${name}" ]]; then
			/bin/rm -rf "/Applications/${name}"
			logMe "Removed Folder: ${name}"
		fi
	done < "${TMP_FILE_STORAGE}"
}

function show_completed_prompt ()
{
	MainDialogBody=(
		--message "The following application(s) have been deleted.<br><br>${messagebody}\n\nIf you need to delete more files, you can choose \"Run Again\" below."
		--ontop 
		--icon "${SD_ICON_FILE}"
		--titlefont shadow=1
		--overlayicon "SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--width 920
		--quitkey 0
		--buttonstyle center
		--button1text "OK"
		--button2text "Run Again"
	)

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?

	[[ ${buttonpress} -eq 0 || ${buttonpress} -eq 10 ]] && cleanup_and_exit
}

#############################
#
# Start of Main Script
#
#############################

autoload 'is-at-least'

declare -a FILES_LIST
declare messagebody

check_swift_dialog_install
create_log_directory
check_support_files
create_infobox_message

while true; do
	build_file_list_array
	construct_display_list
	choose_files_to_delete
	read_in_file_contents

	# Display a final warning with the flles they chose

	show_final_delete_prompt
	show_completed_prompt
done
cleanup_and_exit
