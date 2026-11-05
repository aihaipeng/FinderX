#!/bin/zsh
set -euo pipefail
/usr/bin/open -b org.localsend.localsendApp "$@"
printf '%s\n' '已提交打开请求。'
