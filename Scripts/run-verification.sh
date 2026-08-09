#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

MODE=${1:-all}
STRESS_ITERATIONS=${AURALIS_STRESS_ITERATIONS:-100000}
LOG_DIR=$REPOSITORY_ROOT/.build/logs

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

assert_arm64() {
    [ "$(/usr/bin/uname -m)" = arm64 ] ||
        fail "Auralis verification requires an arm64 host"
}

run_checked_swift_test() {
    label=$1
    shift
    log_path=$LOG_DIR/swift-$label.log
    /bin/mkdir -p "$LOG_DIR"
    set +e
    "$@" >"$log_path" 2>&1
    status=$?
    set -e
    /bin/cat "$log_path"
    [ "$status" -eq 0 ] || fail "$label failed with status $status (full log: $log_path)"
    if /usr/bin/grep -E -q 'ERROR: (Address|Thread)Sanitizer|UndefinedBehaviorSanitizer|runtime error:' "$log_path"; then
        fail "$label reported a sanitizer or runtime fault (full log: $log_path)"
    fi
}

fail_on_invalid_configuration() {
    if /usr/bin/grep -R -E -q '\[Invalid Configuration\]' "$LOG_DIR"; then
        /usr/bin/grep -R -E '\[Invalid Configuration\]' "$LOG_DIR" >&2 || true
        fail "generated-product verification reported [Invalid Configuration]"
    fi
}

run_strict() {
    printf '==> SwiftPM tests with complete concurrency checking\n'
    run_checked_swift_test strict swift test --arch arm64 -Xswiftc -strict-concurrency=complete
}

run_tsan() {
    printf '==> SwiftPM tests under Thread Sanitizer\n'
    run_checked_swift_test tsan env AURALIS_INSTRUMENTED_TESTS=1 swift test --arch arm64 --sanitize=thread
}

run_asan() {
    printf '==> SwiftPM tests under Address Sanitizer\n'
    run_checked_swift_test asan env AURALIS_INSTRUMENTED_TESTS=1 swift test --arch arm64 --sanitize=address
}

run_ubsan() {
    printf '==> SwiftPM tests under Undefined Behavior Sanitizer\n'
    run_checked_swift_test ubsan env AURALIS_INSTRUMENTED_TESTS=1 swift test --arch arm64 -Xswiftc -sanitize=undefined
}

run_coverage() {
    printf '==> SwiftPM tests with coverage\n'
    run_checked_swift_test coverage swift test --arch arm64 --enable-code-coverage
    coverage_profile=$(/usr/bin/find .build -name default.profdata -type f -print -quit)
    [ -n "$coverage_profile" ] || fail "SwiftPM did not produce a coverage profile"
    xcrun llvm-profdata show --summary "$coverage_profile" >"$LOG_DIR/coverage-summary.log"
}

run_stress() {
    printf '==> Sustained audio callback stress (%s iterations)\n' "$STRESS_ITERATIONS"
    AURALIS_STRESS_ITERATIONS=$STRESS_ITERATIONS \
        swift test --arch arm64 --filter 'CoreAudioPCMRendererTests/testSustainedAudioCallbackStressBudget'
}

run_xcode() {
    printf '==> Generated Xcode Debug app/widget/tests\n'
    CODE_SIGNING_ALLOWED=NO "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Generated Xcode Release app/widget\n'
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=NO \
        "$SCRIPT_DIR/build-release-app.sh"
    printf '==> Product verifier failure matrix\n'
    CONFIGURATION=Release CODE_SIGNING_ALLOWED=NO \
        "$SCRIPT_DIR/test-build-verifier.sh"
    fail_on_invalid_configuration
}

run_signed() {
    printf '==> Certificate-backed Xcode Debug app/widget/tests\n'
    CODE_SIGNING_ALLOWED=YES "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Certificate-backed Xcode Release app/widget\n'
    RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/build-release-app.sh"
    printf '==> Signed product and distribution verifier failure matrix\n'
    CONFIGURATION=Release CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/test-build-verifier.sh"
}

run_hardware_preflight() {
    printf '==> Read-only physical hardware preflight\n'
    "$SCRIPT_DIR/hardware-preflight.sh"
}

assert_arm64

case "$MODE" in
    strict) run_strict ;;
    tsan) run_tsan ;;
    asan) run_asan ;;
    ubsan) run_ubsan ;;
    coverage) run_coverage ;;
    stress) run_stress ;;
    xcode) run_xcode ;;
    signed) run_signed ;;
    hardware) run_hardware_preflight ;;
    all)
        run_strict
        run_tsan
        run_asan
        run_ubsan
        run_coverage
        run_stress
        run_xcode
        ;;
    *)
        printf 'usage: %s [all|strict|tsan|asan|ubsan|coverage|stress|xcode|signed|hardware]\n' "$0" >&2
        exit 64
        ;;
esac
