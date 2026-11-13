#!/bin/bash
# End-to-end test against the *running daemon* (needs Accessibility granted to LayoutKeeper.app).
# Uses TextEdit as a guinea pig so your real windows are only moved back to where they already are.
set -uo pipefail
LK="${LK:-$HOME/.local/libexec/layoutkeeper/layoutkeeper}"
TE=com.apple.TextEdit
pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }
frame_of() { "$LK" capture --via-daemon | python3 -c "
import json,sys; l=json.load(sys.stdin)
ws=[w for w in l['windows'] if w['bundleID']=='$1']
print(' '.join(f\"{int(w['abs']['x'])},{int(w['abs']['y'])},{int(w['abs']['w'])},{int(w['abs']['h'])}\" for w in ws))"; }

echo "== daemon"
P=$("$LK" ping) || { echo "$P"; echo "daemon not answering; run scripts/install.sh"; exit 1; }
echo "$P"
grep -q "trusted=true" <<<"$P" && ok "daemon has Accessibility" || { bad "daemon lacks Accessibility (enable LayoutKeeper in System Settings > Privacy & Security > Accessibility)"; exit 1; }

FP=$("$LK" displays | sed -n 's/.*\[\(.*\)\]/\1/p' | head -1)
LAYOUT="$HOME/Library/Application Support/LayoutKeeper/layouts/$FP.json"
BACKUP=$(mktemp); HAD_LAYOUT=0
[ -f "$LAYOUT" ] && { cp "$LAYOUT" "$BACKUP"; HAD_LAYOUT=1; }
restore_layout_file() { if [ "$HAD_LAYOUT" = 1 ]; then cp "$BACKUP" "$LAYOUT"; else rm -f "$LAYOUT"; fi; }
trap restore_layout_file EXIT

echo "== capture sees real windows"
N=$("$LK" capture --via-daemon | python3 -c "import json,sys; print(len(json.load(sys.stdin)['windows']))")
[ "$N" -gt 0 ] && ok "captured $N windows" || bad "captured no windows"

DOC=/tmp/layoutkeeper-e2e.txt; echo "layoutkeeper e2e" > "$DOC"
echo "== open TextEdit at a known place"
open -a TextEdit "$DOC"; sleep 3
"$LK" nudge "$TE" 0 0 >/dev/null 2>&1
BASE=$(frame_of $TE); echo "textedit frame: $BASE"
[ -n "$BASE" ] && ok "TextEdit window visible to AX" || { bad "TextEdit window not visible"; exit 1; }

echo "== save (pin) current layout"
OUT=$("$LK" save); echo "$OUT"; grep -q "^Pinned" <<<"$OUT" && ok "pinned layout" || bad "pin failed"
BACKUP_NOTE="(saved layouts were restored to their pre-test state)"

echo "== move TextEdit, restore, verify it snaps back"
"$LK" nudge "$TE" 137 91 >/dev/null; sleep 1
MOVED=$(frame_of $TE); echo "after nudge: $MOVED"
[ "$MOVED" != "$BASE" ] && ok "nudge moved the window" || bad "nudge did nothing"
OUT=$("$LK" restore --app "$TE"); echo "$OUT"
sleep 1; AFTER=$(frame_of $TE); echo "after restore: $AFTER"
[ "$AFTER" = "$BASE" ] && ok "restore put TextEdit back exactly" || bad "restore mismatch: want $BASE got $AFTER"

echo "== move TextEdit onto the other display (if any), restore"
ND=$("$LK" displays | grep -c "key=")
if [ "$ND" -ge 2 ]; then
  # shift so the window lands 100px inside whichever display it is NOT on now
  read -r DX DY < <("$LK" capture --via-daemon | python3 -c "
import json,sys; l=json.load(sys.stdin)
w=[w for w in l['windows'] if w['bundleID']=='$TE'][0]
d=[d for d in l['displays'] if d['key']!=w['displayKey']][0]['frame']
print(int(d['x']+100-w['abs']['x']), int(d['y']+100-w['abs']['y']))")
  "$LK" nudge "$TE" "$DX" "$DY" >/dev/null; sleep 1
  echo "cross-display: $(frame_of $TE)"
  "$LK" restore --app "$TE" >/dev/null; sleep 1; AFTER=$(frame_of $TE)
  [ "$AFTER" = "$BASE" ] && ok "restore pulled window back from other display" || bad "cross-display restore mismatch: want $BASE got $AFTER"
else
  echo "skip (one display)"
fi

echo "== full restore is a no-op for windows already in place"
OUT=$("$LK" restore --dry-run); echo "$OUT"
grep -qE "moved 0," <<<"$OUT" && ok "dry-run finds nothing to move" || bad "dry-run wants to move windows right after save"

echo "== place-on-launch: quit TextEdit, relaunch, daemon should put it back"
osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1; sleep 2
open -a TextEdit "$DOC"; sleep 1
"$LK" nudge "$TE" 200 120 >/dev/null 2>&1   # macOS may reopen it anywhere; force it off-target
sleep 10
AFTER=$(frame_of $TE); echo "after relaunch+placement: $AFTER"
[ "$AFTER" = "$BASE" ] && ok "daemon placed relaunched app where it was" || bad "place-on-launch mismatch: want $BASE got $AFTER (see ~/Library/Logs/LayoutKeeper.log)"

echo "== a bare signal moves nothing; reload does"
"$LK" save >/dev/null; sleep 1
CUR=$(frame_of $TE)
PID=$(sed -n 's/.*pong pid \([0-9]*\).*/\1/p' <<<"$P")
trap '"$LK" simulate unlock >/dev/null 2>&1; restore_layout_file' EXIT
"$LK" nudge "$TE" 70 40 >/dev/null; kill -USR1 "$PID"; sleep 3
[ "$(frame_of $TE)" != "$CUR" ] && ok "bare SIGUSR1 is ignored" || bad "bare SIGUSR1 moved windows"
"$LK" reload >/dev/null; sleep 3
[ "$(frame_of $TE)" = "$CUR" ] && ok "reload restores" || bad "reload did not restore: want $CUR got $(frame_of $TE)"
for i in $(seq 1 30); do "$LK" ping | grep -q restoring || break; sleep 2; done
"$LK" ping | grep -q restoring && bad "restore passes never finished" || ok "restore passes finish once windows stay put"

echo "== restore --pinned"
"$LK" nudge "$TE" 70 40 >/dev/null; sleep 1
"$LK" restore --pinned --app "$TE" >/dev/null; sleep 1
[ "$(frame_of $TE)" = "$CUR" ] && ok "pinned layout restores" || bad "restore --pinned mismatch: want $CUR got $(frame_of $TE)"

echo "== wake from sleep (simulated): windows go back without being asked"
"$LK" nudge "$TE" 90 60 >/dev/null
"$LK" simulate wake >/dev/null; sleep 8
[ "$(frame_of $TE)" = "$CUR" ] && ok "wake restores the layout" || bad "wake did not restore: want $CUR got $(frame_of $TE)"
for i in $(seq 1 30); do "$LK" ping | grep -q restoring || break; sleep 2; done

echo "== locked screen (simulated): nothing moves until unlock"
"$LK" simulate lock >/dev/null
"$LK" nudge "$TE" 90 60 >/dev/null; NUDGED=$(frame_of $TE)
"$LK" simulate wake >/dev/null; sleep 9
[ "$(frame_of $TE)" = "$NUDGED" ] && ok "no restore while locked" || bad "windows moved while locked"
"$LK" ping | grep -q restoring && ok "restore is waiting for the unlock" || bad "restore gave up while locked"
"$LK" simulate unlock >/dev/null; sleep 8
[ "$(frame_of $TE)" = "$CUR" ] && ok "restore completes after unlock" || bad "no restore after unlock: want $CUR got $(frame_of $TE)"
for i in $(seq 1 30); do "$LK" ping | grep -q restoring || break; sleep 2; done

echo "== a saved window that was closed does not drag another window to its place"
DOC2=/tmp/layoutkeeper-e2e-2.txt; echo "second" > "$DOC2"
open -a TextEdit "$DOC2"; sleep 2
"$LK" nudge "$TE" 0 0 >/dev/null
"$LK" save >/dev/null; sleep 1
TWO=$("$LK" capture --via-daemon | python3 -c "
import json,sys; l=json.load(sys.stdin)
print(sum(1 for w in l['windows'] if w['bundleID']=='$TE'))")
[ "$TWO" = 2 ] && ok "two TextEdit windows saved" || bad "expected 2 TextEdit windows, saw $TWO"
KEEP=$("$LK" capture --via-daemon | python3 -c "
import json,sys; l=json.load(sys.stdin)
w=[w for w in l['windows'] if w['bundleID']=='$TE' and 'e2e-2' not in w['title']][0]['abs']
print(f\"{int(w['x'])},{int(w['y'])},{int(w['w'])},{int(w['h'])}\")")
osascript -e 'tell application "TextEdit" to close (every window whose name contains "e2e-2") saving no' >/dev/null 2>&1; sleep 2
OUT=$("$LK" restore --dry-run --app "$TE"); echo "$OUT"
grep -q "moved 0, in place 1" <<<"$OUT" && ok "remaining window keeps its own place" || bad "leftover record would move the remaining window"
[ "$(frame_of $TE)" = "$KEEP" ] && ok "remaining window untouched" || bad "remaining window moved: want $KEEP got $(frame_of $TE)"
rm -f "$DOC2"

echo "== desktops: an app that ended up on another desktop is sent back"
space_of() { "$LK" capture --via-daemon | python3 -c "
import json,sys; l=json.load(sys.stdin)
print(' '.join(str(w.get('space')) for w in l['windows'] if w['bundleID']=='$1'))"; }
"$LK" save >/dev/null; sleep 1
HOME_SPACE=$(space_of $TE); HOME_FRAME=$(frame_of $TE)
OUT=$("$LK" simulate respace "$TE"); echo "$OUT"
if grep -q "no other desktop" <<<"$OUT"; then
  echo "skip (one desktop)"
else
  sleep 1
  [ "$(space_of $TE)" != "$HOME_SPACE" ] && ok "TextEdit is on another desktop" || bad "could not move TextEdit to another desktop"
  "$LK" restore --app "$TE" >/dev/null; sleep 1
  [ "$(space_of $TE)" = "$HOME_SPACE" ] && ok "restore sent it back to its desktop" || bad "still on the wrong desktop: want $HOME_SPACE got $(space_of $TE)"
  [ "$(frame_of $TE)" = "$HOME_FRAME" ] && ok "and to its position" || bad "wrong position after desktop move: want $HOME_FRAME got $(frame_of $TE)"
  "$LK" simulate respace "$TE" >/dev/null; "$LK" simulate wake >/dev/null; sleep 9
  [ "$(space_of $TE)" = "$HOME_SPACE" ] && ok "wake also sends it back" || bad "wake left it on the wrong desktop"
  for i in $(seq 1 30); do "$LK" ping | grep -q restoring || break; sleep 2; done
fi

echo "== autosave"
"$LK" nudge "$TE" 50 50 >/dev/null; sleep 1
kill -USR2 "$(sed -n 's/.*pong pid \([0-9]*\).*/\1/p' <<<"$P")"; sleep 2
A=$("$LK" show --auto | grep -c TextEdit)
[ "$A" -ge 1 ] && ok "autosave captured TextEdit" || bad "autosave missing TextEdit"

echo "== cleanup"
osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1; rm -f "$DOC"
echo
echo "$pass passed, $fail failed. $BACKUP_NOTE"
[ "$fail" -eq 0 ]
