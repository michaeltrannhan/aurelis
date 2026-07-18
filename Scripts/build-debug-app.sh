#!/bin/sh
set -eu

# Generate, build, test, and validate the macOS app and embedded widget.
#
# Common invocations:
#   Scripts/build-debug-app.sh
#   CODE_SIGNING_ALLOWED=NO Scripts/build-debug-app.sh
#   CONFIGURATION=Release RUN_TESTS=NO Scripts/build-debug-app.sh
#   ARCHS="arm64 x86_64" DEVELOPMENT_TEAM=TEAMID \
#     SIGN_IDENTITY="Apple Development" Scripts/build-debug-app.sh

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_file() {
    [ -e "$1" ] || fail "required path not found: $1"
}

plist_value() {
    plist_path=$1
    plist_key=$2
    value=$(/usr/bin/plutil -extract "$plist_key" raw -o - "$plist_path" 2>/dev/null) ||
        fail "could not read $plist_key from $plist_path"
    printf '%s\n' "$value"
}

assert_plist_value() {
    plist_path=$1
    plist_key=$2
    expected=$3
    description=$4
    actual=$(plist_value "$plist_path" "$plist_key")
    [ "$actual" = "$expected" ] ||
        fail "$description is '$actual'; expected '$expected'"
}

assert_app_group() {
    entitlements_path=$1
    description=$2
    group=$(/usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.application-groups:0' \
        "$entitlements_path" 2>/dev/null) ||
        fail "$description has no application group entitlement"
    [ "$group" = "$APP_GROUP_ID" ] ||
        fail "$description app group is '$group'; expected '$APP_GROUP_ID'"
}

assert_entitlement_value() {
    entitlements_path=$1
    entitlement_key=$2
    expected=$3
    description=$4
    actual=$(/usr/libexec/PlistBuddy \
        -c "Print :$entitlement_key" \
        "$entitlements_path" 2>/dev/null) ||
        fail "could not read $entitlement_key from $entitlements_path"
    [ "$actual" = "$expected" ] ||
        fail "$description is '$actual'; expected '$expected'"
}

codesign_value() {
    bundle_path=$1
    key=$2
    description=$3
    value=$(/usr/bin/codesign -d --verbose=4 "$bundle_path" 2>&1 |
        /usr/bin/sed -n "s/^$key=//p")
    [ -n "$value" ] || fail "could not read $key from $description signature"
    printf '%s\n' "$value"
}

make_app_group_probe_bundle() {
    bundle_path=$1
    bundle_identifier=$2
    executable_source=$3
    entitlements_path=$4
    executable_name=AppGroupRuntimeProbe

    /bin/mkdir -p "$bundle_path/Contents/MacOS"
    /bin/cp "$executable_source" "$bundle_path/Contents/MacOS/$executable_name"
    /usr/bin/plutil -create xml1 "$bundle_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$bundle_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string "$executable_name" "$bundle_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "$bundle_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleVersion -string 1 "$bundle_path/Contents/Info.plist"
    /usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        --entitlements "$entitlements_path" "$bundle_path" >/dev/null 2>&1 ||
        fail "could not sign app-group runtime probe $bundle_identifier"
    /usr/bin/codesign --verify --strict "$bundle_path" >/dev/null 2>&1 ||
        fail "app-group runtime probe signature is invalid: $bundle_identifier"
}

assert_architectures() {
    executable_path=$1
    description=$2
    actual_archs=$(/usr/bin/lipo -archs "$executable_path" 2>/dev/null) ||
        fail "could not inspect architectures for $description"

    for expected_arch in $ARCHS; do
        case " $actual_archs " in
            *" $expected_arch "*) ;;
            *) fail "$description is missing requested architecture $expected_arch (has: $actual_archs)" ;;
        esac
    done

    for actual_arch in $actual_archs; do
        case " $ARCHS " in
            *" $actual_arch "*) ;;
            *) fail "$description contains unexpected architecture $actual_arch (requested: $ARCHS)" ;;
        esac
    done
}

