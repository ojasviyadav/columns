#!/bin/zsh
# Checks the window behaviour Mac apps share, in the check copy (build it first: CHECK_COPY=1 ./build.sh):
# Zoom goes to a larger frame and back, a new window opens stepped from the front one without moving it, Columns stays
# open when its last window closes, and the page keeps the system's keys. COLUMNS_DISPLAY: see launch-check.sh.
cd "${0:A:h}/.."
id=org.learningharness.columns.check; P="first process whose bundle identifier is \"$id\""; fail=0
T=$(mktemp -d); cp checks/fixtures/long.md checks/fixtures/short.md $T/
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 — $3"; fail=1; fi; }
se() { osascript -e "tell application \"System Events\" to tell ($P) to $1" 2>&1; }
frame() { se "get {position, size} of window 1" | tr -d ' '; }
run() {  # run <script text>: runs it in the front page and prints what it returns
  rm -f $T/eval.js.out; print -r -- "$1" > $T/eval.tmp; mv $T/eval.tmp $T/eval.js
  for i in {1..40}; do sleep 0.5; [[ -f $T/eval.js.out ]] && break; done; cat $T/eval.js.out 2>/dev/null
}
COLUMNS_EVAL=$T/eval.js checks/launch-check.sh $T/long.md; sleep 4
se "set size of window 1 to {900, 600}" >/dev/null; sleep 1
small=$(frame)
# Zoom as a title bar double-click does it (performZoom), without bringing Columns to the front.
run 'webkit.messageHandlers.zoom.postMessage(1); return "";' >/dev/null; sleep 1.2
zoomed=$(frame)
run 'webkit.messageHandlers.zoom.postMessage(1); return "";' >/dev/null; sleep 1.2
back=$(frame)
ok "Zoom: a larger frame" '[[ $zoomed != $small ]]' "$small -> $zoomed"
ok "Zoom again: back to the frame before" '[[ $back == $small ]]' "$small -> $zoomed -> $back"
# A double-click on the title bar, as the window gets it, does what the Mac is set to do (the app's own copy of the
# setting stands in for the Mac's here, so the check never changes the Mac's).
dbl() { run 'webkit.messageHandlers.titleDoubleClick.postMessage(1); return "";' >/dev/null; sleep 1.2; }
defaults delete $id AppleActionOnDoubleClick 2>/dev/null; dbl; d1=$(frame); dbl; d2=$(frame)
ok "title bar double-click: fills the screen" '[[ $d1 != $small ]]' "$small -> $d1"
ok "title bar double-click again: back" '[[ $d2 == $small ]]' "$small -> $d1 -> $d2"
defaults write $id AppleActionOnDoubleClick None; sleep 0.5; dbl; d3=$(frame)
ok "title bar double-click, set to No Action: nothing" '[[ $d3 == $small ]]' "$small -> $d3"
defaults write $id AppleActionOnDoubleClick Minimize; sleep 0.5; dbl
mini=$(se "get value of attribute \"AXMinimized\" of window 1")
ok "title bar double-click, set to Minimize: minimized" '[[ $mini == true ]]' "minimized: $mini"
se "set value of attribute \"AXMinimized\" of window 1 to false" >/dev/null; sleep 1
defaults delete $id AppleActionOnDoubleClick
# Narrow window: fewer columns shown than asked for, each one readable.
se "set size of window 1 to {720, 600}" >/dev/null; sleep 1.5
shown=$(run 'R.setColumns(6, true); await new Promise(r => setTimeout(r, 300)); const s = R.state(); return s.columns + " " + s.shown;')
ok "narrow window: fewer columns shown" '[[ $shown == "6 2" ]]' "asked, shown: $shown"
run 'R.setColumns(3, true); return "";' >/dev/null
# Keys: Shift-arrows are left to the system; Option-arrow goes a page.
keys=$(run 'R.go("top", true); const y = () => document.querySelector(".md").style.transform; const a = y();
dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", shiftKey: true, bubbles: true })); const b = y();
dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", altKey: true, bubbles: true })); const c = y(); return [a === b, b !== c].join(" ");')
ok "keys: Shift-arrow left to the system, Option-arrow pages" '[[ $keys == "true true" ]]' "$keys"
# A second file opens as a tab of the window in front, which stays where it is; the tab bar shows.
before=$(frame)
open -g -a "$PWD/build/Columns Check.app" $T/short.md; sleep 3
tabs() { se 'get title of radio buttons of (first UI element of window 1 whose role is "AXTabGroup")' | sed 's/.*error.*/(no tab bar)/'; }
ok "a second file opens as a tab" '[[ $(se "count windows") == 1 && $(tabs) == "long.md, short.md" ]]' "$(se 'count windows') windows, tabs: $(tabs)"
ok "the window stays where it was" '[[ $(frame) == $before ]]' "$before -> $(frame)"
act() { run "webkit.messageHandlers.act.postMessage('$1'); return '';" >/dev/null; sleep 1.2; }
act moveTab
ok "Move Tab to New Window: two windows, each with its tab bar" '[[ $(se "count windows") == 2 && $(tabs) == "short.md" ]]' "$(se 'count windows') windows, front tabs: $(tabs)"
act merge
set_tabs() { tabs | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ' '; }
ok "Merge All Windows: one window, both tabs" '[[ $(se "count windows") == 1 && $(set_tabs) == "long.md short.md " ]]' "$(se 'count windows') windows, tabs: $(tabs)"
selected() { se 'get title of (first radio button of (first UI element of window 1 whose role is "AXTabGroup") whose value is 1)'; }
shown=$(selected); act previousTab
ok "Show Previous Tab: the other tab shows" '[[ $(selected) != $shown ]]' "$shown -> $(selected)"
shown=$(selected); act closeTab
ok "Close Tab: the tab that showed is closed" '[[ $(se "count windows") == 1 && $(tabs) != *$shown* && $(tabs) != "(no tab bar)" ]]' "closed $shown, tabs: $(tabs)"
act reopen
ok "Reopen Closed Tab: it comes back" '[[ $(set_tabs) == "long.md short.md " && $(selected) == $shown ]]' "tabs: $(tabs), showing: $(selected)"
# Closing the window with all its tabs keeps Columns running.
act closeWindow; sleep 1
running=$(pgrep -f "Columns Check.app/Contents/MacOS" | wc -l | tr -d ' ')
ok "the last window closed: Columns keeps running" '[[ $running -ge 1 ]]' "processes: $running"
osascript -e "tell application id \"$id\" to quit" 2>/dev/null
exit $fail
