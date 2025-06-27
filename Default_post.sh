#!/bin/zsh

## last updated by: Scott Kendall
## last updated on: April 10, 2025
## Script version: 5.10.0

###############
# App variables
###############

# appType choices:
#
# app - Universal binary goes in /Applicaions folder
# apl - Application that goes into ~/Applications folder (perosnal applications)
# jav - Application will be installed in /Library/Java/JavaVirtualMachines

# loc - default location of /usr/local
# lib - default location of /usr/local/bin
# jpm - default location of /usr/local/ge
# cli - terminal CLI app that goes in custom location for binary files (ie. /usr/local/ge/bin)

# fnt - Fonts will be store in User's Library fonts folder
# sup - Application is in final location, only work on support files
# ext - Adobe After Effects plugin
# pkg - Install package (.pkg)
# prt - Printer PPD File
# cer - Install Certificates into /usr/local/ge/SSLcerts
# gem - Ruby Gems installed to /usr/local/ge
# dae - System LaunchDaemon /Library/LaunchDaemon
# jmf - Execute JAMF policy (by EventID)
# dmg - Copy the contents of a DMG into the /Applications folder
# chm - Insall chrome extensions into the user's chrome library
# dsk - Install file onto users Desktop
#
#
# Set the PATH to ensure a known good environment

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
LoggedInUser=$(echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
UserDir=$(dscl . -read /Users/${LoggedInUser} NFSHomeDirectory | awk '{ print $2 }' )

appType="dsk"
appName="Join Raspberry Network.pdf"
runAfterDone="No"

FolderPath=""
CertPath="/Library/Frameworks/Python.framework/Versions/3.10/etc/openssl"
ExtensionsFolder="/Library/Application Support/Adobe/CEP/extensions"

# DMG Info
DMGName="ideaIC-2024.3.5-aarch64.dmg"
DMGVolumeName="IntelliJ IDEA CE"

typeset DefaultInstallFolder && DefaultInstallFolder=$(dirname ${0})
typeset CertPath && CertPath="/Library/Frameworks/Python.framework/Versions/3.10/etc/openssl"
typeset ExtensionsFolder && ExtensionsFolder="/Library/Application Support/Adobe/CEP/extensions"
typeset SettingsPath && SettingsPath="${UserDir}/Library/Android/sdk"
typeset unzipLocation && unzipLocation="${DefaultInstallFolder}"
typeset FontDir && FontDir="${UserDir}/Library/Fonts/"

####################
# "Global" variables
####################

platform=$(uname -p)
logDir="/Library/Application Support/GiantEagle/logs"
logStamp=$(echo $(date +%Y%m%d))
logFile="${logDir}/ApplicationInstall_${logStamp}_${appName} (${platform}).log"
typeset SourcePath && "${DefaultInstallFolder}/"
typeset DestPath
typeset ToolsHome && ToolsHome="/usr/local/ge"
typeset SupportFiles && "${ToolsHome}"

###########
# Functions
###########

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions
	[[ ! -d "${logDir}" ]] && /bin/mkdir -p "${logDir}"
	/bin/chmod 755 "${logDir}"

	# If the log file does not exist - create it and set the permissions
	[[ ! -f "${logFile}" ]] && /usr/bin/touch "${logFile}"
	/bin/chmod 644 "${logFile}"
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
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${logFile}"
}

