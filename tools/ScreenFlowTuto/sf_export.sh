#!/bin/zsh
# Usage: sf_export.sh <document.screenflow> <export.mp4>
# ScreenFlow n'est mis au premier plan que pour lancer l'export ; l'application qui
# avait le focus le reprend dès l'export lancé. ScreenFlow reste ouvert (cf. TutoVideo).
doc="${1:A}"; mp4="${2:A}"; name="${doc:t:r}"
rm -f "$mp4"
front_id() { osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' }
start_front=$(front_id)
open -g -a ScreenFlow "$doc"
osascript - "$name" "$start_front" <<'OSA' || exit 1
on run argv
  set n to item 1 of argv
  tell application "System Events" to tell process "ScreenFlow"
    repeat 30 times
      if exists window n then exit repeat
      delay 1
    end repeat
  end tell
  tell application "System Events" to set prevApp to bundle identifier of first process whose frontmost is true
  if prevApp contains "screenflow" then set prevApp to item 2 of argv
  repeat 3 times
    tell application "ScreenFlow" to activate
    delay 0.3
  end repeat
  tell application "System Events" to tell process "ScreenFlow"
    perform action "AXRaise" of window n
    delay 1
    click menu item "Exporter…" of menu 1 of menu bar item 3 of menu bar 1
    repeat 20 times
      if exists sheet 1 of window n then exit repeat
      delay 0.5
    end repeat
    click button "Exporter" of sheet 1 of window n
  end tell
  if prevApp does not contain "screenflow" then tell application id prevApp to activate
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
