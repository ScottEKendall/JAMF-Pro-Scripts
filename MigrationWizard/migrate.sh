#!/bin/zsh

# Written: 05/03/2022
# Last updated: 05/29/2025
# by: Scott Kendall
#
# Script Purpose: Migrate user data to/from MacOS computers
#
# Version History
#
# 1.0 - Initial code
# 2.0 - rewrite using JSON blobs for all data content
# 2.1 - Add support to install JQ if it is missing
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
JQ_FILE_INSTALL_POLICY="install_jq"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Migration Wizard"
SD_INFO_BOX_MSG=""
LOG_FILE="${LOG_DIR}/MigrationWizard.log"
SD_ICON_FILE="SF=externaldrive.fill.badge.timemachine,colour=blue,colour2=purple"
OVERLAY_ICON="/Applications/Self Service.app"
ONE_DRIVE_PATH="${USER_DIR}/Library/CloudStorage/OneDrive-GiantEagle,Inc"
USER_LOG_FILE="${USER_DIR}/Documents/Migration Wizard.log"
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/MigrationWizard.XXXXX)
JSON_DIALOG_BLOB=$(mktemp /var/tmp/MigrationWizard.XXXXX)
/bin/chmod 666 "${JSON_DIALOG_BLOB}"
/bin/chmod 666 "${DIALOG_COMMAND_FILE}"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

######################
#
# Functions
#
#######################

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
    #echo "${1}" 1>&2
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | /usr/bin/tee -a "${LOG_FILE}"
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
    logMe "Checking Support Files"
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
	[[ $(which jq) == *"not found"* ]] && /usr/local/bin/jamf policy -trigger ${JQ_INSTALL_POLICY}
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

########################
# 
# Display Functions
#
########################

function check_for_tech ()
{
	# Determine if they are using the "tech" mode which will allow them to use an external USB drive
    #
    # RETURN: Sets techMode to "Tech"
	# VARIABLES None
	# PARMS Passed: All of the parameters passed into the script

	techMode="User"
 	for param in "$@"; do
		[[ $param == *"tech"* ]] && techMode="tech"
	done
}

function construct_dialog_header_settings()
{
    # Construct the basic Switft Dialog screen info that is used on all messages
    #
    # RETURN: None
	# VARIABLES expected: All of the Widow variables should be set
	# PARMS Passed: $1 is message to be displayed on the window

	echo '{
		"icon" : "'${SD_ICON_FILE}'",
		"message" : "'$1'",
		"bannerimage" : "'${SD_BANNER_IMAGE}'",
		"bannertitle" : "'${SD_WINDOW_TITLE}'",
		"titlefont" : "shadow=1",
		"button1text" : "OK",
		"moveable" : "true",
		"quitkey" : "0",
		"messageposition" : "top",'
}

function display_welcome_message()
{
	# Display welcome message to user
    #
	# VARIABLES expected: JSON_DIALOG_BLOB & SD_WINDOW_TITLE must be set
	# PARMS Passed: None
    # RETURN: None

	WelcomeMsg="Welcome to the "${SD_WINDOW_TITLE} | xargs "<br><br>"
	WelcomeMsg+="This utility is designed to backup certain critical data on your Mac and<br>"
	WelcomeMsg+="you will also have the opportunity to restore this data to a new Mac.<br>"
	WelcomeMsg+="*This utility will NOT backup your entire drive, but only the following files:*<br><br>"
	for i in {0..$jsonAppBlobCount}; do
		app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )
		WelcomeMsg+="* ${app}<br>"
	done
	WelcomeMsg+="<br>If these files are relatively massive in size, it is strongly recommended<br>"
	WelcomeMsg+="that you only backup your system while connected to the internal Giant Eagle<br>"
	WelcomeMsg+="network.  Backup or restore over VPN will have very poor performance.<br>"

	construct_dialog_header_settings "${WelcomeMsg}" > "${JSON_DIALOG_BLOB}"
	echo '}' >> "${JSON_DIALOG_BLOB}"

	${SW_DIALOG} --width 920 --height 675 --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null

}

