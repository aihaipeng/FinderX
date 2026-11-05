#!/bin/zsh
set -euo pipefail
# Create under a private staging directory, then move the link into place.
# This prevents ln from creating a link *inside* an existing target directory.
destination="$1"
source="$2"
[[ -d "$destination" ]] || { print -ru2 -- "目标文件夹不存在：$destination"; exit 1; }
staging=$(/usr/bin/mktemp -d "$destination/.finderx-link.XXXXXXXX")
trap '/bin/rm -rf -- "$staging"' EXIT
/bin/ln -s "$source" "$staging/link"
name="${source:t}"
for (( index = 1; index <= 10000; index++ )); do
  candidate="$destination/$name"
  (( index == 1 )) || candidate="$destination/$name $index"
  [[ ! -e "$candidate" && ! -L "$candidate" ]] || continue
  if "$FINDERX_EXECUTABLE" --move-no-replace "$staging/link" "$candidate"; then
    print -r -- "已创建符号链接：$candidate"
    exit 0
  else
    result_code=$?
    (( result_code == 17 )) || exit "$result_code"
  fi
done
print -ru2 -- '同名文件过多，无法分配新名称。'
exit 1
