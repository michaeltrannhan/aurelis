#!/bin/sh
set -eu

APP_NAME=Auralis.app
APP_BUNDLE_ID=com.michaeltrannhan.Auralis
WIDGET_BUNDLE_ID=com.michaeltrannhan.Auralis.Widget
SCRIPT_DIRECTORY=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SOURCE_APP=$SCRIPT_DIRECTORY/$APP_NAME
INSTALL_DIRECTORY=$HOME/Applications
TARGET_APP=$INSTALL_DIRECTORY/$APP_NAME
SYSTEM_APP=/Applications/$APP_NAME
STAGED_APP=$INSTALL_DIRECTORY/.Auralis.installing.$$
BACKUP_APP=
OLD_MOVED=NO
NEW_INSTALLED=NO
INSTALL_SUCCEEDED=NO
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() {
    printf '\nInstallation stopped: %s\n' "$*" >&2
    printf 'Nothing outside ~/Applications was changed.\n' >&2
    exit 1
}

bundle_identifier() {
    /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

validate_bundle_architecture() {
    bundle_path=$1
    description=$2
    executable_name=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - \
        "$bundle_path/Contents/Info.plist" 2>/dev/null) ||
        fail "could not read the $description executable name"
    architectures=$(/usr/bin/lipo -archs "$bundle_path/Contents/MacOS/$executable_name" 2>/dev/null) ||
        fail "could not inspect the $description architecture"
    [ "$architectures" = arm64 ] ||
        fail "$description must contain arm64 only (found '$architectures')"
}

inspect_signature() {
    bundle_path=$1
    description=$2
    /usr/bin/codesign --verify --deep --strict "$bundle_path" ||
        fail "$description failed code-signature verification"
    metadata=$(/usr/bin/codesign -dv --verbose=4 "$bundle_path" 2>&1) ||
        fail "could not inspect the $description signature"
    authority=$(printf '%s\n' "$metadata" |
        /usr/bin/awk -F= '/^Authority=/ { print substr($0, index($0, "=") + 1); exit }')
    SIGNING_TEAM=$(printf '%s\n' "$metadata" |
        /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2; exit }')
    case "$authority" in
        "Developer ID Application:"*) SIGNATURE_KIND=developer-id ;;
        "Apple Development:"*) SIGNATURE_KIND=development ;;
        *) fail "$description is unsigned, ad-hoc signed, or signed by an unsupported certificate" ;;
    esac
    [ -n "$SIGNING_TEAM" ] || fail "$description signature has no TeamIdentifier"
    printf '%s\n' "$metadata" |
        /usr/bin/grep -q '^CodeDirectory .*flags=.*(runtime)' ||
        fail "$description does not use the hardened runtime"
}

validate_app() {
    app_path=$1
    widget_path=$app_path/Contents/PlugIns/AuralisWidget.appex
    [ -d "$app_path" ] || fail "Auralis.app is missing from this disk image"
    [ -d "$widget_path" ] || fail "the Auralis widget is missing"
    [ "$(bundle_identifier "$app_path" || true)" = "$APP_BUNDLE_ID" ] ||
        fail "the app has an unexpected bundle identifier"
    [ "$(bundle_identifier "$widget_path" || true)" = "$WIDGET_BUNDLE_ID" ] ||
        fail "the widget has an unexpected bundle identifier"
    validate_bundle_architecture "$app_path" app
    validate_bundle_architecture "$widget_path" widget
    inspect_signature "$app_path" app
    app_team=$SIGNING_TEAM
    app_signature_kind=$SIGNATURE_KIND
    inspect_signature "$widget_path" widget
    [ "$SIGNING_TEAM" = "$app_team" ] || fail "the app and widget use different signing teams"
    [ "$SIGNATURE_KIND" = "$app_signature_kind" ] ||
        fail "the app and widget use different signing certificate classes"
}

remove_staged_copy() {
    if [ -d "$STAGED_APP" ]; then
        case "$STAGED_APP" in
            "$INSTALL_DIRECTORY"/.Auralis.installing.[0-9]*) /bin/rm -rf "$STAGED_APP" ;;
            *) printf 'warning: refusing to remove unexpected staging path: %s\n' "$STAGED_APP" >&2 ;;
        esac
    fi
}

