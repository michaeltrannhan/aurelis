#!/bin/sh
set -eu

# Install the Debug app at a stable Applications path, launch it, and capture
# app/widget unified logs for the complete active session. Keeping the widget
# at one durable path avoids stale Launch Services and WidgetKit registrations
# as disposable repository and DerivedData products are replaced.

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
SOURCE_APP_PATH=${APP_PATH:-$REPOSITORY_ROOT/.build/products/Debug/$APP_PRODUCT_NAME.app}
DEBUG_APPLICATIONS_DIR=${DEBUG_APPLICATIONS_DIR:-/Applications}
INSTALLED_APP_PATH=${INSTALLED_APP_PATH:-$DEBUG_APPLICATIONS_DIR/$APP_PRODUCT_NAME-Debug.app}
SKIP_BUILD=${SKIP_BUILD:-NO}
DEPLOY_APP=${DEPLOY_APP:-YES}
LOG_DIR=${LOG_DIR:-$REPOSITORY_ROOT/.build/logs/runtime}
LOG_SUBSYSTEM=${LOG_SUBSYSTEM:-com.michaeltrannhan.Auralis}
APP_BUNDLE_ID=${APP_BUNDLE_ID:-com.michaeltrannhan.Auralis}
WIDGET_BUNDLE_ID=${WIDGET_BUNDLE_ID:-com.michaeltrannhan.Auralis.Widget}
WIDGET_PROCESS_NAME=${WIDGET_PROCESS_NAME:-AuralisWidget}
REFRESH_WIDGET_GALLERY=${REFRESH_WIDGET_GALLERY:-YES}
if [ -z "${LOG_PREDICATE:-}" ]; then
    # Keep every Auralis event, but include system services only when they emit
    # a genuine error/fault (or an explicit sandbox denial). Broad terms such
    # as "invalid" or "connection" also match normal RunningBoard teardown and
    # can flood `log stream`, causing the useful application events to drop.
    LOG_PREDICATE="subsystem == '$LOG_SUBSYSTEM' OR (process == '$WIDGET_PROCESS_NAME' AND (messageType == error OR messageType == fault)) OR (process == 'linkd' AND (eventMessage CONTAINS[c] '$APP_BUNDLE_ID' OR eventMessage CONTAINS[c] '$WIDGET_BUNDLE_ID' OR eventMessage CONTAINS[c] '$WIDGET_PROCESS_NAME') AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] 'unable to issue sandbox extension')) OR ((process == 'intents_helper' OR process == 'appintentsd' OR process == 'chronod') AND (eventMessage CONTAINS[c] '$APP_BUNDLE_ID' OR eventMessage CONTAINS[c] '$WIDGET_BUNDLE_ID' OR eventMessage CONTAINS[c] '$WIDGET_PROCESS_NAME') AND (messageType == error OR messageType == fault)) OR (process == 'tccd' AND eventMessage CONTAINS[c] '$WIDGET_PROCESS_NAME' AND eventMessage CONTAINS[c] 'failed to create LSApplicationRecord') OR ((process == 'sandboxd' OR process == 'kernel') AND (eventMessage CONTAINS[c] '$APP_BUNDLE_ID' OR eventMessage CONTAINS[c] '$WIDGET_BUNDLE_ID' OR eventMessage CONTAINS[c] '$WIDGET_PROCESS_NAME') AND eventMessage CONTAINS[c] 'file-issue-extension')"
fi

case "$SKIP_BUILD" in
    YES|NO) ;;
    *) fail "SKIP_BUILD must be YES or NO" ;;
esac

case "$DEPLOY_APP" in
    YES|NO) ;;
    *) fail "DEPLOY_APP must be YES or NO" ;;
esac

case "$REFRESH_WIDGET_GALLERY" in
    YES|NO) ;;
    *) fail "REFRESH_WIDGET_GALLERY must be YES or NO" ;;
