#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPOSITORY_ROOT"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

ARCH=$(/usr/bin/uname -m)
[ "$ARCH" = "arm64" ] || fail "Auralis CI requires Apple Silicon (arm64); found '$ARCH'"

require_command swift
require_command xcodebuild
require_command xcodegen

SWIFT_VERSION=$(swift --version 2>/dev/null | /usr/bin/awk 'NR==1 {
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]/) { print $i; exit }
    }
}')
[ -n "$SWIFT_VERSION" ] || fail "could not parse Swift version"
SWIFT_MAJOR=${SWIFT_VERSION%%.*}
[ "$SWIFT_MAJOR" -ge 6 ] || fail "Swift >= 6 required; found '$SWIFT_VERSION'"

XCODE_VERSION=$(xcodebuild -version 2>/dev/null | /usr/bin/awk 'NR==1 { print $2 }')
[ -n "$XCODE_VERSION" ] || fail "could not parse Xcode version"
XCODE_MAJOR=${XCODE_VERSION%%.*}
XCODE_MINOR=$(printf '%s' "$XCODE_VERSION" | /usr/bin/awk -F. '{ print ($2 == "" ? 0 : $2) }')
if [ "$XCODE_MAJOR" -lt 16 ] || { [ "$XCODE_MAJOR" -eq 16 ] && [ "$XCODE_MINOR" -lt 4 ]; }; then
    fail "Xcode >= 16.4 required; found '$XCODE_VERSION'"
fi

XCODEGEN_VERSION=$(xcodegen --version 2>/dev/null | /usr/bin/awk '{ print $NF }')
[ "$XCODEGEN_VERSION" = "2.45.4" ] ||
    fail "XcodeGen 2.45.4 required; found '${XCODEGEN_VERSION:-unknown}'"

printf 'ci-preflight ok: arch=%s swift=%s xcode=%s xcodegen=%s developer_dir=%s\n' \
    "$ARCH" \
    "$SWIFT_VERSION" \
    "$XCODE_VERSION" \
    "$XCODEGEN_VERSION" \
    "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || printf unknown)}"
