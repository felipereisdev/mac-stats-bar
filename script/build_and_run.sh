#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

case "$MODE" in
  run|--resources|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [run|--resources|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

pkill -x MacStatsBar >/dev/null 2>&1 || true
bash Scripts/build-app.sh
APP_BUNDLE="$PROJECT_ROOT/build/MacStatsBar.app"

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --resources) /usr/bin/open -n "$APP_BUNDLE" --args --resources ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE" --args --resources
    for attempt in {1..30}; do
      if pgrep -x MacStatsBar >/dev/null; then
        echo "MacStatsBar launched from $APP_BUNDLE"
        exit 0
      fi
      sleep 0.2
    done
    echo "MacStatsBar did not stay running" >&2
    exit 1
    ;;
  --debug) exec lldb -- "$APP_BUNDLE/Contents/MacOS/MacStatsBar" --resources ;;
  --logs|--telemetry)
    /usr/bin/open -n "$APP_BUNDLE" --args --resources
    exec /usr/bin/log stream --info --style compact --predicate 'process == "MacStatsBar"'
    ;;
esac