esac

if [ "$SKIP_BUILD" = NO ]; then
    RUN_APP=NO "$SCRIPT_DIR/build-debug-app.sh"
fi

[ -d "$SOURCE_APP_PATH" ] || fail "debug app not found: $SOURCE_APP_PATH"

if [ "$DEPLOY_APP" = YES ]; then
    case "$INSTALLED_APP_PATH" in
        /*.app) ;;
        *) fail "INSTALLED_APP_PATH must be an absolute .app path" ;;
    esac
    installed_app_name=$(basename -- "$INSTALLED_APP_PATH")
    [ "$installed_app_name" != .app ] || fail "INSTALLED_APP_PATH must name a concrete app bundle"
    INSTALLED_WIDGET_PATH=$INSTALLED_APP_PATH/Contents/PlugIns/$WIDGET_PROCESS_NAME.appex
    STAGED_APP_PATH=$INSTALLED_APP_PATH.auralis-staging
    LEGACY_USER_APP_PATH=$HOME/Applications/$APP_PRODUCT_NAME-Debug.app

    # Stop the previous instance before replacing its signed bundle. This also
    # prevents Launch Services from retaining the repository build as the
    # currently-running application for this bundle identifier.
    /usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" \
        >/dev/null 2>&1 || true
    if [ -d "$INSTALLED_WIDGET_PATH" ]; then
        /usr/bin/pluginkit -r "$INSTALLED_WIDGET_PATH" >/dev/null 2>&1 || true
    fi
    if [ "$LEGACY_USER_APP_PATH" != "$INSTALLED_APP_PATH" ] && [ -d "$LEGACY_USER_APP_PATH" ]; then
        /usr/bin/pluginkit -r \
            "$LEGACY_USER_APP_PATH/Contents/PlugIns/$WIDGET_PROCESS_NAME.appex" \
            >/dev/null 2>&1 || true
        /bin/rm -rf "$LEGACY_USER_APP_PATH"
    fi
    /bin/mkdir -p "$(dirname -- "$INSTALLED_APP_PATH")"
    /bin/rm -rf "$STAGED_APP_PATH"
    /usr/bin/ditto "$SOURCE_APP_PATH" "$STAGED_APP_PATH"
    /bin/rm -rf "$INSTALLED_APP_PATH"
    /bin/mv "$STAGED_APP_PATH" "$INSTALLED_APP_PATH"
    APP_PATH=$INSTALLED_APP_PATH
    printf '==> Installed interactive Debug app at %s\n' "$APP_PATH"
else
    APP_PATH=$SOURCE_APP_PATH
    printf 'warning: DEPLOY_APP=NO may prevent macOS from loading widget App Intents from a protected development folder\n' >&2
fi

if [ "$REFRESH_WIDGET_GALLERY" = YES ]; then
    RELAUNCH_APP=NO APP_PATH="$APP_PATH" \
        "$SCRIPT_DIR/refresh-widget-gallery.sh"
fi
/bin/mkdir -p "$LOG_DIR"
SESSION_ID=$(/bin/date -u '+%Y%m%dT%H%M%SZ')
SESSION_LOG=$LOG_DIR/Auralis-unified-$SESSION_ID.log

printf '==> Capturing app and widget logs at %s\n' "$SESSION_LOG"
# Detailed host operations are persisted by InternalDiagnostics. The unified
# session stays at info level so macOS does not drop useful Auralis/widget
# events while processing the machine-wide debug firehose.
/usr/bin/log stream --style compact --level info \
    --predicate "$LOG_PREDICATE" \
    >"$SESSION_LOG" 2>&1 &
LOG_PID=$!

cleanup() {
    /bin/kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf '==> Launching %s; log capture ends when the app exits\n' "$APP_PATH"
/usr/bin/open -n -W "$APP_PATH"
printf '==> Debug session log saved: %s\n' "$SESSION_LOG"
