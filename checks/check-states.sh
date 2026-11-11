#!/bin/zsh
# Walks the page through its states and its place-keeping in the check copy, and fails on a wrong one.
# Build the check copy first: CHECK_COPY=1 ./build.sh. COLUMNS_DISPLAY names a display to run on (see launch-check.sh).
cd "${0:A:h}/.."
T=$(mktemp -d); : > $T/js.log; fail=0
cp checks/fixtures/long.md checks/fixtures/short.md $T/
run() {  # run <script text>: runs it in the front page and prints what it returns
  rm -f $T/eval.js.out; print -r -- "$1" > $T/eval.tmp; mv $T/eval.tmp $T/eval.js  # in one step: the app reads the file the moment it is there
  for i in {1..80}; do sleep 0.5; [[ -f $T/eval.js.out ]] && break; done
  [[ -s $T/eval.js.out ]] || { echo "FAIL no answer from the page"; fail=1; return; }
  cat $T/eval.js.out; echo; grep -q "FAIL\|ERROR" $T/eval.js.out && fail=1
}
open_file() { COLUMNS_LOG=$T/js.log COLUMNS_EVAL=$T/eval.js checks/launch-check.sh "$1"; sleep 4; }

open_file $T/long.md
run "$(cat checks/states.js)"

# A live reload: text added above the reading line does not move it. (The message of the last check goes too.)
touch $T/long.md; sleep 2.5
run "R.jump('part-6-point-2', true); await new Promise(r => setTimeout(r, 600)); window.was = window.checkLine(); return 'ok   reload: reading ' + window.was;"
python3 - $T/long.md <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, 'w').write(t.replace("## Part 2\n", "## Part 2\n\nAn added paragraph, far above the reading line. " * 1 + "It is long enough to take several lines in a narrow column, so the text below it moves down by a clear amount.\n", 1))
PY
sleep 2.5
run "const now = window.checkLine(); return (now === window.was && R.state().page === 'document' ? 'ok   ' : 'FAIL ') + 'reload: the reading line stays — ' + now;"

# A section collapsed over the reading line, a live reload, the section expanded: the same line again.
run "R.toggleSection('part-6'); await new Promise(r => setTimeout(r, 900)); return (R.state().folded.includes('part-6') ? 'ok   ' : 'FAIL ') + 'collapsed the section being read';"
python3 - $T/long.md <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, 'w').write(t.replace("## Part 4\n", "## Part 4\n\nA second added paragraph, above the collapsed section, while it is collapsed.\n", 1))
PY
sleep 2.5
run "R.toggleSection('part-6'); await new Promise(r => setTimeout(r, 900)); const now = window.checkLine(); return (now === window.was ? 'ok   ' : 'FAIL ') + 'collapse, reload, expand: back on the same line — ' + now;"

open_file $T/short.md
run "const c = document.querySelector('.clip').getBoundingClientRect(), mid = (innerWidth - 10) / 2, s = R.state();
const ok = s.fill === 'single' && Math.abs((c.left + c.right) / 2 - mid) < 2 && getComputedStyle(document.getElementById('ribbons')).display === 'none' && (s.columns === 1 || getComputedStyle(document.querySelectorAll('.col')[1]).display === 'none');
return (ok ? 'ok   ' : 'FAIL ') + 'fill: a short document stands in the middle — ' + JSON.stringify([s.fill, s.columns, Math.round(c.left), Math.round(c.right), innerWidth]);"

# Links: one to a file that is not there says so in a sheet; one to another file (written without ".md", with a
# heading in capitals) opens that file at the heading.
link() { run "const a = document.createElement('a'); a.href = '$1'; document.querySelector('.md').append(a); a.click(); a.remove(); return 'ok   clicked $1';"; }
P='first process whose bundle identifier is "org.learningharness.columns.check"'
link nothing-here.md; sleep 1.5
sheets=$(osascript -e "tell application \"System Events\" to tell ($P) to get count of sheets of window 1" 2>&1)
[[ $sheets == 1 ]] && echo "ok   link to a missing file: a sheet says so" || { echo "FAIL link to a missing file: sheets $sheets"; fail=1; }
osascript -e "tell application \"System Events\" to tell ($P) to click button \"OK\" of sheet 1 of window 1" >/dev/null 2>&1; sleep 1
link 'long#Part 7, point 2'; sleep 4
run "const c = document.querySelector('.clip').getBoundingClientRect(), h = document.getElementById('part-7-point-2'), d = h ? Math.round(h.getBoundingClientRect().top - c.top) : null;
return (d > 0 && d < 60 ? 'ok   ' : 'FAIL ') + 'link to another file: opens at its heading — ' + document.querySelector('.md h1').textContent + ', heading ' + d + ' px below the top';"

[[ -s $T/js.log ]] && { echo "script errors:"; cat $T/js.log; fail=1; }
osascript -e 'tell application id "org.learningharness.columns.check" to quit' 2>/dev/null
exit $fail
