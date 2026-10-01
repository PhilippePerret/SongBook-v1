#!/bin/zsh
# Usage: sf_export.sh <document.screenflow> <export.mp4>
doc="${1:A}"; mp4="${2:A}"; name="${doc:t:r}"
rm -f "$mp4"
open -a ScreenFlow "$doc"
osascript - "$name" <<'OSA'
on run argv
  set n to item 1 of argv
  tell application "ScreenFlow" to activate
  tell application "System Events" to tell process "ScreenFlow"
    repeat 30 times
      if exists window n then exit repeat
      delay 1
    end repeat
    perform action "AXRaise" of window n
    delay 1
    click menu item "Exporter…" of menu 1 of menu bar item 3 of menu bar 1
    repeat 20 times
      if exists sheet 1 of window n then exit repeat
      delay 0.5
    end repeat
    click button "Exporter" of sheet 1 of window n
  end tell
end run
OSA
# attente de la fin d'écriture
prev=-1
while true; do
  sleep 3
  [[ -f "$mp4" ]] || continue
  size=$(stat -f %z "$mp4")
  [[ "$size" == "$prev" && "$size" -gt 0 ]] && break
  prev=$size
done
osascript -e "tell application \"System Events\" to tell process \"ScreenFlow\" to click menu item \"Fermer\" of menu 1 of menu bar item 3 of menu bar 1"
echo "Fait : $mp4"
