#!/bin/sh
set -eu

# CI guardrail for the Apple Silicon macOS 15 runner. It intentionally accepts
# newer local toolchains while keeping Xcode 16.4 as the reproducible minimum.

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

version_at_least() {
    actual=$1
    required=$2
    /usr/bin/awk -v actual="$actual" -v required="$required" '
        BEGIN {
            split(actual, a, ".")
            split(required, r, ".")
            for (part = 1; part <= 3; part += 1) {
                actualPart = (a[part] == "" ? 0 : a[part]) + 0
                requiredPart = (r[part] == "" ? 0 : r[part]) + 0
                if (actualPart > requiredPart) exit 0
                if (actualPart < requiredPart) exit 1
            }
            exit 0
        }
    '
}

EXPECTED_DEVELOPER_DIR=${EXPECTED_DEVELOPER_DIR:-/Applications/Xcode_16.4.app/Contents/Developer}
EXPECTED_XCODEGEN_VERSION=${EXPECTED_XCODEGEN_VERSION:-2.45.4}

[ "$(/usr/bin/uname -m)" = arm64 ] || fail "Auralis CI requires an arm64 runner"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
command -v swift >/dev/null 2>&1 || fail "swift is required"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required"

ACTIVE_DEVELOPER_DIR=$(xcode-select -p)
[ "$ACTIVE_DEVELOPER_DIR" = "$EXPECTED_DEVELOPER_DIR" ] ||
    fail "active developer directory is $ACTIVE_DEVELOPER_DIR; expected $EXPECTED_DEVELOPER_DIR"

XCODE_VERSION=$(xcodebuild -version | /usr/bin/awk '/^Xcode / { print $2; exit }')
[ -n "$XCODE_VERSION" ] || fail "could not determine Xcode version"
version_at_least "$XCODE_VERSION" 16.4 ||
    fail "Xcode $XCODE_VERSION is below the 16.4 minimum"

SWIFT_VERSION=$(swift --version | /usr/bin/sed -n -E 's/.*Apple Swift version ([0-9]+(\.[0-9]+)+).*/\1/p' | /usr/bin/head -n 1)
[ -n "$SWIFT_VERSION" ] || fail "could not determine Apple Swift version"
version_at_least "$SWIFT_VERSION" 6.0 ||
    fail "Swift $SWIFT_VERSION is below the 6.0 minimum"

XCODEGEN_VERSION=$(xcodegen --version | /usr/bin/sed -n -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | /usr/bin/head -n 1)
[ "$XCODEGEN_VERSION" = "$EXPECTED_XCODEGEN_VERSION" ] ||
    fail "XcodeGen $XCODEGEN_VERSION is installed; expected $EXPECTED_XCODEGEN_VERSION"

printf '==> Toolchain preflight passed: arm64, Xcode %s, Swift %s, XcodeGen %s\n' \
    "$XCODE_VERSION" "$SWIFT_VERSION" "$XCODEGEN_VERSION"
