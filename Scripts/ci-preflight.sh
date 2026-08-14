#!/bin/sh
# Stable CI entry point. Implementation: auralis_ci_preflight in Scripts/lib.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$REPOSITORY_ROOT"
auralis_ci_preflight
