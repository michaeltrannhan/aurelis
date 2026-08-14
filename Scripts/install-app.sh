#!/bin/sh
# Install Auralis. Tries Scripts/install-prebuilt.sh first; otherwise builds.
#
# Usage:
#   ./install.sh
#   Scripts/install-app.sh [--system|--user] [--from-source|--prebuilt]
#                          [--skip-build] [--no-launch] [--yes]
#
# Fast path: Scripts/install-prebuilt.sh (GitHub release zip via lib/prebuilt.sh,
# or a local .build/release artifact). Skips cleanly to source if nothing is
# published yet. --prebuilt requires that path. --from-source skips it.
# --yes / non-TTY / CI=true: no prompts.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$REPOSITORY_ROOT"
require_macos_arm64

usage() {
    printf 'usage: %s [--system|--user] [--from-source|--prebuilt] [--skip-build] [--no-launch] [--yes]\n' "$0" >&2
    exit 2
}

INSTALL_SCOPE=system
SKIP_BUILD=${SKIP_BUILD:-NO}
LAUNCH_APP=${LAUNCH_APP:-YES}
INSTALL_MODE=auto

while [ $# -gt 0 ]; do
    case "$1" in
        --system) INSTALL_SCOPE=system ;;
        --user) INSTALL_SCOPE=user ;;
        --skip-build) SKIP_BUILD=YES ;;
        --no-launch) LAUNCH_APP=NO ;;
        --from-source) INSTALL_MODE=source ;;
        --prebuilt) INSTALL_MODE=prebuilt ;;
        --yes|-y) export AURALIS_YES=YES ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done
if auralis_noninteractive; then
    export AURALIS_YES=YES
fi

case "$SKIP_BUILD" in YES|NO) ;; *) fail "SKIP_BUILD must be YES or NO" ;; esac
case "$LAUNCH_APP" in YES|NO) ;; *) fail "LAUNCH_APP must be YES or NO" ;; esac
if [ "$SKIP_BUILD" = YES ] && [ "$INSTALL_MODE" = prebuilt ]; then
    fail "--skip-build and --prebuilt cannot be combined"
fi
if [ "$SKIP_BUILD" = YES ] && [ "$INSTALL_MODE" = source ]; then
    fail "--skip-build and --from-source cannot be combined"
fi

BUILT_APP=$REPOSITORY_ROOT/.build/products/Release/$APP_PRODUCT_NAME.app

build_from_source() {
    printf '==> Building signed Release app from source\n'
    require_xcode_toolchain
    ensure_xcodegen
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/build-release-app.sh"
}

try_prebuilt_install() {
    prebuilt_args="--$INSTALL_SCOPE"
    [ "$LAUNCH_APP" = NO ] && prebuilt_args="$prebuilt_args --no-launch"
    [ "$INSTALL_MODE" = prebuilt ] || prebuilt_args="$prebuilt_args --allow-missing"
    # shellcheck disable=SC2086
    "$SCRIPT_DIR/install-prebuilt.sh" $prebuilt_args
}

if [ "$SKIP_BUILD" = YES ]; then
    printf '==> Reusing existing Release build\n'
    [ -d "$BUILT_APP" ] || fail "release app not found: $BUILT_APP (run without --skip-build)"
    auralis_install_bundle "$BUILT_APP" "$INSTALL_SCOPE" "$LAUNCH_APP"
    print_install_next_steps
    exit 0
fi

if [ "$INSTALL_MODE" != source ]; then
    set +e
    try_prebuilt_install
    prebuilt_status=$?
    set -e
    case "$prebuilt_status" in
        0)
            print_install_next_steps
            exit 0
            ;;
        3)
            [ "$INSTALL_MODE" = prebuilt ] &&
                fail "no prebuilt Auralis release was found"
            printf '==> No prebuilt release found; building from source\n'
            ;;
        *)
            exit "$prebuilt_status"
            ;;
    esac
fi

build_from_source
[ -d "$BUILT_APP" ] || fail "release app not found: $BUILT_APP"
auralis_install_bundle "$BUILT_APP" "$INSTALL_SCOPE" "$LAUNCH_APP"
print_install_next_steps
