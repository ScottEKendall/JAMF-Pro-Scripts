#!/bin/zsh

# Written: May 3, 2022
# Last updated: Mar 7, 2024
# by: Scott Kendall (w491008)
#
# Script Purpose: Migrate user data to/from MacOS computers
#
# Version History
#
# 1.0 - Initial code
# 1.1 - Added Projects Folder
# 1.2 - Rewrote copy commands into a common function and thinned out copy commands
# 1.3 - Add warning dialog for clearing out trash if they choose to backup hidden files
# 1.4 - Add option for Freeform
# 2.0 - Much more detailed reporting of copy progress so that the user can see the status.
#		Removed need to run as admin user and removed warning about emptying trash
# 2.1 - Move from CocoaDialog to SwiftDialog 
# 2.2 - Add a "tech" settings to allow saving / restore from an external (non-network) drive
# 2.3 - Major code cleanup / function name changes, proper variable syntax
# 3.0 - Migrate lots of code to functions / rewrite of code to follow happy path / integrated MS OneDrive
# 3.1 - Renamed log_dir to user_log_dir so to not get confused with LOG_DIR
# 3.2 - Tons of documentation / Heavy use of Dialog BLOBS for more flexibility / Major rewrite of backup/restore routines
# 3.3 - More documentation / designed backup - resetore routine to handle a variety of copy methods (rsync, tar, or cp)

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SWDialog="/usr/local/bin/dialog"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
OVERLAY_ICON="/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"
SD_BANNER_IMAGE="/Library/Application Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png"
ICON_DIRECTORY="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="/Library/Application Support/GiantEagle/logs"

#######################################################################################################
#
# Application Specific variables
# Do NOT changes these variables as they are need specifically for this app
#
#######################################################################################################

typeset -a Answers
typeset BACKUP_RESTORE
typeset BACKUP_LOCATION
typeset MIGRATION_DIRECTORY
typeset HARDWARE_ICON
typeset JSON_APPS_BLOB

# have to "pad" the text title to accomodate for the hardcoded banner image we currently display, this will make it more centered on the screen (5 spaces)
BANNER_TEXT_PADDING="     "
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Mac Migration Wizard"
SD_WINDOW_ICON="SF=externaldrive.fill.badge.timemachine,colour=blue,colour2=purple"
ONE_DRIVE_PATH="${USER_DIR}/Library/CloudStorage/OneDrive-GiantEagle,Inc"
one_drive_disk_image="${ONE_DRIVE_PATH}/ODMigration.sparsebundle"
NOTES_PATH="${USER_DIR}/Library/Group Containers/group.com.apple.notes/"
GOOGLE_PATH="${USER_DIR}/Library/Application Support/Google/Chrome/"
FIREFOX_PATH="${USER_DIR}/Library/Application Support/Firefox/"
SAFARI_PATH="${USER_DIR}/Library/Safari/"
STICKIES_PATH="${USER_DIR}/Library/Containers/com.apple.Stickies/Data/Library/Stickies/"
PROJECTS_PATH="${USER_DIR}/Projects/"
FREEFORM_PATH="${USER_DIR}/Library/Containers/com.apple.freeform/"
BACKUP_DIR_STRUCTURE=("/Notes" "/Google" "/Firefox" "/Safari" "/Keychains" "/Stickies" "/Desktop" "/Documents" "/Pictures" "/Freeform" "/Projects" "/Hidden")
USER_LOG_FILE="${USER_DIR}/Documents/Migration Wizard.log"
DIALOG_CMD_FILE=$(mktemp /var/tmp/BackupWizard.XXXXX)
JSON_DIALOG_BLOB=$(mktemp /var/tmp/exampleDialog.XXXXX)
BACKUP_METHOD="tar"
chmod +rw "${JSON_DIALOG_BLOB}"
# Swift Dialog version requirements

SD_VERSION=$( ${SWDialog} --version)
MIN_SD_REQUIRED_VERSION="2.4.2"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

[[ $1 == "Tech" ]] && TechMode="Tech" || TechMode="User"

######################
#
# Functions
#
#######################