print_build_summary() {
    summary_path=$1
    if /usr/bin/grep -E '^(/.*: )?(warning|error):|^\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*|^Test Suite .* (passed|failed)' \
        "$summary_path" >"$SUMMARY_LOG" 2>/dev/null; then
        /usr/bin/tail -n 60 "$SUMMARY_LOG"
    else
        /usr/bin/tail -n 40 "$summary_path"
    fi
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

SCHEME=${SCHEME:-EQMacRep}
CONFIGURATION=${CONFIGURATION:-Debug}
PROJECT=${PROJECT:-EQMacRep.xcodeproj}
APP_NAME=${APP_NAME:-EQMacRep}
WIDGET_NAME=${WIDGET_NAME:-EQMacRepWidget}
TEST_NAME=${TEST_NAME:-EQMacRepTests}
WIDGET_TEST_NAME=${WIDGET_TEST_NAME:-EQMacRepWidgetTests}
APP_BUNDLE_ID=${APP_BUNDLE_ID:-com.michaeltrannhan.EQMacRep}
WIDGET_BUNDLE_ID=${WIDGET_BUNDLE_ID:-com.michaeltrannhan.EQMacRep.EQMacRepWidget}
APP_GROUP_ID=${APP_GROUP_ID:-com.michaeltrannhan.EQMacRep.group}
MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION:-1}
ARCHS=${ARCHS:-$(/usr/bin/uname -m)}
DESTINATION=${DESTINATION:-platform=macOS,arch=$(/usr/bin/uname -m)}
DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-6T8J96Z3SD}
EXPECTED_SIGNING_TEAM=${EXPECTED_SIGNING_TEAM:-$DEVELOPMENT_TEAM}
SIGN_IDENTITY=${SIGN_IDENTITY:-Apple Development}
CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-YES}
RUN_TESTS=${RUN_TESTS:-YES}
REQUIRE_APP_GROUP_SMOKE=${REQUIRE_APP_GROUP_SMOKE:-$CODE_SIGNING_ALLOWED}
VALIDATE_ONLY=${VALIDATE_ONLY:-NO}
BUILT_APP_OVERRIDE=${BUILT_APP_OVERRIDE:-}
COPY_VALIDATED_APP=${COPY_VALIDATED_APP:-YES}
OUTPUT_APP_OVERRIDE=${OUTPUT_APP_OVERRIDE:-}
LOG_VARIANT=${LOG_VARIANT:-}

case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "CONFIGURATION must be Debug or Release" ;;
esac

case "$CODE_SIGNING_ALLOWED" in
    YES|NO) ;;
    *) fail "CODE_SIGNING_ALLOWED must be YES or NO" ;;
esac

case "$RUN_TESTS" in
    YES|NO) ;;
    *) fail "RUN_TESTS must be YES or NO" ;;
esac

case "$REQUIRE_APP_GROUP_SMOKE" in
    YES|NO) ;;
    *) fail "REQUIRE_APP_GROUP_SMOKE must be YES or NO" ;;
esac

case "$VALIDATE_ONLY" in
    YES|NO) ;;
    *) fail "VALIDATE_ONLY must be YES or NO" ;;
esac

case "$COPY_VALIDATED_APP" in
    YES|NO) ;;
    *) fail "COPY_VALIDATED_APP must be YES or NO" ;;
esac

case "$LOG_VARIANT" in
    ''|*[!A-Za-z0-9_-]*)
        [ -z "$LOG_VARIANT" ] || fail "LOG_VARIANT may contain only letters, numbers, underscores, and hyphens"
        ;;
esac

if [ "$VALIDATE_ONLY" = YES ]; then
    RUN_TESTS=NO
fi

if [ "$CODE_SIGNING_ALLOWED" = YES ] && { [ -z "$DEVELOPMENT_TEAM" ] || [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = - ]; }; then
    fail "signed builds require DEVELOPMENT_TEAM and a certificate-backed SIGN_IDENTITY"
fi

