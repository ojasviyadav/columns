// Walks the page through its state machines and reports each named state (run by check-states.sh in the check copy).
const wait = ms => new Promise(r => setTimeout(r, ms));
const until = async (test, ms = 3000) => { for (const t0 = performance.now(); performance.now() - t0 < ms; await wait(30)) if (test()) return true; return false; };
const out = [], st = () => R.state();
const check = (name, ok, got) => out.push((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : ' — got ' + JSON.stringify(got)));
const tr = () => document.querySelector('.md').style.transform;
const topLine = () => { const c = document.querySelector('.clip').getBoundingClientRect(); const h = [...document.querySelector('.md').querySelectorAll('h1, h2, h3')].find(x => x.getBoundingClientRect().top >= c.top - 1); return h ? h.id + '@' + Math.round(h.getBoundingClientRect().top - c.top) : ''; };

await until(() => st().motion === 'still' && st().layout === 'settled');
check('start: page document', st().page === 'document', st());
check('start: find off, pointer resting or moving', st().find === 'off', st());

// find
R.find('paragraph', 0, true); check('find: found', st().find === 'found' && st().matches > 0, st());
R.find('zzzzqq', 0, true);    check('find: none', st().find === 'none' && st().matches === 0, st());
R.endFind();                  check('find: off', st().find === 'off', st());

// motion: a glide, then the position bar takes over from it
R.go('top', true); await wait(300);
R.go('end', false);
check('motion: gliding', st().motion === 'gliding', st());
const bar = document.getElementById('bar'), th = document.getElementById('thumb').getBoundingClientRect(), y = th.top + th.height / 2;
bar.dispatchEvent(new MouseEvent('mousedown', { clientY: y, bubbles: true }));  // the thumb, grabbed in its middle
check('motion: dragging takes over from the glide', st().motion === 'dragging', st());
const held = tr(); await wait(350);
check('motion: the glide stopped when the drag began', tr() === held && st().motion === 'dragging', [held, tr(), st().motion]);
dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
check('motion: scrolling after the drag', st().motion === 'scrolling', st());
check('motion: still again', await until(() => st().motion === 'still', 1000), st());

// the scroll bar's track, clicked below the thumb, goes one page down (the Mac's default)
R.go('top', true); await wait(250);
const t0y = tr(), tb = document.getElementById('thumb').getBoundingClientRect();
bar.dispatchEvent(new MouseEvent('mousedown', { clientY: Math.min(innerHeight - 4, tb.bottom + 40), bubbles: true }));
dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); await wait(300);
check('scroll bar: a click on the track goes a page', tr() !== t0y && st().motion !== 'dragging', [t0y, tr()]);

// layout: a section folds
const id = R.state().sections ? document.querySelector('.md .sec .sec').dataset.id : '';
R.jump(id, true); await wait(250);
const before = topLine();
R.toggleSection(id); check('layout: folding', st().layout === 'folding' && st().folded.includes(id), st());
check('layout: settled after the fold', await until(() => st().layout === 'settled'), st());
R.toggleSection(id); await until(() => st().layout === 'settled');
check('fold: open again, same top line', !st().folded.includes(id) && topLine() === before, [before, topLine()]);

// layout: column morphs run one at a time; a second change waits; the latest of each kind wins
const n0 = st().columns, b0 = st().boldStarts, n1 = n0 === 5 ? 4 : 5;
R.setColumns(n1);
check('layout: morphing', st().layout === 'morphing', st());
R.setBoldStarts(!b0); R.setColumns(2); R.setColumns(n0 === 6 ? 3 : 6);
check('morph: later changes wait', st().waiting.join() === 'boldStarts,columns' && st().boldStarts === b0, st());
check('morph: all done', await until(() => st().layout === 'settled' && !st().waiting.length && st().columns === (n0 === 6 ? 3 : 6) && st().boldStarts === !b0, 4000), st());
R.setBoldStarts(b0); await until(() => st().layout === 'settled'); R.setColumns(n0); await until(() => st().layout === 'settled' && st().columns === n0);
check('morph: back as it was, same top line', st().columns === n0 && st().boldStarts === b0 && topLine() === before, [before, topLine(), st()]);
check('place: pinned', st().place === 'pinned', st());

// find: a phrase that crosses a line break of the file
R.find('the line break here', 0, true); check('find: across a line break', st().find === 'found' && st().matches === 10, st()); R.endFind();

// bold word starts: a word runs through its apostrophe; print carries no bold
R.setBoldStarts(true); await until(() => st().layout === 'settled' && st().boldStarts);
check('bold word starts: doesn’t is one word', [...document.querySelectorAll('.md b.ws')].some(b => b.textContent === 'does' && b.nextSibling?.data?.startsWith('n’t')), [...document.querySelectorAll('.md p')][1].innerHTML.slice(0, 200));
check('print: no bold word starts', !R.printable().includes('class="ws"'), 0);
R.setBoldStarts(b0); await until(() => st().layout === 'settled' && st().boldStarts === b0);

