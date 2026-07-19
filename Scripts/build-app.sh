#!/bin/sh
set -eu

# Internal shared builder: generate, build, test, and validate the macOS app
# and embedded widget. Use build-debug-app.sh or build-release-app.sh directly.
#
# Common invocations:
#   Scripts/build-debug-app.sh
#   Scripts/build-release-app.sh
#   CODE_SIGNING_ALLOWED=NO Scripts/build-release-app.sh
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

run_xcodebuild() {
    if [ "$ALLOW_PROVISIONING_UPDATES" = YES ]; then
        xcodebuild -allowProvisioningUpdates "$@"
    else
        xcodebuild "$@"
    fi
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

assert_app_intent_parameter_count() {
    metadata_path=$1
    intent_name=$2
    expected=$3
    actual=$(/usr/bin/plutil \
        -extract "actions.$intent_name.parameters" raw -o - "$metadata_path" 2>/dev/null) ||
        fail "widget AppIntent metadata is missing $intent_name"
    [ "$actual" = "$expected" ] ||
        fail "widget AppIntent $intent_name has $actual serialized parameters; expected $expected"
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

assert_profile_authorizes_app_group() {
    profile_path=$1
    decoded_path=$2
    description=$3

    /usr/bin/security cms -D -i "$profile_path" >"$decoded_path" 2>/dev/null ||
        fail "could not decode $description provisioning profile"

    case "$APP_GROUP_ID" in
        group.*)
            profile_index=0
            profile_group_found=NO
            while profile_group=$(/usr/libexec/PlistBuddy \
                -c "Print :Entitlements:com.apple.security.application-groups:$profile_index" \
                "$decoded_path" 2>/dev/null); do
                if [ "$profile_group" = "$APP_GROUP_ID" ]; then
                    profile_group_found=YES
                    break
                fi
                profile_index=$((profile_index + 1))
            done
            [ "$profile_group_found" = YES ] ||
                fail "$description provisioning profile does not authorize App Group $APP_GROUP_ID; enable REGISTER_APP_GROUPS and refresh signing profiles"
            ;;
        "$EXPECTED_SIGNING_TEAM".*)
            # macOS authorizes team-prefixed groups from the signature itself.
            ;;
        *)
            fail "unsupported App Group identifier '$APP_GROUP_ID'; use group.* or $EXPECTED_SIGNING_TEAM.*"
            ;;
    esac
}

unregister_widget_bundle() {
    widget_path=$1
    if [ -e "$widget_path" ] && command -v pluginkit >/dev/null 2>&1; then
        /usr/bin/pluginkit -r "$widget_path" >/dev/null 2>&1 || true
    fi
}

