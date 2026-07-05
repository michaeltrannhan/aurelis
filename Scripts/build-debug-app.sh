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

echo "$APP_DIR"