function create_json_app_blob()
{
	# Construct the core apps blob with all of the important info
    # The list is dynamic..you can add more backup items in here
    #
    # RETURN: None
	# VARIABLES expected: All the PATH, SIZE & FILES need to set before hand

	# Parm 1 - AppName
	# Parm 2 - Local Path
	# Parm 3 - Remote Subdirectory
	# Parm 4 - Icon Path
	# Parm 5 - Size of all files
	# Parm 6 - Number of folders
	# Parm 7 - files to exclude
	# Parm 8 - Progress Count
	
	JSON_APPS_BLOB='[{"app" : "Chrome",   "path" : "'${GOOGLE_PATH}'",        "MigrationDir" : "/Google",    "icon" : "/Applications/Google Chrome.app",                   "size" : "'${google_size}'",    "files" : "'${google_files}'",    "ignore" : "Services",      "progress" : "8"},
					{"app" : "Firefox",   "path" : "'${FIREFOX_PATH}'",       "MigrationDir" : "/Firefox",   "icon" : "/Applications/FireFox.app",                         "size" : "'${firefox_size}'",   "files" : "'${firefox_files}'",   "ignore" : "Services*",     "progress" : "16"},
					{"app" : "Safari",    "path" : "'${SAFARI_PATH}'",        "MigrationDir" : "/Safari",    "icon" : "/Applications/Safari.app",                          "size" : "'${safari_size}'",    "files" : "'${safari_files}'",    "ignore" : "Favicon Cache", "progress" : "24"},
					{"app" : "Notes",     "path" : "'${NOTES_PATH}'",         "MigrationDir" : "/Notes",     "icon" : "/System/Applications/Notes.app",                    "size" : "'${notes_size}'",     "files" : "'${notes_files}'",     "ignore" : "Cache",         "progress" : "40"},
					{"app" : "Stickies",  "path" : "'${STICKIES_PATH}'",      "MigrationDir" : "/Stickies",  "icon" : "/System/Applications/Stickies.app",                 "size" : "'${stickies_size}'",  "files" : "'${stickies_files}'",  "ignore" : "cache",         "progress" : "48"},
					{"app" : "Desktop",   "path" : "'${USER_DIR}/Desktop'",   "MigrationDir" : "/Desktop", 	 "icon" : "'${ICON_FILES}/DesktopFolderIcon.icns'",            "size" : "'${desktop_size}'",   "files" : "'${desktop_files}'",   "ignore" : "",              "progress" : "56"},
					{"app" : "Documents", "path" : "'${USER_DIR}/Documents'", "MigrationDir" : "/Documents", "icon" : "'${ICON_FILES}/DocumentsFolderIcon.icns'",          "size" : "'${documents_size}'", "files" : "'${documents_files}'", "ignore" : "",              "progress" : "64"},
					{"app" : "Pictures",  "path" : "'${USER_DIR}/Pictures'",  "MigrationDir" : "/Pictures",	 "icon" : "/System/Applications/Photos.app",                   "size" : "'${picture_size}'",   "files" : "'${picture_files}'",   "ignore" : "cache",         "progress" : "72"},
					{"app" : "Projects",  "path" : "'${USER_DIR}/Projects'",  "MigrationDir" : "/Projects",  "icon" : "'${ICON_FILES}/DeveloperFolderIcon.icns'",          "size" : "'${project_size}'",   "files" : "'${projects_files}'",  "ignore" : "",              "progress" : "80"},
					{"app" : "Freeform",  "path" : "'${FREEFORM_PATH}'",      "MigrationDir" : "/Freeform",  "icon" : "/System/Applications/Freeform.app",                 "size" : "'${freeform_size}'",  "files" : "'${freeform_files}'",  "ignore" : "",              "progress" : "88"},
					{"app" : "Hidden",    "path" : "'${USER_DIR}'",           "MigrationDir" : "/Hidden",    "icon" : "'${ICON_FILES}/FinderIcon.icns'",                   "size" : "'${hidden_size}'",    "files" : "'${hidden_files}'",    "ignore" : ".Trash",        "progress" : "100" }]'

}

function construct_dialog_header_settings()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
		"icon" : "'${SD_WINDOW_ICON}'",
		"message" : "'$1'",
		"bannerimage" : "'${SD_BANNER_IMAGE}'",
		"bannertitle" : "'${SD_WINDOW_TITLE}'",
		"titlefont" : "shadow=1",
		"button1text" : "OK",
		"height" : "675",
		"width" : "920",
		"moveable" : "true",
		"messageposition" : "top",'		
}

function create_json_dialog_blob()
{
    # Adds to the existing Display BLOB with information from the construct_json_apps_blob
    #
    # RETURN: Creates the temporary JSON_DIALOG_BLOB file
	# VARIABLES expected: JSON_DIALOG_BLOB needs to be constructed first
	# PARMS Passed: $1 is message to be displayed on the window

	construct_dialog_header_settings "${1}" > "${JSON_DIALOG_BLOB}"
	echo '"button1disabled" : "true",
			"listitem" : [' >> "${JSON_DIALOG_BLOB}"

	for i in {0..10}; do
		app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].app' )
		icon=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].icon' )
		echo '{"title" : "'"${app}"'", "status" : "pending", "statustext" : "Pending...", "icon" : "'"${icon}"'"},'>> "${JSON_DIALOG_BLOB}"
	done
	echo "]}" >> "${JSON_DIALOG_BLOB}"
}

