#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/finderx-finder-smoke.XXXXXXXX")"
trap 'rm -rf "$SMOKE_BUILD"' EXIT
swiftc "$ROOT/Tests/FinderSmoke/main.swift" -o "$SMOKE_BUILD/smoke" -framework Cocoa
"$SMOKE_BUILD/smoke" "$@"