function set_file_paths()
{
	# Set the Destination folder based on what is being installed (Determined by 'AppType')
    # Sets "DestPath" variable, must be declared outside of function
	#
    # RETURN: None

	# See if the app is in the main folder or inside a platform folder
	# and also see if it is in ZIP format or executable format.

	if [[ -e "${DefaultInstallFolder}/bin.zip" ]]; then

		# If the file is in the main folder and is in zip format..
		SourcePath="${DefaultInstallFolder}/"

	elif [[ -e "${DefaultInstallFolder}/${platform}/bin.zip" ]]; then
	
		# If the file is in the platform folder and is in zip format.. 
		SourcePath="${DefaultInstallFolder}/${platform}/"

	elif [[ -e "${DefaultInstallFolder}/${appName}" ]]; then

		# If the file is in the main folder and executable format...
		SourcePath="${DefaultInstallFolder}/"

	elif [[ -e "${DefaultInstallFolder}/${platform}/${appName}" ]]; then

		# If the file is in the main folder and executable format...
		SourcePath="${DefaultInstallFolder}/${platform}/"
	fi

	case "${appType}" in
			
		"lib" )
			DestPath="/usr/local/bin"
			;;

		"loc" )
			DestPath="/usr/local"
			;;

		"prt" )
			DestPath="//Library/Printers/PPDs/Contents/Resources"
			;;

		"cli" )
			DestPath="${ToolsHome}/bin"
			;;

		"jpm" )
			DestPath="${ToolsHome}"
			;;

		"cer" )
			DestPath="${ToolsHome}/SSLcerts"
			;;
		
		"jav" )
			DestPath="/Library/Java/JavaVirtualMachines"
			;;

		"gem" )
			DestPath="/usr/local/ge/gems"
			;;

		"zip" )
			DestPath="${unzipLocation}"
			;;

		"dae" )
			DestPath="/Library/LaunchDaemons"
			;;

		"dsk" )
			DestPath="${UserDir}\Desktop"
			;;	

		"app" | "pkg" | "sup" | "jmf" | "dmg" )
			DestPath="/Applications"
			;;

		"apl" )
			DestPath="${UserDir}/Applications"
			;;

		"fnt" )
			DestPath="${UserDir}/Library/Fonts"
			;;

		"ext" )
			DestPath="${ExtensionsFolder}"
			;;

	esac
	SupportFiles="${DestPath}"
}

function set_ownership ()
{
	# Sets the Onwership & permisisons of the Destination file (Determined by 'AppType')
	#
    # RETURN: None

	logMe "Set ownership permissions"
	case ${appType} in

        "lib" | "app" | "sup" | "cer" | "jav" | "dae" | "pkg" |"jmf" | "prt" | "dmg" )
            [[ -e "${DestPath}/${appName}" ]] && chown -R root:wheel "${DestPath}/${appName}" > /dev/null
            ;;

        "fnt" | "jpm"| "cli" | "loc" | "apl" | "gem" | "zip" )
            [[ -e "${DestPath}/${appName}" ]] && chown -R ${LoggedInUser} "${DestPath}/${appName}" > /dev/null
            ;;

	esac
	chmod -R 755 "${DestPath}/${appName}" > /dev/null
}

function clear_quarantine_flag ()
{
	# Clears the Appole Qaurantine flag and performs the gatekeeper scan
	#
    # RETURN: None

    # Only clear the quaratine flag if they are of specific app types

    if [[ "${appType}" == @("fnt|sup|cer|gem|dae") ]] || [[ ! -e "${DestPath}/${appName}" ]] ; then
        logMe "INFO: No need to clear quarantine flag"
        return 0
    fi
	logMe "Clearing the Quarantine flag"
	xattr -d -r com.apple.quarantine "${DestPath}/${appName}" 2> /dev/null
	# Perform the new Gatekeeper scan if on Sonoma or higher
	logMe "Performing Gatekeeper Scan"
	gktool scan "${DestPath}/${appName}"
}

function cleanup ()
{
	for CleanUp_Path (
		"${SourcePath}bin.zip"
		"${SourcePath}sbin.zip"
		"${SourcePath}include.zip"
		"${SourcePath}lib.zip"
		"${SourcePath}share.zip"
		"${SourcePath}man.zip"
		"${SourcePath}${appName}.zip"
		"${SourcePath}${appName}"
		"${DefaultInstallFolder}/arm"
		"${DefaultInstallFolder}/i386"
		"${ToolsHome}/__MACOSX"
		"${DestPath}/__MACOSX"
		"${SourcePath}__MACOSX"
		"${SupportFiles}/__MACOSX"
	) { [[ -e "${CleanUp_Path}" ]] && { rm -rf "${CleanUp_Path}" ;  echo "Cleaning up: ${CleanUp_Path}" ; }}
}