function choose_backup_location()
{
    # Show the user options of which location to store files
    # NOTE: if keyword "Tech" is passsed to this function, you can choos a custom location
    #
	# VARIABLES expected: All Windows title variables
	# PARMS Passed: None
    # RETURN: None
	
	declare values && values='"Microsoft OneDrive (Faster)", "GE Network (Legacy)"'
	
	[[ $techMode == "Tech" ]] && values+=', "External Drive"'

		construct_dialog_header_settings "Please select file Location and the action to be performed." > "${JSON_DIALOG_BLOB}"
		echo '"selectitems" : [
			{"title" : "Location",
			"values" : ['$values'],
			"default" : "Microsoft OneDrive (Faster)"},
			{"title" : "Action",
			"values" : ["Backup", "Restore"],
			"default" : "Backup"},]}' >> "${JSON_DIALOG_BLOB}"

	temp=$("${SW_DIALOG}" --width 800 --json --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null)
	button=$?

	[[ $button -eq 3 || $button -eq 10 ]] && cleanup_and_exit

	[[ ! -z $(echo $temp | /usr/bin/grep "Backup")  ]] && backupRestore="backup" || backupRestore="restore"	
	[[ ! -z $(echo $temp | /usr/bin/grep "OneDrive") ]] && backupLocation="OneDrive" || backupLocation="Network"
	[[ ! -z $(echo $temp | /usr/bin/grep "External" ) ]] && backupLocation="External"
    logMe "INFO: User choose to ${backupRestore} using network location: $backupLocation"
}

function check_network_drive()
{
	# Check for the presence of the network storage location and display an error if it doesn't exist
    #
    # RETURN: None

	declare oneDrive_found && oneDrive_found="No"

	# if the migration directory exists the return gracefully
	[[ -e $migrationDirectory ]] && {logMe "INFO: Storage location exists...continuing..."; return 0;}

	# If not, then throw an error
	if [[ ${backupLocation} == *"OneDrive"* ]]; then
		title="The storeage location that you selected is not available.<br>Please make sure that OneDrive is running on your Mac."
		[[ -e "/Applications/OneDrive.app" ]] && oneDrive_found="Yes"
	else
		title="Please make sure that the Network Volume is mounted on your Mac."
	fi

	MainDialogBody=(
		--message "${title}"
        --titlefont shadow=1
        --ontop
		--icon "${ICON_FILES}AlertStopIcon.icns"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --helpmessage ""
        --width 800
		--height 400
        --ignorednd
        --quitkey 0
    )

	[[ $oneDrive_found == "Yes" ]] && MainDialogBody+=(--button1text "Open OneDrive") || MainDialogBody+=(--button1text "OK")

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	[[ $oneDrive_found == "Yes" ]] && open "/Applications/OneDrive.app"

    logMe "ERROR: No backup drive present at $backupLocation"
	cleanup_and_exit
}

function check_for_fulldisk_access()
{
	[[ $(plutil -lint /Library/Preferences/com.apple.TimeMachine.plist) == *"OK"* ]] && return 0
	WelcomeMsg="To use this application, Full Disk access must be enabled:<br><br>"
	WelcomeMsg+="1.  Click on Apple Menu ()<br>"
	WelcomeMsg+="2.  Click on System Settings<br>"
	WelcomeMsg+="3.  Navigate to Privacy & Security<br>"
	WelcomeMsg+="4.  Navigate to Full Disk Access<br>"
	WelcomeMsg+="5.  Enable 'Terminal'.  You will have to restart the terminal."

	construct_dialog_header_settings "${WelcomeMsg}" > "${JSON_DIALOG_BLOB}"
	echo '}' >> "${JSON_DIALOG_BLOB}"

	${SW_DIALOG} --width 300 --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null
    logMe "ERROR: Full disk access reuired."
	exit 1
}