// a setting turned on and off at once ends as it began; a phrase wrapped onto an indented line is found
R.setBoldStarts(!b0); R.setBoldStarts(b0); await until(() => st().layout === 'settled' && !st().waiting.length);
check('settings: on then off at once ends as it began', st().boldStarts === b0, st());
R.find('alpha beta gamma', 0, true); check('find: across an indented line', st().find === 'found' && st().matches === 1, st()); R.endFind();

// find reads letters the same way in the query and in the document; every heading has a name of its own
R.find('İstanbul', 0, true); check('find: a capital İ', st().matches === 1, st());
R.find('ος', 0, true); check('find: a final sigma', st().matches === 1, st()); R.endFind();
const ids = [...document.querySelector('.md').querySelectorAll('h1, h2, h3')].map(h => h.id);
check('headings: every id once, none empty', new Set(ids).size === ids.length && ids.every(Boolean) && ['constructor', 'topic', 'topic-1', 'topic-1-1', 'section'].every(x => ids.includes(x)), ids.slice(-6));

// Next Section leaves a place to go back to; a link to "#" goes to the beginning
const offset = () => parseFloat(tr().match(/-?[\d.]+/)[0]);
R.go('top', true); R.heading(1, true); R.heading(1, true); const y1 = offset(); R.heading(1, true); const y2 = offset(); R.back(true);
check('back: after Next Section', Math.abs(offset() - y1) < 1 && y1 !== y2, [y1, y2, offset()]);
const hash = document.createElement('a'); hash.setAttribute('href', '#'); document.querySelector('.md').append(hash); hash.click(); hash.remove();
await wait(60); await until(() => st().motion === 'still');
check('link "#": the beginning', Math.abs(offset()) < 1, offset());

// folds keep the reading place
const line = () => { const c = document.querySelector('.clip').getBoundingClientRect(); for (const x of document.querySelector('.md').querySelectorAll('p, h1, h2, h3')) { const r = x.getBoundingClientRect(); if (r.height && r.bottom > c.top + 30) return x.textContent.trim().slice(0, 40) + '@' + Math.round(r.top - c.top); } };
const settled = () => until(() => st().layout === 'settled' && st().motion === 'still');
R.jump('part-6-point-2', true); dispatchEvent(new WheelEvent('wheel', { deltaY: 170, bubbles: true, cancelable: true })); await wait(400); await settled();
const read = line(), part1 = document.querySelector('.md .sec[data-id="part-1"]'), part6 = document.querySelector('.md .sec[data-id="part-6"]');
R.toggleSection('part-1'); await wait(60); await settled();
check('fold above: the reading line stays', line() === read && st().folded.includes('part-1'), [read, line()]);
R.toggleSection('part-1'); await wait(60); await settled();
check('unfold above: the reading line stays', line() === read, [read, line()]);
R.toggleSection('part-6'); await wait(60); await settled();
const headTop = Math.round(part6.firstElementChild.getBoundingClientRect().top - document.querySelector('.clip').getBoundingClientRect().top);
check('fold the section being read: its heading comes to the top line', headTop > 0 && headTop < 60, headTop);
R.toggleSection('part-6'); await wait(60); await settled();
check('unfold it: back on the same line', line() === read, [read, line()]);
R.toggleSection('part-6'); await wait(60); await settled();
R.setColumns(n0 === 2 ? 3 : 2, true); R.setColumns(n0, true);
R.toggleSection('part-6'); await wait(60); await settled();
check('fold, change the columns, unfold: back on the same line', line() === read, [read, line()]);
R.foldAll(true); await wait(60); await settled();
check('collapse all: all folded', st().folded.length >= 10, st());
R.foldAll(false); await wait(60); await settled();
check('expand all: back on the same line', line() === read && !st().folded.length, [read, line()]);
R.foldAll(true, true); R.foldAll(false, true);
check('the same by keyboard (at once)', line() === read, [read, line()]);
check('fill: columns for a long document', st().fill === 'columns', st());
window.checkLine = line;

// page: a message takes the place of the document; input does not reach the hidden text
R.message('Check', 'A message in place of the document.');
const t0 = tr();
dispatchEvent(new WheelEvent('wheel', { deltaY: 400, bubbles: true, cancelable: true })); await wait(100);
check('page: message, wheel ignored', st().page === 'message' && tr() === t0 && getComputedStyle(document.getElementById('note')).display === 'grid', [st().page, t0, tr()]);
return out.join('\n');
