#!/bin/zsh
#
# App Delete
#
# Written: Aug 3, 2022
# Last updated: Dec 21, 2024

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

SW_DIALOG="/usr/local/bin/dialog"
SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/AppDelete.log"
# have to "pad" the text title to accomodate for the hardcoded banner image we currently display, this will make it more centered on the screen (5 spaces)
BANNER_TEXT_PADDING="      "
SD_INFO_BOX_MSG=""
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Remove Applications"

# Create temp files to store the JSON blob display options and for the choosen deleted items
JSON_OPTIONS=$(mktemp /private/tmp/AppDelete.XXXXX)
TMP_FILE_STORAGE=$(mktemp /private/tmp/AppDelete.XXXXX)

# The follow array lists the apps that the users are not allowed to remove.  If the apps show up in the list, they do not appear in the list of apps that can be deleted
MANAGED_APPS=(
    "Company Portal" 
	"Falcon"
    "Jamf Connect"
	"Self Service"
    "ZScaler")

# Swift Dialog version requirements

[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

typeset -a FILES_LIST
typeset HARDWARE_ICON
typeset messagebody
typeset MainDialogBody

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

	# If the log directory doesnt exist - create it and set the permissions
	if [[ ! -d "${LOG_DIR}" ]]; then
		/bin/mkdir -p "${LOG_DIR}"
		/bin/chmod 755 "${LOG_DIR}"
	fi

	# If the log file does not exist - create it and set the permissions
	if [[ ! -f "${LOG_FILE}" ]]; then
		/usr/bin/touch "${LOG_FILE}"
		/bin/chmod 644 "${LOG_FILE}"
	fi
}

function logMe () 
{
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    #
    # RETURN: None
    echo "${1}" 1>&2
    echo "$(/bin/date '+%Y%m%d %H:%M:%S'): ${1}\n" >> "${LOG_FILE}"
}

function alltrim ()
{
    echo "${1}" | /usr/bin/xargs
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
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy # from JAMF
    #
    # RETURN: None

	/usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

####################################################################################################
#
# Functions
#
####################################################################################################


function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
	exit 0
}

function create_filelist_json_blob ()
{
	######################
	#
	# Swift Dialog BLOB file for prompts
	#
	######################

	echo '{
		"overlayicon" : "/System/Applications/App Store.app", 
		"icon" : "'SF=trash.fill, color=black, weight=light'",
		"message" : "Please choose the application(s) that you want to remove from your system",
		"bannerimage" : "'"${SD_BANNER_IMAGE}"'",
		"bannertitle" : "'"${SD_WINDOW_TITLE}"'",
		"messagefont" : "size=18",
		"titlefont" : "shadow=1 size=28",
		"moveable" : "true",
		"ontop" : "true",
		"button1text" : "Next",
		"checkboxstyle" : {
			"style" : "switch",
			"size" : "regular" },
		"button2text" : "Cancel",
		"messageposition" : "top",
		"height" : "750",
		"width" : "920",' > ${JSON_OPTIONS}
}

