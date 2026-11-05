#!/bin/zsh
set -euo pipefail
# Print each path literally; do not interpret backslashes or shell expressions.
if (( $# > 0 )); then
  { printf '%s' "$1"; shift; for selected_path in "$@"; do printf '\n%s' "$selected_path"; done } | /usr/bin/pbcopy
fi
