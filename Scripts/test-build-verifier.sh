#!/bin/sh
set -eu

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

CONFIGURATION=${CONFIGURATION:-Release}
CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-NO}
APP_NAME=${APP_NAME:-EQMacRep}
WIDGET_NAME=${WIDGET_NAME:-EQMacRepWidget}
BASE_APP=${BASE_APP:-$REPOSITORY_ROOT/.build/xcode/$CONFIGURATION/BuildDerivedData/Build/Products/$CONFIGURATION/$APP_NAME.app}
FAULT_ROOT=$REPOSITORY_ROOT/.build/verifier-self-test/$(/usr/bin/uuidgen)
LOG_ROOT=$FAULT_ROOT/logs

[ -d "$BASE_APP" ] || fail "validated base app not found: $BASE_APP"
/bin/mkdir -p "$LOG_ROOT"

expect_failure() {
    label=$1
    shift
    log_path=$LOG_ROOT/$label.log
    set +e
    "$@" >"$log_path" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "$label fault was accepted unexpectedly"
    /usr/bin/grep -q '^error:' "$log_path" ||
        fail "$label fault failed without a verifier error (log: $log_path)"
    printf '    rejected: %s\n' "$label"
}

validate_app() {
    candidate=$1
    env \
        VALIDATE_ONLY=YES \
        COPY_VALIDATED_APP=NO \
        BUILT_APP_OVERRIDE="$candidate" \
        CONFIGURATION="$CONFIGURATION" \
        RUN_TESTS=NO \
        REQUIRE_APP_GROUP_SMOKE=NO \
        CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
        "$SCRIPT_DIR/build-debug-app.sh"
}

printf '==> Verifier self-test (%s, signing: %s)\n' "$CONFIGURATION" "$CODE_SIGNING_ALLOWED"
validate_app "$BASE_APP" >/dev/null

REPLACEMENT_APP=$FAULT_ROOT/replacement-output.app
REPLACEMENT_SENTINEL=$REPLACEMENT_APP/Contents/stale-file-that-must-not-survive
/bin/mkdir -p "$REPLACEMENT_APP/Contents"
/usr/bin/touch "$REPLACEMENT_SENTINEL"
env \
    VALIDATE_ONLY=YES \
    COPY_VALIDATED_APP=YES \
    OUTPUT_APP_OVERRIDE="$REPLACEMENT_APP" \
    BUILT_APP_OVERRIDE="$BASE_APP" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    "$SCRIPT_DIR/build-debug-app.sh" >/dev/null
[ ! -e "$REPLACEMENT_SENTINEL" ] || fail "validated copy retained a stale destination file"
printf '    verified: clean product replacement\n'

BASE_COPY=$FAULT_ROOT/base.app
/usr/bin/ditto "$BASE_APP" "$BASE_COPY"

expect_failure build-failure env \
    ARCHS=eqmacrep-invalid-architecture \
    LOG_VARIANT=verifier-build-failure \
    CONFIGURATION=Debug \
    RUN_TESTS=NO \
    CODE_SIGNING_ALLOWED=NO \
    "$SCRIPT_DIR/build-debug-app.sh"

PLIST_APP=$FAULT_ROOT/plist.app
/usr/bin/ditto "$BASE_COPY" "$PLIST_APP"
/usr/bin/plutil -replace CFBundlePackageType -string BNDL "$PLIST_APP/Contents/Info.plist"
expect_failure plist validate_app "$PLIST_APP"

EMBEDDING_APP=$FAULT_ROOT/embedding.app
/usr/bin/ditto "$BASE_COPY" "$EMBEDDING_APP"
/bin/rm -rf "$EMBEDDING_APP/Contents/PlugIns/$WIDGET_NAME.appex"
expect_failure embedding validate_app "$EMBEDDING_APP"

expect_failure architecture env \
    VALIDATE_ONLY=YES \
    BUILT_APP_OVERRIDE="$BASE_COPY" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    ARCHS=x86_64 \
    "$SCRIPT_DIR/build-debug-app.sh"

expect_failure bundle-identifier env \
    VALIDATE_ONLY=YES \
    BUILT_APP_OVERRIDE="$BASE_COPY" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    APP_BUNDLE_ID=com.example.invalid \
    "$SCRIPT_DIR/build-debug-app.sh"

expect_failure entitlement env \
    VALIDATE_ONLY=YES \
    COPY_VALIDATED_APP=NO \
    BUILT_APP_OVERRIDE="$BASE_COPY" \
    CONFIGURATION="$CONFIGURATION" \
    RUN_TESTS=NO \
    REQUIRE_APP_GROUP_SMOKE=NO \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    APP_GROUP_ID=com.example.invalid.group \
    "$SCRIPT_DIR/build-debug-app.sh"

expect_failure notary-configuration env \
    SKIP_BUILD=YES \
    REQUIRE_NOTARIZATION=YES \
    NOTARY_PROFILE= \
    APP_PATH="$BASE_COPY" \
    OUTPUT_DIRECTORY="$FAULT_ROOT/notary-package" \
    "$SCRIPT_DIR/package-release.sh"

if [ "$CODE_SIGNING_ALLOWED" = YES ]; then
    SIGNATURE_APP=$FAULT_ROOT/signature.app
    /usr/bin/ditto "$BASE_COPY" "$SIGNATURE_APP"
    /usr/bin/plutil -insert EQMacRepVerifierFault -bool true "$SIGNATURE_APP/Contents/Info.plist"
    expect_failure signature validate_app "$SIGNATURE_APP"

    expect_failure distribution-authority env \
        SKIP_BUILD=YES \
        REQUIRE_NOTARIZATION=NO \
        APP_PATH="$BASE_COPY" \
        OUTPUT_DIRECTORY="$FAULT_ROOT/developer-id-package" \
        "$SCRIPT_DIR/package-release.sh"
fi

printf '==> Verifier self-test passed (logs: %s)\n' "$LOG_ROOT"