function select_migration_apps()
{
	# Construct the main dialog box giving the user choices of which files to backup/restore
    #
	# VARIABLES expected: JSON_DIALOG_BLOB must be set
	# PARMS Passed: None
    # RETURN: None

	construct_dialog_header_settings "Select files to $backupRestore for user $LOGGED_IN_USER:" > "${JSON_DIALOG_BLOB}"
	create_checkbox_message_body "" "" "" "" "first"

    for i in {0..$jsonAppBlobCount}; do
        checked=true
        disabled=false
        app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )
        size=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].size' )
        files=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].files' )
        icon=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].icon' )
        if [[ -z $size || -z $files && $backupRestore = "backup" ]]; then
            checked=false
            disabled=true
        fi
		if [[ "${backupRestore}" == "backup" ]]; then
	        create_checkbox_message_body "$app ($size / $files Files)" "$icon" "$checked" "$disabled"
		else
	        create_checkbox_message_body "$app" "$icon" "$checked" "$disabled"
		fi
    done
    create_checkbox_message_body "" "" "" "" "last"

	# Display the message and offer them options
	
	retval=$(${SW_DIALOG} --width 920 --height 800 --json --jsonfile "${JSON_DIALOG_BLOB}")
	button=$?

	# User choose to exit, so cleanup & quit
	[[ $button -eq 2 || $button -eq 10 ]] && cleanup_and_exit

	# Mark each entry in the JSON with the user choice
	for i in {0..$jsonAppBlobCount}; do
		app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )
		choice=$(echo $retval | /usr/bin/grep "$app" | /usr/bin/awk -F " : " '{print $NF}' | /usr/bin/tr -d ',' )
        jsonAppBlob=$(modify_individual_json_field "$jsonAppBlob" "$app" "choice" "$choice")
 	done
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
        line='"checkbox" : ['
    elif [[ "$5:l" == "last" ]]; then
        line='], "checkboxstyle" : {"style" : "switch", "size"  : "small"}}'
    else
        line='{"label" : "'$1'", "icon" : "'$2'", "checked" : "'$3'", "disabled" : "'$4'"},'
    fi
    echo $line >> ${JSON_DIALOG_BLOB}
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
        line='"button1disabled" : "true", "listitem" : ['
    elif [[ "$5:l" == "last" ]]; then
        line=']}'
    else
        line='{"title" : "'$1'", "icon" : "'$2'", "status" : "'$4'", "statustext" : "'$3'"},'
    fi
    echo $line >> ${JSON_DIALOG_BLOB}
}

function update_display_list ()
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

		${SW_DIALOG} \
			--progress \
			--jsonfile "${JSON_DIALOG_BLOB}" \
			--infobox "Please be patient while this is working.... If you have lots of files and/or folders, this process might take a while!" \
			--commandfile ${DIALOG_COMMAND_FILE} \
			--height 800 \
			--width 920 \
			--button1disabled \
			--infotext "Backup File Location: ${migrationDirectory} on ${backupLocation}" & /bin/sleep .2
		;;

	"Destroy" )
	
		#
		# Kill the progress bar and clean up
		#
		echo "quit:" >> "${DIALOG_COMMAND_FILE}"
		;;

	"Update" | "Change" )

		#
		# Increment the progress bar by ${2} amount
		#

		# change the list item status and increment the progress bar
		/bin/echo "listitem: title: "$3", status: $5, statustext: $6" >> "${DIALOG_COMMAND_FILE}"
		/bin/echo "progress: $2" >> "${DIALOG_COMMAND_FILE}"

		/bin/sleep .5
		;;
		
	esac
}

function create_json_dialog_blob()
{
    # Adds to the existing Display BLOB with information from the construct_json_apps_blob
    #
    # RETURN: Creates the temporary JSON_DIALOG_BLOB file
	# VARIABLES expected: JSON_DIALOG_BLOB needs to be constructed first
	# PARMS Passed: $1 is message to be displayed on the window

	construct_dialog_header_settings "${1}" > "${JSON_DIALOG_BLOB}"
	create_listitem_message_body "" "" "" "" "first"
	for i in {0..$jsonAppBlobCount}; do
		app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )
		icon=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].icon' )
       create_listitem_message_body "$app" "$icon" "pending" "Pending..."
	done
	create_listitem_message_body "" "" "" "" "last"

}

