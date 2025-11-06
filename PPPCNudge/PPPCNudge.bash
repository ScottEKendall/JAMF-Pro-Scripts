#!/bin/bash
#
# PPPCNudge (Mosyle-ready, bash-safe)
# Prompts user (via swiftDialog) to enable Screen Recording / Camera / Microphone for Zoom
# Assumes swiftDialog is already installed at:
#   /Library/Application Support/Dialog/Dialog.app
#
# Tested with Mosyle execution "Only based on schedule or events" (User Login / App Installed), UI allowed.
# =========================
# Globals
# =========================
LOGGED_IN_USER="$(/usr/bin/stat -f%Su /dev/console)"
USER_DIR="$(/usr/bin/dscl . -read /Users/"$LOGGED_IN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
SD_INFO_BOX_MSG=""
LOG_STAMP="$(/bin/date +%Y%m%d)"
# swiftDialog app & binary
DIALOG_APP="/Library/Application Support/Dialog/Dialog.app"
SW_DIALOG="/usr/local/bin/dialog"
# Greeting (optional; not currently displayed)
HOUR="$(/bin/date +%H)"
if [ "$HOUR" -lt 12 ]; then
  SD_DIALOG_GREETING="Good morning"
elif [ "$HOUR" -lt 18 ]; then
  SD_DIALOG_GREETING="Good afternoon"
else
  SD_DIALOG_GREETING="Good evening"
fi
# =========================
# App-specific (edit as needed)
# =========================
SUPPORT_DIR="/Library/Application Support"
LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/PPCNudge.log"
BANNER_TEXT_PADDING="      "
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Privacy & Security Settings"
SD_BANNER_IMAGE="/Users/Shared/wallpapers-68da3ca98a592.jpg"
OVERLAY_ICON="/Applications/Self Service.app"
SD_ICON_FILE="/Library/Application Support/Dialog/Dialog.app"   # use swiftDialog app icon by default
# Replace Jamf-style parameters with constants
APP_PATH="/Applications/zoom.us.app"
TCC_KEY="kTCCServiceScreenCapture kTCCServiceCamera kTCCServiceMicrophone"
MAX_ATTEMPTS="5"
SLEEP_TIME="60"
DISPLAY_TYPE="MINI"
# First name (cosmetic)
FIRST_TOKEN="${LOGGED_IN_USER%%.*}"
SD_FIRST_NAME="$(printf "%s" "$FIRST_TOKEN" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
# =========================
# Functions
# =========================
create_log_directory() {
  [ -d "$LOG_DIR" ] || /bin/mkdir -p "$LOG_DIR"
  /bin/chmod 755 "$LOG_DIR"
  [ -f "$LOG_FILE" ] || /usr/bin/touch "$LOG_FILE"
  /bin/chmod 644 "$LOG_FILE"
}
logMe() {
  echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}