function logMe() 
{
    # Writes log entry 
    #
    # RETURN: none
	# VARIABLES expected: USER_LOG_FILE points to logfile location
	# PARMS Passed: $1 is message to be written to log

    echo "${1}" 1>&2
    echo "$(/bin/date '+%Y%m%d %H:%M:%S')\n${1}\n" >> "${USER_LOG_FILE}"
}

function alltrim()
{
	# Removes all leading / trailing spaces 
    #
    # RETURN: trimmed variable
	# VARIABLES expected: none
	# PARMS Passed: $1 is variable to trim

    echo "$1" | xargs
}

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None
	# VARIABLES expected: SD_VERSION & MIN_SD_REQUIRED_VERSION must be set first
	# PARMS Passed: none

    logMe "Ensuring that swiftDialog is installed and up to date..."
    if [[ ! -x "/usr/local/bin/dialog" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    fi
}

function install_swift_dialog ()
{
    # Install Swift dialog From JAMF
    #
	# VARIABLES expected: DIALOG_INSALL_POLICY is the JAMF policy #
	# PARMS Passed: None
    # RETURN: None

	/usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

function choose_backup_location()
{
    # Show the user options of which location to store files
    # NOTE: if keyword "Tech" is passsed to this function, you can choos a custom location
    #
	# VARIABLES expected: All Windows title variables
	# PARMS Passed: None
    # RETURN: None
	
	typeset values && values="Microsoft OneDrive (Faster), GE Network (Legacy)"
	
	[[ $TechMode == "Tech" ]] && values+=", External Drive"

	DialogMsg="${SWDialog} \
			--message \"Please select file Location\" \
            --bannerimage \"${SD_BANNER_IMAGE}\" \
            --bannertitle \"${SD_WINDOW_TITLE}\" \
			--icon \"${SD_WINDOW_ICON}\" \
			--moveable \
			--selecttitle \"Location:\"\
			--selectvalues \"${values}\" \
			--height 330 \
			--width 700 \
			--button1text \"Proceed\" \
			--selectdefault \"Microsoft OneDrive (Faster)\" \
			--selecttitle \"Choose Action:\"\
			--selectvalues \"Backup, Restore\" \
			--json \
			--infobuttontext \"Cancel\" "

	tmp=$(eval "${DialogMsg}" 2>/dev/null)
	button=$?
	echo "$button"

	[[ "${button}" == "3" ]] && cleanup_and_exit

	[[ ! -z $(echo $tmp | grep "Backup")  ]] && BACKUP_RESTORE="backup" || BACKUP_RESTORE="restore"	
	[[ ! -z $(echo $tmp | grep "OneDrive") ]] && BACKUP_LOCATION="OneDrive" || BACKUP_LOCATION="Network"
	[[ ! -z $(echo $tmp | grep "External" ) ]] && BACKUP_LOCATION="External"

	#echo "Choices: "$BACKUP_LOCATION / $BACKUP_RESTORE

}

function onedrive_disk_image()
{
	# routines to create / mount / unmount OneDrive disk images

		case "$1" in 

			"Create" )
				/usr/bin/hdiutil create "${one_drive_disk_image}" -type SPARSEBUNDLE -fs APFS  -volname "Migration"
				;;

			"Mount"  )
				/usr/bin/hdiutil attach -mountroot /Volumes "${one_drive_disk_image}"

				# Wait 5 secs for volume to mount before continuing...
				sleep 5
				;;

			"UnMount" )
 				if /sbin/mount | grep "/Migration"; then
					/usr/bin/hdiutil detach "/Volumes/Migration"
				fi
				;;

			"Destroy" )
				if /sbin/mount | grep "/Migration"; then
					/usr/bin/hdiutil detach "/Volumes/Migration"
					/bin/rm -rf "${one_drive_disk_image}"
				fi
				;;
		esac

		MIGRATION_DIRECTORY="/Volumes/Migration"
}