rollback_if_needed() {
    remove_staged_copy
    if [ "$INSTALL_SUCCEEDED" != YES ]; then
        if [ "$NEW_INSTALLED" = YES ] && [ -d "$TARGET_APP" ]; then
            /bin/rm -rf "$TARGET_APP"
        fi
        if [ "$OLD_MOVED" = YES ] && [ -n "$BACKUP_APP" ] && [ -d "$BACKUP_APP" ] && [ ! -e "$TARGET_APP" ]; then
            /bin/mv "$BACKUP_APP" "$TARGET_APP" || true
        fi
    fi
}
trap rollback_if_needed EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf '\nAuralis guided installer\n'
printf '========================\n\n'
printf 'This installs Auralis for your user at:\n  %s\n\n' "$TARGET_APP"
printf 'It verifies the app, widget, Apple certificate, hardened runtime, and arm64 architecture.\n'
printf 'It does not disable Gatekeeper or change system-wide security settings.\n\n'

validate_app "$SOURCE_APP"

if [ -e "$SYSTEM_APP" ] || [ -L "$SYSTEM_APP" ]; then
    fail "another Auralis copy exists at $SYSTEM_APP; remove it first to avoid duplicate widgets"
fi
if [ -L "$TARGET_APP" ]; then
    fail "$TARGET_APP is a symbolic link; remove it manually before installing"
fi
if [ -e "$TARGET_APP" ] && [ "$(bundle_identifier "$TARGET_APP" || true)" != "$APP_BUNDLE_ID" ]; then
    fail "$TARGET_APP is not an Auralis bundle and will not be replaced"
fi

if /usr/sbin/spctl --assess --type execute "$SOURCE_APP" >/dev/null 2>&1; then
    GATEKEEPER_STATUS=accepted
    printf 'Gatekeeper assessment: accepted.\n'
else
    GATEKEEPER_STATUS=manual
    printf 'Gatekeeper assessment: this build is not Apple-notarized.\n'
    printf 'macOS may require System Settings > Privacy & Security > Open Anyway after the first launch attempt.\n'
fi

printf '\nOnly continue if this DMG came from a source you trust and its external SHA-256 matches.\n'
printf 'Type INSTALL to continue: '
IFS= read -r confirmation || fail "could not read confirmation"
[ "$confirmation" = INSTALL ] || fail "confirmation did not match INSTALL"

/bin/mkdir -p "$INSTALL_DIRECTORY" || fail "could not create $INSTALL_DIRECTORY"
[ -w "$INSTALL_DIRECTORY" ] || fail "$INSTALL_DIRECTORY is not writable"
[ ! -e "$STAGED_APP" ] || fail "temporary install path already exists: $STAGED_APP"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP" || fail "could not copy Auralis into the staging area"
validate_app "$STAGED_APP"

/usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

if [ -d "$TARGET_APP" ]; then
    /bin/mkdir -p "$HOME/.Trash"
    BACKUP_APP=$HOME/.Trash/Auralis-backup-$(/bin/date +%Y%m%d-%H%M%S)-$$.app
    [ ! -e "$BACKUP_APP" ] || fail "backup path already exists: $BACKUP_APP"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$TARGET_APP" >/dev/null 2>&1 || true
    fi
    /usr/bin/pluginkit -r "$TARGET_APP/Contents/PlugIns/AuralisWidget.appex" >/dev/null 2>&1 || true
    /bin/mv "$TARGET_APP" "$BACKUP_APP" || fail "could not move the previous app to the Trash"
    OLD_MOVED=YES
fi

/bin/mv "$STAGED_APP" "$TARGET_APP" || fail "could not move Auralis into $INSTALL_DIRECTORY"
NEW_INSTALLED=YES
validate_app "$TARGET_APP"

if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 ||
        printf 'warning: Launch Services registration failed; log out and back in if the widget is missing.\n' >&2
fi
/usr/bin/pluginkit -a "$TARGET_APP/Contents/PlugIns/AuralisWidget.appex" >/dev/null 2>&1 ||
    printf 'warning: WidgetKit registration will be retried when Auralis launches.\n' >&2

INSTALL_SUCCEEDED=YES
trap - EXIT HUP INT TERM

printf '\nInstalled and verified: %s\n' "$TARGET_APP"
if [ -n "$BACKUP_APP" ]; then
    printf 'Previous version moved to: %s\n' "$BACKUP_APP"
fi

/usr/bin/open "$TARGET_APP" >/dev/null 2>&1 || true
if [ "$GATEKEEPER_STATUS" = manual ]; then
    printf '\nIf macOS blocked the launch:\n'
    printf '  1. Open System Settings > Privacy & Security.\n'
    printf '  2. Find the Auralis message and click Open Anyway.\n'
    printf '  3. Confirm Open, then launch Auralis again.\n'
fi
printf '\nThen grant Screen & System Audio Recording and Accessibility when prompted.\n'
printf 'Add the widget from Notification Center > Edit Widgets.\n\n'
