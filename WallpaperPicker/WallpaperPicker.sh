#!/bin/zsh
#
# Wallpaper Chooser
#
# by: Scott Kendall
#
# Written: 12/10/2025
# Last updated: 12/10/2025
#
# Script Purpose: Allow the user to choose from a selection of wallpapers and set that as their background
# 
# You need to have the app "desktoppr" packaged up and ready to deliver via MDM
#   https://github.com/scriptingosx/desktoppr
# You need to have your wallpapers selection packaged up and ready to deliver
#
# 1.0 - Initial

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="WallPaperPicker"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
[[ -e "${SW_DIALOG}" ]] && SD_VERSION=$( ${SW_DIALOG} --version) || SD_VERSION="0.0.0"

SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
DISPLAY_COUNT=$(system_profiler SPDisplaysDataType -json)

# Make some temp files

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
    spacing=$(defaults read $DEFAULTS_DIR "BannerPadding")
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Wallpaper Picker"
OVERLAY_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"
SD_ICON_FILE="/System/Applications/Photos.app"

# Trigger policies

WALLPAPER_DIR="${SUPPORT_DIR}/Wallpapers"
DESKTOPPR_APP="/usr/local/bin/desktoppr"
DESKTOPPR_INSTALL_POLICY="install_desktoppr"
WALLPAPER_INSTALL_POLICY="install_wallpapers"
SD_INFO_BOX_MSG="You can preview the picture using the carousel images and then select the picture you want to set from the drop down and optionally choose which monitor to change."

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
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

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
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
    [[ ! -e "${WALLPAPER_DIR}" ]] && /usr/local/bin/jamf policy -trigger ${WALLPAPER_INSTALL_POLICY}
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
    [[ $(which desktoppr) == *"not found"* ]] && /usr/local/bin/jamf policy -trigger ${DESKTOPPR_INSTALL_POLICY}
}

function cleanup_and_exit ()
{
	[[ -f ${JSON_OPTIONS} ]] && /bin/rm -rf ${JSON_OPTIONS}
	[[ -f ${TMP_FILE_STORAGE} ]] && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]] && /bin/rm -rf ${DIALOG_COMMAND_FILE}
	exit $1
}

function runAsUser () 
{
    launchctl asuser "$USER_UID" sudo -u "$LOGGED_IN_USER" "$@"
}

function generate_preview () 
{
    local wallpaperPath="$1"
    local previewPath="${wallpaperPath%.*}-preview.png"

    echo $previewPath
    
    if [[ ! -e "$previewPath" ]] && [[ -e "$(dirname "${previewPath}")" ]]; then
        # Generate preview with sips - 512px width while maintaining aspect ratio
        sips -Z 512 "${wallpaperPath}" --out "${previewPath}" >/dev/null 2>&1
    fi
    [ -f "${previewPath}" ]
}

function find_wallpapers ()
{
    # --- Find wallpaper files ---
    logMe "Scanning for wallpapers..."
    # Get all PNG files (excluding previews)
    wallpaperFiles=()
    while IFS= read -r file; do
        if [[ "$file" != *"-preview.png" ]]; then
            wallpaperFiles+=("$file")
        fi
    done < <(find "$WALLPAPER_DIR" -type f -name "*.png" | sort)

    # Exit if no wallpapers found
    if [ ${#wallpaperFiles[@]} -eq 0 ]; then
        logMe "No wallpaper files found"
        cleanup_and_exit 1
    fi
}

function create_display_header ()
{
    dialogOptions=(
        --message $message
        --titlefont shadow=1
        --ontop
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --infobox "${SD_INFO_BOX_MSG}"
        --width 920
        --height 550
        --moveable
        --quitkey 0
        --button1text "Set Wallpaper"
        --button2text "Cancel"

    )
}

function process_for_display ()
{
    # Process wallpapers for display
    wallpaperNames=()
    wallpaperPaths=()

    for wallpaperPath in "${wallpaperFiles[@]}"; do
        # Create preview image if needed
        previewPath="${wallpaperPath%.*}-preview.png"
        #previewPath="${wallpaperPath}"
        if [ ! -f "${previewPath}" ]; then
            generate_preview "${wallpaperPath}" || continue
        fi

        # Get nice display name for the wallpaper
        baseName=$(basename "${wallpaperPath}")
        description=$(mdls -name kMDItemDescription "${wallpaperPath}" 2>/dev/null | awk -F'"' '{print $2}')

        if [[ -z "${description}" || "${description}" == "(null)" ]]; then
            # Convert filename to readable format (capitalize words, replace dashes/underscores with spaces)
            wallpaperName=$(echo "$baseName" | sed -E 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
        else
            wallpaperName="${description}"
        fi

        # Add to our collection
        wallpaperNames+=("${wallpaperName}")
        wallpaperPaths+=("${wallpaperPath}")

        # Add to dialog display,
        dialogOptions+=(--image "${previewPath}" --imagecaption "${wallpaperName}")
    done

    # Exit if no valid wallpapers with previews
    if [ ${#wallpaperNames[@]} -eq 0 ]; then
        logMe "No valid wallpapers found"
        cleanup_and_exit 1
    fi
}

function construct_menu_display ()
{

    # Add dropdown with wallpaper names
    local wallpaperNamesString=$(
        IFS=,
        echo "${wallpaperNames[*]}"
    )
    dialogOptions+=(--selecttitle "Choose a wallpaper",dropdown,required --selectvalues "${wallpaperNamesString}")
    dialogOptions+=(--selecttitle "Which Display",dropdown,required --selectvalues $DISPLAY_COUNT)
}

####################################################################################################
#
# Main Script
#
####################################################################################################

declare wallpaperFiles
declare dialogOptions
declare -a wallpaperNames
declare -a wallpaperPaths

autoload 'is-at-least'

create_log_directory
check_swift_dialog_install
check_support_files
create_display_header

#Extract the number of displays attached to the computer
DISPLAY_COUNT=$(echo $DISPLAY_COUNT | jq -c '[.SPDisplaysDataType[] | .spdisplays_ndrvs[]._name]'| tr -d "[" |tr -d "]" | tr -d '"')

find_wallpapers
process_for_display
construct_menu_display

# --- Show dialog and get user selection ---
logMe "Displaying wallpaper selection dialog..."
while true; do
    dialogOutput=$("${SW_DIALOG}" "${dialogOptions[@]}")
    returnCode=$?

    [[ "$returnCode" == "2" ]] && {logMe "Cancel..."; break; }
    [[ "$returnCode" == "4" ]] && {logMe "Timer Expired"; break; }

    selectedWallpaperName=$(echo "${dialogOutput}" | grep '"Choose a wallpaper" :' | sed 's/"Choose a wallpaper" : "\(.*\)"/\1/')
    selectedDisplay=$(echo "${dialogOutput}" | grep '"Which Display" index :' | awk '{print $NF}' | tr -d '"')

    runAsUser $DESKTOPPR_APP "$selectedDisplay" "${WALLPAPER_DIR}/${selectedWallpaperName}"
done
cleanup_and_exit 0
