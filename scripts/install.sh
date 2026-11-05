#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/FinderX.app"
DEST="$HOME/Applications/FinderX.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ ! -d "$APP" ]]; then
  echo "Build first: scripts/build.sh" >&2
  exit 1
fi

pkill -x FinderX 2>/dev/null || true
pkill -x FinderXFinder 2>/dev/null || true
pkill -x SuperRight 2>/dev/null || true
pkill -x SuperRightFinder 2>/dev/null || true
pluginkit -e ignore -i com.superright.app.finder 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

"$LSREGISTER" -f "$DEST"
pluginkit -r "$DEST/Contents/PlugIns/FinderXFinder.appex" 2>/dev/null || true
pluginkit -a "$DEST/Contents/PlugIns/FinderXFinder.appex" 2>/dev/null || true
pluginkit -e use -i com.finderx.app.finder 2>/dev/null || true

open -g "$DEST"
echo "Installed: $DEST"
echo "If the extension is not enabled: System Settings > General > Login Items & Extensions > File Extensions."