function notify_user_migration_done()
{
	# All done!  Show results
    #
	# VARIABLES expected: migrationDirectory should be set
	# PARMS Passed: None
    # RETURN: None

	msg="Your ${backupRestore} is done.<br><br>Total Elapsed Time $((EndTime / 3600)) hours, $(( (EndTime % 3600) / 60)) minutes and $((EndTime % 60)) Seconds.<br><br> Your files are located in ${migrationDirectory}."
	construct_dialog_header_settings "${msg}" > "${JSON_DIALOG_BLOB}"
	echo "}" >> "${JSON_DIALOG_BLOB}"
	${SW_DIALOG} --width 800 --height 350 --jsonfile ${JSON_DIALOG_BLOB}
}

#####################
#
# Backup/Restore functions
#
####################

function onedrive_disk_image()
{
	# routines to create / mount / unmount OneDrive disk images

		case "$1:l" in 

			"create" )
				/usr/bin/hdiutil create "${one_drive_disk_image}" -type SPARSEBUNDLE -fs APFS  -volname "Migration"
				;;

			"mount"  )
				/usr/bin/hdiutil attach -mountroot /Volumes "${one_drive_disk_image}"

				# Wait 5 secs for volume to mount before continuing...
				sleep 5
				;;

			"unmount" )
 				if /sbin/mount | /usr/bin/grep "/Migration"; then
					/usr/bin/hdiutil detach "/Volumes/Migration"
				fi
				;;

			"destroy" )
				if /sbin/mount | /usr/bin/grep "/Migration"; then
					/usr/bin/hdiutil detach "/Volumes/Migration"
					/bin/rm -rf "${one_drive_disk_image}"
				fi
				;;
		esac

		#migrationDirectory="/Volumes/Migration"
}

function get_migration_directory()
{
	# Determine migration directory from their choices, and make sure it is a valid path 
    #
	# VARIABLES expected: ONE_DRIVE_PATH must be set
	# PARMS Passed: None
    # RETURN: None

	case "${backupLocation}" in

		*"OneDrive"* )
					
			# Create the disk image if it doesn't exist
			migrationDirectory="/Volumes/Migration"
			[[ ! -e "${one_drive_disk_image}" && "${backupRestore}" == "backup" ]] && onedrive_disk_image "Create"

			# Mount the drive

			onedrive_disk_image "Mount"
			check_network_drive
			;;
			
		*"Network"* )

			# Set the default Directory for network location

			[[ -d "/Volumes/${LOGGED_IN_USER}" ]] && migrationDirectory="/Volumes/${LOGGED_IN_USER}/Migration" || migrationDirectory="/Users/${LOGGED_IN_USER}/Migration"
			;;

		*"External"* )

			construct_dialog_header_settings "Please enter the location to store the files:" > "${JSON_DIALOG_BLOB}"
			echo '"button2text" : "Cancel", "json" : "true" }' >> "${JSON_DIALOG_BLOB}"

			temp=$( ${SW_DIALOG} --width 800 --height 300 --jsonfile "${JSON_DIALOG_BLOB}" --textfield "Select a storage location",fileselect,filetype=folder)

			[[ "$?" == "2" ]] && cleanup_and_exit
			
			# Format the Volume name correctly

			migrationDirectory=$( echo $temp | /usr/bin/grep "location" | awk -F ": " '{print $NF}' | tr -d '\' | tr -d '"')
			;;
	esac
}