function perform_install_action()
{
	logMe "Install the application and support file(s) to ${DestPath}"
	case "${appType}" in

		"cer" )
			logMe "Installing Certificate(s)"
			ln -sf "${DestPath}/${appName}" "${CertPath}"
			;;

		"jmf" )
			logMe "Executing JAMF policy: ${JAMFPolicy}"
			jamf policy -event ${JAMFPolicy}
			;;

		"ext" )
			logMe "Moving Adobe Extension to destination"
			unzip -o "${SourcePath}${appName}" -d "${ExtensionsFolder}"
			rm -r "${ExtensionsFolder}/__MACOSX"
			;;

		"fnt" )
			logMe "Installing fonts"
			unzip -o "${SourcePath}${appName}" -d "${DestPath}"
			;;

		"pkg" )
			logMe "Running Package Installer"
			installer -pkg "${SourcePath}${pkgName}" -target "${DestPath}"
			;;
		
		"prt" )
			logMe "Installing Printer PPD File"
			mv -f "${SourcePath}${appName}" "${DestPath}"
			;;

		"app" | "apl" )
			if [[ -e "${SourcePath}/${appName}" ]]; then
				logMe "Moving app to destination"
				rm -r "${DestPath}/${appName}"
				mv -f "${SourcePath}${appName}" "${DestPath}"
			fi
			;;

		"dae" )
			logMe "Installing BootStrap Daemon"
			launchctl bootstrap system "${appName}"
			;;

		"zip" )
			if [[ -f "${SourcePath}${appName}.zip" ]]; then
				logMe "Unzipping files"
				unzip -o "${SourcePath}${appName}" -d "${DestPath}" 
			fi
			;;
		
		"dmg" )
            logMe "Mounting DMG ${DMGName}"
			hdiutil attach "${DMGName}" -nobrowse -quiet
			sleep 5
            logMe "Copying ${DMGVolumeName}/${appName} to ${DestPath}"
			cp -R "/Volumes/${DMGVolumeName}/${appName}" "${DestPath}"
            logMe "Unmounting DMG ${DMGName}"
			hdiutil detach "/Volumes/${DMGVolumeName}" -force -quiet
			;;

		"jav" )
			logMe "Installing Java ${appName}"
			unzip -o "${SourcePath}${appName}" -d "${DestPath}"
			ln -sf "java" "${ToolsHome}/bin"
			;;

		"cli" | "lib" | "jpm" | "loc" | "gem" )

			logMe "Installing binary files"

			# If there is an "appName".zip then extract the .zip file otherwise move the binary to destination

			if [[ -f "${SourcePath}bin.zip" ]]; then
				unzip -o "${SourcePath}bin" -d "${DestPath}"
			else
				mv -f "${SourcePath}${appName}" "${DestPath}"
			fi
			logMe "Installing Extras content to: ${DestPath}"

			# See if there are an extras that need to be installed as well

			for ExtraItem in include lib libexec sbin share etc man Frameworks; do
				[[ -e "${SourcePath}${ExtraItem}.zip" ]] && ExtrasPath="${SourcePath}" || ExtrasPath="${DefaultInstallFolder}"/
				if [[ ! -e "${ExtrasPath}${ExtraItem}.zip" ]]; then
					continue
				fi
				logMe "Installing ${ExtraItem} files"
				unzip -o "${ExtrasPath}${ExtraItem}.zip" -d "${DestPath}"
			done
			chmod -R 755 "${DestPath}"
			;;
	esac

}

#############
#
# Main Script
#
#############

set_file_paths
create_log_directory

logMe "Installing for platform type: ${platform}"
logMe "Installation type: ${appType}"
logMe "Source Folder: ${SourcePath}"
logMe "Destination Folder: ${DestPath}"

#################################
#
# Pre-instalation actions go here
#
#################################

perform_install_action
set_ownership
clear_quarantine_flag

#########################################
#
# Do any application specific commands here
#
#########################################


# Clean up and exit

logMe "Cleanup and Exit"
cleanup
[[ $runAfterDone == "Yes" ]] && sudo /usr/bin/open "${DestPath}/${appName}"
exit 0
