#!/bin/bash

LOCALADMIN="localmgr"
kickstart=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart

echo "Configuring Remote Management"
if id -u $LOCALADMIN >/dev/null 2>&1; then
    echo "Defined local admin account exists"
    # Deactivate ARD agent, deny all access
    echo "Deactivating ARD agent"
    $kickstart -deactivate -configure -access -off
    echo "Turning off default AllLocalUsers remote management setting"
    defaults write /Library/Preferences/com.apple.RemoteManagement ARD_AllLocalUsers -bool FALSE
    # Remove 'naprivs' key from users configured by ARD's -specifiedUSers flag
    echo "Removing naprivs key from local users"
    RemoteManagementUsers=$(dscl . list /Users naprivs | awk '{print $1}')
        for EnabledUser in $RemoteManagementUsers; do
            echo "--- naprivs removed from $EnabledUser"
            dscl . delete /Users/$EnabledUser naprivs
        done
    # Turn ARD back on and enable only the specified LOCALADMIN
    echo "Reconfiguring ARD for only specified users"
    $kickstart -configure -allowAccessFor -specifiedUsers
    echo "Setting specified local admin account as sole ARD user"
    $kickstart -configure -users $LOCALADMIN -access -on -privs -all
    echo "Restarting ARD agent"
    $kickstart -activate -restart -agent
    echo "--- Remote management reset; user ${LOCALADMIN} configured for access"
    exit 0
else
    echo "--- ERROR: The specified local admin account does not exist."
    exit 1
fi