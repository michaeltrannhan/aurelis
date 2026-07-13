#!/bin/sh
set -eu

swift build

APP_DIR=".build/EQMacRep.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/debug/EQMacRep" "$MACOS_DIR/EQMacRep"
cp "Resources/EQMacRep-Info.plist" "$CONTENTS_DIR/Info.plist"

# Screen & System Audio Recording (TCC) permission is keyed to the app's code
# signing requirement. Use a certificate-backed identity so that requirement is
# stable when the executable changes. If the caller did not pin an identity,
# choose the first valid code-signing identity in the user's keychains.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*) \([[:xdigit:]]\{40\}\) .*/\1/p' \
        | head -n 1)"
fi

if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    printf '%s\n' \
        "A persistent code-signing identity is required." \
        "Create or import an Apple Development or local Code Signing certificate," \
        "then rerun with SIGN_IDENTITY='certificate name or SHA-1 hash'." \
        "Ad-hoc signing is unsupported because its TCC requirement changes after rebuilds." >&2
    exit 1
fi

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "$APP_DIR"
