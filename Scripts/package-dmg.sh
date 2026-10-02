#!/bin/sh
set -eu

# Build a certificate-backed Auralis disk image.
#
# Default: an explicitly labeled, unnotarized community/development DMG.
# Official release: REQUIRE_NOTARIZATION=YES NOTARY_PROFILE=<profile> ...
#
# Ad-hoc and unsigned apps are intentionally rejected. Auralis needs a stable
# designated requirement for Screen Recording, WidgetKit, and App Group access.

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/prebuilt.sh"

cleanup() {
    if [ "${DMG_MOUNTED:-NO}" = YES ] && [ -n "${MOUNT_ROOT:-}" ]; then
        /usr/bin/hdiutil detach "$MOUNT_ROOT" >/dev/null 2>&1 ||
            /usr/bin/hdiutil detach -force "$MOUNT_ROOT" >/dev/null 2>&1 || true
        DMG_MOUNTED=NO
    fi
    if [ -n "${PACKAGE_ROOT:-}" ] && [ -d "$PACKAGE_ROOT" ]; then
        case "$PACKAGE_ROOT" in
            "$OUTPUT_DIRECTORY"/.auralis-dmg-package.*) /bin/rm -rf "$PACKAGE_ROOT" ;;
            *) printf 'warning: refusing to clean unexpected temporary path: %s\n' "$PACKAGE_ROOT" >&2 ;;
        esac
    fi
}

cd "$REPOSITORY_ROOT"
auralis_load_versions

SKIP_BUILD=${SKIP_BUILD:-NO}
REQUIRE_NOTARIZATION=${REQUIRE_NOTARIZATION:-NO}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
OUTPUT_DIRECTORY=${OUTPUT_DIRECTORY:-$REPOSITORY_ROOT/.build/release}
APP_PATH=${APP_PATH:-$REPOSITORY_ROOT/.build/products/Release/$APP_PRODUCT_NAME.app}
DMG_TEMPLATE_DIRECTORY=$REPOSITORY_ROOT/packaging/dmg

case "$SKIP_BUILD" in YES|NO) ;; *) fail "SKIP_BUILD must be YES or NO" ;; esac
case "$REQUIRE_NOTARIZATION" in YES|NO) ;; *) fail "REQUIRE_NOTARIZATION must be YES or NO" ;; esac
if [ "$REQUIRE_NOTARIZATION" = YES ] && [ -z "$NOTARY_PROFILE" ]; then
    fail "NOTARY_PROFILE is required when REQUIRE_NOTARIZATION=YES"
fi
if [ "$REQUIRE_NOTARIZATION" = NO ] && [ -n "$NOTARY_PROFILE" ]; then
    fail "NOTARY_PROFILE was provided but REQUIRE_NOTARIZATION is not YES"
fi

require_macos_arm64
require_command codesign
require_command ditto
require_command hdiutil
require_command lipo
require_command plutil
require_command shasum
require_command spctl
require_command xcrun
require_file "$DMG_TEMPLATE_DIRECTORY/Install Auralis.command"
require_file "$DMG_TEMPLATE_DIRECTORY/READ ME.txt"

if [ "$SKIP_BUILD" = NO ]; then
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES "$SCRIPT_DIR/build-release-app.sh"
fi

[ -d "$APP_PATH" ] || fail "release app not found: $APP_PATH"
VALIDATE_ONLY=YES \
    COPY_VALIDATED_APP=NO \
    BUILT_APP_OVERRIDE="$APP_PATH" \
    CONFIGURATION=Release \
    RUN_TESTS=NO \
    CODE_SIGNING_ALLOWED=YES \
    "$SCRIPT_DIR/build-release-app.sh"
auralis_validate_signed_app "$APP_PATH"

if [ "$REQUIRE_NOTARIZATION" = YES ] && [ "$AURALIS_APP_SIGNATURE_KIND" != developer-id ]; then
    fail "notarized DMGs require a Developer ID Application signature; found '$AURALIS_APP_SIGNATURE_AUTHORITY'"
fi

/bin/mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY=$(CDPATH='' cd -- "$OUTPUT_DIRECTORY" && pwd)
PACKAGE_ROOT=$(/usr/bin/mktemp -d "$OUTPUT_DIRECTORY/.auralis-dmg-package.XXXXXX") ||
    fail "could not create DMG staging directory"
STAGING_ROOT=$PACKAGE_ROOT/staging
MOUNT_ROOT=$PACKAGE_ROOT/mount
NOTARY_ZIP=$PACKAGE_ROOT/Auralis-notary.zip
DMG_MOUNTED=NO
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/bin/mkdir -p "$STAGING_ROOT" "$MOUNT_ROOT"