function create_migration_directories ()
{
	# Create the backup subfolders inside the migration directory 
    #
	# VARIABLES expected: migrationDirectory must be set
	# PARMS Passed: None
    # RETURN: None

	declare subdir_name
	declare dir_structure

	[[ "${BACKUP_METHOD}" == "tar" ]] && return 0

	dir_structure=$(echo "$jsonAppBlob" | /usr/bin/jq -r '.[].MigrationDir')
	for subdir_name in ${dir_structure}; do
		# If the destination directory doesn't exist, make it
	    [[ ! -d "${migrationDirectory}${subdir_name}" ]] && /bin/mkdir -p "${migrationDirectory}${subdir_name}"
	done
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
    declare -i i

	update_display_list "Create" "Calculating Space Requirements..."

	for i in {0..$jsonAppBlobCount}; do
        progress=$(( (i * 100) / jsonAppBlobCount ))
        # Extract info from the JSON blob
        app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )
        path=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].path' )
        # update the display
        update_display_list "Update" "$progress" "$app" "Calculating Chrome" "wait" "Working..."

        # calculate # of files and sizes
        size=$( calculate_folder_size "${path}" )
        files=$( calculate_num_of_files "${path}" )

        # Modify the JSON with the new info
        jsonAppBlob=$(modify_individual_json_field "$jsonAppBlob" "$app" "size" "$size")
        jsonAppBlob=$(modify_individual_json_field "$jsonAppBlob" "$app" "files" "$files")

        # Update the display
		if [[ -z $size || -z $files ]]; then
			update_display_list "Update" "$progress" "$app" "" "fail" "No Files"
		else
			update_display_list "Update" "$progress" "$app" "" "success" "Done"
			fi
    done

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

    if [[ -e $1 ]]; then
    	[[ "${1}" == "${USER_DIR}/hidden" ]] && filepath="${USER_DIR}/.[^.]*" || filepath="${1}"
    	echo $( /usr/bin/du -hcs ${~filepath} | /usr/bin/tail -1 | /usr/bin/awk '{print $1}' ) 2>&1
    fi
}

function calculate_num_of_files()
{
	# calculate the sizes of each directory so we can show the user
	#
	# VARIABLES expected: none
	# PARMS Passed: $1 is directory to be acted upon
    # RETURN: Total # of files found

	if [[ "${1}" == "${USER_DIR}/hidden" ]]; then
		echo $( /usr/bin/find ${USER_DIR} -name ".*" -maxdepth 3 -print | /usr/bin/wc -l )
	elif [[ -e "${1}" ]]; then
		echo $( /usr/bin/find "${1}" -name "*" -print 2>/dev/null | /usr/bin/wc -l )
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
	# ex: perform_file_copy ${path} "${migrationDirectory}${migration}" "backup" "${app}" ${ignore} ${progress} ${size} ${files} "Working..."
	# ex: perform_file_copy "${migrationDirectory}${migration}" ${path} "restore" "${app}" ${ignore} ${progress} ${size} ${files} "Restoring..."
	#
    # RETURN: None

	declare log_msg
	declare source_dir
	declare exclude_files
	declare dest_dir

	source_dir=${1}
	dest_dir=${2}
	action=${3}
	log_title=${4}
	exclude_files=${5}
	progress_count=${6}
	file_size=${7}
	file_number=${8}
	app_name=${4}

	update_display_list "Update" "${progress_count}" "${log_title}" "${log_title}" "wait" "Working..."
	
	log_msg="-------------------------\n"
	log_msg+="Working on ${app_name}\n"
	log_msg+="${action} files from ${source_dir} to ${dest_dir}\n"
	log_msg+="Exclude the following directories: ${exclude_files}\n"
	log_msg+="-------------------------\n"
	log_msg+="# of files to ${action}: ${file_number}\n"
	log_msg+="total size of ${action}: ${file_size}\n"
	log_msg+="-------------------------\n\n"

	case "${BACKUP_METHOD}" in

		"tar")
			copyCommand="/usr/bin/tar"
            if [[ "${action}" == "backup" ]]; then
				[[ "${log_title}" == "Hidden" ]] && source_dir=${source_dir}/.??*
                [[ ! -z $(echo "${exclude_files}" | /usr/bin/xargs ) ]] && copyCommand+=" --exclude="${exclude_files}
			    copyCommand+=" -cvzPf ${dest_dir}.tar.gz ${source_dir}"
            else
			    copyCommand+=" -xvzPf ${source_dir}.tar.gz ${dest_dir}"
			fi
			log_msg+="${copyCommand}\n"
			echo $log_msg >> "${USER_LOG_FILE}"
			eval ${copyCommand} >> "${USER_LOG_FILE}" 2>&1
			;;

		"rsync")
			copyCommand="/usr/bin/rsync -avzrlD "${source_dir}" ${dest_dir} --progress"
			[[ "${action}" == "backup" ]] && copyCommand+=" --exclude="${exclude_files}
			log_msg+="${copyCommand}\n"
			echo $log_msg >> "${USER_LOG_FILE}"
			eval ${copyCommand} >> "${USER_LOG_FILE}" 2>&1
			;;
	esac

	# restore ownership privledges

	if [[ "${action}" = "restore" ]]; then
		echo " " >> "${USER_LOG_FILE}"
		echo "Restoring ownership permissions on ${dest_dir}" >> "${USER_LOG_FILE}"
		/usr/sbin/chown -R ${LOGGED_IN_USER} "${dest_dir}"
	fi
	update_display_list "Update" "${progress_count}" "${log_title}" "${log_title}" "success" "Finished"
}