function build_file_list_array ()
{
	typeset -a tmp_array
	typeset saved_IFS=$IFS

	IFS=$'\n'
	FILES_LIST=( $(/usr/bin/find /Applications/* -maxdepth 0 -type d -iname '*.app' ! -ipath '*Contents*' | /usr/bin/sort -f | /usr/bin/awk -F '/' '{ print $3 }' | /usr/bin/awk -F '.app' '{ print $1 }'))
	${IFS+':'} unset saved_IFS

	# remove the items from array that are in the Managed apps array

	for i in "${MANAGED_APPS[@]}"; do FILES_LIST=("${FILES_LIST[@]/$i}") ; done

	# Add only the non-empty items into the tmp_array

	for i in "${FILES_LIST[@]}"; do [[ -n "$i" ]] && tmp_array+=("${i}") ; done

	# copy the newly created array back into the working array

	FILES_LIST=(${tmp_array[@]})
}

function construct_display_list ()
{

	# Construct the Swift Dialog display list based on files that can be deleted

	if [[ ${#FILES_LIST[@]} -ne 0 ]]; then

		# Construct the fils(s) list

		echo ' "checkbox" : [' >> ${JSON_OPTIONS}
		for i in "${FILES_LIST[@]}"; do
			echo '{"label" : "'"${i}"'", "checked" : false, "disabled" : false, "icon" : "/Applications/'${i}'.app" },' >> "${JSON_OPTIONS}"
		done
		echo ']}' >> "${JSON_OPTIONS}"
		chmod 644 "${JSON_OPTIONS}"

	fi

}

function choose_files_to_delete ()
{

	MainDialogBody="${SW_DIALOG} \
		--helpmessage 'Choose which applications you want to remove.  \nThey can be installed again from Self Service.' \
		--jsonfile '${JSON_OPTIONS}' \
		--infobox '${SD_INFO_BOX_MSG}' \
		--quitkey 0 \
		--json" 

	# Show the dialog screen and allow the user to choose

	tmp=$(eval "${MainDialogBody}")
	buttonpress=$?

	# User hit cancel so exit the app safely

	[[ ${buttonpress} -eq 2 || ${buttonpress} -eq 10 ]] && cleanup_and_exit

	# Strip out the files that they did not choose

	echo $tmp | grep -v ": false" > "${TMP_FILE_STORAGE}"
}

function read_in_file_contents ()
{
	messagebody=""
	while read -r line; do
		name=$( echo $(alltrim "${line}") | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
		[[ -e "/Applications/${name}.app" ]] && messagebody+="- ${name}  \n"
	done < "${TMP_FILE_STORAGE}"
}

function show_final_delete_prompt ()
{
	MainDialogBody="${SW_DIALOG} \
		--message 'Are you sure you want to delete these applications?\n\n${messagebody}' \
		--icon "SF=trash.fill,color=black,weight=light" \
		--height 500 \
		--ontop \
		--bannerimage '${SD_BANNER_IMAGE}' \
		--bannertitle '${SD_WINDOW_TITLE}' \
		--button1text 'Delete' \
		--button2text 'Cancel' \
		--buttonstyle center  "

	# Show the dialog screen and allow the user to choose

	eval "${MainDialogBody}"
	buttonpress=$?

	# User wants to continue, so delete the files

	[[ ${buttonpress} -eq 0 ]] && delete_files

	# user choose to exit
	
	[[ ${buttonpress} -eq 2 ]] && cleanup_and_exit

}

function delete_files () 
{
	while read -r line; do
		name=$( echo $(alltrim "${line}" ) | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')
		if [[ -n "${name}" ]] && [[ -e "/Applications/${name}.app" ]]; then
			/bin/rm -rf "/Applications/${name}.app"
			logMe "Removed application: ${name}"
		fi
	done < "${TMP_FILE_STORAGE}"
}

function show_completed_prompt ()
{

	MainDialogBody="${SW_DIALOG} \
		--message 'The following application(s) have been deleted.<br><br>${messagebody}\n\nIf you need to delete more files, you can choose \"Run Again\" below.' \
		--ontop \
		--icon "SF=trash.fill,color=black,weight=light" \
		--overlayicon 'SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none' \
		--bannerimage '${SD_BANNER_IMAGE}' \
		--bannertitle '${SD_WINDOW_TITLE}' \
		--width 920 \
		--quitkey 0 \
		--button1text 'OK' \
		--button2text 'Run Again'"

	# Show the dialog screen and allow the user to choose

	tmp=$(eval "${MainDialogBody}")
	buttonpress=$?

	[[ ${buttonpress} -eq 0 || ${buttonpress} -eq 10 ]] && cleanup_and_exit
}

####################################################################################################
#
# Auto Load Functions
#
####################################################################################################

autoload 'is-at-least'

#############################
#
# Start of Main Script
#
#############################

check_swift_dialog_install
create_log_directory
while true; do
	create_filelist_json_blob
	build_file_list_array
	construct_display_list
	choose_files_to_delete
	read_in_file_contents

	# Display a final warning with the flles they chose

	show_final_delete_prompt
	show_completed_prompt
done
cleanup_and_exit
