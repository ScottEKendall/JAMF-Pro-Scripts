#!/bin/zsh
#
# HomeBrewPkgRemoval
#
# by: Scott Kendall
#
# Written: 01/03/2023
# Last updated: 12/23/2025
#
# Script Purpose: Remove HomeBrew Casks / Forumals using Swfit dialog GUI
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
SCRIPT_NAME="BrewPkgRemoval"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.0.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

# Make some temp files for this app

JSON_OPTIONS=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
TMP_FILE_STORAGE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
/bin/chmod 600 $JSON_OPTIONS
/bin/chmod 600 $TMP_FILE_STORAGE

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################
   
# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles)
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
    BANNER_SUBTITLE=""
fi
[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Delete HomeBrew Packages"
OVERLAY_ICON="https://brew.sh/assets/img/homebrew.svg"
SD_ICON_FILE="SF=trash.fill, color=black, weight=light"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

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


function runAsUser() 
{
    sudo -H -u "$LOGGED_IN_USER" "$@"
}

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

	/usr/local/bin/jamf policy -event ${DIALOG_INSTALL_POLICY}
}

function check_logged_in_user ()
{    
    # PURPOSE: Make sure there is a logged in user
    # RETURN: None
    # EXPECTED: $LOGGED_IN_USER
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        logMe "INFO: No user logged in, exiting"
        cleanup_and_exit 0
    else
		USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
		USER_UID=$(id -u "$LOGGED_IN_USER") 
		logMe "INFO: Logged in user: $LOGGED_IN_USER"
		logMe "INFO: Brew path: $BREW_PATH"
		logMe "INFO: Running as user $(runAsUser whoami)"
		logMe "INFO: Brew version $(runAsUser "$BREW_PATH" --version)"
    fi
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -event ${SUPPORT_FILE_INSTALL_POLICY}
}

