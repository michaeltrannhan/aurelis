#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$REPOSITORY_ROOT"

MIN_PHYSICAL_OUTPUTS=${MIN_PHYSICAL_OUTPUTS:-2}
BUILD_DIRECTORY=$REPOSITORY_ROOT/.build/verification
PROBE=$BUILD_DIRECTORY/AuralisHardwarePreflight

case "$MIN_PHYSICAL_OUTPUTS" in
    ''|*[!0-9]*)
        printf 'error: MIN_PHYSICAL_OUTPUTS must be a nonnegative integer\n' >&2
        exit 64
        ;;
esac

require_command xcrun

/bin/mkdir -p "$BUILD_DIRECTORY"
xcrun swiftc "$SCRIPT_DIR/HardwarePreflight.swift" \
    -framework CoreAudio \
    -o "$PROBE"
"$PROBE" "$MIN_PHYSICAL_OUTPUTS"
