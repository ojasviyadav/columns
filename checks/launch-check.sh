#!/bin/zsh
# Opens files in the check copy (build/Columns Check.app), in the background.
#   COLUMNS_DISPLAY=<display name>  opens the window on that display (default: the main display), so checks can run
#                                   on a display of their own while you keep working
#   COLUMNS_EXPORT=<file.pdf>       also exports the first file as a PDF two seconds after launch
#   COLUMNS_LOG=<file>              collects the page's script errors
#   COLUMNS_EVAL=<file>             a script written there runs in the front page within a second; its result lands in <file>.out
cd "${0:A:h}/.."
id=org.learningharness.columns.check
osascript -e "tell application id \"$id\" to quit" 2>/dev/null; sleep 1
# No "reopen windows?" prompt after a crash.
rm -rf ~/Library/Saved\ Application\ State/$id.savedState
defaults write $id ApplePersistenceIgnoreState -bool YES
# A window off every display draws no frames, and every timed check then stalls: the frame is worked out from the
# display as it is now.
frame=$(COLUMNS_DISPLAY="${COLUMNS_DISPLAY:-}" osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.import("stdlib");
var want = ObjC.unwrap($.getenv("COLUMNS_DISPLAY")) || "", ss = $.NSScreen.screens, f = null;
for (var i = 0; i < ss.count; i++) { var s = ss.objectAtIndex(i); if (want ? ObjC.unwrap(s.localizedName) == want : i == 0) f = s.visibleFrame; }
f ? "{{" + (f.origin.x + 12) + ", " + (f.origin.y + 12) + "}, {" + Math.min(1470, f.size.width - 24) + ", " + Math.min(919, f.size.height - 24) + "}}" : ""')
[[ -z "$frame" ]] && { echo "No display named \"$COLUMNS_DISPLAY\"" >&2; exit 1; }
env=(--env "COLUMNS_FRAME=$frame")
for v in COLUMNS_EXPORT COLUMNS_LOG COLUMNS_EVAL; do [[ -n "${(P)v}" ]] && env+=(--env "$v=${(P)v}"); done
open -g -n "${env[@]}" -a "$PWD/build/Columns Check.app" "$@"
# With a display named, every window of the check copy must be on it: one anywhere else (the user's own display)
# quits the check copy and stops the checks.
if [[ -n "${COLUMNS_DISPLAY:-}" ]]; then
  area=$(COLUMNS_DISPLAY="$COLUMNS_DISPLAY" osascript -l JavaScript -e 'ObjC.import("AppKit"); ObjC.import("stdlib");
var want = ObjC.unwrap($.getenv("COLUMNS_DISPLAY")), ss = $.NSScreen.screens, mainH = ss.objectAtIndex(0).frame.size.height, a = "";
for (var i = 0; i < ss.count; i++) { var s = ss.objectAtIndex(i), f = s.frame; if (ObjC.unwrap(s.localizedName) == want) a = [f.origin.x, mainH - f.origin.y - f.size.height, f.size.width, f.size.height].join(" "); }
a')
  read ax ay aw ah <<< "$area"
  for i in {1..20}; do
    sleep 0.5
    wins=$(osascript -e "tell application \"System Events\" to tell (first process whose bundle identifier is \"$id\") to get position of every window" 2>/dev/null | tr -d ' ')
    [[ -n "$wins" ]] && break
  done
  for x y in ${(s:,:)wins}; do
    if (( x < ax || y < ay || x >= ax + aw || y >= ay + ah )); then
      osascript -e "tell application id \"$id\" to quit" 2>/dev/null
      echo "STOP a check window opened at $x,$y, outside \"$COLUMNS_DISPLAY\" ($ax,$ay ${aw}x$ah); the check copy was quit" >&2
      exit 3
    fi
  done
fi