check_support_files() {
  if [ ! -e "$SD_BANNER_IMAGE" ]; then
    logMe "INFO: Banner image not found at $SD_BANNER_IMAGE. Continuing without it."
  fi
}
cleanup_and_exit() {
  local exitcode="$1"
  [ -z "$exitcode" ] && exitcode=0
  [ -f "$JSON_OPTIONS" ] && /bin/rm -rf "$JSON_OPTIONS"
  [ -f "$TMP_FILE_STORAGE" ] && /bin/rm -rf "$TMP_FILE_STORAGE"
  [ -f "$DIALOG_COMMAND_FILE" ] && /bin/rm -rf "$DIALOG_COMMAND_FILE"
  exit "$exitcode"
}
# Run a command in the logged-in user’s Aqua session with a clean env
runAsUser() {
  local USER_ID
  USER_ID="$(/usr/bin/id -u "$LOGGED_IN_USER")"
  /bin/launchctl asuser "$USER_ID" /usr/bin/env -i \
    HOME="$USER_DIR" \
    USER="$LOGGED_IN_USER" \
    LOGNAME="$LOGGED_IN_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@"
}
# Map a TCC key → pref pane & dialog message (no jq needed)
pane_and_message_for_key() {
  local key="$1"
  case "$key" in
    kTCCServiceScreenCapture)
      PREF_SCREEN="Privacy_ScreenCapture"
      MESSAGE="Please approve the *Screen & Audio Recordings* for $APP_NAME. This lets others view your screen or lets you record screens."
      ;;
    kTCCServiceCamera)
      PREF_SCREEN="Privacy_Camera"
      MESSAGE="Please allow the *Camera* for $APP_NAME. This lets others see you during meetings."
      ;;
    kTCCServiceMicrophone)
      PREF_SCREEN="Privacy_Microphone"
      MESSAGE="Please allow the *Microphone* for $APP_NAME. This lets others hear you during meetings."
      ;;
    kTCCServiceSystemPolicyAllFiles)
      PREF_SCREEN="Privacy_FilesAndFolders"
      MESSAGE="Please approve *Files & Folders* for $APP_NAME so it can access necessary files."
      ;;
    kTCCServiceAccessibility)
      PREF_SCREEN="Privacy_Accessibility"
      MESSAGE="Please allow *Accessibility* for $APP_NAME so automation actions can work properly."
      ;;
    *)
      PREF_SCREEN="Privacy_ScreenCapture"
      MESSAGE="Please enable the required privacy permission for $APP_NAME."
      ;;
  esac
}
# Show swiftDialog popup first
welcomemsg() {
  local message="$1"
  local display_lower
  display_lower="$(printf "%s" "$DISPLAY_TYPE" | tr '[:upper:]' '[:lower:]')"
  local dlg_args=(
    --message "$message"
    --titlefont shadow=1
    --ontop
    --icon "$SD_ICON_FILE"
    --overlayicon "$OVERLAY_ICON"
    --bannerimage "$SD_BANNER_IMAGE"
    --bannertitle "$SD_WINDOW_TITLE"
    --infobox "$SD_INFO_BOX_MSG"
    --helpmessage "This setting needs to be set for this particular app so it will work properly"
    --ignorednd
    --width 680
    --moveable
    --quitkey 0
    --button1text "OK"
  )
  [ "$display_lower" = "mini" ] && dlg_args+=(--mini)
  logMe "DEBUG: Launching Dialog via open -a in user context…"
  runAsUser /usr/bin/open -a "$DIALOG_APP" --args "${dlg_args[@]}"
}
# Query TCC
Check_TCC() {
  local key="$1"
  local bid="$2"
  if [ "$tccKeyDB" = "User" ]; then
    logMe "Querying user TCC database for $key"
    tccKeyStatus="$(sqlite3 "$USER_DIR/Library/Application Support/com.apple.TCC/TCC.db" "SELECT * FROM access WHERE service like '$key'" | grep "$bid" | awk -F '|' '{print $4}')"
    tccApproval="$bid"
    if [ "$tccKeyStatus" = "2" ]; then
      tccKeyStatus="on"
    elif [ "$tccKeyStatus" = "0" ]; then
      tccKeyStatus="off"
    else
      tccApproval=""
    fi
  else
    logMe "Querying system TCC database for $key"
    tccApproval="$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT client FROM access WHERE service like '$key' AND auth_value = '2'" | grep -o "$bid")"
    [ -n "$tccApproval" ] && tccKeyStatus="on"
  fi
}
get_app_details() {
  local key="$1"
  if [ ! -e "$APP_PATH" ]; then
    logMe "INFO: Could not find $APP_NAME at $APP_PATH. Exiting."
    cleanup_and_exit 0
  fi
  if ! echo "$bundleID" | grep -Eq '^[A-Za-z0-9]+[.-].*'; then
    logMe "WARNING: Invalid bundleID for $APP_NAME at $APP_PATH!"
    cleanup_and_exit 1
  fi
  Check_TCC "$key" "$bundleID"
  TCCresults="0"
  if [ "$tccKeyDB" = "User" ]; then
    if [ -z "$tccApproval" ]; then
      logMe "WARNING: $key should be in User TCC, but not found. App may need to be launched once."
      TCCresults="1"
      return 1
    else
      if [ "$tccKeyStatus" = "off" ]; then
        logMe "INFO: $key in User TCC but not approved for $APP_NAME"
      else
        logMe "INFO: $key in User TCC and already approved for $APP_NAME"
      fi
      return 0
    fi
  fi
  if [ "$tccApproval" = "$bundleID" ]; then
    logMe "INFO: ${PREF_SCREEN} already approved for $APP_NAME"
    tccKeyStatus="on"
    return 0
  fi
  logMe "${PREF_SCREEN} not yet approved for $APP_NAME"
  logMe "INFO: Valid application found, continuing"
}
# =========================
# Main
# =========================
create_log_directory
if [ -z "$LOGGED_IN_USER" ] || [ "$LOGGED_IN_USER" = "loginwindow" ]; then
  logMe "INFO: No user logged in"
  cleanup_and_exit 0
