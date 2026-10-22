#!/bin/bash
# Builds a universal MacStatsBar.app and zips it for a GitHub release: build/MacStatsBar-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-app.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/MacStatsBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/MacStatsBar.app "$ZIP"
echo "$ZIP"
