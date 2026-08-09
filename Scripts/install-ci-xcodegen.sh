#!/bin/sh
set -eu

XCODEGEN_VERSION=${XCODEGEN_VERSION:-2.45.4}
XCODEGEN_SHA256=${XCODEGEN_SHA256:-090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef}
TEMP_ROOT=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
INSTALL_ROOT=$TEMP_ROOT/auralis-xcodegen-$XCODEGEN_VERSION
ARCHIVE_PATH=$TEMP_ROOT/xcodegen-$XCODEGEN_VERSION.zip

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required to install XcodeGen"
command -v shasum >/dev/null 2>&1 || fail "shasum is required to verify XcodeGen"
command -v unzip >/dev/null 2>&1 || fail "unzip is required to install XcodeGen"

/bin/rm -rf "$INSTALL_ROOT" "$ARCHIVE_PATH"
curl --fail --location --retry 3 --retry-delay 2 --output "$ARCHIVE_PATH" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
printf '%s  %s\n' "$XCODEGEN_SHA256" "$ARCHIVE_PATH" | shasum -a 256 --check
/bin/mkdir -p "$INSTALL_ROOT"
unzip -q "$ARCHIVE_PATH" -d "$INSTALL_ROOT"
XCODEGEN_BINARY=$(/usr/bin/find "$INSTALL_ROOT" -type f -name xcodegen -perm -111 -print -quit)
[ -n "$XCODEGEN_BINARY" ] || fail "XcodeGen archive did not contain an executable"
XCODEGEN_DIRECTORY=$(dirname "$XCODEGEN_BINARY")

if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$XCODEGEN_DIRECTORY" >> "$GITHUB_PATH"
fi
printf '==> Installed XcodeGen %s at %s\n' "$XCODEGEN_VERSION" "$XCODEGEN_BINARY"
