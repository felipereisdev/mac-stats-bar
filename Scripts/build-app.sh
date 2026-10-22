#!/bin/bash
# Builds build/MacStatsBar.app. Pass --universal for an arm64 + x86_64 binary.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacStatsBar
else
    swift build -c release
    BINARY=$(swift build -c release --show-bin-path)/MacStatsBar
fi

APP=build/MacStatsBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "$APP"
