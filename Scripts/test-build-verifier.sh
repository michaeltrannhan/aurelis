#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

CONFIGURATION=${CONFIGURATION:-Release}
CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-NO}
APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
WIDGET_NAME=${WIDGET_NAME:-AuralisWidget}
FAULT_ID=$(/usr/bin/uuidgen)
FAULT_ROOT=$REPOSITORY_ROOT/.build/verifier-self-test/$FAULT_ID
LOG_ROOT=$REPOSITORY_ROOT/.build/logs/verifier-self-test/$FAULT_ID
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

cleanup_fault_products() {
    if [ -d "$FAULT_ROOT" ]; then
        /usr/bin/find "$FAULT_ROOT" -type d -name "$WIDGET_NAME.appex" -prune -print |
            while IFS= read -r widget_path; do
                /usr/bin/pluginkit -r "$widget_path" >/dev/null 2>&1 || true
            done
        if [ -x "$LSREGISTER" ]; then
            /usr/bin/find "$FAULT_ROOT" -type d -name '*.app' -prune -print |
                while IFS= read -r app_path; do
                    "$LSREGISTER" -u "$app_path" >/dev/null 2>&1 || true
                done
        fi
        /bin/rm -rf "$FAULT_ROOT"
    fi
}

trap cleanup_fault_products EXIT

case "$CONFIGURATION" in
    Debug)
        BUILD_SCRIPT=$SCRIPT_DIR/build-debug-app.sh
        DEFAULT_BASE_APP=$REPOSITORY_ROOT/.build/products/Debug/$APP_PRODUCT_NAME.app
        ;;
    Release)
        BUILD_SCRIPT=$SCRIPT_DIR/build-release-app.sh
        DEFAULT_BASE_APP=$REPOSITORY_ROOT/.build/products/Release/$APP_PRODUCT_NAME.app
        ;;
    *) fail "CONFIGURATION must be Debug or Release" ;;
esac
BASE_APP=${BASE_APP:-$DEFAULT_BASE_APP}

[ -d "$BASE_APP" ] || fail "validated base app not found: $BASE_APP"
/bin/mkdir -p "$LOG_ROOT"

expect_failure() {
    label=$1
    shift
    log_path=$LOG_ROOT/$label.log
    set +e
    "$@" >"$log_path" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$label fault was accepted unexpectedly"
    /usr/bin/grep -q '^error:' "$log_path" ||
        fail "$label fault failed without a verifier error (log: $log_path)"
    printf '    rejected: %s\n' "$label"
}

validate_app() {
    candidate=$1
    env \
        VALIDATE_ONLY=YES \
        COPY_VALIDATED_APP=NO \
        BUILT_APP_OVERRIDE="$candidate" \
        CONFIGURATION="$CONFIGURATION" \
        RUN_TESTS=NO \
        REQUIRE_APP_GROUP_SMOKE=NO \
        CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
        "$BUILD_SCRIPT"
}

printf '==> Verifier self-test (%s, signing: %s)\n' "$CONFIGURATION" "$CODE_SIGNING_ALLOWED"
validate_app "$BASE_APP" >/dev/null

REPLACEMENT_APP=$FAULT_ROOT/replacement-output.app
REPLACEMENT_SENTINEL=$REPLACEMENT_APP/Contents/stale-file-that-must-not-survive
/bin/mkdir -p "$REPLACEMENT_APP/Contents"
/usr/bin/touch "$REPLACEMENT_SENTINEL"
env \
    VALIDATE_ONLY=YES \
    COPY_VALIDATED_APP=YES \
    OUTPUT_APP_OVERRIDE="$REPLACEMENT_APP" \
    BUILT_APP_OVERRIDE="$BASE_APP" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    "$BUILD_SCRIPT" >/dev/null
[ ! -e "$REPLACEMENT_SENTINEL" ] || fail "validated copy retained a stale destination file"
printf '    verified: clean product replacement\n'

BASE_COPY=$FAULT_ROOT/base.app
/usr/bin/ditto "$BASE_APP" "$BASE_COPY"

expect_failure build-failure env \
    ARCHS=auralis-invalid-architecture \
    LOG_VARIANT=verifier-build-failure \
    BUILD_ROOT_OVERRIDE="$FAULT_ROOT/build-failure-derived" \
    OUTPUT_APP_OVERRIDE="$FAULT_ROOT/build-failure-output.app" \
    CONFIGURATION=Debug \
    RUN_TESTS=NO \
    CODE_SIGNING_ALLOWED=NO \
    "$SCRIPT_DIR/build-debug-app.sh"
[ -d "$BASE_APP" ] || fail "build-failure fault removed the validated base app"