function cleanup_and_exit ()
{
	local exitCode="${1:-0}"
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf "${JSON_OPTIONS}"
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf "${TMP_FILE_STORAGE}"
	exit "${exitCode}"
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
	# PURPOSE: Build the Array of items that can be removed
    # PARMS: None
    # RETURN: None

    # Fetch both formulae and casks cleanly into a Zsh array split by lines
	
	brew_list=( ${(f)"$(
		runAsUser "$BREW_PATH" list --formula 2>/dev/null
		runAsUser "$BREW_PATH" list --cask 2>/dev/null
	)"} )

    #brew_list=( ${(f)"$(brew list --formula; brew list --cask)"} )
    FILES_LIST=("${brew_list[@]}")
}

function construct_display_list ()
{
	# PURPOSE: Construct the Swift Dialog JSON blob for the listitem
    # PARMS: None
    # RETURN: None

	echo '{"checkboxstyle" : {
		"style" : "switch",
		"size" : "mini" },' > ${JSON_OPTIONS}

	# Construct the Swift Dialog list item display list based on files that can be deleted

	if [[ ${#FILES_LIST[@]} -ne 0 ]]; then

		# Construct the fils(s) list

		echo ' "checkbox" : [' >> ${JSON_OPTIONS}
		for i in "${FILES_LIST[@]}"; do
            echo '{"label" : "'"${i}"'", "checked" : false, "disabled" : false, "icon" : "/System/Applications/TextEdit.app" },' >> "${JSON_OPTIONS}"
		done
		sed -i '' -e '$ s/,$//' "$JSON_OPTIONS"
		echo ']}' >> "${JSON_OPTIONS}"
		chmod 644 "${JSON_OPTIONS}"
	fi

}

function choose_files_to_delete ()
{
	MainDialogBody=(
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
		--icon "${SD_ICON_FILE}"
		--overlayicon "${OVERLAY_ICON}"
		--messageposition top
		--moveable
		--vieworder "textfield, dropdown, checkbox"
		--message "$SD_DIALOG_GREETING $SD_FIRST_NAME. Please choose the brew formulas/casks that you want to remove from your system."
		--helpmessage "Choose the brew formulas/casks that you want to remove from your system."
		--width 820
		--height 650
		--ontop
		--buttonstyle center
		--infobox "${SD_INFO_BOX_MSG}"
		--jsonfile "${JSON_OPTIONS}"
		--selecttitle "Dependency Handling"
		--selectvalues "Respect Dependencies,Ignore Dependencies"
		--selectdefault "Respect Dependencies"
		--quitkey 0
		--button1text "Next"
		--button2text "Cancel"
    )

	tmp=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
    buttonpress=$?

	# User hit cancel so exit the app safely

	[[ ${buttonpress} -eq 2 || ${buttonpress} -eq 10 ]] && cleanup_and_exit 0
 
	# Strip out the files that they did not choose
	#echo $tmp | grep -v "false" > "${TMP_FILE_STORAGE}"
	printf '%s\n' "$tmp" | grep '"true"' > "${TMP_FILE_STORAGE}"

	IGNORE_DEPENDENCIES=false
	if echo "$tmp" | grep -q '"Dependency Handling" : "Ignore Dependencies"'; then
		IGNORE_DEPENDENCIES=true
	fi


}

function read_in_file_contents ()
{
	# PURPOSE: Read in the file list of the options that the user chose to remove
    # PARMS: None
    # RETURN: None

    FILES_LIST=()
	messagebody=""
	while read -r line; do
		name=$( echo "${line}" | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
		messagebody+="- ${name}\n"
        FILES_LIST+=("$name")
	done < "${TMP_FILE_STORAGE}"
}

function show_final_delete_prompt ()
{

	local dependencyWarnings=""
	local dependencyCount=0
	local usersOfPkg=""

	DependencyMode="Respect Dependencies"

	[[ "$IGNORE_DEPENDENCIES" == "true" ]] && DependencyMode="Ignore Dependencies"
	# Only check dependencies when respecting them
	if [[ "$IGNORE_DEPENDENCIES" != "true" ]]; then
		for pkg in "${FILES_LIST[@]}"; do
			usersOfPkg=$(runAsUser "$BREW_PATH" uses --installed "$pkg" 2>/dev/null)
			if [[ -n "$usersOfPkg" ]]; then
				# Count the # of dependencies and show each dependency
				((dependencyCount++))
				dependencyWarnings+="\n__${pkg} is required by:__<br>"
				while read -r dependency; do
					[[ -n "$dependency" ]] && dependencyWarnings+="• ${dependency}<br>"
				done <<< "$usersOfPkg"

				dependencyWarnings+="<br><br>"
			fi
		done

		if (( dependencyCount > 0 )); then
			dependencyWarnings="⚠️ ${dependencyCount} selected package(s) have dependency requirements.<br><br>${dependencyWarnings}"
		fi
	fi

	MainDialogBody=(
		--message "Mode: __${DependencyMode}__<br>Are you sure you want to delete these applications?<br>${messagebody}<br>${dependencyWarnings}"
		--icon "${SD_ICON_FILE}"
		--overlayicon warning
		--height 600
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
	[[ ${buttonpress} -eq 2 || ${buttonpress} -eq 10 ]] && cleanup_and_exit 0
}

function delete_files () 
{
    local total_packages=${#FILES_LIST[@]}
    local total_steps=$(( total_packages + 2 ))
    local current_step=0
	local brewArgs=( uninstall )

    SUCCESSFUL_REMOVALS=()
    FAILED_REMOVALS=()
	FAILED_REASONS=()

	[[ "$IGNORE_DEPENDENCIES" == "true" ]] && brewArgs+=( --ignore-dependencies )

    # 1. Main Uninstall Loop
    for pkg in "${FILES_LIST[@]}"; do
        pkg="${pkg//$'\r'/}"
        ((current_step++))
        percent=$(( (current_step * 100) / total_steps ))
		# Exit if there is no package
		if [[ -z "$pkg" ]] && continue
                
        logMe "INFO: Uninstalling: $pkg"

		if ! runAsUser "$BREW_PATH" list --formula "$pkg" >/dev/null 2>&1 && ! runAsUser "$BREW_PATH" list --cask "$pkg" >/dev/null 2>&1; then
			# Make sure package exists
			logMe "WARNING: Package $pkg no longer installed"
			FAILED_REMOVALS+=("$pkg")
			FAILED_REASONS["$pkg"]="$pkg - Package Not Installed"
			continue
		fi
		# try and remove the package and mark it accordingly
		if runAsUser "$BREW_PATH" "${brewArgs[@]}" "$pkg" >> "$LOG_FILE" 2>&1; then
		#if runAsUser "$BREW_PATH" "${brewArgs[@]}" "$pkg" ; then
			logMe "SUCCESS: Successfully removed $pkg"
			SUCCESSFUL_REMOVALS+=("$pkg")
		else
			logMe "FAILURE: Failed to remove $pkg"
			FAILED_REMOVALS+=("$pkg")
			FAILED_REASONS["$pkg"]="$pkg - Dependency Conflict"
		fi
    done
}

function show_completed_prompt ()
{
    local successText=""
    local failedText=""
    local finalMessage=""

    if (( ${#SUCCESSFUL_REMOVALS[@]} > 0 )); then
        successText="__Successfully Removed__\n\n"
        for pkg in "${SUCCESSFUL_REMOVALS[@]}"; do
            successText+="• ${pkg}<br>"
        done
    fi

    if (( ${#FAILED_REMOVALS[@]} > 0 )); then
        failedText="\n__Failed To Remove__\n\n"
		for pkg in "${FAILED_REMOVALS[@]}"; do
			failedText+="• ${FAILED_REASONS["$pkg"]}<br>"
		done
    fi

    finalMessage="${successText}${failedText}"

    [[ -z "$finalMessage" ]] && finalMessage="No changes were made."
	finalMessage+="\nIf you need to delete more files, you can choose \"Run Again\" below."

	MainDialogBody=(
		--message "${finalMessage}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--icon "${SD_ICON_FILE}"
		--titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
		--overlayicon "SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
		--ontop 
		--width 900
		--height 500
		--quitkey 0
		--buttonstyle center
		--button1text "OK"
		--button2text "Run Again"
	)

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?

	[[ ${buttonpress} -eq 0 || ${buttonpress} -eq 10 ]] && cleanup_and_exit 0
}

function check_contents ()
{

	if (( ${#FILES_LIST[@]} > 0 )); then
		return 0
	fi

	# Show a "no packages found message"
	MainDialogBody=(
		--message "No brew formulas or casks found."
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--icon "${SD_ICON_FILE}"
		--titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
		--overlayicon "SF=checkmark.circle.fill,color=green,weight=heavy"
		--ontop 
		--width 800
		--quitkey 0
		--buttonstyle center
		--button1text "OK"
	)

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?
	cleanup_and_exit 0
}

function get_brew_path ()
{
	if [[ -x /opt/homebrew/bin/brew ]]; then
  		BREW_PATH="/opt/homebrew/bin/brew"
	elif [[ -x /usr/local/bin/brew ]]; then
		BREW_PATH="/usr/local/bin/brew"
	else
		logMe "ERROR: Homebrew not found"
		cleanup_and_exit 1
	fi
}

#############################
#
# Start of Main Script
#
#############################

autoload 'is-at-least'

declare -a FILES_LIST
declare -a SUCCESSFUL_REMOVALS
declare -a FAILED_REMOVALS
declare -A FAILED_REASONS
declare messagebody

declare BREW_PATH
declare IGNORE_DEPENDENCIES

create_log_directory
check_swift_dialog_install
get_brew_path
check_logged_in_user
check_support_files
create_infobox_message


while true; do
	build_file_list_array
	check_contents
	construct_display_list
	choose_files_to_delete
	read_in_file_contents

    if (( ${#FILES_LIST[@]} == 0 )); then
        logMe "INFO: No packages selected"
        continue
    fi

	# Display a final warning with the flles they chose

	show_final_delete_prompt
	show_completed_prompt
done
cleanup_and_exit 0 