fi
check_support_files
# :white_check_mark: Ensure swiftDialog app/binary exists before proceeding
if [ ! -d "$DIALOG_APP" ]; then
  logMe "ERROR: SwiftDialog app not found at $DIALOG_APP. Exiting script."
  cleanup_and_exit 1
fi
if [ ! -x "$SW_DIALOG" ]; then
  logMe "ERROR: SwiftDialog binary not found or not executable at $SW_DIALOG. Exiting script."
  cleanup_and_exit 1
fi
# Normalize app path and gather info
case "$APP_PATH" in *.app) : ;; *) APP_PATH="${APP_PATH}.app" ;; esac
if [ ! -e "$APP_PATH" ]; then
  logMe "INFO: The Application $APP_PATH is not installed"
  cleanup_and_exit 0
fi
APP_NAME="$(basename "$APP_PATH" .app)"
SD_ICON_FILE="$APP_PATH"
bundleID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
logMe "Bundle ID for $APP_NAME is $bundleID"
# Keys that live in user TCC (for routing queries)
userTCCServices="kTCCServiceAddressBook kTCCServiceAppleEvents kTCCServiceBluetoothAlways kTCCServiceCalendar kTCCServiceCamera kTCCServiceFileProviderDomain kTCCServiceLiverpool kTCCServiceMicrophone kTCCServicePhotos kTCCServiceReminders kTCCServiceSystemPolicyAppBundles kTCCServiceSystemPolicyAppData kTCCServiceSystemPolicyDesktopFolder kTCCServiceSystemPolicyDocumentsFolder kTCCServiceSystemPolicyDownloadsFolder kTCCServiceSystemPolicyNetworkVolumes kTCCServiceSystemPolicyRemovableVolumes kTCCServiceUbiquity kTCCServiceWebBrowserPublicKeyCredential"
# Split TCC_KEY
IFS=' ' read -r -a TCC_KEY_ARRAY <<< "$TCC_KEY"
for key in "${TCC_KEY_ARRAY[@]}"; do
  if echo "$userTCCServices" | grep -qw "$key"; then
    tccKeyDB="User"
  else
    tccKeyDB="System"
  fi
  # Map pane + message
  pane_and_message_for_key "$key"
  # MINI mode strips markdown asterisks
  if [ "$(printf "%s" "$DISPLAY_TYPE" | tr '[:upper:]' '[:lower:]')" = "mini" ]; then
    MESSAGE="$(printf "%s" "$MESSAGE" | tr -d '*')"
  fi
  get_app_details "$key"
  # Skip if the user TCC row doesn't exist yet (likely first-launch issue)
  if [ "$TCCresults" = "1" ]; then
    logMe "Skipping $key for now. Continuing…"
    continue
  fi
  dialogAttempts=0
  until [ "$tccApproval" = "$bundleID" ] && [ "$tccKeyStatus" = "on" ]; do
    if [ "$dialogAttempts" -ge "$MAX_ATTEMPTS" ]; then
      logMe "Prompts ignored after $MAX_ATTEMPTS attempts. Giving up."
      cleanup_and_exit 1
    fi
    logMe "Requesting user to manually approve ${PREF_SCREEN} for $APP_NAME…"
    runAsUser /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?${PREF_SCREEN}"
    # Show the dialog prompt (user session)
    welcomemsg "$MESSAGE"
    sleep "$SLEEP_TIME"
    dialogAttempts=$((dialogAttempts + 1))
    logMe "Re-checking approval for ${PREF_SCREEN}…"
    Check_TCC "$key" "$bundleID"
  done
  logMe "INFO: ${key} for $APP_NAME has been approved!"