function select_migration_apps()
{
	# Construct the main dialog box giving the user choices of which files to backup/restore
    #
	# VARIABLES expected: JSON_DIALOG_BLOB must be set
	# PARMS Passed: None
    # RETURN: None

	construct_dialog_header_settings "Select files to $BACKUP_RESTORE for user $LOGGED_IN_USER:" > "${JSON_DIALOG_BLOB}"
	echo '"checkboxstyle" : {
		  "style" : "switch",
		  "size"  : "regular"
		  }, "checkbox" : [' >> "${JSON_DIALOG_BLOB}"

		for i in {0..10}; do
			app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].app' )
			size=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].size' )
			files=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].files' )
			icon=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].icon' )
			echo '{"label" : "'"$app (${size} / ${files} Files)"'", "checked" : true, "icon" : "'"${icon}"'"},'>> "${JSON_DIALOG_BLOB}"
		done
		echo "]}" >> "${JSON_DIALOG_BLOB}"

	/bin/chmod 775 "${JSON_DIALOG_BLOB}"

	# Display the message and offer them options
	
	TmpMsg="${SWDialog} --json --jsonfile '${JSON_DIALOG_BLOB}'"

	tmp=$(eval "${TmpMsg}")
	button=$?

	# User choose to exit, so cleanup & quit
	[[ $button -eq 2 ]] && cleanup_and_exit

	# Process each checkbox item and set it in the control array
	for i in {0..10}; do
		app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].app' )
		Answers[$i+1]=$(echo $tmp | grep "$app" | awk -F " : " '{print $NF}' | tr -d ',' )
	done

}

function get_migration_directory()
{
	# Determine migration directory from their choices, and make sure it is a valid path 
    #
	# VARIABLES expected: ONE_DRIVE_PATH must be set
	# PARMS Passed: None
    # RETURN: None

	case "${BACKUP_LOCATION}" in

		*"OneDrive"* )
					
			# Create the disk image if it doesn't exist
			MIGRATION_DIRECTORY="/Volumes/Migration"
			if [[ ! -e "${one_drive_disk_image}" && "${BACKUP_RESTORE}" == "backup" ]]; then
				onedrive_disk_image "Create"
			fi

			# Mount the drive

			onedrive_disk_image "Mount"
			
			;;
			# MIGRATION_DIRECTORY="${ONE_DRIVE_PATH}"
			#[[ -e "${MIGRATION_DIRECTORY}" ]] && /bin/mkdir -p "${MIGRATION_DIRECTORY}/Migration"
			#MIGRATION_DIRECTORY+="/Migration"
			#;;
			
		*"Network"* )

			# Set the default Directory for network location

			[[ -d "/Volumes/${LOGGED_IN_USER}" ]] && MIGRATION_DIRECTORY="/Volumes/${LOGGED_IN_USER}/Migration" || MIGRATION_DIRECTORY="/Users/${LOGGED_IN_USER}/Migration"
			;;

		*"External"* )

			construct_dialog_header_settings "Please enter the location for your files" > "${JSON_DIALOG_BLOB}"
			echo '"button2text" : "Cancel", "json" : "true"}'>> "${JSON_DIALOG_BLOB}"
			tmp=$( ${SWDialog} --jsonfile "${JSON_DIALOG_BLOB}" --textfield "Select a storage location",fileselect,filetype=folder)

			[[ "$?" == "2" ]] && cleanup_and_exit
			
			# Format the Volume name correctly

			MIGRATION_DIRECTORY=$( echo $tmp | grep "location" | awk -F ": " '{print $NF}' | tr -d '\' | tr -d '"')

			#MIGRATION_DIRECTORY+="/Migration"
			;;
	esac
	if [[ "$1" == "backup" ]]; then

		if [[ ! -e ${MIGRATION_DIRECTORY} ]]; then
			no_network_drive_present
			cleanup_and_exit
		fi

	else
		#
		# If they want to do a restore, then make sure that the Migration Volume is present and mount it
		#
		echo $BACKUP_LOCATION
		case "${BACKUP_LOCATION}" in
			*"OneDrive"* )

				if [[ -e "${one_drive_disk_image}" ]]; then
					onedrive_disk_image "Mount"

					# If there was an error mounting the OneDrive volume then exit

					if [[ $? -ne 0 ]]; then
						cleanup_and_exit
						exit 1
					fi
					MIGRATION_DIRECTORY="/Volumes/Migration"

					# Make sure that their Network Home Drive is mounted, otherwise exit

					if [[ ! -e "${MIGRATION_DIRECTORY}" ]]; then
						no_network_drive_present
						cleanup_and_exit
					fi
				fi
				;;

			*"Network"* )
				# Verify mount point for network drive

				[ -d "/Volumes/${LOGGED_IN_USER}" ] && MIGRATION_DIRECTORY="/Volumes/${LOGGED_IN_USER}/Migration" || MIGRATION_DIRECTORY="/Users/${LOGGED_IN_USER}/Migration"
				;;

			*"External"* )
				construct_dialog_header_settings "Please enter the location for your files" > "${JSON_DIALOG_BLOB}"
				echo '"button2text" : "Cancel", "json" : "true"}'>> "${JSON_DIALOG_BLOB}"
				tmp=$( ${SWDialog} --jsonfile "${JSON_DIALOG_BLOB}" --textfield "Select a storage location",fileselect,filetype=folder)

				[[ "$?" == "2" ]] && cleanup_and_exit
				
				# Format the Volume name correctly

				MIGRATION_DIRECTORY=$( echo $tmp | grep "location" | awk -F ": " '{print $NF}' | tr -d '\' | tr -d '"')

				#MIGRATION_DIRECTORY+="/Migration"
				;;
		esac
	fi
	
}

