#!/bin/sh
# Canonical local/dev/install entry for Auralis.
#   Scripts/auralis.sh {install|build|test|dev|verify|release|preflight|xcodegen}
# Stable wrappers: ./install.sh, Scripts/install-app.sh, make install|build|test

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    printf 'usage: %s {install|build|test|dev|verify|release|preflight|xcodegen} [args]\n' "$0" >&2
    printf '  install     Install the app (prebuilt fast path, else source)\n' >&2
    printf '  build       Build Release (or: build debug|release)\n' >&2
    printf '  test        SwiftPM tests (swift test)\n' >&2
    printf '  verify      Verification gates (see Scripts/run-verification.sh)\n' >&2
    printf '  dev         Build and run the Debug app\n' >&2
    printf '  release     Package/notarize the Release zip\n' >&2
    printf '  preflight   Toolchain checks (CI)\n' >&2
    printf '  xcodegen    Install pinned XcodeGen\n' >&2
    exit 2
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
    install)
        exec "$SCRIPT_DIR/install-app.sh" "$@"
        ;;
    build)
        case "${1:-release}" in
            debug)
                shift
                exec "$SCRIPT_DIR/build-debug-app.sh" "$@"
                ;;
            release|"")
                [ "${1:-}" = release ] && shift
                exec "$SCRIPT_DIR/build-release-app.sh" "$@"
                ;;
            *)
                fail "build expects debug or release"
                ;;
        esac
        ;;
    test)
        cd "$REPOSITORY_ROOT"
        exec swift test "$@"
        ;;
    verify)
        exec "$SCRIPT_DIR/run-verification.sh" "$@"
        ;;
    dev)
        RUN_APP=YES exec "$SCRIPT_DIR/build-debug-app.sh" "$@"
        ;;
    release)
        exec "$SCRIPT_DIR/package-release.sh" "$@"
        ;;
    preflight)
        exec "$SCRIPT_DIR/ci-preflight.sh" "$@"
        ;;
    xcodegen)
        exec "$SCRIPT_DIR/install-xcodegen-ci.sh" "$@"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        printf 'error: unknown command: %s\n' "$cmd" >&2
        usage
        ;;
esac