function backup_files()
{
	# routine to backup files.  loop thru the requested choices
    #
	# VARIABLES expected: jsonAppBlob, migrationDirectory  & USER_LOG_FILE should be set
	# PARMS Passed: None
    # RETURN: None

	declare path
	declare app
	declare ignore
	declare size
	declare files
	declare progresss
	declare migration_path

	create_migration_log

	echo "Backup file location: ${migrationDirectory}\n" >> "${USER_LOG_FILE}"

	# Create the diretory Structure that we need to backup all the files
	create_migration_directories

	# Recreate the JSON blob so we can show status updates to the user
	#create_json_dialog_blob "Back up files for user ${LOGGED_IN_USER} to ${migrationDirectory}"

	# Make sure that the user has ownership rights in the Migration folder
	/usr/sbin/chown ${LOGGED_IN_USER} "${migrationDirectory}"
	
	# process each option. Read in the APPS blob for detailed info
	update_display_list "Create" "Back up files for ${LOGGED_IN_USER} to ${migrationDirectory}:"
	for i in {0..$jsonAppBlobCount}; do

		app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )
        choice=$(echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].choice')
        progress=$(( (i * 100) / jsonAppBlobCount ))
        if [[ $choice == "false" ]]; then
			update_display_list "Update" ${progress} "${app}" "" "error" "Skipped"
			continue
        fi

		path=$( echo "${jsonAppBlob}" | /usr/bin/jq '.['$i'].path' )
		migration=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].MigrationDir' )
		size=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].size' )
		files=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].files' )
		ignore=$( echo "${jsonAppBlob}" | /usr/bin/jq '.['$i'].ignore' )
    	perform_file_copy ${path} "${migrationDirectory}${migration}" "backup" "${app}" ${ignore} ${progress} ${size} ${files} "Working..."
	done

	#
	# All done with Backup, so cleanup and exit
	#
    logMe "INFO: Done $backupRestore to $backupLocation"
	/bin/sleep 1
}

function restore_files()
{
	# routine to restore files.  loop thru the requested choices
    #
	# VARIABLES expected: jsonAppBlob, migrationDirectory  & USER_LOG_FILE should be set
	# PARMS Passed: None
    # RETURN: None

	declare path
	declare app
	declare ignore
	declare size
	declare files
	declare progresss
	declare migration_path

	create_migration_log

	echo "Backup file location: "${migrationDirectory} >> "${USER_LOG_FILE}"

	# Create the diretory Structure that we need to backup all the files
	#create_migration_directories

	# Make sure that the user has ownership rights in the Migration folder
	/usr/sbin/chown ${LOGGED_IN_USER} "${migrationDirectory}"
	
	# process each option. Read in the APPS blob for detailed info
	update_display_list "Create" "Restoring files for ${LOGGED_IN_USER}:"
    for i in {0..$jsonAppBlobCount}; do

        choice=$(echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].choice')
        progress=$(( (i * 100) / jsonAppBlobCount ))
		app=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].app' )

        if [[ $choice == "false" ]]; then
			update_display_list "Update" ${progress} "${app}" "" "error" "Skipped"
			continue
        fi

		path=$( echo "${jsonAppBlob}" | /usr/bin/jq '.['$i'].path' )
		migration=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].MigrationDir' )
		size=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].size' )
		files=$( echo "${jsonAppBlob}" | /usr/bin/jq -r '.['$i'].files' )
		ignore=$( echo "${jsonAppBlob}" | /usr/bin/jq '.['$i'].ignore' )

		#osascript -e 'tell application "Google Chrome.app" to quit without saving'
		# If the file doesn't exist, the show the error msg and continue on
		if [[ ! -e "${migrationDirectory}${migration}.tar.gz" ]]; then
			update_display_list "Update" ${progress} "${app}" "" "fail" "Backup file not found"
			continue
		fi
		[[ ! -e "${path}" ]] && /bin/mkdir -p "${path}"
		perform_file_copy "${migrationDirectory}${migration}" ${path} "restore" "${app}" ${ignore} ${progress} ${size} ${files} "Restoring..."
	done

    # All done
    logMe "INFO: Done $backupRestore from $backupLocation"
	/bin/sleep 1
}