function no_network_drive_present()
{
	# No drive present, show user an error
    #
    # RETURN: None

	[[ ${BACKUP_LOCATION} == "*OneDrive*" ]] && title="Please make sure that OneDrive is running on your Mac." || title="Please make sure that the Network Volume is mounted on your Mac."

	${SWDialog} \
		--message "${title}" \
		--title "${SD_WINDOW_TITLE}" \
		--icon "${ICON_FILES}AlertStopIcon.icns" \
		--button1text "OK" \
		--width 560 \
		--height 200 \
		--icon-size 50
}

function create_migration_directories()
{
	# Create the backup subfolders inside the migration directory 
    #
	# VARIABLES expected: MIGRATION_DIRECTORY must be set
	# PARMS Passed: None
    # RETURN: None

	typeset dir_name

	if [[ "${BACKUP_METHOD}" == "tar" ]]; then
		return 0
	fi
	for subdir_name in ${BACKUP_DIR_STRUCTURE}; do
		# If the destination directory doesn't exist, make it
	    [[ ! -d "${MIGRATION_DIRECTORY}${subdir_name}" ]] && /bin/mkdir -p "${MIGRATION_DIRECTORY}${subdir_name}"
	done
}

function update_display_list()
{
	# Function to handle various aspects of the Swift Dialog behaviour
    #
    # RETURN: None
	# VARIABLES expected: JSON_DIALOG_BLOB & Window variables should be set
	# PARMS List
	#
	# #1 - Action to be done ("Create, Destroy, "Update", "change")
	# #2 - Progress bar % (pass as integer)
	# #3 - Application Title (must match the name in the dialog list entry)
	# #4 - Progress Text (text to be display on bottom on window)
	# #5 - Progress indicator (wait, success, fail, pending)
	# #6 - List Item Text (text to be displayed while updating list entry)

	## i.e. update_display_list "Update" "8" "Google Chrome" "Calculating Chrome" "pending" "Working..."
	## i.e.	update_display_list "Update" "8" "Google Chrome" "" "success" "Done"

	case "$1" in

	"Create" )

		#
		# Create the progress bar
		#
		create_json_dialog_blob "${2}"

		${SWDialog} \
			--progress \
			--jsonfile "${JSON_DIALOG_BLOB}" \
			--infobox "Please be patient while this is working.... If you have lots of files and/or folders, this process might take a while!" \
			--commandfile ${DIALOG_CMD_FILE} \
			--button1disabled \
			--infotext "Files are stored in: ${MIGRATION_DIRECTORY}" & /bin/sleep .3
		;;

	"Destroy" )
	
		#
		# Kill the progress bar and clean up
		#
		echo "quit:" >> "${DIALOG_CMD_FILE}"
		;;

	"Update" | "Change" )

		#
		# Increment the progress bar by ${2} amount
		#

		# change the list item status and increment the progress bar
		/bin/echo "listitem: title: "$3", status: $5, statustext: $6" >> "${DIALOG_CMD_FILE}"
		/bin/echo "progress: $2" >> "${DIALOG_CMD_FILE}"

		/bin/sleep .5
		;;
		
	esac
}

function create_migration_log()
{
    # Creates the migration log output on the users desktop
    #
	# VARIABLES expected: USER_LOG_FILE is the location of the migration log output
	# PARMS Passed: None
	# RETURN: None

	[[ -e "${USER_LOG_FILE}" ]] && /bin/rm "${USER_LOG_FILE}"
	
	echo "$(/bin/date) -- "${SD_WINDOW_TITLE}" started" > "${USER_LOG_FILE}"
	/usr/bin/open "${USER_LOG_FILE}"
}

