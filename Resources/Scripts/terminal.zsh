#!/bin/zsh
set -euo pipefail
/usr/bin/open -b com.apple.Terminal "$@"
printf '%s\n' '已提交打开请求。'