#####################
#
# JSON Blob functions
#
#####################

function modify_individual_json_field () 
{
	# Change the entry for a particular JSON record
    #
	# PARMS Passed: $1 = JSON Blob
	#				$2 = entry to search for
	#				$3 = field name to change
    #               $4 = new value
    # RETURN: Contents of discovered record

    updated_json=$(echo "$1" | /usr/bin/jq --arg app "$2" --arg value "$4" 'map(if .app == $app then .'$3' = $value else . end)')
    [[ $? -ne 0 ]] && return 1

    echo "$updated_json"
}

function extract_individual_json_field () 
{
	# Extract an indivdual entry of a particular record from a JSON blob
    #
	# PARMS Passed: $1 = JSON Blob
	#				$2 - JSON record to search for
	#				$3 - field name to extract
    # RETURN: Contents of discovered record

	echo "$1" | /usr/bin/jq -r --arg app "$2" --arg fld "$3" '.[] | select(.app == $app) | .[$fld] // "Field not found"'

}

function extract_json_field ()
{
	# Extract a particular field from a JSON blob
    #
	# PARMS Passed: $1 = JSON Blob
	#				$2 - field name to search for
    # RETURN: Array of found items

	declare -A result_array
	result_array=$(echo "$1" | jq -r --arg field "$2" '.[].[$field]')
	echo $result_array
}

############################
#
# Start of Main Script
#
############################
autoload 'is-at-least'

declare backupRestore
declare backupLocation
declare migrationDirectory
declare techMode
declare -a jsonAppBlob
declare -i jsonAppBlobCount 

one_drive_disk_image="${ONE_DRIVE_PATH}/ODMigration.sparsebundle"
BACKUP_METHOD="tar"


# Construct the core apps blob with all of the important info
# The list is dynamic..you can add more backup items in here
# Format of JSON structure:
# Parm 1 - AppName
# Parm 2 - Local Path
# Parm 3 - Remote Subdirectory
# Parm 4 - Icon Path
# Parm 5 - Size of all files
# Parm 6 - Number of folders
# Parm 7 - directories to exclude
# Parm 8 - User menu choice - will be filled in with Y/N

jsonAppBlob='[{
"app" : "Chrome Bookmarks",   
"path" : "'${USER_DIR}'/Library/Application Support/Google/Chrome/",
"MigrationDir" : "/Google",
"icon" : "/Applications/Google Chrome.app",
"size" : "0",
"files" : "0",
"ignore" : "Services",
"choice" : ""},

{"app" : "Firefox Bookmarks",
"path" : "'${USER_DIR}'/Library/Application Support/Firefox/",
"MigrationDir" : "/Firefox",
"icon" : "/Applications/FireFox.app",
"size" : "0",
"files" : "0",
"ignore" : "Services*",
"choice" : ""},

