#!/bin/bash
# Builds MacStatsBar.app, installs it in /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

Scripts/build-app.sh

pkill -x MacStatsBar 2>/dev/null || true
rm -rf /Applications/MacStatsBar.app
cp -R build/MacStatsBar.app /Applications/
open /Applications/MacStatsBar.app
echo "Instalado em /Applications/MacStatsBar.app"
