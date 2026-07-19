#!/bin/sh
set -eu

# Build the diagnostics-enabled Debug app and embedded widget. Build/test logs
# and app runtime diagnostics stay under .build/logs in this repository.

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

case "${CONFIGURATION:-Debug}" in
    Debug) ;;
    *) fail "build-debug-app.sh only builds Debug; use Scripts/build-release-app.sh for Release" ;;
esac

RUN_APP=${RUN_APP:-NO}
case "$RUN_APP" in
    YES|NO) ;;
    *) fail "RUN_APP must be YES or NO" ;;
esac

if [ "$RUN_APP" = YES ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != YES ]; then
    fail "RUN_APP=YES requires CODE_SIGNING_ALLOWED=YES for WidgetKit and App Group IPC"
fi

APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
OUTPUT_APP_OVERRIDE=${OUTPUT_APP_OVERRIDE:-$REPOSITORY_ROOT/.build/products/Debug/$APP_PRODUCT_NAME.app}
AURALIS_DEBUG_LOG_PATH=${AURALIS_DEBUG_LOG_PATH:-$REPOSITORY_ROOT/.build/logs/runtime/Auralis-debug.log}

CONFIGURATION=Debug \
OUTPUT_APP_OVERRIDE="$OUTPUT_APP_OVERRIDE" \
AURALIS_DEBUG_LOG_PATH="$AURALIS_DEBUG_LOG_PATH" \
AURALIS_DIAGNOSTICS_MODE=detailed \
LOG_VARIANT=${LOG_VARIANT:-debug} \
    "$SCRIPT_DIR/build-app.sh"

if [ "$RUN_APP" = YES ]; then
    SKIP_BUILD=YES APP_PATH="$OUTPUT_APP_OVERRIDE" \
        "$SCRIPT_DIR/run-debug-app.sh"
fi
