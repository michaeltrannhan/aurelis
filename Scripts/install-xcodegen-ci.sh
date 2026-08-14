#!/bin/sh
# Stable CI entry point. Implementation: ensure_xcodegen in Scripts/lib.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
ensure_xcodegen
