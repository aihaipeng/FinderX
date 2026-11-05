#!/bin/bash
set -euo pipefail

DEST="$HOME/Applications/FinderX.app"

pkill -x FinderX 2>/dev/null || true
pkill -x FinderXFinder 2>/dev/null || true
pluginkit -r "$DEST/Contents/PlugIns/FinderXFinder.appex" 2>/dev/null || true
rm -rf "$DEST"

echo "Removed: $DEST"
echo "Configuration is kept at ~/Library/Containers/com.finderx.app.finder/Data/Library/Application Support/FinderX."