done
runAsUser /usr/bin/osascript -e 'quit app "System Settings"'
cleanup_and_exit 0]
New
10:14
#!/bin/bash
#
# PPPCNudge (Mosyle-ready, bash-safe)
# Prompts user (via swiftDialog) to enable Screen Recording / Camera / Microphone for Zoom
# Assumes swiftDialog is already installed at:
#   /Library/Application Support/Dialog/Dialog.app
#
# Tested with Mosyle execution "Only based on schedule or events" (User Login / App Installed), UI allowed.

# =========================
# Globals
# =========================
LOGGED_IN_USER="$(/usr/bin/stat -f%Su /dev/console)"
USER_DIR="$(/usr/bin/dscl . -read /Users/"$LOGGED_IN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"

SD_INFO_BOX_MSG=""
LOG_STAMP="$(/bin/date +%Y%m%d)"

# swiftDialog app & binary
DIALOG_APP="/Library/Application Support/Dialog/Dialog.app"
SW_DIALOG="/usr/local/bin/dialog"

# Greeting (optional; not currently displayed)
HOUR="$(/bin/date +%H)"
if [ "$HOUR" -lt 12 ]; then
  SD_DIALOG_GREETING="Good morning"
elif [ "$HOUR" -lt 18 ]; then
  SD_DIALOG_GREETING="Good afternoon"
else
  SD_DIALOG_GREETING="Good evening"
fi

# =========================
# App-specific (edit as needed)
# =========================
SUPPORT_DIR="/Library/Application Support"
LOG_DIR="${SUPPORT_DIR}/logs"
LOG_FILE="${LOG_DIR}/PPCNudge.log"

BANNER_TEXT_PADDING="      "
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Privacy & Security Settings"
SD_BANNER_IMAGE="/Users/Shared/wallpapers-68da3ca98a592.jpg"
OVERLAY_ICON="/Applications/Self Service.app"
SD_ICON_FILE="/Library/Application Support/Dialog/Dialog.app"   # use swiftDialog app icon by default

# Replace Jamf-style parameters with constants
APP_PATH="/Applications/zoom.us.app"
TCC_KEY="kTCCServiceScreenCapture kTCCServiceCamera kTCCServiceMicrophone"
MAX_ATTEMPTS="5"
SLEEP_TIME="60"
DISPLAY_TYPE="MINI"

# First name (cosmetic)
FIRST_TOKEN="${LOGGED_IN_USER%%.*}"
SD_FIRST_NAME="$(printf "%s" "$FIRST_TOKEN" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"

# =========================
# Functions
# =========================
create_log_directory() {
  [ -d "$LOG_DIR" ] || /bin/mkdir -p "$LOG_DIR"
  /bin/chmod 755 "$LOG_DIR"
  [ -f "$LOG_FILE" ] || /usr/bin/touch "$LOG_FILE"
  /bin/chmod 644 "$LOG_FILE"
}

logMe() {
  echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

check_support_files() {
  if [ ! -e "$SD_BANNER_IMAGE" ]; then
    logMe "INFO: Banner image not found at $SD_BANNER_IMAGE. Continuing without it."
  fi
}

cleanup_and_exit() {
  local exitcode="$1"
  [ -z "$exitcode" ] && exitcode=0
  [ -f "$JSON_OPTIONS" ] && /bin/rm -rf "$JSON_OPTIONS"
  [ -f "$TMP_FILE_STORAGE" ] && /bin/rm -rf "$TMP_FILE_STORAGE"
  [ -f "$DIALOG_COMMAND_FILE" ] && /bin/rm -rf "$DIALOG_COMMAND_FILE"
  exit "$exitcode"
}

# Run a command in the logged-in user's Aqua session with a clean env
runAsUser() {
  local USER_ID
  USER_ID="$(/usr/bin/id -u "$LOGGED_IN_USER")"
  /bin/launchctl asuser "$USER_ID" /usr/bin/env -i \
    HOME="$USER_DIR" \
    USER="$LOGGED_IN_USER" \
    LOGNAME="$LOGGED_IN_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@"
}

# Map a TCC key → pref pane & dialog message (no jq needed)
pane_and_message_for_key() {
  local key="$1"
  case "$key" in
    kTCCServiceScreenCapture)
      PREF_SCREEN="Privacy_ScreenCapture"
      MESSAGE="Please approve the **Screen & Audio Recordings** for *$APP_NAME*. This lets others view your screen or lets you record screens."
      ;;
    kTCCServiceCamera)
      PREF_SCREEN="Privacy_Camera"
      MESSAGE="Please allow the **Camera** for *$APP_NAME*. This lets others see you during meetings."
      ;;
    kTCCServiceMicrophone)
      PREF_SCREEN="Privacy_Microphone"
      MESSAGE="Please allow the **Microphone** for *$APP_NAME*. This lets others hear you during meetings."
      ;;
    kTCCServiceSystemPolicyAllFiles)
      PREF_SCREEN="Privacy_FilesAndFolders"
      MESSAGE="Please approve **Files & Folders** for *$APP_NAME* so it can access necessary files."
      ;;
    kTCCServiceAccessibility)
      PREF_SCREEN="Privacy_Accessibility"
      MESSAGE="Please allow **Accessibility** for *$APP_NAME* so automation actions can work properly."
      ;;
    *)
      PREF_SCREEN="Privacy_ScreenCapture"
      MESSAGE="Please enable the required privacy permission for *$APP_NAME*."
      ;;
  esac
}

