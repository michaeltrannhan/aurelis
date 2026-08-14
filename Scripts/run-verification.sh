#!/bin/sh
# Stable CI entry point — do not rename.
# Gates: all|preflight|strict|tsan|asan|ubsan|stress|xcode|signed|hardware|coverage
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$REPOSITORY_ROOT"

MODE=${1:-all}
STRESS_ITERATIONS=${AURALIS_STRESS_ITERATIONS:-100000}
COVERAGE_FLOOR=${AURALIS_COVERAGE_FLOOR:-59}

assert_no_forbidden_diagnostics() {
    log_glob=$1
    # shellcheck disable=SC2086
    if /usr/bin/grep -E -n '\[Invalid Configuration\]|AddressSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer|runtime error:' $log_glob 2>/dev/null; then
        fail "forbidden sanitizer/runtime/Invalid Configuration diagnostics detected in $log_glob"
    fi
}

run_strict() {
    printf '==> SwiftPM tests with complete concurrency checking\n'
    LOG_DIR=.build/logs/verification
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/strict.log"
    swift test -Xswiftc -strict-concurrency=complete 2>&1 | /usr/bin/tee "$LOG_FILE"
    assert_no_forbidden_diagnostics "$LOG_FILE"
}

run_tsan() {
    printf '==> SwiftPM tests under Thread Sanitizer\n'
    LOG_DIR=.build/logs/verification
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/tsan.log"
    AURALIS_INSTRUMENTED_TESTS=1 swift test --sanitize=thread 2>&1 | /usr/bin/tee "$LOG_FILE"
    assert_no_forbidden_diagnostics "$LOG_FILE"
}

run_asan() {
    printf '==> SwiftPM tests under Address Sanitizer\n'
    LOG_DIR=.build/logs/verification
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/asan.log"
    AURALIS_INSTRUMENTED_TESTS=1 swift test --sanitize=address 2>&1 | /usr/bin/tee "$LOG_FILE"
    assert_no_forbidden_diagnostics "$LOG_FILE"
}

run_ubsan() {
    printf '==> SwiftPM tests under Undefined Behavior Sanitizer\n'
    LOG_DIR=.build/logs/verification
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/ubsan.log"
    AURALIS_INSTRUMENTED_TESTS=1 swift test --sanitize=undefined 2>&1 | /usr/bin/tee "$LOG_FILE"
    assert_no_forbidden_diagnostics "$LOG_FILE"
}

run_stress() {
    printf '==> Sustained audio callback stress (%s iterations)\n' "$STRESS_ITERATIONS"
    LOG_DIR=.build/logs/verification
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/stress.log"
    AURALIS_STRESS_ITERATIONS=$STRESS_ITERATIONS \
        swift test --filter 'CoreAudioPCMRendererTests/testSustainedAudioCallbackStressBudget' 2>&1 | /usr/bin/tee "$LOG_FILE"
    assert_no_forbidden_diagnostics "$LOG_FILE"
}

run_xcode() {
    printf '==> Generated Xcode Debug app/widget/tests\n'
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Generated Xcode Release app/widget\n'
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
        "$SCRIPT_DIR/build-release-app.sh"
    printf '==> Product verifier failure matrix\n'
    CONFIGURATION=Release CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
        "$SCRIPT_DIR/test-build-verifier.sh"
}

run_signed() {
    printf '==> Certificate-backed Xcode Debug app/widget/tests\n'
    CODE_SIGNING_ALLOWED=YES ARCHS=arm64 "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Certificate-backed Xcode Release app/widget\n'
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES ARCHS=arm64 \
        "$SCRIPT_DIR/build-release-app.sh"
    printf '==> Signed product and distribution verifier failure matrix\n'
    CONFIGURATION=Release CODE_SIGNING_ALLOWED=YES ARCHS=arm64 \
        "$SCRIPT_DIR/test-build-verifier.sh"
}

run_hardware_preflight() {
    printf '==> Read-only physical hardware preflight\n'
    "$SCRIPT_DIR/hardware-preflight.sh"
}

run_coverage() {
    printf '==> Coverage floor (%s%% global line coverage)\n' "$COVERAGE_FLOOR"
    LOG_DIR=.build/logs/verification
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/coverage.log"
    RESULT_BUNDLE="$LOG_DIR/coverage.xcresult"
    rm -rf "$RESULT_BUNDLE"

    if [ ! -f Auralis.xcodeproj/project.pbxproj ]; then
        require_command xcodegen
        xcodegen generate
    fi

    set +e
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 xcodebuild test \
        -project Auralis.xcodeproj \
        -scheme Auralis \
        -destination 'platform=macOS,arch=arm64' \
        -enableCodeCoverage YES \
        -resultBundlePath "$RESULT_BUNDLE" \
        CODE_SIGNING_ALLOWED=NO \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        2>&1 | /usr/bin/tee "$LOG_FILE"
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "coverage test run failed"

    assert_no_forbidden_diagnostics "$LOG_FILE"
    "$SCRIPT_DIR/check-coverage-floor.sh" "$RESULT_BUNDLE" "$COVERAGE_FLOOR"
}

case "$MODE" in
    strict) run_strict ;;
    tsan) run_tsan ;;
    asan) run_asan ;;
    ubsan) run_ubsan ;;
    stress) run_stress ;;
    xcode) run_xcode ;;
    signed) run_signed ;;
    hardware) run_hardware_preflight ;;
    coverage) run_coverage ;;
    preflight) "$SCRIPT_DIR/ci-preflight.sh" ;;
    all)
        "$SCRIPT_DIR/ci-preflight.sh"
        run_strict
        run_tsan
        run_asan
        run_ubsan
        run_stress
        run_xcode
        ;;
    *)
        printf 'usage: %s [all|preflight|strict|tsan|asan|ubsan|stress|xcode|signed|hardware|coverage]\n' "$0" >&2
        exit 64
        ;;
esac