unregister_app_bundle() {
    app_path=$1
    if [ -e "$app_path" ] && [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$app_path" >/dev/null 2>&1 || true
    fi
}

retire_widget_bundle() {
    widget_path=$1
    unregister_widget_bundle "$widget_path"

    # WidgetKit may keep an extension process alive after its disposable Xcode
    # product has been unregistered and removed. Match the exact product path
    # so a stable app or another widget with the same executable name is not
    # interrupted.
    widget_executable=$widget_path/Contents/MacOS/$WIDGET_NAME
    widget_pattern=$(printf '%s\n' "$widget_executable" |
        /usr/bin/sed 's/[][\\.^$*+?(){}|]/\\&/g')
    /usr/bin/pkill -TERM -f "^$widget_pattern([[:space:]]|$)" >/dev/null 2>&1 || true
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
    provisioning_profile=$5
    executable_name=AppGroupRuntimeProbe

    /bin/mkdir -p "$bundle_path/Contents/MacOS"
    /bin/cp "$executable_source" "$bundle_path/Contents/MacOS/$executable_name"
    /bin/cp "$provisioning_profile" "$bundle_path/Contents/embedded.provisionprofile"
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

SCHEME=${SCHEME:-Auralis}
CONFIGURATION=${CONFIGURATION:-Debug}
PROJECT=${PROJECT:-Auralis.xcodeproj}
APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
APP_EXECUTABLE_NAME=${APP_EXECUTABLE_NAME:-Auralis}
APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-Auralis}
WIDGET_NAME=${WIDGET_NAME:-AuralisWidget}
WIDGET_DISPLAY_NAME=${WIDGET_DISPLAY_NAME:-Auralis Widget}
TEST_NAME=${TEST_NAME:-AuralisTests}
WIDGET_TEST_NAME=${WIDGET_TEST_NAME:-AuralisWidgetTests}
APP_BUNDLE_ID=${APP_BUNDLE_ID:-com.michaeltrannhan.Auralis}
WIDGET_BUNDLE_ID=${WIDGET_BUNDLE_ID:-com.michaeltrannhan.Auralis.Widget}
APP_GROUP_ID=${APP_GROUP_ID:-group.com.michaeltrannhan.Auralis}
APP_URL_NAME=${APP_URL_NAME:-$APP_BUNDLE_ID}
APP_URL_SCHEME=${APP_URL_SCHEME:-auralis}
MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION:-2}
ARCHS=${ARCHS:-$(/usr/bin/uname -m)}
DESTINATION=${DESTINATION:-platform=macOS,arch=$(/usr/bin/uname -m)}
DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-6T8J96Z3SD}
EXPECTED_SIGNING_TEAM=${EXPECTED_SIGNING_TEAM:-$DEVELOPMENT_TEAM}
SIGN_IDENTITY=${SIGN_IDENTITY:-Apple Development}
CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED:-YES}
ALLOW_PROVISIONING_UPDATES=${ALLOW_PROVISIONING_UPDATES:-$CODE_SIGNING_ALLOWED}
RUN_TESTS=${RUN_TESTS:-YES}
REQUIRE_APP_GROUP_SMOKE=${REQUIRE_APP_GROUP_SMOKE:-$CODE_SIGNING_ALLOWED}
VALIDATE_ONLY=${VALIDATE_ONLY:-NO}
BUILT_APP_OVERRIDE=${BUILT_APP_OVERRIDE:-}
COPY_VALIDATED_APP=${COPY_VALIDATED_APP:-YES}
OUTPUT_APP_OVERRIDE=${OUTPUT_APP_OVERRIDE:-}
BUILD_ROOT_OVERRIDE=${BUILD_ROOT_OVERRIDE:-}
LOG_VARIANT=${LOG_VARIANT:-}
AURALIS_DEBUG_LOG_PATH=${AURALIS_DEBUG_LOG_PATH:-}
AURALIS_DIAGNOSTICS_MODE=${AURALIS_DIAGNOSTICS_MODE:-}
CLEAN_DERIVED_PRODUCTS=${CLEAN_DERIVED_PRODUCTS:-YES}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "CONFIGURATION must be Debug or Release" ;;
esac

if [ -z "$AURALIS_DIAGNOSTICS_MODE" ]; then
    if [ "$CONFIGURATION" = Debug ]; then
        AURALIS_DIAGNOSTICS_MODE=detailed
    else
        AURALIS_DIAGNOSTICS_MODE=minimal
    fi
fi

case "$CONFIGURATION:$AURALIS_DIAGNOSTICS_MODE" in
    Debug:detailed|Release:minimal) ;;
    Debug:*) fail "Debug builds require AURALIS_DIAGNOSTICS_MODE=detailed" ;;
    Release:*) fail "Release builds require AURALIS_DIAGNOSTICS_MODE=minimal" ;;
esac

case "$CODE_SIGNING_ALLOWED" in
    YES|NO) ;;
    *) fail "CODE_SIGNING_ALLOWED must be YES or NO" ;;
esac

