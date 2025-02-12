#!/bin/zsh

######################################################################################################
#
# Gobal "Common" variables (do not change these!)
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

# Swift Dialog version requirements
SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.4.0"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

###################################################
#
# App Specfic variables (Feel free to change these)
#
###################################################

SUPPORT_DIR="/Library/Application Support/GiantEagle"
SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"

LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/AppDelete.log"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
STOP_ICON="${ICON_FILES}AlertStopIcon.icns"
GROUP_ICON="${ICON_FILES}GroupIcon.icns"
SUCCESS_ICON="${ICON_FILES}Toolbarinfo.icns"

JSON_OPTIONS=$(mktemp /var/tmp/MigrateAccount.XXXXX)
chmod 666 "${JSON_OPTIONS}"
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/MigrateAccount.XXXXX)
chmod 666 "${DIALOG_COMMAND_FILE}"
BANNER_TEXT_PADDING="      " #5 spaces to accomodate for icon offset
SD_INFO_BOX_MSG=""
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Migrate Account"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)

USERS_ON_SYSTEM=$( dscl . ls /Users | grep -v '_' | grep -v 'root' | grep -v 'daemon'| grep -v 'nobody'| grep -v $LOGGED_IN_USER | tr '\n' ',' )
USERS_ON_SYSTEM=${USERS_ON_SYSTEM:0:-1} # remove the last , from the list so it doesn't create a blank SD entry

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
            eval "dialog --jsonfile ${JSON_OPTIONS}" & sleep .2
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
            [[ -z ${2} ]] && /bin/echo "icon: none" >> "${DIALOG_COMMAND_FILE}" || /bin/echo "icon: ${2}" >> "${DIALOG_COMMAND_FILE}"
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

function cleanup_and_exit ()
{
    # 
    # Expect Parmaters
    # $1 = Good, Fail, Restart
    #

    ExitOptions=$1
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	
    if [[ $ExitOptions == "Good" ]]; then
        exit 0
    elif [[ $ExitOptions == "Fail" ]]; then
        exit 1
    elif [[ $ExitOptions == "Restart" ]]; then
        update_display_list "image" $SUCCESS_ICON "" "" "Successfully transfered ${oldUser} to ${newUser}. The system needs to restart to finish the process."
        logMe "Restarting computer after successful rename"
        osascript -e 'tell application "System Events" to restart'
    fi
}

function create_welcome_dialog ()
{

	DialogBody=(
        --message "Please enter the following information below. During this process, the data from the old user will be moved to the new user"
		--ontop
		--icon "${GROUP_ICON}"
		--overlayicon computer
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
        --textfield "Enter the name of the NEW user,required"
        --selecttitle "Select user to migrate FROM",required --selectvalues "${USERS_ON_SYSTEM}"
        --width 800
        --ignorednd
        --moveable
		--quitkey 0
		--button1text "OK"
        --button2text "Cancel"
    )

    # Example of appending items to the display array
    #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && DialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

	returnval=$("${SW_DIALOG}" "${DialogBody[@]}" 2>/dev/null)
    [[ "$?" == "2" ]] && cleanup_and_exit "Good"

    oldUser=$(echo $returnval | grep "SelectedOption" | awk '{print $3}' | tr -d '"' | xargs )
    newUser=$(echo $returnval | grep "NEW" | awk -F ":" '{print $2}' | xargs )
}

function create_workflow_dialog ()
{
    # Have to use the advanced JSON featuers in SwiftDialog since we are going to modify list items along the way

    echo '{
        "icon" : "'${GROUP_ICON}'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "message" : "Proceeding to migrate **'${oldUser}'** to **'${newUser}'**.  Doing some validity checks....",
        "titlefont" : "shadow=1",
        "button1text" : "OK",
        "ontop" : "true",
        "movable" : "true",
        "commandfile" : "'${DIALOG_COMMAND_FILE}'",
        "height" : "500",
        "listitem" : [
            { "title" : "Verify Account Info",       "status" : "pending", "statustext" : "Pending" },
            { "title" : "Retrieve Display Name",     "status" : "pending", "statustext" : "Pending" },
            { "title" : "Update Display Name",       "status" : "pending", "statustext" : "Pending" },
            { "title" : "Update NFS Home Directory", "status" : "pending", "statustext" : "Pending" },
            { "title" : "Move Files to New User",    "status" : "pending", "statustext" : "Pending" },
            { "title" : "Verify Rename",             "status" : "pending", "statustext" : "Pending" },
            ]}' > ${JSON_OPTIONS}
}

function test_root_user ()
{
	# Ensures that script is run as ROOT
    if [[ "${UID}" != 0 ]]; then
    	MainDialogBody=(
        --message "In order for this script to function properly, it must be run as an admin user!"
		--ontop
		--icon "$STOP_ICON"
		--overlayicon computer
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--button1text "OK"
    )

        # Example of appending items to the display array
        #    [[ ! -z "${SD_IMAGE_TO_DISPLAY}" ]] && MainDialogBody+=(--height 520 --image "${SD_IMAGE_TO_DISPLAY}")

    	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
		cleanup_and_exit "Fail"
	fi
}

