#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

MIN_PHYSICAL_OUTPUTS=${MIN_PHYSICAL_OUTPUTS:-2}
BUILD_DIRECTORY=$REPOSITORY_ROOT/.build/verification
PROBE=$BUILD_DIRECTORY/EQMacRepHardwarePreflight

case "$MIN_PHYSICAL_OUTPUTS" in
    ''|*[!0-9]*)
        printf 'error: MIN_PHYSICAL_OUTPUTS must be a nonnegative integer\n' >&2
        exit 64
        ;;
esac

command -v xcrun >/dev/null 2>&1 || {
    printf 'error: xcrun is required\n' >&2
    exit 1
}

/bin/mkdir -p "$BUILD_DIRECTORY"
xcrun swiftc "$SCRIPT_DIR/HardwarePreflight.swift" \
    -framework CoreAudio \
    -o "$PROBE"
"$PROBE" "$MIN_PHYSICAL_OUTPUTS"