{"app" : "Outlook Signatures",
"path" : "'${USER_DIR}'/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/Signatures",
"MigrationDir" : "/OutlookSignature",
"icon" : "/Applications/Microsoft Outlook.app",
"size" : "0",
"files" : "0",
"ignore" : "",
"choice" : ""},

{"app" : "OnteNote Notebooks",
"path" : "'${USER_DIR}'/Library/Containers/com.microsoft.onenote.mac/Data/Library/Application Support/Microsoft User Data/OneNote",
"MigrationDir" : "/OneNote",
"icon" : "/Applications/Microsoft OneNote.app",
"size" : "0",
"files" : "0",
"ignore" : "",
"choice" : ""},

{"app" : "Safari Bookmarks",
"path" : "'${USER_DIR}'/Library/Safari/",
"MigrationDir" : "/Safari",
"icon" : "/Applications/Safari.app",
"size" : "0",
"files" : "0",
"ignore" : "Favicon Cache",
"choice" : ""},

{"app" : "Notes",
"path" : "'${USER_DIR}'/Library/Group Containers/group.com.apple.notes/",
"MigrationDir" : "/Notes",
"icon" : "/System/Applications/Notes.app",
"size" : "0",
"files" : "0",
"ignore" : "Cache",
"choice" : ""},

{"app" : "Stickies",
"path" : "'${USER_DIR}'/Library/Containers/com.apple.Stickies/Data/Library/Stickies/",
"MigrationDir" : "/Stickies",
"icon" : "/System/Applications/Stickies.app",
"size" : "0",
"files" : "0",
"ignore" : "cache",
"choice" : ""},

{"app" : "Desktop",
"path" : "'${USER_DIR}'/Desktop",
"MigrationDir" : "/Desktop",
"icon" : "'${ICON_FILES}DesktopFolderIcon.icns'",
"size" : "0",
"files" : "0",
"ignore" : "",
"choice" : ""},

{"app" : "Documents",
"path" : "'${USER_DIR}'/Documents",
"MigrationDir" : "/Documents",
"icon" : "'${ICON_FILES}DocumentsFolderIcon.icns'",
"size" : "0",
"files" : "0",
"ignore" : "",
"choice" : ""},

{"app" : "Pictures",
"path" : "'${USER_DIR}'/Pictures",
"MigrationDir" : "/Pictures",
"icon" : "/System/Applications/Photos.app",
"size" : "0",
"files" : "0",
"ignore" : "cache",
"choice" : ""},

{"app" : "Projects",
"path" : "'${USER_DIR}'/Projects",
"MigrationDir" : "/Projects",
"icon" : "'${ICON_FILES}DeveloperFolderIcon.icns'",
"size" : "0",
"files" : "0",
"ignore" : "",
"choice" : ""},

{"app" : "Freeform",
"path" : "'${USER_DIR}'/Library/Containers/com.apple.freeform/",
"MigrationDir" : "/Freeform",
"icon" : "/System/Applications/Freeform.app",
"size" : "0",
"files" : "0",
"ignore" : "",
"choice" : ""},

{"app" : "Hidden Files",
"path" : "'${USER_DIR}'",
"MigrationDir" : "/Hidden",
"icon" : "'${ICON_FILES}FinderIcon.icns'",
"size" : "0",
"files" : "0",
"ignore" : ".Trash",
"choice" : ""
}]'

check_swift_dialog_install
check_support_files
check_for_tech "$@"
check_for_fulldisk_access
jsonAppBlobCount=$(($(echo "$jsonAppBlob" | jq 'length')-1))
display_welcome_message
choose_backup_location
get_migration_directory


create_json_dialog_blob "Performing space calculations for Files & Folders"
[[ "${backupRestore}" == "backup" ]] && calculate_storage_space
select_migration_apps

#
# Start the elapsed time clock
#
SECONDS=0
#
# Perform the Backup or Restore routine
#
[[ "${backupRestore}" == "backup" ]] && backup_files || restore_files
#
# sound the alarm!
#
EndTime=$SECONDS

echo -e "\a"

# Cleanup and exit

update_display_list "Destroy"
onedrive_disk_image "UnMount"
notify_user_migration_done
cleanup_and_exit
