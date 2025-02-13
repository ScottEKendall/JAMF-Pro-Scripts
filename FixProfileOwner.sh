#!/bin/zsh
#
# FixProfileOwner
#
# by: Scott Kendall
#
# Written: 9/20/2023
# Last updated: 02/13/2025
#
# Script Purpose: change the permissions on the files in the users directory so that they are the owner of all the files
#
# 1.0 - Initial rewrite using Swift Dialog prompts
# 1.1 - Code cleanup to be more consistant with all apps

######################################################################################################
#
# Gobal "Common" variables
#
######################################################################################################

LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )

SW_DIALOG="/usr/local/bin/dialog"
SD_BANNER_IMAGE="/Library/Application Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png"
LOG_STAMP=$(echo $(/bin/date +%Y%m%d))
LOG_DIR="/Library/Application Support/GiantEagle/logs"
LOG_FILE="${LOG_DIR}/FixProfileOwner.log"

# have to "pad" the text title to accomodate for the hardcoded banner image we currently display, this will make it more centered on the screen (5 spaces)
BANNER_TEXT_PADDING="     "
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Fix Profile Ownership"
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/FixProfileOwner.XXXXX)
chmod 644 "${DIALOG_COMMAND_FILE}"
ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
SD_ICON_FILE=$ICON_FILES"ToolbarCustomizeIcon.icns"

# Swift Dialog version requirements
SW_DIALOG="/usr/local/bin/dialog"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"
MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

USER_SCAN_START_DIR="${USER_DIR}"

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
            eval "${DIALOG_COMMAND_FILE}"
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

####################################################################################################
#
# Local Functions
#
####################################################################################################

function show_welcome_message ()
{
    # Purpose: Display dialog message to user 
    # Return: None

    MainDialogBody=(
        --message "Please wait while determining which files to analyze...<br>Starting the scan at folder: ${USER_SCAN_START_DIR}"
        --icon "${SD_ICON_FILE}"
        --iconsize 128
        --overlayicon computer
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --moveable
        --titlefont shadow=1, size=24
        --messagefont size=18
        --width 770
        --height 350
        --button1disabled
        --commandfile "${DIALOG_COMMAND_FILE}"
        --button1text "none"
        --progress
        --ontop
    )

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null & sleep 0.5

}

function get_total_app_count ()
{
    # Purpose: get a file count of the files in the users home drive & subfolders
    # Return: None
    # Expectations: total_app_count needs to be a global var
    #
    update_display_list "progress" "" "" "" "Performing Directory Scan"
    for file in ${USER_SCAN_START_DIR}/**/*(.); do
        update_display_list "progress" "" "" "" "Files found so far: $total_app_count" 0
        total_app_count+=1
    done
    update_display_list "progress" "" "" "" "" 100
}

function change_permissions ()
{
    # Purpose: Change the ownership of the files in the users home folder to <SID>
    #          Change the /usr/local/jpmc folder owner to <SID>
    # Return: None

    typeset -i appcounter=0
    # Change owernship of all the files in the user's home folder to correct ID

     update_display_list "clear" "Changing the permissions to make sure you are the owner,<br> and your files are set correctly."
    for file in  ${USER_SCAN_START_DIR}/**/*(.); do
        chown $LOGGED_IN_USER ${file}
        progress_percentage=$(((appcounter*100)/total_app_count))
        update_display_list "progress" "" "" "" "Fixing Permisions on: $appcounter of $total_app_count files" "$progress_percentage"
        appcounter+=1
    done

    # Change ownership to user for the /usr/local/jpmc folder
    update_display_list "clear" "Changing permissions on /usr/local/ge"
    update_display_list "progress" "" "" "" "" 100
    chown -R ${LOGGED_IN_USER} /usr/local/ge

    #reset .toolsenv back to root...don't want the user to be able to delete it

    if [[ -e ${UserDir}/.toolsenv ]]; then
        chown root:wheel ${UserDir}/.toolsenv
    fi

}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit 0
}

####################################################################################################
#
# Auto Load Functions
#
####################################################################################################

autoload 'is-at-least'

#############################
# Start of Main Script
#############################

typeset -i total_app_count && total_app_count=0

check_swift_dialog_install
check_support_files
show_welcome_message
get_total_app_count
sleep 4  #sleep a bit so the user can see the progress status
change_permissions
sleep 4
update_display_list "Destroy"
cleanup_and_exit