function calculate_storage_space()
{
	# calculate the sizes of each directory so we can show the user
    #
	# VARIABLES expected: PATH, SIZE & FILES should be declared
	# PARMS Passed: None
    # RETURN: None

	update_display_list "Create" "Calculating Space Requirements..."

	update_display_list "Update" "8" "Chrome" "Calculating Chrome" "wait" "Working..."
	google_size=$( calculate_folder_size "${GOOGLE_PATH}" )
	google_files=$( calculate_num_of_files "${GOOGLE_PATH}" )
	update_display_list "Update" "8" "Chrome" "" "success" "Done"

	update_display_list "Update" "16" "Firefox" "Calculating Firefox" "wait" "Working..."
	firefox_size=$( calculate_folder_size "${FIREFOX_PATH}" )
	firefox_files=$( calculate_num_of_files "${FIREFOX_PATH}" )
	update_display_list "Update" "16" "Firefox" "" "success" "Done"

	update_display_list "Update" "32" "Safari" "Calculating Safari" "wait" "Working..."
	safari_size=$( calculate_folder_size "${SAFARI_PATH}" )
	safari_files=$( calculate_num_of_files "${SAFARI_PATH}" )
	update_display_list "Update" "32" "Safari" "" "success" "Done"

	update_display_list "Update" "46" "Notes" "Calculating Notes" "wait" "Working..."
	notes_size=$( calculate_folder_size "${NOTES_PATH}" )
	notes_files=$( calculate_num_of_files "${NOTES_PATH}" )
	update_display_list "Update" "46" "Notes" "" "success" "Done"

	update_display_list "Update" "54" "Stickies" "Calculating Stickies" "wait" "Working..."
	stickies_size=$( calculate_folder_size "${STICKIES_PATH}" )
	stickies_files=$( calculate_num_of_files "${STICKIES_PATH}" )
	update_display_list "Update" "54" "Stickies" "" "success" "Done"

	update_display_list "Update" "62" "Desktop" "Calculating Desktop" "wait" "Working..."
	desktop_size=$( calculate_folder_size "${USER_DIR}/Desktop" )
	desktop_files=$( calculate_num_of_files "${USER_DIR}/Desktop" )
	update_display_list "Update" "62" "Desktop" "" "success" "Done"

	update_display_list "Update" "70" "Documents" "Calculating Documents" "wait" "Working..."
	documents_size=$( calculate_folder_size "${USER_DIR}/Documents" )
	documents_files=$( calculate_num_of_files "${USER_DIR}/Documents" )
	update_display_list "Update" "70" "Documents" "" "success" "Done"

	update_display_list "Update" "78" "Pictures" "Calculating Pictures" "wait" "Working..."
	picture_size=$( calculate_folder_size "${USER_DIR}/Pictures" )
	picture_files=$( calculate_num_of_files "${USER_DIR}/Pictures" )
	update_display_list "Update" "78" "Pictures" "" "success" "Done"

	update_display_list "Update" "86" "Projects" "Calculating Projects" "wait" "Working..."
	project_size=$( calculate_folder_size "${PROJECTS_PATH}" )
	project_files=$( calculate_num_of_files "${PROJECTS_PATH}" )
	update_display_list "Update" "86" "Projects" "" "success" "Done"

	update_display_list "Update" "94" "Freeform" "Calculating Freeform" "wait" "Working..."
	freeform_size=$( calculate_folder_size "${FREEFORM_PATH}" )
	freeform_files=$( calculate_num_of_files "${FREEFORM_PATH}" )
	update_display_list "Update" "94" "Freeform" "" "success" "Done"

	update_display_list "Update" "100" "Hidden" "Calculating Hidden Files" "wait" "Working..."
	hidden_size=$( calculate_folder_size "${USER_DIR}/hidden" )
	hidden_files=$( calculate_num_of_files "${USER_DIR}/hidden" )
	update_display_list "Update" "100" "Hidden" "" "success" "Done"

	/bin/sleep 2
	update_display_list "Destroy"
}

function calculate_folder_size()
{
	# calculate the sizes of each directory so we can show the user
	#
	# VARIABLES expected: none
	# PARMS Passed: $1 is directory to be acted upon
	# RETURN: Total Size of folder

	[[ "${1}" == "${USER_DIR}/hidden" ]] && filepath="${USER_DIR}/.[^.]*" || filepath="${1}"
	echo $( du -hcs ${~filepath} | tail -1 | awk '{print $1}' ) 2>&1
	return 0
}

function calculate_num_of_files()
{
	# calculate the sizes of each directory so we can show the user
	#
	# VARIABLES expected: none
	# PARMS Passed: $1 is directory to be acted upon
    # RETURN: Total # of files found

	if [[ "${1}" == "${USER_DIR}/hidden" ]]; then
		echo $( find ${USER_DIR} -name ".*" -maxdepth 3 -print | wc -l )
	elif [[ -e "${1}" ]]; then
		echo $( find "${1}" -name "*" -print 2>/dev/null | wc -l )
	fi
}

