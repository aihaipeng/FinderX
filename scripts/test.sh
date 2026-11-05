#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/finderx-tests.XXXXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
export MACOSX_DEPLOYMENT_TARGET=13.0
for script in "$ROOT"/Resources/Scripts/*.zsh; do /bin/zsh -n "$script"; done
swiftc -o "$TEST_BUILD/tests" "$ROOT"/Sources/Core/*.swift "$ROOT"/Sources/Runtime/*.swift \
  "$ROOT"/Sources/Shared/*.swift "$ROOT/Sources/Platform/macOS/NativeCommands.swift" \
  "$ROOT/Sources/Platform/macOS/ScriptLibrary.swift" "$ROOT/Tests/main.swift" -framework Cocoa
"$TEST_BUILD/tests" "$ROOT"