# Show swiftDialog popup first
welcomemsg() {
  local message="$1"
  local display_lower
  display_lower="$(printf "%s" "$DISPLAY_TYPE" | tr '[:upper:]' '[:lower:]')"

  local dlg_args=(
    --message "$message"
    --titlefont shadow=1
    --ontop
    --icon "$SD_ICON_FILE"
    --overlayicon "$OVERLAY_ICON"
    --bannerimage "$SD_BANNER_IMAGE"
    --bannertitle "$SD_WINDOW_TITLE"
    --infobox "$SD_INFO_BOX_MSG"
    --helpmessage "This setting needs to be set for this particular app so it will work properly"
    --ignorednd
    --width 680
    --moveable
    --quitkey 0
    --button1text "OK"
  )
  [ "$display_lower" = "mini" ] && dlg_args+=(--mini)

  logMe "DEBUG: Launching Dialog via open -a in user context…"
  runAsUser /usr/bin/open -a "$DIALOG_APP" --args "${dlg_args[@]}"
}

# Query TCC
Check_TCC() {
  local key="$1"
  local bid="$2"

  if [ "$tccKeyDB" = "User" ]; then
    logMe "Querying user TCC database for $key"
    tccKeyStatus="$(sqlite3 "$USER_DIR/Library/Application Support/com.apple.TCC/TCC.db" "SELECT * FROM access WHERE service like '$key'" | grep "$bid" | awk -F '|' '{print $4}')"
    tccApproval="$bid"
    if [ "$tccKeyStatus" = "2" ]; then
      tccKeyStatus="on"
    elif [ "$tccKeyStatus" = "0" ]; then
      tccKeyStatus="off"
    else
      tccApproval=""
    fi
  else
    logMe "Querying system TCC database for $key"
    tccApproval="$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT client FROM access WHERE service like '$key' AND auth_value = '2'" | grep -o "$bid")"
    [ -n "$tccApproval" ] && tccKeyStatus="on"
  fi
}

get_app_details() {
  local key="$1"

  if [ ! -e "$APP_PATH" ]; then
    logMe "INFO: Could not find $APP_NAME at $APP_PATH. Exiting."
    cleanup_and_exit 0
  fi

  if ! echo "$bundleID" | grep -Eq '^[A-Za-z0-9]+[.-].*'; then
    logMe "WARNING: Invalid bundleID for $APP_NAME at $APP_PATH!"
    cleanup_and_exit 1
  fi

  Check_TCC "$key" "$bundleID"

  TCCresults="0"
  if [ "$tccKeyDB" = "User" ]; then
    if [ -z "$tccApproval" ]; then
      logMe "WARNING: $key should be in User TCC, but not found. App may need to be launched once."
      TCCresults="1"
      return 1
    else
      if [ "$tccKeyStatus" = "off" ]; then
        logMe "INFO: $key in User TCC but not approved for $APP_NAME"
      else
        logMe "INFO: $key in User TCC and already approved for $APP_NAME"
      fi
      return 0
    fi
  fi

  if [ "$tccApproval" = "$bundleID" ]; then
    logMe "INFO: ${PREF_SCREEN} already approved for $APP_NAME"
    tccKeyStatus="on"
    return 0
  fi

  logMe "${PREF_SCREEN} not yet approved for $APP_NAME"
  logMe "INFO: Valid application found, continuing"
}

