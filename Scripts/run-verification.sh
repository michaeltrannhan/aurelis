#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

MODE=${1:-all}
STRESS_ITERATIONS=${EQMACREP_STRESS_ITERATIONS:-100000}

run_strict() {
    printf '==> SwiftPM tests with complete concurrency checking\n'
    swift test -Xswiftc -strict-concurrency=complete
}

run_tsan() {
    printf '==> SwiftPM tests under Thread Sanitizer\n'
    EQMACREP_INSTRUMENTED_TESTS=1 swift test --sanitize=thread
}

run_stress() {
    printf '==> Sustained audio callback stress (%s iterations)\n' "$STRESS_ITERATIONS"
    EQMACREP_STRESS_ITERATIONS=$STRESS_ITERATIONS \
        swift test --filter 'CoreAudioPCMRendererTests/testSustainedAudioCallbackStressBudget'
}

run_xcode() {
    printf '==> Generated Xcode Debug app/widget/tests\n'
    CODE_SIGNING_ALLOWED=NO "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Generated Xcode Release app/widget\n'
    CONFIGURATION=Release RUN_TESTS=NO CODE_SIGNING_ALLOWED=NO \
        "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Product verifier failure matrix\n'
    CONFIGURATION=Release CODE_SIGNING_ALLOWED=NO \
        "$SCRIPT_DIR/test-build-verifier.sh"
}

run_signed() {
    printf '==> Certificate-backed Xcode Debug app/widget/tests\n'
    CODE_SIGNING_ALLOWED=YES "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Certificate-backed Xcode Release app/widget\n'
    CONFIGURATION=Release RUN_TESTS=NO CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/build-debug-app.sh"
    printf '==> Signed product and distribution verifier failure matrix\n'
    CONFIGURATION=Release CODE_SIGNING_ALLOWED=YES \
        "$SCRIPT_DIR/test-build-verifier.sh"
}

run_hardware_preflight() {
    printf '==> Read-only physical hardware preflight\n'
    "$SCRIPT_DIR/hardware-preflight.sh"
}

case "$MODE" in
    strict) run_strict ;;
    tsan) run_tsan ;;
    stress) run_stress ;;
    xcode) run_xcode ;;
    signed) run_signed ;;
    hardware) run_hardware_preflight ;;
    all)
        run_strict
        run_tsan
        run_stress
        run_xcode
        ;;
    *)
        printf 'usage: %s [all|strict|tsan|stress|xcode|signed|hardware]\n' "$0" >&2
        exit 64
        ;;
esac