case "$PROJECT" in
    /*) PROJECT_PATH=$PROJECT ;;
    *) PROJECT_PATH=$REPOSITORY_ROOT/$PROJECT ;;
esac

BUILD_ROOT=$REPOSITORY_ROOT/.build/xcode/$CONFIGURATION
DERIVED_DATA_DIR=$BUILD_ROOT/BuildDerivedData
TEST_DERIVED_DATA_DIR=$BUILD_ROOT/TestDerivedData
LOG_DIR=$REPOSITORY_ROOT/.build/logs
if [ "$CODE_SIGNING_ALLOWED" = YES ]; then
    SIGNING_MODE=signed
else
    SIGNING_MODE=unsigned
fi
if [ -n "$LOG_VARIANT" ]; then
    LOG_STEM=$CONFIGURATION-$SIGNING_MODE-$LOG_VARIANT
else
    LOG_STEM=$CONFIGURATION-$SIGNING_MODE
fi
XCODEGEN_LOG=$LOG_DIR/xcodegen-$LOG_STEM.log
BUILD_LOG=$LOG_DIR/xcodebuild-$LOG_STEM.log
TEST_LOG=$LOG_DIR/xcodebuild-$LOG_STEM-tests.log
SUMMARY_LOG=$LOG_DIR/xcodebuild-$LOG_STEM.summary.log
if [ -n "$OUTPUT_APP_OVERRIDE" ]; then
    case "$OUTPUT_APP_OVERRIDE" in
        /*) OUTPUT_APP=$OUTPUT_APP_OVERRIDE ;;
        *) OUTPUT_APP=$REPOSITORY_ROOT/$OUTPUT_APP_OVERRIDE ;;
    esac
else
    OUTPUT_APP=$REPOSITORY_ROOT/.build/$APP_NAME.app
fi

require_command plutil
require_command lipo
require_command ditto
require_file "$REPOSITORY_ROOT/project.yml"
require_file "$REPOSITORY_ROOT/Resources/EQMacRep.entitlements"
require_file "$REPOSITORY_ROOT/Resources/EQMacRepWidget.entitlements"

/bin/mkdir -p "$LOG_DIR" "$BUILD_ROOT"
if [ "$VALIDATE_ONLY" = NO ]; then
    require_command xcodegen
    require_command xcodebuild
    /bin/rm -rf "$DERIVED_DATA_DIR" "$TEST_DERIVED_DATA_DIR" "$OUTPUT_APP"

    printf '==> Generating %s\n' "$PROJECT"
    set +e
    xcodegen generate \
        --spec "$REPOSITORY_ROOT/project.yml" \
        --project "$REPOSITORY_ROOT" \
        >"$XCODEGEN_LOG" 2>&1
    xcodegen_status=$?
    set -e
    if [ "$xcodegen_status" -ne 0 ]; then
        /usr/bin/tail -n 40 "$XCODEGEN_LOG" >&2
        fail "xcodegen failed with status $xcodegen_status (full log: $XCODEGEN_LOG)"
    fi

    require_file "$PROJECT_PATH/project.pbxproj"
    SCHEME_PATH=$PROJECT_PATH/xcshareddata/xcschemes/$SCHEME.xcscheme
    require_file "$SCHEME_PATH"
    /usr/bin/grep -q "$TEST_NAME.xctest" "$SCHEME_PATH" ||
        fail "shared scheme $SCHEME does not contain $TEST_NAME"
    /usr/bin/grep -q "$WIDGET_TEST_NAME.xctest" "$SCHEME_PATH" ||
        fail "shared scheme $SCHEME does not contain $WIDGET_TEST_NAME"

    printf '==> Building %s (%s, architectures: %s)\n' "$SCHEME" "$CONFIGURATION" "$ARCHS"
    set +e
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        ARCHS="$ARCHS" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$MARKETING_VERSION" \
        CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
        clean build \
        >"$BUILD_LOG" 2>&1
    xcodebuild_status=$?
    set -e

    print_build_summary "$BUILD_LOG"
    if [ "$xcodebuild_status" -ne 0 ]; then
        fail "xcodebuild failed with status $xcodebuild_status (full log: $BUILD_LOG)"
    fi

    /usr/bin/grep -q '\*\* BUILD SUCCEEDED \*\*' "$BUILD_LOG" ||
        fail "xcodebuild returned success without a BUILD SUCCEEDED marker"

if [ "$RUN_TESTS" = YES ]; then
    printf '==> Testing %s (%s)\n' "$SCHEME" "$CONFIGURATION"
    if [ "$REQUIRE_APP_GROUP_SMOKE" = YES ]; then
        APP_GROUP_TEST_ARGUMENT=
    else
        APP_GROUP_TEST_ARGUMENT='-skip-testing:EQMacRepWidgetTests/WidgetRenderingTests/testSignedHostResolvesConfiguredApplicationGroup'
    fi
    set +e
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$TEST_DERIVED_DATA_DIR" \
        ARCHS="$ARCHS" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$MARKETING_VERSION" \
        CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
        $APP_GROUP_TEST_ARGUMENT \
        clean test \
        >"$TEST_LOG" 2>&1
    xcodebuild_status=$?
    set -e

    print_build_summary "$TEST_LOG"
    if [ "$xcodebuild_status" -ne 0 ]; then
        fail "xcodebuild test failed with status $xcodebuild_status (full log: $TEST_LOG)"
    fi
    /usr/bin/grep -q '\*\* TEST SUCCEEDED \*\*' "$TEST_LOG" ||
        fail "xcodebuild returned success without a TEST SUCCEEDED marker"
fi
fi

BUILT_PRODUCTS_DIR=$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION
if [ -n "$BUILT_APP_OVERRIDE" ]; then
    BUILT_APP=$BUILT_APP_OVERRIDE
else
    BUILT_APP=$BUILT_PRODUCTS_DIR/$APP_NAME.app
fi
BUILT_WIDGET=$BUILT_APP/Contents/PlugIns/$WIDGET_NAME.appex
APP_INFO=$BUILT_APP/Contents/Info.plist
WIDGET_INFO=$BUILT_WIDGET/Contents/Info.plist
APP_EXECUTABLE=$BUILT_APP/Contents/MacOS/$APP_NAME
WIDGET_EXECUTABLE=$BUILT_WIDGET/Contents/MacOS/$WIDGET_NAME
BUILT_TEST_BUNDLE=$BUILT_APP/Contents/PlugIns/$TEST_NAME.xctest

require_file "$BUILT_APP"
require_file "$BUILT_WIDGET"
require_file "$APP_INFO"
require_file "$WIDGET_INFO"
require_file "$APP_EXECUTABLE"
require_file "$WIDGET_EXECUTABLE"
[ ! -e "$BUILT_TEST_BUNDLE" ] ||
    fail "artifact app unexpectedly contains test bundle: $BUILT_TEST_BUNDLE"

assert_plist_value "$APP_INFO" CFBundlePackageType APPL "app package type"
assert_plist_value "$WIDGET_INFO" CFBundlePackageType 'XPC!' "widget package type"
assert_plist_value "$APP_INFO" CFBundleIdentifier "$APP_BUNDLE_ID" "app bundle identifier"
assert_plist_value "$WIDGET_INFO" CFBundleIdentifier "$WIDGET_BUNDLE_ID" "widget bundle identifier"
assert_plist_value "$APP_INFO" CFBundleShortVersionString "$MARKETING_VERSION" "app marketing version"
assert_plist_value "$WIDGET_INFO" CFBundleShortVersionString "$MARKETING_VERSION" "widget marketing version"
assert_plist_value "$APP_INFO" CFBundleVersion "$CURRENT_PROJECT_VERSION" "app build version"
assert_plist_value "$WIDGET_INFO" CFBundleVersion "$CURRENT_PROJECT_VERSION" "widget build version"
assert_plist_value "$WIDGET_INFO" NSExtension.NSExtensionPointIdentifier \
    com.apple.widgetkit-extension "widget extension point"

assert_architectures "$APP_EXECUTABLE" "app executable"
assert_architectures "$WIDGET_EXECUTABLE" "widget executable"

APP_SOURCE_ENTITLEMENTS=$REPOSITORY_ROOT/Resources/EQMacRep.entitlements
WIDGET_SOURCE_ENTITLEMENTS=$REPOSITORY_ROOT/Resources/EQMacRepWidget.entitlements
assert_app_group "$APP_SOURCE_ENTITLEMENTS" "app source entitlements"
assert_app_group "$WIDGET_SOURCE_ENTITLEMENTS" "widget source entitlements"
assert_entitlement_value "$WIDGET_SOURCE_ENTITLEMENTS" com.apple.security.app-sandbox true \
    "widget sandbox entitlement"

if [ "$CODE_SIGNING_ALLOWED" = YES ]; then
    require_command codesign
    /usr/bin/codesign --verify --strict --verbose=2 "$BUILT_WIDGET" >/dev/null 2>&1 ||
        fail "widget signature verification failed"
    /usr/bin/codesign --verify --strict --verbose=2 "$BUILT_APP" >/dev/null 2>&1 ||
        fail "app signature verification failed"

    APP_BUILT_ENTITLEMENTS=$BUILD_ROOT/app-entitlements.plist
    WIDGET_BUILT_ENTITLEMENTS=$BUILD_ROOT/widget-entitlements.plist
    /usr/bin/codesign -d --entitlements :- "$BUILT_APP" \
        >"$APP_BUILT_ENTITLEMENTS" 2>/dev/null ||
        fail "could not read signed app entitlements"
    /usr/bin/codesign -d --entitlements :- "$BUILT_WIDGET" \
        >"$WIDGET_BUILT_ENTITLEMENTS" 2>/dev/null ||
        fail "could not read signed widget entitlements"
    assert_app_group "$APP_BUILT_ENTITLEMENTS" "signed app"
    assert_app_group "$WIDGET_BUILT_ENTITLEMENTS" "signed widget"
    assert_entitlement_value "$WIDGET_BUILT_ENTITLEMENTS" com.apple.security.app-sandbox true \
        "signed widget sandbox entitlement"

    APP_SIGNING_TEAM=$(codesign_value "$BUILT_APP" TeamIdentifier "signed app")
    WIDGET_SIGNING_TEAM=$(codesign_value "$BUILT_WIDGET" TeamIdentifier "signed widget")
    [ "$APP_SIGNING_TEAM" = "$WIDGET_SIGNING_TEAM" ] ||
        fail "app signing team '$APP_SIGNING_TEAM' does not match widget signing team '$WIDGET_SIGNING_TEAM'"
    [ "$APP_SIGNING_TEAM" = "$EXPECTED_SIGNING_TEAM" ] ||
        fail "signed products use team '$APP_SIGNING_TEAM'; expected '$EXPECTED_SIGNING_TEAM'"

    require_command xcrun
    APP_GROUP_PROBE_ROOT=$BUILD_ROOT/AppGroupProbe
    /bin/rm -rf "$APP_GROUP_PROBE_ROOT"
    /bin/mkdir -p "$APP_GROUP_PROBE_ROOT"
    APP_GROUP_PROBE_EXECUTABLE=$APP_GROUP_PROBE_ROOT/AppGroupRuntimeProbe
    xcrun swiftc "$REPOSITORY_ROOT/Scripts/AppGroupRuntimeProbe.swift" \
        -o "$APP_GROUP_PROBE_EXECUTABLE" ||
        fail "could not compile app-group runtime probe"

    APP_GROUP_APP_PROBE=$APP_GROUP_PROBE_ROOT/AppProbe.app
    APP_GROUP_WIDGET_PROBE=$APP_GROUP_PROBE_ROOT/WidgetProbe.app
    make_app_group_probe_bundle \
        "$APP_GROUP_APP_PROBE" "$APP_BUNDLE_ID.AppGroupProbe" \
        "$APP_GROUP_PROBE_EXECUTABLE" "$APP_BUILT_ENTITLEMENTS"
    make_app_group_probe_bundle \
        "$APP_GROUP_WIDGET_PROBE" "$WIDGET_BUNDLE_ID.AppGroupProbe" \
        "$APP_GROUP_PROBE_EXECUTABLE" "$WIDGET_BUILT_ENTITLEMENTS"

    APP_GROUP_TOKEN=$(/usr/bin/uuidgen)
    APP_GROUP_MARKER=.eqmacrep-app-group-smoke-$APP_GROUP_TOKEN
    APP_GROUP_APP_PATH=$(
        "$APP_GROUP_APP_PROBE/Contents/MacOS/AppGroupRuntimeProbe" \
            "$APP_GROUP_ID" write "$APP_GROUP_MARKER" "$APP_GROUP_TOKEN"
    ) || fail "signed app entitlements could not write the app-group smoke marker"

    set +e
    APP_GROUP_WIDGET_PATH=$(
        "$APP_GROUP_WIDGET_PROBE/Contents/MacOS/AppGroupRuntimeProbe" \
            "$APP_GROUP_ID" read "$APP_GROUP_MARKER" "$APP_GROUP_TOKEN"
    )
    app_group_widget_status=$?
    set -e
    if [ "$app_group_widget_status" -ne 0 ]; then
        /bin/rm -f "$APP_GROUP_APP_PATH/$APP_GROUP_MARKER"
        fail "signed widget entitlements could not read the app-group smoke marker"
    fi
    [ "$APP_GROUP_APP_PATH" = "$APP_GROUP_WIDGET_PATH" ] ||
        fail "signed app and widget probes resolved different app-group containers"
fi

if [ "$COPY_VALIDATED_APP" = YES ]; then
    if [ "$BUILT_APP" != "$OUTPUT_APP" ]; then
        printf '==> Replacing validated app at %s\n' "$OUTPUT_APP"
        /bin/rm -rf "$OUTPUT_APP"
        /usr/bin/ditto "$BUILT_APP" "$OUTPUT_APP"
    fi
    VALIDATED_APP=$OUTPUT_APP
else
    VALIDATED_APP=$BUILT_APP
fi

printf '==> Validation succeeded\n'
printf '    app: %s\n' "$VALIDATED_APP"
printf '    widget package type: XPC!\n'
if [ "$CODE_SIGNING_ALLOWED" = YES ]; then
    printf '    live app-group access: %s\n' "$APP_GROUP_APP_PATH"
fi
printf '    build log: %s\n' "$BUILD_LOG"
if [ "$RUN_TESTS" = YES ]; then
    printf '    test log: %s\n' "$TEST_LOG"
fi