if [ "$CODE_SIGNING_ALLOWED" = NO ]; then
    printf 'warning: unsigned output is for CI/build verification only; desktop widgets and App Group IPC require a certificate-backed signed build\n' >&2
fi

case "$ALLOW_PROVISIONING_UPDATES" in
    YES|NO) ;;
    *) fail "ALLOW_PROVISIONING_UPDATES must be YES or NO" ;;
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

case "$CLEAN_DERIVED_PRODUCTS" in
    YES|NO) ;;
    *) fail "CLEAN_DERIVED_PRODUCTS must be YES or NO" ;;
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

if [ -n "$BUILD_ROOT_OVERRIDE" ]; then
    case "$BUILD_ROOT_OVERRIDE" in
        /*) BUILD_ROOT=$BUILD_ROOT_OVERRIDE ;;
        *) BUILD_ROOT=$REPOSITORY_ROOT/$BUILD_ROOT_OVERRIDE ;;
    esac
else
    BUILD_ROOT=$REPOSITORY_ROOT/.build/xcode/$CONFIGURATION
fi
DERIVED_DATA_DIR=$BUILD_ROOT/BuildDerivedData
TEST_DERIVED_DATA_DIR=$BUILD_ROOT/TestDerivedData
TARGETED_TEST_DERIVED_DATA_DIR=$BUILD_ROOT/TargetedTestDerivedData
APP_GROUP_PROBE_ROOT=$BUILD_ROOT/AppGroupProbe
DERIVED_WIDGET_PRODUCT=$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_PRODUCT_NAME.app/Contents/PlugIns/$WIDGET_NAME.appex
TEST_DERIVED_WIDGET_PRODUCT=$TEST_DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_PRODUCT_NAME.app/Contents/PlugIns/$WIDGET_NAME.appex
TARGETED_TEST_DERIVED_WIDGET_PRODUCT=$TARGETED_TEST_DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_PRODUCT_NAME.app/Contents/PlugIns/$WIDGET_NAME.appex
DERIVED_STANDALONE_WIDGET_PRODUCT=$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$WIDGET_NAME.appex
TEST_DERIVED_STANDALONE_WIDGET_PRODUCT=$TEST_DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$WIDGET_NAME.appex
TARGETED_TEST_DERIVED_STANDALONE_WIDGET_PRODUCT=$TARGETED_TEST_DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$WIDGET_NAME.appex
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
    OUTPUT_APP=$REPOSITORY_ROOT/.build/$APP_PRODUCT_NAME.app
fi
STAGED_OUTPUT_APP=$OUTPUT_APP.auralis-staging
LEGACY_UNSCOPED_OUTPUT_APP=$REPOSITORY_ROOT/.build/$APP_PRODUCT_NAME.app
LEGACY_DEBUG_OUTPUT_APP=$REPOSITORY_ROOT/.build/debug/$APP_PRODUCT_NAME.app
LEGACY_RELEASE_OUTPUT_APP=$REPOSITORY_ROOT/.build/release/$APP_PRODUCT_NAME.app
LEGACY_RELEASE_OUTPUT_DIR=$REPOSITORY_ROOT/.build/release

cleanup_disposable_products() {
    unregister_app_bundle "$APP_GROUP_PROBE_ROOT/AppProbe.app"
    unregister_app_bundle "$APP_GROUP_PROBE_ROOT/WidgetProbe.app"
    /bin/rm -rf "$APP_GROUP_PROBE_ROOT"
    /bin/rm -rf "$STAGED_OUTPUT_APP"

    if [ "$VALIDATE_ONLY" = NO ]; then
        retire_widget_bundle "$DERIVED_WIDGET_PRODUCT"
        retire_widget_bundle "$TEST_DERIVED_WIDGET_PRODUCT"
        retire_widget_bundle "$TARGETED_TEST_DERIVED_WIDGET_PRODUCT"
        retire_widget_bundle "$DERIVED_STANDALONE_WIDGET_PRODUCT"
        retire_widget_bundle "$TEST_DERIVED_STANDALONE_WIDGET_PRODUCT"
        retire_widget_bundle "$TARGETED_TEST_DERIVED_STANDALONE_WIDGET_PRODUCT"

        if [ "$COPY_VALIDATED_APP" = YES ] && [ "$CLEAN_DERIVED_PRODUCTS" = YES ]; then
            /bin/rm -rf \
                "$DERIVED_DATA_DIR" \
                "$TEST_DERIVED_DATA_DIR" \
                "$TARGETED_TEST_DERIVED_DATA_DIR"
        fi
    fi
}

trap cleanup_disposable_products EXIT

require_command plutil
require_command lipo
require_command ditto
require_file "$REPOSITORY_ROOT/project.yml"
require_file "$REPOSITORY_ROOT/Resources/Auralis.entitlements"
require_file "$REPOSITORY_ROOT/Resources/AuralisWidget.entitlements"

/bin/mkdir -p "$LOG_DIR" "$BUILD_ROOT"
if [ "$VALIDATE_ONLY" = NO ]; then
    require_command xcodegen
    require_command xcodebuild
    retire_widget_bundle "$DERIVED_WIDGET_PRODUCT"
    retire_widget_bundle "$TEST_DERIVED_WIDGET_PRODUCT"
    retire_widget_bundle "$TARGETED_TEST_DERIVED_WIDGET_PRODUCT"
    retire_widget_bundle "$DERIVED_STANDALONE_WIDGET_PRODUCT"
    retire_widget_bundle "$TEST_DERIVED_STANDALONE_WIDGET_PRODUCT"
    retire_widget_bundle "$TARGETED_TEST_DERIVED_STANDALONE_WIDGET_PRODUCT"
    retire_widget_bundle "$OUTPUT_APP/Contents/PlugIns/$WIDGET_NAME.appex"
    /bin/rm -rf \
        "$DERIVED_DATA_DIR" \
        "$TEST_DERIVED_DATA_DIR" \
        "$TARGETED_TEST_DERIVED_DATA_DIR" \
        "$STAGED_OUTPUT_APP"
    if [ "$LEGACY_UNSCOPED_OUTPUT_APP" != "$OUTPUT_APP" ]; then
        retire_widget_bundle "$LEGACY_UNSCOPED_OUTPUT_APP/Contents/PlugIns/$WIDGET_NAME.appex"
        /bin/rm -rf "$LEGACY_UNSCOPED_OUTPUT_APP"
    fi
    if [ "$LEGACY_DEBUG_OUTPUT_APP" != "$OUTPUT_APP" ]; then
        retire_widget_bundle "$LEGACY_DEBUG_OUTPUT_APP/Contents/PlugIns/$WIDGET_NAME.appex"
        /bin/rm -rf "$LEGACY_DEBUG_OUTPUT_APP"
    fi
    if [ "$LEGACY_RELEASE_OUTPUT_APP" != "$OUTPUT_APP" ]; then
        retire_widget_bundle "$LEGACY_RELEASE_OUTPUT_APP/Contents/PlugIns/$WIDGET_NAME.appex"
        /bin/rm -rf "$LEGACY_RELEASE_OUTPUT_APP"
        /bin/rmdir "$LEGACY_RELEASE_OUTPUT_DIR" >/dev/null 2>&1 || true
    fi

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
    run_xcodebuild \
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
        REGISTER_APP_GROUPS=YES \
        AURALIS_DEBUG_LOG_PATH="$AURALIS_DEBUG_LOG_PATH" \
        AURALIS_DIAGNOSTICS_MODE="$AURALIS_DIAGNOSTICS_MODE" \
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
        APP_GROUP_TEST_ARGUMENT='-skip-testing:AuralisWidgetTests/WidgetRenderingTests/testSignedHostResolvesConfiguredApplicationGroup'
    fi
    set +e
    run_xcodebuild \
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
        REGISTER_APP_GROUPS=YES \
        AURALIS_DEBUG_LOG_PATH= \
        AURALIS_DIAGNOSTICS_MODE="$AURALIS_DIAGNOSTICS_MODE" \
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
    BUILT_APP=$BUILT_PRODUCTS_DIR/$APP_PRODUCT_NAME.app
fi
BUILT_WIDGET=$BUILT_APP/Contents/PlugIns/$WIDGET_NAME.appex
APP_INFO=$BUILT_APP/Contents/Info.plist
WIDGET_INFO=$BUILT_WIDGET/Contents/Info.plist
APP_EXECUTABLE=$BUILT_APP/Contents/MacOS/$APP_EXECUTABLE_NAME
WIDGET_EXECUTABLE=$BUILT_WIDGET/Contents/MacOS/$WIDGET_NAME
APP_ICON=$BUILT_APP/Contents/Resources/AppIcon.icns
APP_ASSETS=$BUILT_APP/Contents/Resources/Assets.car
WIDGET_ASSETS=$BUILT_WIDGET/Contents/Resources/Assets.car
APP_INTENT_METADATA=$BUILT_APP/Contents/Resources/Metadata.appintents/extract.actionsdata
WIDGET_INTENT_METADATA=$BUILT_WIDGET/Contents/Resources/Metadata.appintents/extract.actionsdata
BUILT_TEST_BUNDLE=$BUILT_APP/Contents/PlugIns/$TEST_NAME.xctest

require_file "$BUILT_APP"
require_file "$BUILT_WIDGET"
require_file "$APP_INFO"
require_file "$WIDGET_INFO"
require_file "$APP_EXECUTABLE"
require_file "$WIDGET_EXECUTABLE"
require_file "$APP_ICON"
require_file "$APP_ASSETS"
require_file "$WIDGET_ASSETS"
require_file "$APP_INTENT_METADATA"
require_file "$WIDGET_INTENT_METADATA"
[ ! -e "$BUILT_TEST_BUNDLE" ] ||
    fail "artifact app unexpectedly contains test bundle: $BUILT_TEST_BUNDLE"

assert_plist_value "$APP_INFO" CFBundlePackageType APPL "app package type"
assert_plist_value "$WIDGET_INFO" CFBundlePackageType 'XPC!' "widget package type"
assert_plist_value "$APP_INFO" CFBundleDisplayName "$APP_DISPLAY_NAME" "app display name"
assert_plist_value "$APP_INFO" CFBundleName "$APP_DISPLAY_NAME" "app bundle name"
assert_plist_value "$APP_INFO" CFBundleExecutable "$APP_EXECUTABLE_NAME" "app executable name"
assert_plist_value "$APP_INFO" CFBundleIconFile AppIcon "app icon name"
assert_plist_value "$WIDGET_INFO" CFBundleDisplayName "$WIDGET_DISPLAY_NAME" "widget display name"
assert_plist_value "$WIDGET_INFO" CFBundleName "$WIDGET_DISPLAY_NAME" "widget bundle name"
assert_plist_value "$WIDGET_INFO" CFBundleExecutable "$WIDGET_NAME" "widget executable name"
assert_plist_value "$APP_INFO" CFBundleIdentifier "$APP_BUNDLE_ID" "app bundle identifier"
assert_plist_value "$WIDGET_INFO" CFBundleIdentifier "$WIDGET_BUNDLE_ID" "widget bundle identifier"
assert_plist_value "$APP_INFO" CFBundleURLTypes.0.CFBundleURLName "$APP_URL_NAME" "app URL name"
assert_plist_value "$APP_INFO" CFBundleURLTypes.0.CFBundleURLSchemes.0 "$APP_URL_SCHEME" "app URL scheme"
assert_plist_value "$APP_INFO" CFBundleShortVersionString "$MARKETING_VERSION" "app marketing version"
assert_plist_value "$WIDGET_INFO" CFBundleShortVersionString "$MARKETING_VERSION" "widget marketing version"
assert_plist_value "$APP_INFO" CFBundleVersion "$CURRENT_PROJECT_VERSION" "app build version"
assert_plist_value "$WIDGET_INFO" CFBundleVersion "$CURRENT_PROJECT_VERSION" "widget build version"
assert_plist_value "$APP_INFO" AuralisDebugLogPath "$AURALIS_DEBUG_LOG_PATH" "debug runtime log path"
assert_plist_value "$APP_INFO" AuralisDiagnosticsMode "$AURALIS_DIAGNOSTICS_MODE" "diagnostics mode"
assert_plist_value "$WIDGET_INFO" NSExtension.NSExtensionPointIdentifier \
    com.apple.widgetkit-extension "widget extension point"

for intent_metadata in "$APP_INTENT_METADATA" "$WIDGET_INTENT_METADATA"; do
    assert_app_intent_parameter_count "$intent_metadata" RefreshAppIntent 0
    assert_app_intent_parameter_count "$intent_metadata" SetAppMutedIntent 2
    assert_app_intent_parameter_count "$intent_metadata" SetOutputDeviceMutedIntent 2
    assert_app_intent_parameter_count "$intent_metadata" SetBoostAppIntent 2
    assert_app_intent_parameter_count "$intent_metadata" SetAppVolumeIntent 2
    assert_app_intent_parameter_count "$intent_metadata" SetEQBandGainAppIntent 3
done

assert_architectures "$APP_EXECUTABLE" "app executable"
assert_architectures "$WIDGET_EXECUTABLE" "widget executable"

APP_SOURCE_ENTITLEMENTS=$REPOSITORY_ROOT/Resources/Auralis.entitlements
WIDGET_SOURCE_ENTITLEMENTS=$REPOSITORY_ROOT/Resources/AuralisWidget.entitlements
assert_app_group "$APP_SOURCE_ENTITLEMENTS" "app source entitlements"
assert_app_group "$WIDGET_SOURCE_ENTITLEMENTS" "widget source entitlements"
assert_entitlement_value "$WIDGET_SOURCE_ENTITLEMENTS" com.apple.security.app-sandbox true \
    "widget sandbox entitlement"

if [ "$CODE_SIGNING_ALLOWED" = YES ]; then
    require_command codesign
    require_command security
    /usr/bin/codesign --verify --strict --verbose=2 "$BUILT_WIDGET" >/dev/null 2>&1 ||
        fail "widget signature verification failed"
    /usr/bin/codesign --verify --strict --verbose=2 "$BUILT_APP" >/dev/null 2>&1 ||
        fail "app signature verification failed"

    APP_BUILT_ENTITLEMENTS=$BUILD_ROOT/app-entitlements.plist
    WIDGET_BUILT_ENTITLEMENTS=$BUILD_ROOT/widget-entitlements.plist
    /usr/bin/codesign -d --entitlements - --xml "$BUILT_APP" \
        >"$APP_BUILT_ENTITLEMENTS" 2>/dev/null ||
        fail "could not read signed app entitlements"
    /usr/bin/codesign -d --entitlements - --xml "$BUILT_WIDGET" \
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

    APP_PROVISIONING_PROFILE=$BUILT_APP/Contents/embedded.provisionprofile
    WIDGET_PROVISIONING_PROFILE=$BUILT_WIDGET/Contents/embedded.provisionprofile
    require_file "$APP_PROVISIONING_PROFILE"
    require_file "$WIDGET_PROVISIONING_PROFILE"
    assert_profile_authorizes_app_group \
        "$APP_PROVISIONING_PROFILE" "$BUILD_ROOT/app-provisioning-profile.plist" "app"
    assert_profile_authorizes_app_group \
        "$WIDGET_PROVISIONING_PROFILE" "$BUILD_ROOT/widget-provisioning-profile.plist" "widget"

    if [ "$REQUIRE_APP_GROUP_SMOKE" = YES ]; then
        require_command xcrun
        unregister_app_bundle "$APP_GROUP_PROBE_ROOT/AppProbe.app"
        unregister_app_bundle "$APP_GROUP_PROBE_ROOT/WidgetProbe.app"
        /bin/rm -rf "$APP_GROUP_PROBE_ROOT"
        /bin/mkdir -p "$APP_GROUP_PROBE_ROOT"
        APP_GROUP_PROBE_EXECUTABLE=$APP_GROUP_PROBE_ROOT/AppGroupRuntimeProbe
        xcrun swiftc "$REPOSITORY_ROOT/Scripts/AppGroupRuntimeProbe.swift" \
            -o "$APP_GROUP_PROBE_EXECUTABLE" ||
            fail "could not compile app-group runtime probe"

        APP_GROUP_APP_PROBE=$APP_GROUP_PROBE_ROOT/AppProbe.app
        APP_GROUP_WIDGET_PROBE=$APP_GROUP_PROBE_ROOT/WidgetProbe.app
        make_app_group_probe_bundle \
            "$APP_GROUP_APP_PROBE" "$APP_BUNDLE_ID" \
            "$APP_GROUP_PROBE_EXECUTABLE" "$APP_BUILT_ENTITLEMENTS" \
            "$APP_PROVISIONING_PROFILE"
        make_app_group_probe_bundle \
            "$APP_GROUP_WIDGET_PROBE" "$WIDGET_BUNDLE_ID" \
            "$APP_GROUP_PROBE_EXECUTABLE" "$WIDGET_BUILT_ENTITLEMENTS" \
            "$WIDGET_PROVISIONING_PROFILE"

        APP_GROUP_TOKEN=$(/usr/bin/uuidgen)
        APP_GROUP_MARKER=.auralis-app-group-smoke-$APP_GROUP_TOKEN
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
        [ "$APP_GROUP_APP_PATH" = "$APP_GROUP_WIDGET_PATH" ] || {
            /bin/rm -f "$APP_GROUP_APP_PATH/$APP_GROUP_MARKER"
            fail "signed app and widget probes resolved different app-group containers"
        }
        /bin/rm -f "$APP_GROUP_APP_PATH/$APP_GROUP_MARKER"
    fi
fi

if [ "$COPY_VALIDATED_APP" = YES ]; then
    if [ "$BUILT_APP" != "$OUTPUT_APP" ]; then
        printf '==> Replacing validated app at %s\n' "$OUTPUT_APP"
        /bin/rm -rf "$STAGED_OUTPUT_APP"
        /usr/bin/ditto "$BUILT_APP" "$STAGED_OUTPUT_APP"
        /bin/rm -rf "$OUTPUT_APP"
        /bin/mv "$STAGED_OUTPUT_APP" "$OUTPUT_APP"
    fi
    VALIDATED_APP=$OUTPUT_APP
else
    VALIDATED_APP=$BUILT_APP
fi

printf '==> Validation succeeded\n'
printf '    app: %s\n' "$VALIDATED_APP"
printf '    widget package type: XPC!\n'
if [ "$CODE_SIGNING_ALLOWED" = YES ] && [ "$REQUIRE_APP_GROUP_SMOKE" = YES ]; then
    printf '    live app-group access: %s\n' "$APP_GROUP_APP_PATH"
fi
printf '    build log: %s\n' "$BUILD_LOG"
if [ "$RUN_TESTS" = YES ]; then
    printf '    test log: %s\n' "$TEST_LOG"
fi
if [ -n "$AURALIS_DEBUG_LOG_PATH" ]; then
    printf '    runtime log: %s\n' "$AURALIS_DEBUG_LOG_PATH"
else
    printf '    runtime log: ~/Library/Logs/Auralis/Auralis.log (minimal, bounded)\n'
fi