PLIST_APP=$FAULT_ROOT/plist.app
/usr/bin/ditto "$BASE_COPY" "$PLIST_APP"
/usr/bin/plutil -replace CFBundlePackageType -string BNDL "$PLIST_APP/Contents/Info.plist"
expect_failure plist validate_app "$PLIST_APP"

BRANDING_APP=$FAULT_ROOT/branding.app
/usr/bin/ditto "$BASE_COPY" "$BRANDING_APP"
/usr/bin/plutil -replace CFBundleDisplayName -string 'Wrong Brand' "$BRANDING_APP/Contents/Info.plist"
expect_failure branding validate_app "$BRANDING_APP"

URL_SCHEME_APP=$FAULT_ROOT/url-scheme.app
/usr/bin/ditto "$BASE_COPY" "$URL_SCHEME_APP"
/usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string wrong-scheme \
    "$URL_SCHEME_APP/Contents/Info.plist"
expect_failure url-scheme validate_app "$URL_SCHEME_APP"

APP_ICON_APP=$FAULT_ROOT/app-icon.app
/usr/bin/ditto "$BASE_COPY" "$APP_ICON_APP"
/bin/rm -f "$APP_ICON_APP/Contents/Resources/AppIcon.icns"
expect_failure app-icon validate_app "$APP_ICON_APP"

APP_ASSETS_APP=$FAULT_ROOT/app-assets.app
/usr/bin/ditto "$BASE_COPY" "$APP_ASSETS_APP"
/bin/rm -f "$APP_ASSETS_APP/Contents/Resources/Assets.car"
expect_failure app-assets validate_app "$APP_ASSETS_APP"

WIDGET_ASSETS_APP=$FAULT_ROOT/widget-assets.app
/usr/bin/ditto "$BASE_COPY" "$WIDGET_ASSETS_APP"
/bin/rm -f "$WIDGET_ASSETS_APP/Contents/PlugIns/$WIDGET_NAME.appex/Contents/Resources/Assets.car"
expect_failure widget-assets validate_app "$WIDGET_ASSETS_APP"

INTENT_METADATA_APP=$FAULT_ROOT/intent-metadata.app
/usr/bin/ditto "$BASE_COPY" "$INTENT_METADATA_APP"
INTENT_METADATA=$INTENT_METADATA_APP/Contents/PlugIns/$WIDGET_NAME.appex/Contents/Resources/Metadata.appintents/extract.actionsdata
/usr/bin/plutil -replace actions.SetAppMutedIntent.parameters -json '[]' "$INTENT_METADATA"
expect_failure intent-metadata validate_app "$INTENT_METADATA_APP"

EMBEDDING_APP=$FAULT_ROOT/embedding.app
/usr/bin/ditto "$BASE_COPY" "$EMBEDDING_APP"
/bin/rm -rf "$EMBEDDING_APP/Contents/PlugIns/$WIDGET_NAME.appex"
expect_failure embedding validate_app "$EMBEDDING_APP"

expect_failure architecture env \
    VALIDATE_ONLY=YES \
    BUILT_APP_OVERRIDE="$BASE_COPY" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    ARCHS=x86_64 \
    "$BUILD_SCRIPT"

expect_failure bundle-identifier env \
    VALIDATE_ONLY=YES \
    BUILT_APP_OVERRIDE="$BASE_COPY" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    APP_BUNDLE_ID=com.example.invalid \
    "$BUILD_SCRIPT"

expect_failure entitlement env \
    VALIDATE_ONLY=YES \
    COPY_VALIDATED_APP=NO \
    BUILT_APP_OVERRIDE="$BASE_COPY" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    APP_GROUP_ID=com.example.invalid.group \
    "$BUILD_SCRIPT"

expect_failure notary-configuration env \
    SKIP_BUILD=YES \
    REQUIRE_NOTARIZATION=YES \
    NOTARY_PROFILE= \
    APP_PATH="$BASE_COPY" \
    OUTPUT_DIRECTORY="$FAULT_ROOT/notary-package" \
    "$SCRIPT_DIR/package-release.sh"

if [ "$CODE_SIGNING_ALLOWED" = YES ]; then
    SIGNATURE_APP=$FAULT_ROOT/signature.app
    /usr/bin/ditto "$BASE_COPY" "$SIGNATURE_APP"
    /usr/bin/plutil -insert AuralisVerifierFault -bool true "$SIGNATURE_APP/Contents/Info.plist"
    expect_failure signature validate_app "$SIGNATURE_APP"

    expect_failure distribution-authority env \
        SKIP_BUILD=YES \
        REQUIRE_NOTARIZATION=NO \
        APP_PATH="$BASE_COPY" \
        OUTPUT_DIRECTORY="$FAULT_ROOT/developer-id-package" \
        "$SCRIPT_DIR/package-release.sh"
fi

printf '==> Verifier self-test passed (logs: %s)\n' "$LOG_ROOT"
