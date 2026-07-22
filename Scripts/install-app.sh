#!/bin/sh
set -eu

# Build the signed Release app and install it as a real application bundle.
# Default target is /Applications (all users, may prompt for permission).
# Use --user to install into ~/Applications instead (no admin needed).
#
# Usage:
#   Scripts/install-app.sh [--system|--user] [--skip-build] [--no-launch]
#
# Environment overrides mirror the other entry points:
#   DEVELOPMENT_TEAM, SIGN_IDENTITY, ALLOW_PROVISIONING_UPDATES,
#   CODE_SIGNING_ALLOWED, APP_PRODUCT_NAME, APP_BUNDLE_ID, WIDGET_BUNDLE_ID

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s [--system|--user] [--skip-build] [--no-launch]\n' "$0" >&2
    exit 2
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
APP_BUNDLE_ID=${APP_BUNDLE_ID:-com.michaeltrannhan.Auralis}
INSTALL_SCOPE=system
SKIP_BUILD=${SKIP_BUILD:-NO}
LAUNCH_APP=${LAUNCH_APP:-YES}

while [ $# -gt 0 ]; do
    case "$1" in
        --system) INSTALL_SCOPE=system ;;
        --user) INSTALL_SCOPE=user ;;
        --skip-build) SKIP_BUILD=YES ;;
        --no-launch) LAUNCH_APP=NO ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

case "$INSTALL_SCOPE" in
    system)
        INSTALL_DIR=/Applications
        OTHER_APP=$HOME/Applications/$APP_PRODUCT_NAME.app
        ;;
    user)
        INSTALL_DIR=$HOME/Applications
        OTHER_APP=/Applications/$APP_PRODUCT_NAME.app
        ;;
esac

# Two copies share one bundle identifier: Launch Services and WidgetKit would
# show duplicate entries and pick an arbitrary host for AppIntents.
if [ -d "$OTHER_APP" ]; then
    other_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
        "$OTHER_APP/Contents/Info.plist" 2>/dev/null || true)
    [ "$other_id" = "$APP_BUNDLE_ID" ] &&
        fail "$APP_PRODUCT_NAME is already installed at $OTHER_APP; remove it first (duplicate bundle identifiers break the widget gallery)"
fi
case "$SKIP_BUILD" in YES|NO) ;; *) fail "SKIP_BUILD must be YES or NO" ;; esac
case "$LAUNCH_APP" in YES|NO) ;; *) fail "LAUNCH_APP must be YES or NO" ;; esac

BUILT_APP=$REPOSITORY_ROOT/.build/products/Release/$APP_PRODUCT_NAME.app
TARGET_APP=$INSTALL_DIR/$APP_PRODUCT_NAME.app

if [ "$SKIP_BUILD" = NO ]; then
    printf '==> Building signed Release app\n'
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/build-release-app.sh"
fi

[ -d "$BUILT_APP" ] || fail "release app not found: $BUILT_APP (run without --skip-build)"

# A running instance keeps old code resident and can republish a stale widget
# registration while the bundle is being replaced.
/usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true

/bin/mkdir -p "$INSTALL_DIR" ||
    fail "cannot create $INSTALL_DIR (check permissions)"
[ -w "$INSTALL_DIR" ] ||
    fail "cannot write to $INSTALL_DIR (try --user for a per-user install)"

if [ -d "$TARGET_APP" ]; then
    printf '==> Replacing %s\n' "$TARGET_APP"
    /bin/rm -rf "$TARGET_APP" ||
        fail "cannot replace $TARGET_APP (is it in use by another user?)"
fi

/usr/bin/ditto "$BUILT_APP" "$TARGET_APP" ||
    fail "could not copy the app to $INSTALL_DIR"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP" ||
    fail "installed app failed signature verification"

printf '==> Installed %s\n' "$TARGET_APP"

# Register the app and its widget with Launch Services/WidgetKit, clear the
# widget discovery cache, and relaunch when requested.
APP_PATH="$TARGET_APP" RELAUNCH_APP="$LAUNCH_APP" \
    "$SCRIPT_DIR/refresh-widget-gallery.sh"

printf '==> Done. Next steps:\n'
printf '    1. Grant Screen & System Audio Recording when prompted.\n'
printf '    2. Grant Accessibility when prompted.\n'
printf '    3. Click the date/time in the menu bar -> Edit Widgets -> search Auralis.\n'
