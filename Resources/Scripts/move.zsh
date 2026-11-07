#!/bin/zsh
set -euo pipefail
# Arguments: destination, one source. The framework invokes this once per source.
# Exit 100 when the source is already in the destination.
destination="$1"
source="$2"
[[ -d "$destination" ]] || { print -ru2 -- "目标文件夹不存在：$destination"; exit 1; }
[[ -e "$source" || -L "$source" ]] || { print -ru2 -- "源文件不存在：$source"; exit 1; }
real_destination=$(cd -- "$destination" && /bin/pwd -P)
real_parent=$(cd -- "${source:h}" && /bin/pwd -P)
if [[ "$real_destination" == "$real_parent" ]]; then
  print -r -- '已跳过：已经位于目标目录。'
  exit 100
fi
if [[ -d "$source" && ! -L "$source" ]]; then
  real_source=$(cd -- "$source" && /bin/pwd -P)
  if [[ "$real_destination" == "$real_source" || "$real_destination" == "$real_source"/* ]]; then
    print -ru2 -- '不能把文件夹移动到自身或其子目录。'
    exit 1
  fi
fi
name="${source:t}"
for (( index = 1; index <= 10000; index++ )); do
  candidate="$destination/$name"
  (( index == 1 )) || candidate="$destination/$name $index"
  [[ ! -e "$candidate" && ! -L "$candidate" ]] || continue
  # The app provides this CLI primitive for atomic, exclusive moves on macOS.
  if "$FINDERX_EXECUTABLE" --move-no-replace "$source" "$candidate"; then
    print -r -- "已移动：$candidate"
    exit 0
  else
    result_code=$?
    (( result_code == 17 )) || exit "$result_code"
  fi
done
print -ru2 -- '同名文件过多，无法分配新名称。'
exit 1