if [ "$REQUIRE_NOTARIZATION" = YES ]; then
    printf '==> Notarizing the app before creating the disk image\n'
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP" ||
        fail "could not create notarization upload"
    /usr/bin/xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    /usr/bin/xcrun stapler staple "$APP_PATH"
    /usr/bin/xcrun stapler validate "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
    DMG_NAME=$(auralis_dist_dmg_name "$MARKETING_VERSION")
    DMG_EDITION="Developer ID signed and Apple-notarized"
else
    DMG_NAME=$(auralis_dist_unnotarized_dmg_name "$MARKETING_VERSION")
    DMG_EDITION="certificate-backed but NOT Apple-notarized"
fi

DMG_PATH=$OUTPUT_DIRECTORY/$DMG_NAME
CHECKSUM_PATH=$OUTPUT_DIRECTORY/$(auralis_dist_dmg_checksum_name "$MARKETING_VERSION" "$REQUIRE_NOTARIZATION")

printf '==> Staging %s\n' "$DMG_NAME"
/usr/bin/ditto "$APP_PATH" "$STAGING_ROOT/$APP_PRODUCT_NAME.app" ||
    fail "could not stage Auralis.app"
/bin/cp "$DMG_TEMPLATE_DIRECTORY/Install Auralis.command" "$STAGING_ROOT/Install Auralis.command"
/bin/chmod 0755 "$STAGING_ROOT/Install Auralis.command"
/usr/bin/sed \
    -e "s/@VERSION@/$MARKETING_VERSION/g" \
    -e "s/@EDITION@/$DMG_EDITION/g" \
    "$DMG_TEMPLATE_DIRECTORY/READ ME.txt" >"$STAGING_ROOT/READ ME.txt"
/bin/ln -s /Applications "$STAGING_ROOT/Applications"
/bin/sh -n "$STAGING_ROOT/Install Auralis.command"
auralis_validate_signed_app "$STAGING_ROOT/$APP_PRODUCT_NAME.app"

/bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH"
/usr/bin/hdiutil create \
    -volname "Auralis $MARKETING_VERSION" \
    -srcfolder "$STAGING_ROOT" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH" >/dev/null || fail "could not create $DMG_PATH"

if [ "$REQUIRE_NOTARIZATION" = YES ]; then
    printf '==> Notarizing the disk image\n'
    /usr/bin/xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
    /usr/bin/xcrun stapler validate "$DMG_PATH"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
else
    printf 'warning: this DMG is not notarized and Gatekeeper may require Open Anyway\n' >&2
fi

printf '==> Verifying the finished disk image\n'
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null || fail "disk image verification failed"
/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_ROOT" \
    "$DMG_PATH" >/dev/null || fail "could not mount finished disk image"
DMG_MOUNTED=YES
[ -L "$MOUNT_ROOT/Applications" ] || fail "disk image has no Applications link"
[ "$(/usr/bin/readlink "$MOUNT_ROOT/Applications")" = /Applications ] ||
    fail "disk image Applications link has an unexpected target"
[ -f "$MOUNT_ROOT/READ ME.txt" ] || fail "disk image has no instructions"
[ -x "$MOUNT_ROOT/Install Auralis.command" ] || fail "disk image installer is not executable"
/bin/sh -n "$MOUNT_ROOT/Install Auralis.command"
auralis_validate_signed_app "$MOUNT_ROOT/$APP_PRODUCT_NAME.app"
if [ "$REQUIRE_NOTARIZATION" = YES ]; then
    /usr/sbin/spctl --assess --type execute --verbose=4 "$MOUNT_ROOT/$APP_PRODUCT_NAME.app"
fi
/usr/bin/hdiutil detach "$MOUNT_ROOT" >/dev/null || fail "could not unmount finished disk image"
DMG_MOUNTED=NO

(cd "$OUTPUT_DIRECTORY" && /usr/bin/shasum -a 256 "$DMG_NAME") >"$CHECKSUM_PATH" ||
    fail "could not write $CHECKSUM_PATH"
(cd "$OUTPUT_DIRECTORY" && /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$CHECKSUM_PATH")") ||
    fail "DMG checksum verification failed"

printf '==> DMG package validated\n'
printf '    edition:  %s\n' "$DMG_EDITION"
printf '    dmg:      %s\n' "$DMG_PATH"
printf '    checksum: %s\n' "$CHECKSUM_PATH"