function show_err_msg ()
{
    # Parameters Expected
    #

    # $1 - List item to change
    # $2 - Message to display
    # $3 - Status to show
    # $4 - Icon to show

    update_display_list "icon" $4
    update_display_list "change" "$1" "$3"
    update_display_list "infotext" "$2"
    wait
}

function verify_account_info ()
{
    #
    # This function will perform various validity checks to ensure it is safe to proceed
    #
    #
    # Test #1 - Verify that the accounts differ
    #
    update_display_list "change" "Verify Account Info" "wait"
    if [[ "${oldUser}" == "${newUser}" ]]; then
        show_err_msg "Verify Account Info" "New user is the same as the old user.  No account info will be changed at this time." "fail" $STOP_ICON
        logMe "ERROR: New user is the same as the old one...no account info changed"
		cleanup_and_exit "Fail"
    fi

    #
    # Test #2 - Make sure there is not an existing user account already
    #
    readonly existingUsers=($(dscl . -list /Users | grep -Ev "^_|com.*|root|nobody|daemon|\/" | cut -d, -f1 | sed 's/CN=//g'))

    if [[ " ${existingUsers[@]} " =~ " ${newUser} " ]]; then
        show_err_msg "Verify Account Info" "The account '${newUser}' is already present on this system. Cannot create the new account at this time." "fail" $STOP_ICON
        logMe "ERROR: New user account '${newUser}' is already present on this computer...no account info changed"
		cleanup_and_exit "Fail"
    fi
    #
    # Test #3 - Check to see if new account folder already exists
    #
    readonly existingHomeFolders=($(ls /Users))

    # Ensure existing home folder is not in use
    if [[ " ${existingHomeFolders[@]} " =~ " ${newUser} " ]]; then
        show_err_msg "Verify Account Info" "The home folder for '${newUser}' is already in use on this system. Cannot create the new account at this time." "fail" $STOP_ICON
        logMe "ERROR: The home folder for '${newUser}' is already present on this computer...no account info changed"
		cleanup_and_exit "Fail"
    fi
    #
    # Test #4 - logout user if they are already logged in
    #
    loginCheck=$(ps -Ajc | grep ${oldUser} | grep loginwindow | awk '{print $2}')

    # Logs out user if they are logged in
    timeoutCounter='0'
    while [[ "${loginCheck}" ]]; do
        update_display_list "infotext" "${oldUser} account logged in. Logging user off to complete username update."
        sudo launchctl bootout gui/$(id -u ${oldUser})
        sleep 5
        loginCheck=$(ps -Ajc | grep ${oldUser} | grep loginwindow | awk '{print $2}')
        timeoutCounter=$((${timeoutCounter} + 1))
        if [[ ${timeoutCounter} -eq 4 ]]; then
            show_err_msg "Verify Account Info" "Timeout unable to log out ${oldUser} account." "fail" $STOP_ICON
            logMe "ERROR: Timeout waiting for $oldUser to logout...no account info changed"
            cleanup_and_exit "Fail"
        fi
    done
    update_display_list "change" "Verify Account Info" "success"
}

