#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_distribution_signature() {
    bundle_path=$1
    description=$2
    metadata=$(/usr/bin/codesign -dv --verbose=4 "$bundle_path" 2>&1) ||
        fail "could not inspect $description signature"
    printf '%s\n' "$metadata" |
        /usr/bin/grep -q '^Authority=Developer ID Application:' ||
        fail "$description requires a Developer ID Application signature"
    printf '%s\n' "$metadata" |
        /usr/bin/grep -q '^CodeDirectory .*flags=.*(runtime)' ||
        fail "$description does not enable the hardened runtime"
}

validate_distribution_product() {
    product_path=$1
    widget_path=$product_path/Contents/PlugIns/$WIDGET_NAME.appex

    VALIDATE_ONLY=YES \
        COPY_VALIDATED_APP=NO \
        BUILT_APP_OVERRIDE="$product_path" \
        CONFIGURATION=Release \
        RUN_TESTS=NO \
        CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/build-debug-app.sh"

    require_distribution_signature "$product_path" "app"
    require_distribution_signature "$widget_path" "embedded widget"
}

cleanup() {
    if [ -n "${ARCHIVE_VALIDATION_ROOT:-}" ] && [ -d "$ARCHIVE_VALIDATION_ROOT" ]; then
        /bin/rm -rf "$ARCHIVE_VALIDATION_ROOT"
    fi
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
WIDGET_NAME=${WIDGET_NAME:-AuralisWidget}
MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION:-1}
SKIP_BUILD=${SKIP_BUILD:-NO}
REQUIRE_NOTARIZATION=${REQUIRE_NOTARIZATION:-YES}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
OUTPUT_DIRECTORY=${OUTPUT_DIRECTORY:-$REPOSITORY_ROOT/.build/release}
APP_PATH=${APP_PATH:-$REPOSITORY_ROOT/.build/$APP_PRODUCT_NAME.app}
WIDGET_PATH=$APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex
ARCHIVE_PATH=$OUTPUT_DIRECTORY/$APP_PRODUCT_NAME-$MARKETING_VERSION-$CURRENT_PROJECT_VERSION.zip
ARCHIVE_VALIDATION_ROOT=

case "$SKIP_BUILD" in YES|NO) ;; *) fail "SKIP_BUILD must be YES or NO" ;; esac
case "$REQUIRE_NOTARIZATION" in YES|NO) ;; *) fail "REQUIRE_NOTARIZATION must be YES or NO" ;; esac

if [ "$REQUIRE_NOTARIZATION" = YES ] && [ -z "$NOTARY_PROFILE" ]; then
    fail "NOTARY_PROFILE is required when REQUIRE_NOTARIZATION=YES"
fi

require_command codesign
require_command ditto
require_command xcrun
require_command spctl

if [ "$SKIP_BUILD" = NO ]; then
    CONFIGURATION=Release RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/build-debug-app.sh"
fi

[ -d "$APP_PATH" ] || fail "release app not found: $APP_PATH"
[ -d "$WIDGET_PATH" ] || fail "embedded widget not found: $WIDGET_PATH"
validate_distribution_product "$APP_PATH"

/bin/mkdir -p "$OUTPUT_DIRECTORY"
/bin/rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

if [ -n "$NOTARY_PROFILE" ]; then
    printf '==> Submitting %s for notarization\n' "$ARCHIVE_PATH"
    xcrun notarytool submit "$ARCHIVE_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    /bin/rm -f "$ARCHIVE_PATH"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
else
    printf 'warning: notarization skipped because REQUIRE_NOTARIZATION=NO\n' >&2
fi

ARCHIVE_VALIDATION_ROOT=$(/usr/bin/mktemp -d "$OUTPUT_DIRECTORY/.auralis-archive-validation.XXXXXX") ||
    fail "could not create archive validation directory"
trap cleanup EXIT HUP INT TERM
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$ARCHIVE_VALIDATION_ROOT" ||
    fail "could not extract release archive for validation"
EXTRACTED_APP=$ARCHIVE_VALIDATION_ROOT/$APP_PRODUCT_NAME.app
[ -d "$EXTRACTED_APP" ] || fail "release archive does not contain $APP_PRODUCT_NAME.app at its root"
validate_distribution_product "$EXTRACTED_APP"

if [ -n "$NOTARY_PROFILE" ]; then
    xcrun stapler validate "$EXTRACTED_APP"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"
fi

printf '==> Release package validated: %s\n' "$ARCHIVE_PATH"
