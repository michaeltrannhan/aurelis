#!/bin/sh
set -eu

# Download a GitHub release archive, verify SHA-256, and unpack Auralis.app.
# Does not compile. Default is unpack-only so install.sh can place the bundle.
# Naming/unpack: Scripts/lib/prebuilt.sh. Called by Scripts/install-app.sh.
#
# Usage:
#   Scripts/install-prebuilt.sh [--version VER] [--output DIR] [--zip|--tarball]
#   Scripts/install-prebuilt.sh --user|--system [--version VER] [--no-launch]
#   Scripts/install-prebuilt.sh --allow-missing   # exit 3 if no release (install-app.sh)
#
# --user / --system copy the unpacked app into ~/Applications or /Applications.
# Without those flags the app is left under --output (default .build/prebuilt).
# Prefers a local .build/release zip from package-release.sh when present.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/prebuilt.sh"

usage() {
    printf 'usage: %s [--version VER] [--output DIR] [--zip|--tarball] [--allow-missing]\n' "$0" >&2
    printf '       %s --user|--system [--version VER] [--no-launch] [--allow-missing]\n' "$0" >&2
    exit 2
}

cd "$REPOSITORY_ROOT"

VERSION=${AURALIS_DIST_VERSION:-}
OUTPUT_DIRECTORY=${OUTPUT_DIRECTORY:-$REPOSITORY_ROOT/.build/prebuilt}
ARCHIVE_KIND=zip
INSTALL_SCOPE=
LAUNCH_APP=YES
ALLOW_MISSING=NO

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || usage
            VERSION=$2
            shift
            ;;
        --output)
            [ $# -ge 2 ] || usage
            OUTPUT_DIRECTORY=$2
            shift
            ;;
        --zip) ARCHIVE_KIND=zip ;;
        --tarball) ARCHIVE_KIND=tarball ;;
        --system) INSTALL_SCOPE=system ;;
        --user) INSTALL_SCOPE=user ;;
        --no-launch) LAUNCH_APP=NO ;;
        --allow-missing) ALLOW_MISSING=YES ;;
        --yes|-y) AURALIS_YES=YES ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

auralis_dist_require_arm64
require_command curl

exit_no_prebuilt() {
    printf '==> No prebuilt Auralis release found\n' >&2
    exit 3
}

local_asset_path() {
    printf '%s/%s\n' "$REPOSITORY_ROOT/.build/release" "$1"
}

resolve_version() {
    if [ -n "$VERSION" ]; then
        return 0
    fi
    auralis_load_versions
    case "$ARCHIVE_KIND" in
        zip) local_name=$(auralis_dist_zip_name "$MARKETING_VERSION") ;;
        tarball) local_name=$(auralis_dist_tarball_name "$MARKETING_VERSION") ;;
    esac
    if [ -f "$(local_asset_path "$local_name")" ]; then
        VERSION=$MARKETING_VERSION
        return 0
    fi
    if VERSION=$(auralis_dist_latest_version 2>/dev/null); then
        return 0
    fi
    if [ "$ALLOW_MISSING" = YES ]; then
        exit_no_prebuilt
    fi
    VERSION=$(auralis_dist_latest_version)
}

resolve_version

case "$ARCHIVE_KIND" in
    zip) ASSET=$(auralis_dist_zip_name "$VERSION") ;;
    tarball) ASSET=$(auralis_dist_tarball_name "$VERSION") ;;
    *) fail "unknown archive kind: $ARCHIVE_KIND" ;;
esac
CHECKSUMS=$(auralis_dist_checksums_name "$VERSION")

DOWNLOAD_ROOT=$OUTPUT_DIRECTORY/download
UNPACK_ROOT=$OUTPUT_DIRECTORY/unpack
LOCAL_ASSET=$(local_asset_path "$ASSET")
LOCAL_CHECKSUMS=$(local_asset_path "$CHECKSUMS")
/bin/mkdir -p "$DOWNLOAD_ROOT" "$UNPACK_ROOT"
/bin/rm -rf "$UNPACK_ROOT"
/bin/mkdir -p "$UNPACK_ROOT"

if [ -f "$LOCAL_ASSET" ]; then
    printf '==> Using local prebuilt %s\n' "$LOCAL_ASSET"
    /bin/cp "$LOCAL_ASSET" "$DOWNLOAD_ROOT/$ASSET"
    if [ -f "$LOCAL_CHECKSUMS" ]; then
        /bin/cp "$LOCAL_CHECKSUMS" "$DOWNLOAD_ROOT/$CHECKSUMS"
        auralis_dist_verify_asset "$DOWNLOAD_ROOT/$CHECKSUMS" "$DOWNLOAD_ROOT" "$ASSET"
    else
        printf 'warning: no local %s; relying on code signature\n' "$CHECKSUMS" >&2
    fi
else
    printf '==> Downloading Auralis %s (%s)\n' "$VERSION" "$ASSET"
    if ! curl -fsSL "$(auralis_dist_asset_url "$VERSION" "$ASSET")" \
        -o "$DOWNLOAD_ROOT/$ASSET"; then
        [ "$ALLOW_MISSING" = YES ] && exit_no_prebuilt
        fail "could not download $(auralis_dist_asset_url "$VERSION" "$ASSET")"
    fi
    if ! curl -fsSL "$(auralis_dist_asset_url "$VERSION" "$CHECKSUMS")" \
        -o "$DOWNLOAD_ROOT/$CHECKSUMS"; then
        [ "$ALLOW_MISSING" = YES ] && exit_no_prebuilt
        fail "could not download $(auralis_dist_asset_url "$VERSION" "$CHECKSUMS")"
    fi
    auralis_dist_verify_asset "$DOWNLOAD_ROOT/$CHECKSUMS" "$DOWNLOAD_ROOT" "$ASSET"
fi

printf '==> Unpacking %s\n' "$ASSET"
case "$ARCHIVE_KIND" in
    zip) auralis_dist_unpack_zip "$DOWNLOAD_ROOT/$ASSET" "$UNPACK_ROOT" ;;
    tarball) auralis_dist_unpack_tarball "$DOWNLOAD_ROOT/$ASSET" "$UNPACK_ROOT" ;;
esac

EXTRACTED_APP=$UNPACK_ROOT/$APP_PRODUCT_NAME.app
[ -d "$EXTRACTED_APP" ] ||
    fail "archive did not contain $APP_PRODUCT_NAME.app at its root"
/usr/bin/codesign --verify --deep --strict "$EXTRACTED_APP" ||
    fail "unpacked app failed signature verification"

STAGED_APP=$OUTPUT_DIRECTORY/$APP_PRODUCT_NAME.app
/bin/rm -rf "$STAGED_APP"
/usr/bin/ditto "$EXTRACTED_APP" "$STAGED_APP"

printf '==> Staged %s\n' "$STAGED_APP"

if [ -z "$INSTALL_SCOPE" ]; then
    printf '    Copy to ~/Applications or /Applications, or re-run with --user/--system.\n'
    exit 0
fi

auralis_install_bundle "$STAGED_APP" "$INSTALL_SCOPE" "$LAUNCH_APP"
