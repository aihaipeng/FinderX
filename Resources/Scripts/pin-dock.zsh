#!/bin/zsh
set -euo pipefail
# Dock integration uses the same preference format as the original application.
# This is an editable preset; it is not a public Dock API.
export LC_ALL=C
added=0
restart_dock() { if (( added > 0 )); then /usr/bin/killall Dock; fi }
trap restart_dock EXIT
existing=$(/usr/bin/defaults read com.apple.dock persistent-others 2>/dev/null || true)
xml_escape() {
  REPLY="${1//&/&amp;}"
  REPLY="${REPLY//</&lt;}"
  REPLY="${REPLY//>/&gt;}"
}
file_url() {
  local input="$1" char encoded='file://' number
  for (( offset = 1; offset <= ${#input}; offset++ )); do
    char="${input[$offset]}"
    case "$char" in
      [a-zA-Z0-9/._~-]) encoded+="$char" ;;
      *) printf -v number '%%%02X' "'$char"; encoded+="$number" ;;
    esac
  done
  REPLY="$encoded"
}
for selected_path in "$@"; do
  [[ -d "$selected_path" ]] || { print -ru2 -- "不是文件夹：$selected_path"; exit 1; }
  file_url "$selected_path"
  url="$REPLY"
  [[ "$existing" != *"$url"* ]] || continue
  xml_escape "${selected_path:t}"
  label="$REPLY"
  xml="<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$url</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-label</key><string>$label</string><key>file-type</key><integer>2</integer></dict><key>tile-type</key><string>directory-tile</string></dict>"
  /usr/bin/defaults write com.apple.dock persistent-others -array-add "$xml"
  existing+="$url"
  (( added += 1 ))
done
print -r -- "已新增固定 $added 个文件夹。"