function perform_file_copy()
{
	# Perform the actual copy of files.  RSYNC is used for flexibility in compression & ignoring directories
	#
	# Parm 1 - SourceDir
	# Parm 2 - Destination Dir
	# Parm 3 - backup / restore
	# Parm 4 - Log Title
	# Parm 5 - files to exclude
	# Parm 6 - Progress Count
	# Parm 7 - Size of Directory
	# Parm 8 - # of files to backup
	# Parm 9 - JSON block key index (appname)
	# Parm 10- List Item Text
	#
	# ex: 	perform_file_copy "${USER_DIR}/" "${MIGRATION_DIRECTORY}/Hidden" "backup" "Hidden Files" ".Trash" "100" ${hidden_size} ${hidden_files} "Google"
	#
    # RETURN: None

	typeset log_msg
	typeset source_dir
	typeset exclude_files
	typeset dest_dir

	update_display_list "Update" "${6}" "${4}" "${4}" "wait" "${9}"

	# Set the source directory differently if we are working on the hidden files

	#[[ "${4}" == "Hidden" ]] && source_dir=${1}.[^.]* || source_dir=${1}
	
	exclude_files=${5}
	dest_dir=${2}

	log_msg="${3} files from ${source_dir} to ${dest_dir}\n"
	log_msg+="Exclude the following directories: ${5}\n\n"
	log_msg+="-------------------------\n\n"
	log_msg+="# of files to ${3}: ${8}\n"
	log_msg+="Bytes to ${3}: ${7}\n\n"

	case "${BACKUP_METHOD}" in

		"tar")
			copyCommand="/usr/bin/tar"
            if [[ "${3}" == "backup" ]]; then
				[[ "${4}" == "Hidden" ]] && { source_dir=${1}/.??* ; dest_dir="Hidden" } || source_dir=${1}
                [[ "${exclude_files}" != '""' ]] && copyCommand+=" --exclude="${exclude_files}
			    copyCommand+=" -cvzPf ${dest_dir}.tar.gz ${source_dir}"
            else
				[[ "${4}" == "Hidden" ]] && source_dir="Hidden" || source_dir=${1}
			    copyCommand+=" -xvzPf ${source_dir}.tar.gz ${dest_dir}"
			fi
			log_msg+="${copyCommand}"
			echo $log_msg >> "${USER_LOG_FILE}"
			eval ${copyCommand} 2>>"${USER_LOG_FILE}" 1>/private/tmp/tmp.log
			;;

		"rsync")
			copyCommand="/usr/bin/rsync -avzrlD "${source_dir}" ${dest_dir} --progress"
			[[ "${3}" == "backup" ]] && copyCommand+=" --exclude="${exclude_files}
			log_msg+="\n${copyCommand}"
			echo $log_msg >> "${USER_LOG_FILE}"
			eval ${copyCommand} 2>&1 >>"${USER_LOG_FILE}"
			;;
	esac

	# restore ownership privledges

	if [[ "${3}" = "restore" ]]; then
		echo " " >> "${USER_LOG_FILE}"
		echo "Restoring ownership permissions on ${2}" >> "${USER_LOG_FILE}"
		/usr/sbin/chown -R ${LOGGED_IN_USER} "${2}"
	fi
	update_display_list "Update" "${6}" "${4}" "${4}" "success" "Finished"
}

function backup_files()
{
	# routine to backup files.  loop thru the requested choices
    #
	# VARIABLES expected: JSON_APPS_BLOB, MIGRATION_DIRECTORY  & USER_LOG_FILE should be set
	# PARMS Passed: None
    # RETURN: None

	typeset path
	typeset app
	typeset ignore
	typeset size
	typeset files
	typeset progresss
	typeset migration_path

	create_migration_log

	echo "\nSaving files to: \n"${MIGRATION_DIRECTORY} >> "${USER_LOG_FILE}"

	# Create the diretory Structure that we need to backup all the files
	create_migration_directories

	# Recreate the JSON blob so we can show status updates to the user
	create_json_dialog_blob "Backing up files for user ${LOGGED_IN_USER}"

	# Make sure that the user has ownership rights in the Migration folder
	/usr/sbin/chown ${LOGGED_IN_USER} "${MIGRATION_DIRECTORY}"
	
	# process each option. Read in the APPS blob for detailed info
	update_display_list "Create" "Backing up files for ${LOGGED_IN_USER}:"
	for i in {0..10}; do
		app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].app' )
		verbal_app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].verbalapp' )
		path=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq '.['$i'].path' )
		migration_sub=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].MigrationDir' )
		size=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].size' )
		files=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].files' )
		ignore=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq '.['$i'].ignore' )
		progress=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].progress' )

		# Skip the file if they don't want to back it up
		if [[ ${Answers[$i+1]} == "false" ]]; then
			update_display_list "Update" ${progress} "${app}" "" "error" "Skipped"
			continue
		fi
		perform_file_copy ${path} "${MIGRATION_DIRECTORY}${migration_sub}" "backup" "${app}" ${ignore} ${progress} ${size} ${files} "Working..."
	done

	#
	# All done with Backup, so cleanup and exit
	#
	/bin/sleep 1
}

