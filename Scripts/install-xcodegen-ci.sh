#!/bin/sh
set -eu

# Pin XcodeGen 2.45.4 from the official GitHub release and verify SHA-256.

XCODEGEN_VERSION=2.45.4
XCODEGEN_SHA256=090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

INSTALL_ROOT=${AURALIS_XCODEGEN_ROOT:-"${RUNNER_TEMP:-/tmp}/auralis-xcodegen-${XCODEGEN_VERSION}"}
BIN_DIR="$INSTALL_ROOT/bin"
ZIP_PATH="$INSTALL_ROOT/xcodegen.zip"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$INSTALL_ROOT" "$BIN_DIR"

prepend_path() {
    export PATH="$BIN_DIR:$PATH"
    if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$BIN_DIR" >> "$GITHUB_PATH"
    fi
}

if [ -x "$BIN_DIR/xcodegen" ]; then
    INSTALLED=$("$BIN_DIR/xcodegen" --version 2>/dev/null | /usr/bin/awk '{ print $NF }' || true)
    if [ "$INSTALLED" = "$XCODEGEN_VERSION" ]; then
        prepend_path
        printf 'Using cached XcodeGen %s at %s\n' "$XCODEGEN_VERSION" "$BIN_DIR"
        exit 0
    fi
fi

curl -fsSL "$XCODEGEN_URL" -o "$ZIP_PATH"
ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$ZIP_PATH" | /usr/bin/awk '{ print $1 }')
[ "$ACTUAL_SHA" = "$XCODEGEN_SHA256" ] ||
    fail "XcodeGen zip SHA-256 mismatch: expected $XCODEGEN_SHA256, got $ACTUAL_SHA"

rm -rf "$INSTALL_ROOT/extract"
mkdir -p "$INSTALL_ROOT/extract"
/usr/bin/unzip -q "$ZIP_PATH" -d "$INSTALL_ROOT/extract"

if [ -x "$INSTALL_ROOT/extract/bin/xcodegen" ]; then
    cp "$INSTALL_ROOT/extract/bin/xcodegen" "$BIN_DIR/xcodegen"
elif [ -x "$INSTALL_ROOT/extract/xcodegen" ]; then
    cp "$INSTALL_ROOT/extract/xcodegen" "$BIN_DIR/xcodegen"
elif [ -x "$INSTALL_ROOT/extract/xcodegen/bin/xcodegen" ]; then
    cp "$INSTALL_ROOT/extract/xcodegen/bin/xcodegen" "$BIN_DIR/xcodegen"
else
    fail "could not locate xcodegen binary inside release zip"
fi
chmod +x "$BIN_DIR/xcodegen"

VERSION=$("$BIN_DIR/xcodegen" --version 2>/dev/null | /usr/bin/awk '{ print $NF }')
[ "$VERSION" = "$XCODEGEN_VERSION" ] ||
    fail "installed XcodeGen reports '$VERSION'; expected $XCODEGEN_VERSION"

prepend_path
printf 'Installed XcodeGen %s (sha256 verified) to %s\n' "$XCODEGEN_VERSION" "$BIN_DIR"
