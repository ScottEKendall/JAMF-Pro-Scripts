#!/bin/zsh

# Replace legacy Apple Keynote with Keynote Creator Studio in-place
# for the currently logged-in console user AND the 'ladmin' account.
# Also removes legacy /Applications/Keynote.app after Dock updates.
# Uses --replacing 'Keynote' to preserve position when possible (label-based).
# Skips Dock changes if legacy app is not installed (avoids stale/ghost entries).
# Gracefully handles "already exists" during add.
# Only restarts Dock if changes were made to the console user's Dock.
#
# Updated for dockutil 3.0.2+ (Swift version)
# John Sherrod - v2.3 - January 30, 2026

###############################################################################
# Preconditions
###############################################################################

if ! command -v dockutil >/dev/null 2>&1; then
    echo "ERROR: dockutil not found at runtime"
    exit 1
fi

if [[ "$(dockutil --version)" != *"3."* ]]; then
    echo "WARNING: This script is optimized for dockutil 3.x (you have $(dockutil --version))"
fi

###############################################################################
# Determine logged-in user
###############################################################################

loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" \
    | awk '/Name :/ && ! /loginwindow/ { print $3 }')

if [[ -z "$loggedInUser" || "$loggedInUser" == "loginwindow" ]]; then
    loggedInUser=""
    echo "No logged-in console user detected. Will process ladmin only."
fi

###############################################################################
# Fixed admin user to always process
###############################################################################

ADMIN_USER="ladmin"

###############################################################################
# App paths and identifiers
###############################################################################

NEW_KEYNOTE="/Applications/Keynote Creator Studio.app"
OLD_KEYNOTE="/Applications/Keynote.app"
OLD_BUNDLE_ID="com.apple.iWork.Keynote"
OLD_LABEL="Keynote"  # Visible label in Dock for legacy Keynote (adjust if localized/renamed)

if [[ ! -d "$NEW_KEYNOTE" ]]; then
    echo "New Keynote app not found at $NEW_KEYNOTE. Exiting without changes."
    exit 0
fi

###############################################################################
# Function to process a single user
###############################################################################

process_user() {
    local targetUser="$1"
    local plistPath="/Users/$targetUser/Library/Preferences/com.apple.dock.plist"
    local isConsole=$( [[ "$targetUser" == "$loggedInUser" ]] && echo "yes" || echo "no" )
    local changesMade=0

    if [[ ! -f "$plistPath" ]]; then
        echo "Dock plist not found for $targetUser at $plistPath — skipping."
        return
    fi

    # If legacy Keynote.app is gone, assume any Dock entry is stale → skip replacement
    if [[ ! -d "$OLD_KEYNOTE" ]]; then
        echo "Legacy Keynote.app not installed for $targetUser — skipping Dock replacement (stale entries ignored)."
        # Optional: Clean ghost entries if desired
        # dockutil --remove "$OLD_BUNDLE_ID" --no-restart "$plistPath" 2>/dev/null
        return
    fi

    find_output=$(dockutil --find "$OLD_BUNDLE_ID" "$plistPath" 2>/dev/null)
    if [[ -n "$find_output" ]]; then
        echo "Legacy Keynote found in Dock for $targetUser — replacing with --replacing '$OLD_LABEL'…"

        # Use --replacing to try preserving position (label match required)
        replace_result=$(dockutil --add "$NEW_KEYNOTE" --replacing "$OLD_LABEL" --no-restart "$plistPath" 2>&1)
        replace_exit=$?

        if [[ $replace_exit -eq 0 ]]; then
            ((changesMade++))
            echo "Replacement successful (position preserved if label matched)."
        elif echo "$replace_result" | grep -qi "already exists in dock"; then
            echo "New Keynote (Keynote Creator Studio) already exists in Dock — no change needed."
        else
            echo "Replacement attempted but returned non-zero: $replace_result"
            # Fallback: try plain add if --replacing failed for other reasons
            add_result=$(dockutil --add "$NEW_KEYNOTE" --no-restart "$plistPath" 2>&1)
            if [[ $? -eq 0 ]]; then
                ((changesMade++))
                echo "Fallback add successful (appended to end)."
            elif echo "$add_result" | grep -qi "already exists in dock"; then
                echo "New Keynote already in Dock (fallback) — no change needed."
            else
                echo "Fallback add failed: $add_result"
            fi
        fi

        if [[ $changesMade -gt 0 ]]; then
            echo "Changes applied for $targetUser."
            if [[ "$isConsole" == "yes" ]]; then
                echo "Restarting Dock for console user $targetUser…"
                killall Dock 2>/dev/null || true
            else
                echo "(Dock restart not needed for non-logged-in user $targetUser — changes apply on next login.)"
            fi
        else
            echo "No effective changes made for $targetUser (likely already up to date)."
        fi
    else
        echo "Legacy Keynote (bundle $OLD_BUNDLE_ID) not found in Dock for $targetUser — no changes needed."
    fi
}

###############################################################################
# Process users
###############################################################################

if [[ -n "$loggedInUser" ]]; then
    echo "Processing console user: $loggedInUser"
    process_user "$loggedInUser"
fi

echo "Processing admin user: $ADMIN_USER"
process_user "$ADMIN_USER"

###############################################################################
# Cleanup: remove dockutil binary (optional)
###############################################################################

if [[ -x /usr/local/bin/dockutil ]]; then
    echo "Cleaning up dockutil binary…"
    rm -f /usr/local/bin/dockutil
fi

###############################################################################
# Cleanup: remove legacy Keynote.app (one-time, system-wide)
###############################################################################

if [[ -d "$OLD_KEYNOTE" ]]; then
    echo "Removing legacy Keynote.app at $OLD_KEYNOTE…"
    rm -rf "$OLD_KEYNOTE"
    if [[ $? -eq 0 ]]; then
        echo "Legacy Keynote.app successfully removed."
    else
        echo "WARNING: Failed to remove $OLD_KEYNOTE (permissions or in use?)."
    fi
else
    echo "Legacy Keynote.app already not present at $OLD_KEYNOTE — no removal needed."
fi

exit 0