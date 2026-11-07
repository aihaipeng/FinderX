#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/FinderX.app"
APPEX="$APP/Contents/PlugIns/FinderXFinder.appex"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

export MACOSX_DEPLOYMENT_TARGET=13.0
TARGET="$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET}"
SHARED_SOURCES=("$ROOT"/Sources/Core/*.swift "$ROOT"/Sources/Shared/*.swift)
HOST_SOURCES=("$ROOT"/Sources/App/*.swift "$ROOT"/Sources/Runtime/*.swift "$ROOT"/Sources/Platform/macOS/*.swift "${SHARED_SOURCES[@]}")

swiftc -target "$TARGET" -O -o "$APP/Contents/MacOS/FinderX" "${HOST_SOURCES[@]}" \
  -framework Cocoa -framework FinderSync

swiftc -target "$TARGET" -O -module-name FinderXFinder -emit-executable \
  -o "$APPEX/Contents/MacOS/FinderXFinder" \
  "$ROOT/Sources/FinderExtension/FinderSync.swift" \
  "${SHARED_SOURCES[@]}" \
  -framework Cocoa -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -Xlinker -undefined -Xlinker dynamic_lookup

cp "$ROOT/Resources/AppInfo.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ExtensionInfo.plist" "$APPEX/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R "$ROOT/Resources/Scripts" "$APP/Contents/Resources/Scripts"

codesign --force --sign - --entitlements "$ROOT/Resources/Extension.entitlements" "$APPEX"
codesign --force --sign - "$APP"

echo "Built: $APP"