function restore_files()
{
	# routine to restore files.  loop thru the requested choices
    #
	# VARIABLES expected: JSON_APPS_BLOB, MIGRATION_DIRECTORY  & USER_LOG_FILE should be set
	# PARMS Passed: None
    # RETURN: None

	typeset path
	typeset app
	typeset ignore
	typeset size
	typeset files
	typeset progresss
	typeset migration_path

	create_migration_log

	echo "\nSaving files to: \n"${MIGRATION_DIRECTORY} >> "${USER_LOG_FILE}"

	# Create the diretory Structure that we need to backup all the files
	create_migration_directories

	# Recreate the JSON blob so we can show status updates to the user
	create_json_dialog_blob "Restoring files for user ${LOGGED_IN_USER}"

	# Make sure that the user has ownership rights in the Migration folder
	/usr/sbin/chown ${LOGGED_IN_USER} "${MIGRATION_DIRECTORY}"
	
	# process each option. Read in the APPS blob for detailed info
	update_display_list "Create" "Restoring files for ${LOGGED_IN_USER}:"
	for i in {0..10}; do
		app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].app' )
		verbal_app=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].verbalapp' )
		path=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq '.['$i'].path' )
		migration_sub=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].MigrationDir' )
		size=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].size' )
		files=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].files' )
		ignore=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq '.['$i'].ignore' )
		progress=$( echo "${JSON_APPS_BLOB}" | /usr/local/ge/bin/jq -r '.['$i'].progress' )

		# Skip the file if they don't want to back it up
		if [[ ${Answers[$i+1]} == "false" ]]; then
			update_display_list "Update" ${progress} "${app}" "" "error" "Skipped"
			continue
		fi
		#osascript -e 'tell application "Google Chrome.app" to quit without saving'
		[[ ! -e "${path}" ]] && /bin/mkdir -p "${path}"
		perform_file_copy "${MIGRATION_DIRECTORY}${migration_sub}" ${path} "restore" "${app}" ${ignore} ${progress} ${size} ${files} "Restoring..."
	done

	#
	# All done with Backup, so cleanup and exit
	#
	/bin/sleep 1
}

function notify_user_migration_done()
{
	# All done!  Show results
    #
	# VARIABLES expected: MIGRATION_DIRECTORY should be set
	# PARMS Passed: None
    # RETURN: None

	msg="Your ${BACKUP_RESTORE} is done.<br><br>Total Elapsed Time $((EndTime / 3600)) hours, $((EndTime / 60)) minutes and $((EndTime % 60)) Seconds.<br><br> Your files are located in ${MIGRATION_DIRECTORY}."
	construct_dialog_header_settings "${msg}" > "${JSON_DIALOG_BLOB}"
	echo "}" >> "${JSON_DIALOG_BLOB}"
	$SWDialog --jsonfile ${JSON_DIALOG_BLOB}
}

function cleanup_and_exit()
{
	# Cleanup and quit the script
    #
    # RETURN: None
	/bin/rm "${DIALOG_CMD_FILE}"
	/bin/rm "${JSON_DIALOG_BLOB}"
	exit 0

}

function check_for_fulldisk_access()
{
	if ! plutil -lint /Library/Preferences/com.apple.TimeMachine.plist >/dev/null ; then
		return 0
	fi
	WelcomeMsg="To use this application, Full Disk access must be enabled:<br><br>"
	WelcomeMsg+="1.  Click on Apple Menu ()<br>"
	WelcomeMsg+="2.  Click on System Settings<br>"
	WelcomeMsg+="3.  Navigate to Privacy & Security<br>"
	WelcomeMsg+="4.  Navigate to Full Disk Access<br>"
	WelcomeMsg+="5.  Enable 'Terminal'.  You will have to restart the terminal."

	

	construct_dialog_header_settings "${WelcomeMsg}" > "${JSON_DIALOG_BLOB}"
	echo '}'>> "${JSON_DIALOG_BLOB}"

	${SWDialog} --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null
	exit 1
}

############################
#
# Start of Main Script
#
############################
autoload 'is-at-least'

# Create the JSON blob so users can see status updates

check_swift_dialog_install
#check_for_fulldisk_access
display_welcome_message
choose_backup_location
get_migration_directory
create_json_app_blob
create_json_dialog_blob "Performing space calculations for Files & Folders"
calculate_storage_space
create_json_app_blob
select_migration_apps


#
# Start the elapsed time clock
#
SECONDS=0
#
# Performa the Backup or Restore routine
#
[[ "${BACKUP_RESTORE}" == "backup" ]] && backup_files || restore_files
#
# sound the alarm!
#
EndTime=$SECONDS

echo -e "\a"

# Cleanup and exit

update_display_list "Destroy"
notify_user_migration_done
onedrive_disk_image "UnMount"
cleanup_and_exit
