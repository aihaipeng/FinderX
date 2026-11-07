#!/bin/zsh
set -euo pipefail
# Arguments: destination or --choose, then all selected paths.
# Exit 130 when the user cancels the destination chooser.
(( $# >= 2 )) || { print -ru2 -- '需要目标目录和至少一个源文件。'; exit 1; }
destination="$1"
shift
if [[ "$destination" == --choose ]]; then
  destination=$(/usr/bin/osascript <<'APPLESCRIPT'
try
  activate
  return POSIX path of (choose folder with prompt "选择“拷贝到”的目标文件夹" with invisibles)
on error number -128
  return ""
end try
APPLESCRIPT
  )
  [[ -n "$destination" ]] || { print -r -- '已取消拷贝。'; exit 130; }
fi
[[ "$destination" == /* && -d "$destination" ]] || { print -ru2 -- "目标文件夹不存在：$destination"; exit 1; }
real_destination="${destination:A}"
for source in "$@"; do
  [[ "$source" == /* && ( -e "$source" || -L "$source" ) ]] || { print -ru2 -- "源文件不存在或不是绝对路径：$source"; exit 1; }
  if [[ -d "$source" && ! -L "$source" ]]; then
    real_source="${source:A}"
    if [[ "$real_source" == / || "$real_destination" == "$real_source" || "$real_destination" == "$real_source"/* ]]; then
      print -ru2 -- '不能把文件夹拷贝到自身或其子目录。'
      exit 1
    fi
  fi
done
staging=$(/usr/bin/mktemp -d "$destination/.finderx-copy.XXXXXXXX")
trap '/bin/rm -rf -- "$staging"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
for source in "$@"; do
  source="${source:a}"
  /bin/cp -pPR "$source" "$staging/payload"
  name="${source:t}"
  copied=false
  for (( index = 1; index <= 10000; index++ )); do
    candidate="$destination/$name"
    (( index == 1 )) || candidate="$destination/$name $index"
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || continue
    # Publish the complete copy without replacing or nesting into an occupied path.
    if "$FINDERX_EXECUTABLE" --move-no-replace "$staging/payload" "$candidate"; then
      print -r -- "已拷贝：$candidate"
      copied=true
      break
    else
      result_code=$?
      (( result_code == 17 )) || exit "$result_code"
    fi
  done
  [[ "$copied" == true ]] || { print -ru2 -- '同名文件过多，无法分配新名称。'; exit 1; }
done