# =========================
# Main
# =========================
create_log_directory

if [ -z "$LOGGED_IN_USER" ] || [ "$LOGGED_IN_USER" = "loginwindow" ]; then
  logMe "INFO: No user logged in"
  cleanup_and_exit 0
fi

check_support_files

# ✅ Ensure swiftDialog app/binary exists before proceeding
if [ ! -d "$DIALOG_APP" ]; then
  logMe "ERROR: SwiftDialog app not found at $DIALOG_APP. Exiting script."
  cleanup_and_exit 1
fi

if [ ! -x "$SW_DIALOG" ]; then
  logMe "ERROR: SwiftDialog binary not found or not executable at $SW_DIALOG. Exiting script."
  cleanup_and_exit 1
fi

# Normalize app path and gather info
case "$APP_PATH" in *.app) : ;; *) APP_PATH="${APP_PATH}.app" ;; esac
if [ ! -e "$APP_PATH" ]; then
  logMe "INFO: The Application $APP_PATH is not installed"
  cleanup_and_exit 0
fi
APP_NAME="$(basename "$APP_PATH" .app)"
SD_ICON_FILE="$APP_PATH"
bundleID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
logMe "Bundle ID for $APP_NAME is $bundleID"

# Keys that live in user TCC (for routing queries)
userTCCServices="kTCCServiceAddressBook kTCCServiceAppleEvents kTCCServiceBluetoothAlways kTCCServiceCalendar kTCCServiceCamera kTCCServiceFileProviderDomain kTCCServiceLiverpool kTCCServiceMicrophone kTCCServicePhotos kTCCServiceReminders kTCCServiceSystemPolicyAppBundles kTCCServiceSystemPolicyAppData kTCCServiceSystemPolicyDesktopFolder kTCCServiceSystemPolicyDocumentsFolder kTCCServiceSystemPolicyDownloadsFolder kTCCServiceSystemPolicyNetworkVolumes kTCCServiceSystemPolicyRemovableVolumes kTCCServiceUbiquity kTCCServiceWebBrowserPublicKeyCredential"

# Split TCC_KEY
IFS=' ' read -r -a TCC_KEY_ARRAY <<< "$TCC_KEY"

for key in "${TCC_KEY_ARRAY[@]}"; do
  if echo "$userTCCServices" | grep -qw "$key"; then
    tccKeyDB="User"
  else
    tccKeyDB="System"
  fi

  # Map pane + message
  pane_and_message_for_key "$key"
  # MINI mode strips markdown asterisks
  if [ "$(printf "%s" "$DISPLAY_TYPE" | tr '[:upper:]' '[:lower:]')" = "mini" ]; then
    MESSAGE="$(printf "%s" "$MESSAGE" | tr -d '*')"
  fi

  get_app_details "$key"

  # Skip if the user TCC row doesn't exist yet (likely first-launch issue)
  if [ "$TCCresults" = "1" ]; then
    logMe "Skipping $key for now. Continuing…"
    continue
  fi

  dialogAttempts=0
  until [ "$tccApproval" = "$bundleID" ] && [ "$tccKeyStatus" = "on" ]; do
    if [ "$dialogAttempts" -ge "$MAX_ATTEMPTS" ]; then
      logMe "Prompts ignored after $MAX_ATTEMPTS attempts. Giving up."
      cleanup_and_exit 1
    fi

    logMe "Requesting user to manually approve ${PREF_SCREEN} for $APP_NAME…"
    runAsUser /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?${PREF_SCREEN}"

    # Show the dialog prompt (user session)
    welcomemsg "$MESSAGE"

    sleep "$SLEEP_TIME"
    dialogAttempts=$((dialogAttempts + 1))

    logMe "Re-checking approval for ${PREF_SCREEN}…"
    Check_TCC "$key" "$bundleID"
  done

  logMe "INFO: ${key} for $APP_NAME has been approved!"
done

runAsUser /usr/bin/osascript -e 'quit app "System Settings"'
cleanup_and_exit 0