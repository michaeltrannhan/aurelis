#!/bin/sh
set -eu

# Build and validate the Release app and embedded widget. Release products do
# not receive a repo-local runtime log path or compile DEBUG diagnostics.

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

case "${CONFIGURATION:-Release}" in
    Release) ;;
    *) fail "build-release-app.sh only builds Release; use Scripts/build-debug-app.sh for Debug" ;;
esac

APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
RUN_TESTS=${RUN_TESTS:-NO}
OUTPUT_APP_OVERRIDE=${OUTPUT_APP_OVERRIDE:-$REPOSITORY_ROOT/.build/products/Release/$APP_PRODUCT_NAME.app}

CONFIGURATION=Release \
RUN_TESTS="$RUN_TESTS" \
OUTPUT_APP_OVERRIDE="$OUTPUT_APP_OVERRIDE" \
AURALIS_DEBUG_LOG_PATH= \
AURALIS_DIAGNOSTICS_MODE=minimal \
LOG_VARIANT=${LOG_VARIANT:-release} \
    "$SCRIPT_DIR/build-app.sh"
