#!/bin/sh
set -eu

# Clear macOS's per-user widget discovery cache, register the stable Auralis
# extension path, and optionally relaunch the host app. This repairs the case
# where chronod remembers a disposable Xcode DerivedData bundle after it has
# been removed by the build.

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
WIDGET_NAME=${WIDGET_NAME:-AuralisWidget}
APP_BUNDLE_ID=${APP_BUNDLE_ID:-com.michaeltrannhan.Auralis}
WIDGET_BUNDLE_ID=${WIDGET_BUNDLE_ID:-com.michaeltrannhan.Auralis.Widget}
DEBUG_APPLICATIONS_DIR=${DEBUG_APPLICATIONS_DIR:-/Applications}
APP_PATH=${APP_PATH:-$DEBUG_APPLICATIONS_DIR/$APP_PRODUCT_NAME-Debug.app}
RELAUNCH_APP=${RELAUNCH_APP:-YES}

case "$RELAUNCH_APP" in
    YES|NO) ;;
    *) fail "RELAUNCH_APP must be YES or NO" ;;
esac

case "$APP_PATH" in
    /*) ;;
    *) APP_PATH=$REPOSITORY_ROOT/$APP_PATH ;;
esac

WIDGET_PATH=$APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex
APP_INFO=$APP_PATH/Contents/Info.plist
WIDGET_INFO=$WIDGET_PATH/Contents/Info.plist
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$APP_PATH" ] || fail "app not found: $APP_PATH"
[ -d "$WIDGET_PATH" ] || fail "embedded widget not found: $WIDGET_PATH"
[ -f "$APP_INFO" ] || fail "app Info.plist not found: $APP_INFO"
[ -f "$WIDGET_INFO" ] || fail "widget Info.plist not found: $WIDGET_INFO"
[ -x "$LSREGISTER" ] || fail "Launch Services registration tool not found: $LSREGISTER"

actual_app_bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_INFO")
[ "$actual_app_bundle_id" = "$APP_BUNDLE_ID" ] ||
    fail "app bundle identifier is '$actual_app_bundle_id'; expected '$APP_BUNDLE_ID'"
actual_widget_bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$WIDGET_INFO")
[ "$actual_widget_bundle_id" = "$WIDGET_BUNDLE_ID" ] ||
    fail "widget bundle identifier is '$actual_widget_bundle_id'; expected '$WIDGET_BUNDLE_ID'"

unregister_disposable_app_records() {
    disposable_root=$REPOSITORY_ROOT/.build
    [ -d "$disposable_root" ] || return 0

    # Xcode test products and verifier fault copies use the production bundle
    # identifiers. Launch Services can retain one of those paths even after
    # pluginkit reports only the stable extension registration.
    /usr/bin/find "$disposable_root" -type d -name '*.app' -prune -print |
        while IFS= read -r candidate_app; do
            candidate_info=$candidate_app/Contents/Info.plist
            [ -f "$candidate_info" ] || continue
            candidate_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
                "$candidate_info" 2>/dev/null || true)
            case "$candidate_id" in
                "$APP_BUNDLE_ID"|"$WIDGET_BUNDLE_ID") ;;
                *) continue ;;
            esac
            /usr/bin/pluginkit -r \
                "$candidate_app/Contents/PlugIns/$WIDGET_NAME.appex" \
                >/dev/null 2>&1 || true
            "$LSREGISTER" -u "$candidate_app" >/dev/null 2>&1 || true
        done

    /usr/bin/find "$disposable_root" -type d -name "$WIDGET_NAME.appex" -prune -print |
        while IFS= read -r candidate_widget; do
            /usr/bin/pluginkit -r "$candidate_widget" >/dev/null 2>&1 || true
        done
}

/usr/bin/codesign --verify --strict "$WIDGET_PATH" >/dev/null 2>&1 ||
    fail "widget signature is invalid; run Scripts/build-debug-app.sh first"
/usr/bin/codesign --verify --strict "$APP_PATH" >/dev/null 2>&1 ||
    fail "app signature is invalid; run Scripts/build-debug-app.sh first"

printf '==> Refreshing Auralis widget registration\n'
printf '    widget: %s\n' "$WIDGET_PATH"

# A running host can immediately republish the old extension registration.
/usr/bin/osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true
/usr/bin/pluginkit -r "$WIDGET_PATH" >/dev/null 2>&1 || true
unregister_disposable_app_records

# chronod owns WidgetKit discovery/timelines; NotificationCenter owns the macOS
# widget gallery. Both are per-user services and launchd restarts them on demand.
/usr/bin/killall chronod >/dev/null 2>&1 || true
/usr/bin/killall NotificationCenter >/dev/null 2>&1 || true

# Register the containing application before its embedded extension. AppIntent
# execution resolves the archived intent type through the parent app's Launch
# Services record; registering only the nested appex can leave linkd unable to
# issue access to the extension after an in-place development replacement.
"$LSREGISTER" -f "$APP_PATH" ||
    fail "macOS rejected the containing app registration"
/usr/bin/pluginkit -a "$WIDGET_PATH" ||
    fail "macOS rejected the widget registration"

registrations=$(/usr/bin/pluginkit -m -A -D -v -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true)
registration_count=$(printf '%s\n' "$registrations" |
    /usr/bin/grep -F -c "$WIDGET_BUNDLE_ID(" || true)
[ "$registration_count" -eq 1 ] || {
    printf '%s\n' "$registrations" >&2
    fail "expected one widget registration; found $registration_count"
}
printf '%s\n' "$registrations" | /usr/bin/grep -F "$WIDGET_PATH" >/dev/null || {
    printf '%s\n' "$registrations" >&2
    fail "widget registered from an unexpected path"
}

if [ "$RELAUNCH_APP" = YES ]; then
    /usr/bin/open -n "$APP_PATH"
    printf '==> Relaunched Auralis\n'
fi

printf '==> Widget registration refreshed\n'
printf '    Close and reopen Edit Widgets, then search for Auralis.\n'