function perform_migration ()
{
    #################
    # Perform the actual migration, but perform validity checks along the way
    #################
    #
    # Captures current "RealName" this is the displayName and format it correctly

    update_display_list "change" "Retrieve Display Name" "wait"
    fullRealName=$(dscl . -read /Users/${oldUser} RealName)
    readonly origRealName=$(echo ${fullRealName} | cut -d' ' -f2-)
    logMe "Full RealName is: "$origRealName
    update_display_list "change" "Retrieve Display Name" "success"

    # Step #1
    # Updates "RealName" (human readable) to new username

    update_display_list "change" "Update Display Name" "wait"
    sudo dscl . -change "/Users/${oldUser}" RealName "${origRealName}" "${newUser}"
    logMe "Migrate Realname from $oldUser to $newUser"
    
    #
    # Validity Check #1
    # Verify that the folder name could be changed
    #
    
    if [[ $? -ne 0 ]]; then

        show_err_msg "Update Display Name" "Could not rename the user's RealName in dscl. - err=$?" "fail" $STOP_ICON
        logMe "Could not rename the user's RealName in dscl. - err=$?"
        logMe "Reverting RealName changes"

        sudo dscl . -change "/Users/${oldUser}" RealName "${origRealName}" "${origRealName}"
		cleanup_and_exit "Fail"

    else
        logMe "Migration of Realname succesful"
        update_display_list "change" "Update Display Name" "success"
    fi

    # Step #2
    # Captures current NFS home directory

    update_display_list "change" "Update NFS Home Directory" "wait"    
    readonly origHomeDir=$(dscl . -read "/Users/${oldUser}" NFSHomeDirectory | awk '{print $2}' -)
    logMe "Old User $oldUser Home Directory is: $origHomeDir"

    #
    # Validity Check #2
    # Verify that the original users folder was found
    #

    if [[ -z "${origHomeDir}" ]]; then
        show_err_msg "Update NFS Home Directory" "Cannot obtain the original home directory name, is the oldUserName correct?" "fail" $STOP_ICON
        logMe "Cannot obtain the original home directory name, is the oldUserName correct?"
        logMe "Reverting RealName changes"

        sudo dscl . -change "/Users/${oldUser}" RealName "${newUser}" "${origRealName}"
		cleanup_and_exit "Fail"
    fi
    
    # Step #3
    # Updates NFS home directory

    sudo dscl . -change "/Users/${oldUser}" NFSHomeDirectory "${origHomeDir}" "/Users/${newUser}"
    logMe "Migration of User $oldUser NFS Home Directory is: $origHomeDir"

    #
    # Validity Check #3
    # Verify that the Home Folder could be changed
    #

    if [[ $? -ne 0 ]]; then
        show_err_msg "Update NFS Home Directory" "Could not rename the user's home directory pointer, aborting further changes! - err="$? "fail" $STOP_ICON
        logMe "Could not rename the user's home directory pointer, aborting further changes! - err=$?"
        logMe "Reverting Home Directory changes"

        sudo dscl . -change "/Users/${oldUser}" NFSHomeDirectory "/Users/${newUser}" "${origHomeDir}"

        logMe "Reverting RealName changes"
        sudo dscl . -change "/Users/${oldUser}" RealName "${newUser}" "${origRealName}"
		cleanup_and_exit "Fail"
    else
        logMe "Migration of NFS Home Directory succesful"
        update_display_list "change" "Update NFS Home Directory" "success"
    fi

    # Step #4
    # Move data to new home folder

    update_display_list "change" "Move Files to New User" "wait"    
    mv "${origHomeDir}" "/Users/${newUser}"
    logMe "Move data from  $origHomeDir to: /Users/${newUser}"

    #
    # Validity Check #4
    # Verify that the data could be moved
    #

    if [[ $? -ne 0 ]]; then
        show_err_msg "Move Files to New User" "Could not rename the user's home directory in /Users" "fail" $STOP_ICON
        logMe "Could not rename the user's home directory in /Users"
        logMe "Reverting Home Directory changes"

        mv "/Users/${newUser}" "${origHomeDir}"
        sudo dscl . -change "/Users/${oldUser}" NFSHomeDirectory "/Users/${newUser}" "${origHomeDir}"

        logMe "Reverting RealName changes"

        sudo dscl . -change "/Users/${oldUser}" RealName "${newUser}" "${origRealName}"
		cleanup_and_exit "Fail"
    else
        logMe "Migration of Data successful"
        update_display_list "change" "Move Files to New User" "success"
    fi

    # Step #5
    # Actual username change

    update_display_list "change" "Verify Rename" "wait"
    sudo dscl . -change "/Users/${oldUser}" RecordName "${oldUser}" "${newUser}"

    #
    # Validity Check #4
    # Verify that the rename was successful
    #

    if [[ $? -ne 0 ]]; then
        show_err_msg "Verify Rename"  "Could not rename the user's RecordName in dscl - the user should still be able to login, but with user name ${oldUser}" "fail" $STOP_ICON
        logMe "Could not rename the user's RecordName in dscl - the user should still be able to login, but with user name ${oldUser}"
        logMe "Reverting username change"

        sudo dscl . -change "/Users/${oldUser}" RecordName "${newUser}" "${oldUser}"

        logMe "Reverting Home Directory changes"

        mv "/Users/${newUser}" "${origHomeDir}"
        sudo dscl . -change "/Users/${oldUser}" NFSHomeDirectory "/Users/${newUser}" "${origHomeDir}"

        logMe "Reverting RealName changes"

        sudo dscl . -change "/Users/${oldUser}" RealName "${newUser}" "${origRealName}"
		cleanup_and_exit "Fail"
    else
        # Everything was successful to this point, so update the display and restart the system
        update_display_list "change" "Verify Rename" "success"
        update_display_list "icon" ${SUCCESS_ICON}
        update_display_list "infotext" "Successfuly migrated old user: $oldUser to new user: $newUser"
        logMe "Verification of Data successfull.  System restart in order"
        update_display_list "buttonchange" "Restart"
        wait
        cleanup_and_exit "Restart"
    fi
}

##############################
# 
# Main Script Start
#
##############################

declare newUser
declare oldUser
declare fullRealName
declare origRealName
declare origHomeDir

autoload 'is-at-least'

check_swift_dialog_install
check_support_files
test_root_user
create_welcome_dialog
create_workflow_dialog
update_display_list "create"
verify_account_info
perform_migration
# Technically, the script should never get this far if everything went OK
cleanup_and_exit "Good"