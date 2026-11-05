#!/bin/zsh
set -euo pipefail
application="$1"
shift
/usr/bin/open -a "$application" "$@"
printf '%s\n' '已提交打开请求。'
