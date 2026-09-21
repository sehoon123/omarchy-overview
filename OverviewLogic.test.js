const assert = require('node:assert/strict');
const { test } = require('node:test');
const L = require('./OverviewLogic.js');
const windows = [
  { address: 'a', title: '한글 문서 – Café', lastIpcObject: { class: 'Chromium', monitor: 1 }, workspace: { id: 2 } },
  { address: 'b', title: 'Notes [a.*]', lastIpcObject: { class: 'org.editor' }, workspace: { id: 1 } },
];
test('literal, case-insensitive AND search over title/app/desktop', () => {
  assert.ok(L.matches(windows[0], 'CHROMIUM 한글'));
  assert.ok(L.matches(windows[0], 'desktop 2'));
  assert.ok(L.matches(windows[1], '[a.*]'));
  assert.ok(!L.matches(windows[0], '.*'));
  assert.ok(!L.matches(windows[0], '한글 missing'));
  assert.ok(L.matches(windows[0], '   '));
});
test('Unicode normalization and missing metadata', () => {
  assert.ok(L.matches(windows[0], 'Cafe\u0301'));
  assert.ok(L.matches(windows[0], '한글'.normalize('NFD')));
  assert.ok(L.matches({}, ''));
  assert.ok(!L.matches({}, 'title'));
});
test('named desktops have stable selectors; only special workspaces are excluded', () => {
  assert.equal(L.workspaceKey({ id: -1337, name: 'Main:1' }), 'name:Main:1');
  assert.equal(L.workspaceKey({ id: -1555, name: 'Main:1' }), 'name:Main:1');
  assert.equal(L.workspaceKey({ id: -99, name: 'special:scratch' }), 0);
  assert.equal(L.workspaceKey({ id: 3, name: '3' }), 3);
  assert.equal(L.workspaceKey(null), 0);
  assert.ok(L.matches({ workspace: { id: -1337, name: 'Main:2' } }, 'Desktop 2'));
  assert.ok(L.matches({ workspace: { id: -1337, name: 'Main:2' } }, 'Main:2'));
});
test('per-monitor strip includes empty slots and parked desktops, but not dormant global placeholders', () => {
  const order = [2, 1, 'name:Main:1', 'name:Main:2', 'name:Side:1', 'name:Missing:3'];
  const info = { 'name:Main:1': { monitor: 'DP-1' }, 'name:Main:2': { monitor: 'DP-1' },
    'name:Side:1': { monitor: 'DP-2' }, 'name:Missing:3': { monitor: 'DP-2' } };
  const live = [{ id: -1400, name: 'Missing:3', monitor: { name: 'DP-1' } }];
  assert.deepEqual(L.workspaceKeys(order, live, info, 'DP-1', true), ['name:Main:1', 'name:Main:2', 'name:Missing:3']);
  assert.deepEqual(L.workspaceKeys(order, live, info, 'DP-2', true), ['name:Side:1']);
  assert.deepEqual(L.workspaceKeys(order, live, info, 'DP-1', false), order);
});
test('cold start uses native Wayland activation until Hyprland sends focus metadata', () => {
  const idle = { address: 'a', wayland: { activated: false } };
  const active = { address: 'b', wayland: { activated: true } };
  assert.equal(L.focusedWindow(null, [idle, {}, active]), active);
  assert.equal(L.focusedWindow(idle, [idle, active]), idle);
  assert.equal(L.focusedWindow(null, [idle, {}]), null);
  assert.equal(L.focusedWindow(null, []), null);
});
test('selection is address-stable across reorder and removal', () => {
  assert.equal(L.selectionIndex(windows, 'b', 0), 1); // Prefer the focused window on opening.
  assert.equal(L.selectionIndex(windows, 'closed', 0), 0);
  assert.equal(L.selectionIndex([...windows].reverse(), 'a', 0), 1);
  assert.equal(L.selectionIndex(windows.slice(0, 1), 'b', 1), 0);
  assert.equal(L.selectionIndex([], 'a', 5), 0);
});
test('desktop reveal scrolls minimally with room for outlines and close buttons', () => {
  assert.equal(L.revealOffset(0, 400, 1200, 876, 148, 16), 640);
  assert.equal(L.revealOffset(700, 400, 1200, 188, 148, 16), 172);
  assert.equal(L.revealOffset(120, 400, 1200, 188, 148, 16), 120);
  assert.equal(L.revealOffset(700, 400, 1200, 1036, 148, 16), 800);
  assert.equal(L.revealOffset(999, 400, 320, 16, 148, 16), 0);
  assert.equal(L.revealOffset(100, 0, 1200, 188, 148, 16), 0);
  assert.equal(L.revealOffset(0, 100, 1200, 188, 148, 16), 172);
  assert.equal(L.revealOffset(172, 100, 1200, 188, 148, 16), 172);
});
test('live budget deduplicates and always prioritizes preview/drag/selection', () => {
  assert.deepEqual(L.liveAddresses(windows, ['b', 'b', '', 'a'], 1), ['b']);
  assert.deepEqual(L.liveAddresses(windows, ['drag', 'b'], 6), ['drag', 'b', 'a']);
  assert.deepEqual(L.liveAddresses([], ['a', '', 'a'], 6), ['a']);
  assert.deepEqual(L.liveAddresses(windows, ['b'], 0), ['b', 'a']);
});
function nativeWindow(address = 'a', x = 0) {
  return { address, wayland: {}, workspace: { id: 1 }, monitor: { id: 0, name: 'DP-2' },
    lastIpcObject: { mapped: true, hidden: false, monitor: 0, at: [x, 0], size: [800, 600] } };
}
const outputs = [{ id: 0, name: 'DP-2', x: 0, y: 0, width: 1600, height: 1000, scale: 1 }];
test('native previews require visible session and the actual assigned monitor', () => {
  const window = nativeWindow();
  assert.ok(L.canCapture(true, true, window, outputs));
  assert.ok(!L.canCapture(false, true, window, outputs));
  assert.ok(!L.canCapture(true, false, window, outputs));
  assert.ok(!L.canCapture(true, true, window, []));
  assert.ok(!L.canCapture(true, true, { ...window, monitor: null }, outputs));
  assert.ok(!L.canCapture(true, true, { ...window, monitor: null, workspace: { id: 1, monitor: window.monitor } }, outputs));
  assert.ok(!L.canCapture(true, true, { ...window, wayland: null }, outputs));
  for (const changes of [{ mapped: false }, { mapped: undefined }, { monitor: -1 }, { hidden: true },
    { size: [0, 600] }, { size: [Infinity, 600] }, { size: [10000, 10000] }]) {
    assert.ok(!L.canCapture(true, true, { ...window, lastIpcObject: { ...window.lastIpcObject, ...changes } }, outputs));
  }
  for (const name of ['', 'FALLBACK', 'FALLBACK-1', 'HEADLESS-1'])
    assert.deepEqual(L.previewScreens([{ name, width: 1920, height: 1080 }]), []);
  assert.deepEqual(L.previewScreens([{ name: 'DP-2', width: 0, height: 1000 }]), []);
});
test('covered/other-workspace windows can be captured, but fully off-viewport ones cannot', () => {
  const covered = nativeWindow(); covered.lastIpcObject.visible = false; covered.workspace.id = 2;
  assert.ok(L.canCapture(true, true, covered, outputs));
  assert.ok(L.canCapture(true, true, nativeWindow('partial', -400), outputs));
  assert.equal(L.captureReason(nativeWindow('outside', -800), outputs), 'Off-screen preview unavailable');
  assert.equal(L.captureReason(nativeWindow('outside', 1600), outputs), 'Off-screen preview unavailable');
});
test('capture planning deduplicates and bounds streams and estimated native pixels', () => {
  const list = [nativeWindow('a'), nativeWindow('b', 800), nativeWindow('off', 3000)];
  assert.deepEqual(L.capturePlan(list, ['b', 'b', 'missing'], outputs), ['b', 'a']);
  assert.deepEqual(L.capturePlan(list, ['b'], outputs, 1), ['b']);
  assert.deepEqual(L.capturePlan(list, ['b'], outputs, 32, 480000), ['b']);
  assert.deepEqual(L.capturePlan(list, [], outputs, 0), []);
});
test('spatial order follows desktop positions, not pointer allocation order', () => {
  const right = nativeWindow('a', 800), left = nativeWindow('z', 0);
  assert.ok(L.spatialCompare(left, right) < 0);
});
test('settings validate types, ranges and stream caps without coercion', () => {
  const result = L.settings({ keepCache: 'false', dim: 999, liveLimit: 1000 });
  assert.equal(result.keepCache, true);
  assert.equal(result.dim, 80);
  assert.equal(result.liveLimit, 0);
  assert.equal(L.setting('liveLimit', 6), 6); // Preserve an existing user's cap.
  assert.equal(L.setting('keepCache', false), false);
  assert.equal(L.setting('dim', NaN), undefined);
  assert.equal(L.setting('command', 'anything'), undefined);
});
test('palette reads public scalar tokens only, with safe fallbacks', () => {
  const result = L.palette('accent = "#123abc" # note\nbackground = \'#ffffff\'\nforeground = "url(foo)"\n[section]\naccent = "#000000"');
  assert.equal(result.accent, '#123abc');
  assert.equal(result.background, '#ffffff');
  assert.equal(result.foreground, '#ecf0f7');
});

// --- Extracted shell.qml policy (Workstream C). Quirk assertions carry a
// --- `PINS F-nn` marker naming the AUDIT.md finding that will rewrite them.
test('openOverview refusals are reported in precedence order', () => {
  assert.equal(L.openBlocked({}), '');
  assert.equal(L.openBlocked({ shutdownRequested: false, activating: false, shown: false, opening: false }), '');
  assert.equal(L.openBlocked({ shutdownRequested: true, activating: true, shown: true, opening: true }), 'shutdown');
  assert.equal(L.openBlocked({ shown: true, opening: true }), 'shown');
  assert.equal(L.openBlocked({ opening: true }), 'opening');
  // PINS F-09 - corrected by F-09 fix: the 30 ms post-activation window silently drops an open.
  assert.equal(L.openBlocked({ activating: true, shown: true }), 'activating');
  // PINS F-06 - corrected by F-06 fix: today shell.qml only checks truthiness, so the reason never reaches the user.
  assert.ok(L.openBlocked({ opening: true }) && !L.openBlocked({}));
});
test('closeOverview picks one of four modes', () => {
  const state = { opening: false, shutdownRequested: false, busy: false, closing: false, shown: true, motion: true };
  assert.equal(L.closeMode(state), 'animate');
  assert.equal(L.closeMode({ ...state, motion: false }), 'immediate');
  assert.equal(L.closeMode({ ...state, shown: false }), 'immediate');
  // PINS F-06 - corrected by F-06 fix: closing an in-flight open is immediate and silent.
  assert.equal(L.closeMode({ ...state, opening: true, busy: true, closing: true }), 'immediate');
  assert.equal(L.closeMode({ ...state, shutdownRequested: true, busy: true, closing: true }), 'immediate');
  // PINS F-08 - corrected by F-08 fix: a wedged action defers the close instead of performing it.
  assert.equal(L.closeMode({ ...state, busy: true, closing: true }), 'deferToBusy');
  // F-07 residual fixed: a close arriving during a close is still ignored, which
  // is correct, but `closing` is no longer unbounded - the close watchdog below
  // finishes the session even when the exit motion never completes, so `closing`
  // can no longer latch the whole UI into a permanently disabled state.
  assert.equal(L.closeMode({ ...state, closing: true }), 'ignore');
  assert.equal(L.closeVerdict({ closing: true, session: 2, openCount: 2, source: 'watchdog' }).action, 'finish');
});
test('shutdown waits for work, flushes settings, then quits', () => {
  const ready = { shutdownRequested: true, busy: false, preparing: false, activating: false, saving: false };
  assert.equal(L.shutdownReady(ready), 'quit');
  assert.equal(L.shutdownReady({ ...ready, saving: true }), 'flush');
  assert.equal(L.shutdownReady({ ...ready, shutdownRequested: false }), 'wait');
  assert.equal(L.shutdownReady({ ...ready, preparing: true }), 'wait');
  assert.equal(L.shutdownReady({ ...ready, activating: true }), 'wait');
  // F-03 fixed: waiting while a desktop action is in flight is still correct, but
  // the wait is now bounded - onBusyChanged re-arms finishShutdown() when the
  // reply lands, and the shutdown watchdog's `expired` deadline quits regardless,
  // so `busy` can delay the quit but can no longer cancel it.
  assert.equal(L.shutdownReady({ ...ready, busy: true }), 'wait');
  assert.equal(L.shutdownReady({ ...ready, busy: true, expired: true }), 'quit');
});
test('activation prefers the native Wayland handle over an address dispatch', () => {
  assert.deepEqual(L.activationTarget({ wayland: {}, address: 'nonsense' }), { mode: 'wayland' });
  assert.deepEqual(L.activationTarget({ address: '5f1c2a' }), { mode: 'dispatch', address: '0x5f1c2a' });
  assert.deepEqual(L.activationTarget({ address: '0x5f1c2a' }), { mode: 'dispatch', address: '0x5f1c2a' });
  assert.deepEqual(L.activationTarget(null), { mode: 'none' });
  assert.deepEqual(L.activationTarget({}), { mode: 'none' });
  assert.deepEqual(L.activationTarget({ address: 'window one' }), { mode: 'none' });
  assert.deepEqual(L.activationTarget({ address: '0x5f1c2a; hyprctl' }), { mode: 'none' });
  // Pinned quirk, no audit finding: the test is case-insensitive but the prefix check is not.
  assert.deepEqual(L.activationTarget({ address: '0X5F1C2A' }), { mode: 'dispatch', address: '0x0X5F1C2A' });
});
test('live streams narrow to the priority set during Quick Look and stop while closing', () => {
  const list = [{ address: 'a' }, { address: 'b' }, { address: 'c' }];
  const state = { windows: list, priority: ['', '', 'b', 'a', 'b', 'c'], limit: 0, previewAddress: '', closing: false,
    planned: ['a', 'b', 'c', 'd'] };
  assert.deepEqual(L.liveSelection(state), ['b', 'a', 'c']);
  assert.deepEqual(L.liveSelection({ ...state, previewAddress: 'b' }), ['b']);
  assert.deepEqual(L.liveSelection({ ...state, closing: true }), []);
  assert.deepEqual(L.liveSelection({ ...state, closing: true, previewAddress: 'b' }), []);
  assert.deepEqual(L.liveSelection({ ...state, limit: 2 }), ['b', 'a']);
  assert.deepEqual(L.liveSelection({ ...state, planned: ['a'] }), ['a']);
  assert.deepEqual(L.liveSelection({ ...state, planned: [] }), []);
  // Only the first three priority entries (preview, drag source, selection) are honoured.
  assert.deepEqual(L.liveSelection({ ...state, priority: ['c', 'c', 'c', 'b'], limit: 1 }), ['c']);
  // PINS F-15 - corrected by F-15 fix: limit 0 is the default and means every planned stream runs live.
  assert.equal(L.liveSelection({ ...state, limit: 0 }).length, 3);
});
function intent(key, options) {
  const opts = options || {};
  return L.keyIntent({ key: key, modifiers: opts.modifiers || {}, editing: !!opts.editing,
    composing: !!opts.composing, flags: opts.flags || {} });
}
test('Escape unwinds exactly one layer and is always accepted', () => {
  assert.deepEqual(intent('escape'), { action: 'closeOverview', accept: true, sync: false });
  assert.equal(intent('escape', { editing: true, composing: true,
    flags: { dragging: true, settingsShown: true, previewAddress: 'a', query: 'x' } }).action, 'clearSearch');
  assert.equal(intent('escape', { flags: { dragging: true, settingsShown: true, previewAddress: 'a', query: 'x' } }).action, 'cancelDrag');
  assert.equal(intent('escape', { flags: { settingsShown: true, previewAddress: 'a', query: 'x' } }).action, 'closeSettings');
  assert.equal(intent('escape', { flags: { previewAddress: 'a', query: 'x' } }).action, 'closePreview');
  assert.equal(intent('escape', { flags: { query: 'x' } }).action, 'clearSearch');
  assert.equal(intent('escape', { flags: { busy: true } }).action, 'closeOverview'); // Escape outranks the busy guard.
  assert.equal(intent('escape', { flags: { query: 'x' } }).sync, false);
});
test('the settings panel keeps its keys; a busy or dragging session swallows them', () => {
  assert.deepEqual(intent('space', { flags: { settingsShown: true } }), { action: 'none', accept: false, sync: false });
  assert.deepEqual(intent('down', { flags: { settingsShown: true, busy: true } }), { action: 'none', accept: false, sync: false });
  assert.deepEqual(intent('enter', { flags: { dragging: true } }), { action: 'none', accept: true, sync: false });
  // PINS F-08 - corrected by F-08 fix: while busy every non-Escape key is swallowed without feedback.
  assert.deepEqual(intent('space', { flags: { busy: true } }), { action: 'none', accept: true, sync: false });
  // Enter/Space/arrows belong to the IME first, and must not be accepted.
  assert.deepEqual(intent('space', { editing: true, composing: true }), { action: 'none', accept: false, sync: false });
  assert.deepEqual(intent('enter', { editing: true, composing: true }), { action: 'none', accept: false, sync: false });
  assert.equal(intent('space', { composing: true }).action, 'togglePreview'); // Composing only matters while editing.
});
test('shortcuts never steal a keystroke that belongs to the search text', () => {
  assert.equal(intent('f', { modifiers: { ctrl: true } }).action, 'focusSearch');
  assert.deepEqual(intent('f'), { action: 'none', accept: false, sync: false });
  assert.equal(intent('space').action, 'togglePreview');
  assert.equal(intent('space', { editing: true }).action, 'togglePreview');
  assert.deepEqual(intent('space', { editing: true, flags: { query: 'ab' } }), { action: 'none', accept: false, sync: false });
  assert.equal(intent('space', { editing: true, modifiers: { ctrl: true }, flags: { query: 'ab' } }).action, 'togglePreview');
  assert.equal(intent('z', { modifiers: { ctrl: true } }).action, 'undo');
  assert.equal(intent('z', { modifiers: { ctrl: true }, editing: true }).action, 'undo');
  assert.deepEqual(intent('z', { modifiers: { ctrl: true }, editing: true, flags: { query: 'ab' } }), { action: 'none', accept: false, sync: false });
  assert.deepEqual(intent('left', { editing: true, flags: { query: 'ab' } }), { action: 'none', accept: false, sync: false });
  assert.equal(intent('right', { editing: true, flags: { query: 'ab' } }).action, 'none');
  assert.equal(intent('up', { editing: true, flags: { query: 'ab' } }).action, 'moveSelection');
  assert.equal(intent('left', { editing: true }).action, 'moveSelection');
});
test('desktop and selection navigation report direction and step', () => {
  assert.deepEqual(intent('left', { modifiers: { ctrl: true } }), { action: 'navigateDesktop', accept: true, sync: true, direction: 'previous' });
  assert.deepEqual(intent('right', { modifiers: { ctrl: true } }), { action: 'navigateDesktop', accept: true, sync: true, direction: 'next' });
  assert.equal(intent('left', { modifiers: { ctrl: true }, editing: true, flags: { query: 'ab' } }).action, 'navigateDesktop');
  assert.deepEqual(intent('tab'), { action: 'cycleSelection', accept: true, sync: true, step: 1 });
  assert.equal(intent('tab', { modifiers: { shift: true } }).step, -1);
  assert.equal(intent('backtab').step, -1);
  assert.equal(intent('backtab', { modifiers: { shift: true } }).step, -1);
  assert.deepEqual(intent('down'), { action: 'moveSelection', accept: true, sync: true, direction: 'down' });
  assert.deepEqual(intent('up'), { action: 'moveSelection', accept: true, sync: true, direction: 'up' });
  assert.equal(intent('enter', { flags: { windowCount: 2, query: 'ab' } }).action, 'choose');
  assert.equal(intent('enter', { flags: { windowCount: 0 } }).action, 'choose'); // An empty desktop still switches.
  // Pinned quirk, no audit finding: Enter with a query and no matches does nothing yet is accepted.
  assert.deepEqual(intent('enter', { flags: { windowCount: 0, query: 'ab' } }), { action: 'none', accept: true, sync: true });
  assert.deepEqual(intent(''), { action: 'none', accept: false, sync: false }); // Unmapped keys reach the text field.
  assert.deepEqual(intent('a'), { action: 'none', accept: false, sync: false });
});
test('only accepted non-Escape intents re-target Quick Look', () => {
  for (const i of [intent('space'), intent('tab'), intent('down'), intent('enter'),
    intent('f', { modifiers: { ctrl: true } }), intent('right', { modifiers: { ctrl: true } })])
    assert.equal(i.sync, true);
  for (const i of [intent('escape'), intent('space', { flags: { busy: true } }), intent('a'),
    intent('space', { flags: { settingsShown: true } })])
    assert.equal(i.sync, false);
});
test('strip zones are clipped to the scrollable viewport, zero-width edges included', () => {
  const clip = { x: 100, width: 200 };
  assert.equal(L.zoneVisible({ x: 40, width: 59 }, clip), false);
  assert.equal(L.zoneVisible({ x: 40, width: 60 }, clip), true); // Touching the left edge still counts.
  assert.equal(L.zoneVisible({ x: 300, width: 10 }, clip), true);
  assert.equal(L.zoneVisible({ x: 301, width: 10 }, clip), false);
  assert.equal(L.zoneVisible({ x: 150, width: 10 }, clip), true);
  const inside = { kind: 'desktop', key: 'desktop:2', id: 2, x: 120, y: 18, width: 140, height: 90 };
  assert.deepEqual(L.clipZone(inside, clip), inside);
  const left = L.clipZone({ kind: 'remove', key: 'remove:3', id: 3, x: 60, y: 10, width: 80, height: 20 }, clip);
  assert.deepEqual(left, { kind: 'remove', key: 'remove:3', id: 3, x: 100, y: 10, width: 40, height: 20 });
  const right = L.clipZone({ kind: 'desktop', key: 'desktop:4', id: 4, x: 260, y: 10, width: 140, height: 20 }, clip);
  assert.equal(right.x, 260); assert.equal(right.width, 40);
  // Pinned quirk, no audit finding: an edge-touching zone survives with zero width and can never be hit.
  const edge = L.clipZone({ kind: 'desktop', id: 5, x: 40, y: 10, width: 60, height: 20 }, clip);
  assert.equal(edge.width, 0);
  assert.equal(L.hitZone([edge], 100, 15).kind, 'background');
  const source = { kind: 'desktop', id: 6, x: 60, y: 10, width: 80, height: 20 };
  L.clipZone(source, clip); assert.equal(source.x, 60); // The caller's zone is never mutated.
});
test('hit testing is first-match-wins over half-open rectangles', () => {
  const zones = [{ kind: 'undo', key: 'undo', x: 0, y: 0, width: 10, height: 10 },
    { kind: 'window', key: 'window:a', address: 'a', index: 0, x: 5, y: 5, width: 20, height: 20 }];
  assert.equal(L.hitZone(zones, 0, 0).kind, 'undo');
  assert.equal(L.hitZone(zones, 6, 6).kind, 'undo');
  assert.equal(L.hitZone(zones, 9.9, 9.9).kind, 'undo');
  assert.equal(L.hitZone(zones, 10, 10).kind, 'window'); // Right/bottom edges belong to the next zone.
  assert.equal(L.hitZone(zones, 24, 24).address, 'a');
  assert.deepEqual(L.hitZone(zones, 25, 25), { kind: 'background', key: 'background' });
  assert.deepEqual(L.hitZone(zones, -1, 5), { kind: 'background', key: 'background' });
  assert.deepEqual(L.hitZone([], 5, 5), { kind: 'background', key: 'background' });
});
test('a delegate whose model entry vanished is skipped, never dereferenced', () => {
  // PINS F-14 - corrected by F-14 fix: both the hit-test scan and the status scan
  // used to read item.modelData.address, which throws for the turn in which a
  // refreshToplevels() reset leaves a live delegate with no model entry.
  assert.equal(L.delegateAddress({ modelData: { address: '0x1' } }), '0x1');
  assert.equal(L.delegateAddress({ modelData: { address: 12 } }), '12');
  for (const missing of [undefined, null, 0, '', false, {}, { modelData: null }, { modelData: undefined },
    { modelData: {} }, { modelData: { address: null } }, { modelData: { address: undefined } },
    { modelData: { address: '' } }, { modelData: { address: {} } }, { modelData: { address: [] } },
    { modelData: { address: NaN } }, { modelData: { address: Infinity } }])
    assert.equal(L.delegateAddress(missing), '', JSON.stringify(missing));
  // The scan both callers run: a broken delegate contributes no zone, the good
  // ones keep their own index, and an unusable address never matches a window -
  // not even a window whose own address is empty.
  const delegates = [{ modelData: { address: 'a' }, inLayout: true, layoutIndex: 0 }, { modelData: null },
    null, { modelData: { address: '' }, inLayout: true, layoutIndex: 9 },
    { modelData: { address: 'b' }, inLayout: true, layoutIndex: 1 }];
  const scanned = [];
  for (const item of delegates) {
    const address = L.delegateAddress(item);
    if (!item || !item.inLayout || !address) continue;
    scanned.push({ kind: 'window', key: 'window:' + address, address: address, index: item.layoutIndex,
      x: item.layoutIndex * 100, y: 0, width: 80, height: 60 });
  }
  assert.deepEqual(scanned.map(z => [z.address, z.index, z.key]), [['a', 0, 'window:a'], ['b', 1, 'window:b']]);
  assert.equal(L.hitZone(scanned, 110, 10).address, 'b');
  assert.equal(L.hitZone(scanned, 90, 10).kind, 'background');
  for (const window of [{ address: '' }, { address: undefined }])
    assert.equal(delegates.some(item => { const a = L.delegateAddress(item); return a && a === String(window.address); }), false);
});
test('an extreme ratio still publishes a clickable window zone inside its own card', () => {
  // PINS F-06/F-14 follow-up: zones() publishes the letterboxed surface, and a
  // 1x1000 window (aspect .001) letterboxes it to a sub-pixel sliver, so the card
  // was visible but practically unclickable - and that sliver is also the zone a
  // drop reports.
  const card = { x: 100, y: 200, width: 300, height: 400 };
  const sliver = { kind: 'window', key: 'window:a', address: 'a', index: 0, window: { address: 'a' },
    x: 249.8, y: 200, width: 0.4, height: 400 };
  const grown = L.hittableZone(sliver, card);
  assert.deepEqual([grown.width, grown.height], [24, 400]);
  assert.equal(grown.x + grown.width / 2, sliver.x + sliver.width / 2); // Centred on the surface.
  assert.ok(grown.x >= card.x && grown.x + grown.width <= card.x + card.width);
  assert.ok(grown.y >= card.y && grown.y + grown.height <= card.y + card.height);
  assert.equal(L.hitZone([grown], 250, 300).address, 'a');
  // Identity, index, key and the window object survive untouched.
  assert.deepEqual(Object.keys(grown), Object.keys(sliver));
  assert.equal(grown.window, sliver.window);
  assert.deepEqual([grown.kind, grown.key, grown.address, grown.index], ['window', 'window:a', 'a', 0]);
  // A zone that is already hittable is the identical object: every normal card's
  // published zone is byte-identical to what zones() built.
  const normal = { kind: 'window', key: 'window:b', x: 0, y: 0, width: 190, height: 119 };
  assert.equal(L.hittableZone(normal, { x: 0, y: 0, width: 190, height: 140 }), normal);
  assert.equal(L.hittableZone(normal, null), normal);
  for (const size of [24, 25, 100])
    assert.equal(L.hittableZone({ x: 0, y: 0, width: size, height: size }, card).width, size);
  // The card is the hard bound: a card smaller than the minimum is never exceeded,
  // so a zone can never reach a neighbour's packed cell.
  const tiny = { x: 0, y: 0, width: 10, height: 8 };
  assert.deepEqual(L.hittableZone({ x: 4, y: 4, width: 0.2, height: 8 }, tiny), { x: 0, y: 0, width: 10, height: 8 });
  const left = { x: 0, y: 0, width: 100, height: 100 }, right = { x: 104, y: 0, width: 100, height: 100 };
  const a = L.hittableZone({ x: 0.4, y: 50, width: 0.2, height: 1 }, left);
  const b = L.hittableZone({ x: 203.4, y: 50, width: 0.2, height: 1 }, right);
  assert.deepEqual([a.x, a.width, b.x, b.width], [0, 24, 180, 24]);
  assert.ok(a.x + a.width <= right.x && b.x >= left.x + left.width); // No overlap after growing.
  for (const z of [a, b]) assert.deepEqual([z.height, z.y], [24, 38.5]);
  // A refused layout (0x0 cards) invents nothing, and the minimum is a parameter.
  const empty = { kind: 'window', x: 0, y: 0, width: 0, height: 0 };
  assert.equal(L.hittableZone(empty, { x: 0, y: 0, width: 0, height: 0 }), empty);
  assert.equal(L.hittableZone({ x: 0, y: 0, width: 2, height: 2 }, card, 0).width, 2);
  assert.equal(L.hittableZone({ x: 0, y: 0, width: 2, height: 2 }, card, 44).height, 44);
});
const statusState = {
  shown: true, busy: false, desktop: 2, appFilter: '', order: [1, 2], perMonitor: false, monitor: 'DP-2',
  desktopLabels: ['Desktop 1', 'Desktop 2'], dragging: false, message: '', query: '', selectedAddress: 'a',
  previewAddress: '', previewSource: null, settingsShown: false, settings: { dim: 40 }, settingsError: '',
  liveAddresses: ['a'], delegateCount: 3, cachedFrames: 1, windowCaptureEnabled: true, captureTopologyReady: true,
  captureViews: 2, opening: false, closing: false, motionProgress: 1, previewError: '', accent: '#76b5ff',
  composing: false, searchFocused: true, preparing: false, openCount: 4, firstFrameMs: 12, workerPid: 99,
  workerRestarts: 0, completedRequests: 7, lastActionMs: 3,
  layout: { x: 0, y: 0, width: 100, height: 80, rects: [] }, zones: []
};
test('status payload emits exactly today IPC key set, in order', () => {
  assert.deepEqual(Object.keys(L.statusPayload(statusState, [])), ['visible', 'busy', 'desktop', 'appFilter',
    'order', 'perMonitor', 'monitor', 'desktopLabels', 'windows', 'dragging', 'message', 'query', 'selectedAddress',
    'previewAddress', 'previewSourceId', 'settingsShown', 'settings', 'settingsError', 'liveAddresses',
    'delegateCount', 'cachedFrames', 'windowCaptureEnabled', 'captureTopologyReady', 'captureViews',
    'captureBackend', 'opening', 'closing', 'motionProgress', 'previewError', 'accent', 'composing',
    'searchFocused', 'preparing', 'primed', 'openCount', 'firstFrameMs', 'workerPid', 'workerRestarts',
    'completedRequests', 'lastActionMs', 'layout', 'zones']);
  const payload = L.statusPayload(statusState, [{ address: 'a' }]);
  assert.equal(payload.visible, true);
  assert.equal(payload.desktop, 2);
  assert.equal(payload.captureBackend, 'native-window');
  assert.deepEqual(payload.windows, [{ address: 'a' }]);
  assert.equal(payload.previewSourceId, 0);
  assert.equal(L.statusPayload({ ...statusState, previewSource: { serial: 12 } }, []).previewSourceId, 12);
  assert.deepEqual(payload.layout, statusState.layout);
  // PINS F-16 - corrected by F-16 fix: `primed` is permanently empty and `cachedFrames` counts live streams, not a cache.
  assert.deepEqual(payload.primed, []);
  assert.equal(payload.cachedFrames, 1);
});
test('status zones expose geometry only, never window objects', () => {
  const zone = { kind: 'window', key: 'window:a', address: 'a', index: 3, window: { title: 'private' },
    x: 1, y: 2, width: 3, height: 4 };
  const payload = L.statusPayload({ ...statusState, zones: [zone, { kind: 'desktop', key: 'desktop:2', id: 2, x: 5, y: 6, width: 7, height: 8 }] }, []);
  assert.deepEqual(Object.keys(payload.zones[0]), ['kind', 'id', 'address', 'x', 'y', 'width', 'height']);
  assert.equal(JSON.stringify(payload.zones),
    '[{"kind":"window","address":"a","x":1,"y":2,"width":3,"height":4},{"kind":"desktop","id":2,"x":5,"y":6,"width":7,"height":8}]');
});
test('status cards expose exactly the nine per-window keys', () => {
  const source = { hasContent: true, serial: 5, fresh: true, generation: 2, capturedAt: 1700 };
  assert.deepEqual(L.statusCard({ address: 'a' }, source, true, ''), { address: 'a', thumbnail: true,
    imageReady: true, sourceId: 5, live: true, reason: '', fresh: true, generation: 2, capturedAt: 1700 });
  assert.deepEqual(L.statusCard({ address: 'b' }, null, false, 'Display is unavailable'), { address: 'b',
    thumbnail: false, imageReady: false, sourceId: 0, live: false, reason: 'Display is unavailable', fresh: false,
    generation: 0, capturedAt: 0 });
  // `live` and `fresh` are the same value under two names, for compatibility.
  const stale = L.statusCard({ address: 'c' }, { hasContent: true, serial: 1, fresh: false, generation: 3, capturedAt: 9 }, false, '');
  assert.equal(stale.live, false); assert.equal(stale.fresh, false);
  assert.equal(stale.thumbnail, true);
  // Pinned quirk, no audit finding: fields a real CaptureStream always defines stay undefined for a
  // partial source, and JSON.stringify then drops those keys from the reply.
  const partial = L.statusCard({ address: 'd' }, { hasContent: false }, false, 'Loading window preview…');
  assert.equal(partial.sourceId, undefined); assert.equal(partial.generation, undefined);
  assert.equal(JSON.stringify(partial), '{"address":"d","thumbnail":false,"imageReady":false,"reason":"Loading window preview…"}');
});

// --- Capture policy coverage (previously untested paths of captureReason/capturePlan).
function ipcWindow(changes, extra) {
  const base = nativeWindow();
  return Object.assign(base, extra || {}, { lastIpcObject: Object.assign(base.lastIpcObject, changes || {}) });
}
test('capture policy names one reason per refusal', () => {
  assert.equal(L.captureReason(nativeWindow(), outputs), '');
  assert.equal(L.captureReason(null, outputs), 'Waiting for window metadata');
  assert.equal(L.captureReason(undefined, outputs), 'Waiting for window metadata');
  assert.equal(L.captureReason(ipcWindow({}, { wayland: null }), outputs), 'Waiting for window metadata');
  assert.equal(L.captureReason(ipcWindow({}, { workspace: { id: -99, name: 'special:scratch' } }), outputs),
    'Waiting for window metadata');
  for (const mapped of [false, undefined, 1, 'true'])
    assert.equal(L.captureReason(ipcWindow({ mapped: mapped }), outputs), 'Window is not captureable');
  assert.equal(L.captureReason(ipcWindow({ hidden: true }), outputs), 'Window is not captureable');
  assert.equal(L.captureReason(ipcWindow({}, { monitor: null }), outputs), 'Window is not captureable');
  // The window's own monitor id, not its workspace's remembered monitor, owns capture.
  assert.equal(L.captureReason(ipcWindow({ monitor: 1 }), outputs), 'Window is not captureable');
  assert.equal(L.captureReason(ipcWindow({ monitor: '0' }), outputs), 'Window is not captureable');
  assert.equal(L.captureReason(nativeWindow(), []), 'Display is unavailable');
  assert.equal(L.captureReason(nativeWindow(), [{ ...outputs[0], id: 9 }]), 'Display is unavailable');
  assert.equal(L.captureReason(nativeWindow(), [{ ...outputs[0], name: 'DP-1' }]), 'Display is unavailable');
  assert.equal(L.captureReason(ipcWindow({}, { monitor: { id: 0, name: 'HEADLESS-1' } }),
    [{ ...outputs[0], name: 'HEADLESS-1' }]), 'Display is unavailable');
  for (const bad of [{ at: [0] }, { at: [] }, { at: [0, 0, 0] }, { size: [800] }, { at: ['0', 0] },
    { size: [800, NaN] }, { at: [0, Infinity] }, { size: [800, 0] }, { size: [-800, 600] }])
    assert.equal(L.captureReason(ipcWindow(bad), outputs), 'Waiting for window geometry');
});
test('per-window preview budget is 16 MP of scaled pixels', () => {
  const hidpi = [{ id: 0, name: 'DP-2', x: 0, y: 0, width: 3840, height: 2400, scale: 1.6 }];
  assert.equal(L.captureReason(ipcWindow({ size: [2500, 2500] }), hidpi), '');
  assert.equal(L.captureReason(ipcWindow({ size: [2501, 2500] }), hidpi), 'Window exceeds preview memory budget');
  assert.equal(L.captureReason(ipcWindow({ size: [4000, 4001] }), outputs), 'Window exceeds preview memory budget');
  assert.equal(L.captureReason(ipcWindow({ size: [4000, 4000] }), [{ ...outputs[0], scale: 0 }]), ''); // scale 0 falls back to 1
  // PINS F-15 - corrected by F-15 fix: 16 MP is admitted per window, i.e. ~64 MB of stream pixels.
  assert.equal(L.captureReason(ipcWindow({ size: [4000, 4000] }), outputs), '');
});
test('fully off-viewport windows are refused on both axes', () => {
  assert.equal(L.captureReason(ipcWindow({ at: [-800, 0] }), outputs), 'Off-screen preview unavailable');
  assert.equal(L.captureReason(ipcWindow({ at: [-799, 0] }), outputs), '');
  assert.equal(L.captureReason(ipcWindow({ at: [1600, 0] }), outputs), 'Off-screen preview unavailable');
  assert.equal(L.captureReason(ipcWindow({ at: [1599, 0] }), outputs), '');
  assert.equal(L.captureReason(ipcWindow({ at: [0, -600] }), outputs), 'Off-screen preview unavailable');
  assert.equal(L.captureReason(ipcWindow({ at: [0, 1000] }), outputs), 'Off-screen preview unavailable');
  assert.equal(L.captureReason(ipcWindow({ at: [0, 999] }), outputs), '');
  const offset = [{ id: 0, name: 'DP-2', x: 1600, y: 0, width: 1600, height: 1000, scale: 1 }];
  assert.equal(L.captureReason(nativeWindow(), offset), 'Off-screen preview unavailable');
  assert.equal(L.captureReason(ipcWindow({ at: [1500, 0] }), offset), '');
});
test('capture plan keeps priority order while truncating by views and pixels', () => {
  const list = [nativeWindow('a'), nativeWindow('b', 800), nativeWindow('c', 100)]; // 480000 scaled px each
  assert.deepEqual(L.capturePlan(list, ['c', 'b'], outputs), ['c', 'b', 'a']);
  assert.deepEqual(L.capturePlan(list, [], outputs), ['a', 'b', 'c']);
  assert.deepEqual(L.capturePlan(list, ['c', 'b'], outputs, 2), ['c', 'b']);
  assert.deepEqual(L.capturePlan(list, ['c', 'b'], outputs, 1), ['c']);
  assert.deepEqual(L.capturePlan(list, ['c'], outputs, 32, 960000), ['c', 'a']);
  assert.deepEqual(L.capturePlan(list, ['c'], outputs, 32, 479999), []);
  assert.deepEqual(L.capturePlan(list, [], outputs, 0), []);
  assert.deepEqual(L.capturePlan(list, [], outputs, -1), []);
  assert.deepEqual(L.capturePlan(list, [], outputs, 32, 0), []);
  assert.deepEqual(L.capturePlan(list, [], outputs, 32, -1), []);
  assert.deepEqual(L.capturePlan(list, ['a', 'a', '', 'missing', 'c'], outputs), ['a', 'c', 'b']);
  assert.deepEqual(L.capturePlan([nativeWindow('a'), nativeWindow('a', 400)], [], outputs), ['a']);
  assert.deepEqual(L.capturePlan([], ['a'], outputs), []);
  assert.deepEqual(L.capturePlan([nativeWindow('off', 3000)], [], outputs), []);
  // A window over the remaining pixel budget is skipped, not a stop condition.
  const big = nativeWindow('big'); big.lastIpcObject.size = [1400, 900];
  assert.deepEqual(L.capturePlan([big, nativeWindow('small', 900)], [], outputs, 32, 1000000), ['small']);
  // Scaled area is rounded up per axis, and the scale comes from the first output with that name.
  const frac = [{ ...outputs[0], scale: 1.25 }];
  assert.deepEqual(L.capturePlan([nativeWindow('a')], [], frac, 32, 750000), ['a']);
  assert.deepEqual(L.capturePlan([nativeWindow('a')], [], frac, 32, 749999), []);
  const shadow = [{ ...outputs[0], id: 7, scale: 2 }, outputs[0]];
  assert.equal(L.captureReason(nativeWindow(), shadow), ''); // matched by name and id
  assert.deepEqual(L.capturePlan([nativeWindow('a')], [], shadow, 32, 1920000), ['a']);
  assert.deepEqual(L.capturePlan([nativeWindow('a')], [], shadow, 32, 1919999), []);
  // PINS F-15 - corrected by F-15 fix: the defaults admit 32 streams and 64 MP (~256 MB) of pixels.
  const many = []; for (let i = 0; i < 40; i++) many.push(nativeWindow('w' + i, i * 10));
  assert.equal(L.capturePlan(many, [], outputs).length, 32);
  assert.equal(L.capturePlan(many, [], outputs, 64).length, 40);
});
test('canCapture needs a visible session and a settled topology', () => {
  const window = nativeWindow();
  assert.equal(L.canCapture(true, true, window, outputs), true);
  assert.equal(L.canCapture(false, true, window, outputs), false);
  assert.equal(L.canCapture(true, false, window, outputs), false);
  assert.equal(L.canCapture(false, false, window, outputs), false);
  assert.equal(L.canCapture(1, 'ready', window, outputs), true); // Truthy flags are coerced, the result is a bool.
  assert.equal(L.canCapture(undefined, undefined, window, outputs), false);
  assert.equal(L.canCapture(true, true, window, []), false);
  assert.equal(L.canCapture(true, true, null, outputs), false);
});
const stopped = 'Live preview stopped \u00b7 reopen Overview to retry';
test('a card with no image always says why, and a stopped stream names the only cure', () => {
  const card = extra => L.previewReason({ refusal: '', captureEnabled: true, planned: true,
    hasCapture: true, failed: false, ...extra });
  // PINS F-11 - corrected by F-11 fix: a stream the compositor stopped says so and
  // names what actually works. There is no automatic retry and no knob for one
  // (AGENTS.md), so "unavailable" was a dead end for the rest of the session.
  assert.equal(card({ failed: true }), stopped);
  assert.equal(card({ failed: 1 }), stopped);
  assert.notEqual(card({ failed: true }), 'Live preview unavailable');
  assert.equal(card({}), 'Loading window preview\u2026');
  // No producer yet: planned (or a session that captures nothing yet) is still
  // loading; unplanned inside a capturing session is the budget refusal.
  assert.equal(card({ hasCapture: false, planned: false }), 'Preview budget reached');
  assert.equal(card({ hasCapture: false, planned: true }), 'Loading window preview\u2026');
  assert.equal(card({ hasCapture: false, planned: false, captureEnabled: false }), 'Loading window preview\u2026');
  // A held plan keeps the address planned through the exit animation (F-13), so a
  // closing card never flips to the budget sentence.
  assert.equal(card({ hasCapture: false, planned: true, captureEnabled: true }), 'Loading window preview\u2026');
  // captureReason()'s refusal outranks everything: it is the specific truth.
  for (const refusal of ['Waiting for window metadata', 'Window is not captureable', 'Display is unavailable',
    'Waiting for window geometry', 'Window exceeds preview memory budget', 'Off-screen preview unavailable'])
    for (const failed of [true, false])
      assert.equal(card({ refusal: refusal, failed: failed, hasCapture: failed }), refusal);
  assert.equal(L.previewReason({ refusal: L.captureReason(null, outputs) }), 'Waiting for window metadata');
  assert.equal(L.previewReason({ refusal: L.captureReason(nativeWindow(), outputs), hasCapture: true, failed: true }), stopped);
  // Every reason a card can show is distinct, non-empty and short enough for the
  // 11 px placeholder label, whatever the shell passes in - including nothing.
  const seen = new Set(['Waiting for window metadata', 'Window is not captureable', 'Display is unavailable',
    'Waiting for window geometry', 'Window exceeds preview memory budget', 'Off-screen preview unavailable']);
  for (const captureEnabled of [true, false, undefined])
    for (const planned of [true, false, undefined])
      for (const hasCapture of [true, false, undefined])
        for (const failed of [true, false, undefined]) {
          const reason = L.previewReason({ refusal: '', captureEnabled, planned, hasCapture, failed });
          assert.equal(typeof reason, 'string');
          assert.ok(reason.length > 0, 'a card without an image must always say why');
          assert.ok(reason.length <= 48, 'reason too long for a card label: ' + reason);
          seen.add(reason);
        }
  assert.deepEqual([...seen].length, 9);
  assert.ok(seen.has(stopped));
  assert.ok(!seen.has('Live preview unavailable'));
  for (const empty of [undefined, null, {}, { refusal: '' }, { refusal: 0 }, { refusal: null }])
    assert.equal(L.previewReason(empty), 'Loading window preview\u2026');
});
test('the capture plan is held for the exit animation and recomputed on the next open', () => {
  const hold = (closing, plan, frozen, addresses) =>
    L.capturePlanHold({ closing: closing, plan: plan, frozen: frozen, addresses: addresses });
  // PINS F-13 - corrected by F-13 fix: a plan change during the close animation
  // used to reach NativeCapture.captureEnabled and blank a card for the exit.
  assert.deepEqual(hold(true, ['a'], ['a', 'b'], ['a', 'b']), ['a', 'b']);
  assert.deepEqual(hold(true, [], ['a', 'b'], ['a', 'b']), ['a', 'b']);
  assert.deepEqual(hold(true, ['b', 'a'], ['a', 'b'], ['b', 'a']), ['a', 'b']); // Held order, not the new one.
  // Opening again recomputes: the held list is only consulted while closing.
  assert.deepEqual(hold(false, ['a'], ['a', 'b'], ['a', 'b']), ['a']);
  assert.deepEqual(hold(false, [], ['a', 'b'], ['a', 'b']), []);
  for (const idle of [undefined, null, 0, ''])
    assert.deepEqual(hold(idle, ['c'], ['a'], ['a']), ['c']);
  // A window that closed during the animation is not resurrected, and one that
  // appeared is never added - holding may only keep, never start (`allowNew`).
  assert.deepEqual(hold(true, ['a', 'b'], ['a', 'b'], ['b']), ['b']);
  assert.deepEqual(hold(true, ['a', 'new'], ['a'], ['a', 'new']), ['a']);
  assert.deepEqual(hold(true, ['new'], ['a'], ['new']), []);
  assert.deepEqual(hold(true, ['a'], [], ['a']), []);
  // Missing inputs are empty plans, never exceptions.
  assert.deepEqual(L.capturePlanHold(), []);
  assert.deepEqual(L.capturePlanHold({}), []);
  assert.deepEqual(L.capturePlanHold({ closing: true }), []);
  assert.deepEqual(L.capturePlanHold({ closing: true, frozen: ['a'] }), []);
  assert.deepEqual(L.capturePlanHold({ plan: ['a'] }), ['a']);
  // The result is never the caller's own array while closing, so the shell cannot
  // mutate the held plan through it.
  const frozen = ['a'];
  assert.notEqual(hold(true, [], frozen, ['a']), frozen);
  // The exact F-13 scenario, with the real planner: two windows, a budget that
  // fits one, and a drag being cancelled as the close starts. The live plan flips
  // from the drag source to the selection; the held plan does not.
  const pair = [nativeWindow('a'), nativeWindow('b', 800)]; // 480000 scaled px each
  const dragging = L.capturePlan(pair, ['b'], outputs, 32, 600000);
  const cancelled = L.capturePlan(pair, ['a'], outputs, 32, 600000);
  assert.deepEqual([dragging, cancelled], [['b'], ['a']]);
  assert.deepEqual(hold(true, cancelled, dragging, ['a', 'b']), ['b']);
  assert.deepEqual(hold(false, cancelled, dragging, ['a', 'b']), ['a']);
  // The live streams stay off while closing whatever the held plan says.
  assert.deepEqual(L.liveSelection({ windows: pair, priority: ['b'], limit: 0, previewAddress: '',
    closing: true, planned: hold(true, cancelled, dragging, ['a', 'b']) }), []);
});

// --- Settings validation coverage.
test('settings defaults are the complete key set and a fresh object each call', () => {
  assert.deepEqual(Object.keys(L.defaults()),
    ['followTheme', 'blur', 'dim', 'motion', 'liveLimit', 'keepCache', 'monitorOnly']);
  assert.deepEqual(L.defaults(), { followTheme: true, blur: true, dim: 40, motion: true, liveLimit: 0,
    keepCache: true, monitorOnly: false });
  assert.notEqual(L.defaults(), L.defaults());
  assert.deepEqual(L.settings({}), L.defaults());
  // PINS F-15 - corrected by F-15 fix: the default liveLimit of 0 means no cap on live streams.
  assert.equal(L.defaults().liveLimit, 0);
});
test('boolean settings refuse every non-boolean value', () => {
  for (const name of ['followTheme', 'blur', 'motion', 'keepCache', 'monitorOnly']) {
    assert.equal(L.setting(name, true), true);
    assert.equal(L.setting(name, false), false);
    for (const value of [0, 1, 'true', 'false', '', null, undefined, NaN, [], {}])
      assert.equal(L.setting(name, value), undefined, name + ' accepted ' + JSON.stringify(value));
  }
});
test('dim clamps to 0..80 with rounding and rejects everything unnumeric', () => {
  assert.equal(L.setting('dim', 0), 0);
  assert.equal(L.setting('dim', 80), 80);
  assert.equal(L.setting('dim', -5), 0);
  assert.equal(L.setting('dim', 999), 80);
  assert.equal(L.setting('dim', 80.5), 80);
  assert.equal(L.setting('dim', 39.5), 40);
  assert.equal(L.setting('dim', 40.4), 40);
  assert.equal(L.setting('dim', -0.4), 0);
  for (const value of [NaN, Infinity, -Infinity, '40', '', true, false, null, undefined, [40], {}])
    assert.equal(L.setting('dim', value), undefined, 'dim accepted ' + JSON.stringify(value));
  assert.equal(L.settings({ dim: 12.6 }).dim, 13);
  assert.equal(L.settings({ dim: '12' }).dim, 40);
});
test('liveLimit accepts only the published enum', () => {
  for (const value of [0, 1, 6, 12]) assert.equal(L.setting('liveLimit', value), value);
  for (const value of [2, 3, 5, 11, 13, -1, 6.5, 1000, '6', NaN, Infinity, true, null])
    assert.equal(L.setting('liveLimit', value), undefined, 'liveLimit accepted ' + JSON.stringify(value));
  assert.equal(L.settings({ liveLimit: 12 }).liveLimit, 12);
  assert.equal(L.settings({ liveLimit: 7 }).liveLimit, 0);
});
test('settings ignores unknown keys and preserves the legacy keepCache key', () => {
  const result = L.settings({ command: 'rm -rf /', version: 1, dim: 12, keepCache: false });
  assert.deepEqual(Object.keys(result), Object.keys(L.defaults()));
  assert.equal(result.command, undefined);
  assert.equal(result.version, undefined);
  assert.equal(result.dim, 12);
  // A settings file is read with JSON.parse, which keeps "__proto__" as an own key, so no value is inherited.
  assert.equal(L.settings(JSON.parse('{"__proto__":{"blur":false},"dim":10}')).blur, true);
  // Pinned quirk, no audit finding: values are read with document[key], so a prototype set in JS is honoured.
  assert.equal(L.settings({ __proto__: { blur: false } }).blur, false);
  assert.equal(L.setting('command', 'anything'), undefined);
  assert.equal(L.setting('toString', 'anything'), undefined);
  assert.equal(L.setting('', 1), undefined);
  // PINS F-16 - corrected by F-16 fix: keepCache survives as a legacy key although this tree has no frame cache.
  assert.equal(result.keepCache, false);
  assert.equal(L.setting('keepCache', true), true);
});

// --- Open-path policy (Workstream B: AUDIT.md F-01, F-02, F-05 and the visible
// --- recheck). Each test fails against the pre-fix inline shell.qml policy.
test('a paused open survives topology churn instead of being dropped', () => {
  const paused = { screens: 2, opening: false, resumeOpen: true, shown: false, shutdownRequested: false, attempts: 0 };
  assert.equal(L.settleOutcome(paused).action, 'resume');
  assert.equal(L.settleOutcome({ ...paused, opening: true }).action, 'context');
  assert.equal(L.settleOutcome({ ...paused, resumeOpen: false }).action, 'none');
  // An explicit close, a visible session and a shutdown are never resurrected.
  assert.equal(L.settleOutcome({ ...paused, shutdownRequested: true }).action, 'none');
  assert.equal(L.settleOutcome({ ...paused, shown: true }).action, 'none');
  assert.equal(L.settleOutcome({ ...paused, opening: true, shutdownRequested: true }).action, 'none');
  // A pause that found no open to keep leaves the flag alone but still settles.
  assert.deepEqual(L.settleOutcome({ screens: 1 }), { topologyReady: true, attempts: 0, action: 'none', reason: '' });
});
test('the settle timer never reports a topology as ready without a usable output', () => {
  const blind = { screens: 0, opening: true, resumeOpen: false, shown: false, shutdownRequested: false, attempts: 0 };
  assert.equal(L.settleOutcome(blind).topologyReady, false);
  assert.equal(L.settleOutcome(blind).action, 'retry');
  assert.equal(L.settleOutcome(blind).attempts, 1);
  assert.equal(L.settleOutcome({ ...blind, attempts: 1 }).action, 'retry');
  const last = L.settleOutcome({ ...blind, attempts: 2 });
  assert.equal(last.action, 'fail');
  assert.equal(last.topologyReady, false);
  assert.equal(L.openFailure(last.reason), 'No usable display for the overview');
  // The budget self-heals, so the next open starts from a full one.
  assert.equal(last.attempts, 0);
  assert.equal(L.settleOutcome({ ...blind, attempts: 0, maxAttempts: 1 }).action, 'fail');
  // A hidden session with no open pending keeps the flag honest and acts on nothing.
  assert.deepEqual(L.settleOutcome({ screens: 0 }), { topologyReady: false, attempts: 0, action: 'none', reason: '' });
  assert.equal(L.settleOutcome({ ...blind, screens: 1 }).topologyReady, true);
});
test('presentOverview refuses a session that would be visible with no panel', () => {
  const ready = { opening: true, shutdownRequested: false, screens: 1, topologyReady: true, contextAllowed: true };
  assert.equal(L.presentBlocked(ready), '');
  assert.equal(L.presentBlocked({ ...ready, opening: false }), 'ignore');
  assert.equal(L.presentBlocked({ ...ready, shutdownRequested: true }), 'ignore');
  assert.equal(L.presentBlocked({ ...ready, screens: 0 }), 'noOutput');
  assert.equal(L.presentBlocked({ ...ready, screens: undefined }), 'noOutput');
  // A visible session with no capture permission or unsettled outputs is also dead.
  assert.equal(L.presentBlocked({ ...ready, topologyReady: false }), 'noTopology');
  assert.equal(L.presentBlocked({ ...ready, contextAllowed: false }), 'noContext');
  // The missing panel outranks the other two, because it is the one the user sees.
  assert.equal(L.presentBlocked({ ...ready, screens: 0, topologyReady: false, contextAllowed: false }), 'noOutput');
  assert.equal(L.openFailure(L.presentBlocked({ ...ready, screens: 0 })), 'No usable display for the overview');
});
test('a refused capture-context check names the real cause and retries a draining helper', () => {
  assert.deepEqual(L.contextRefusal({ refusal: 'output', attempts: 0, purpose: 'open' }),
    { action: 'fail', reason: 'output' });
  assert.equal(L.openFailure('output'), 'No display selected for the overview');
  assert.equal(L.contextRefusal({ refusal: 'draining', attempts: 0 }).action, 'retry');
  assert.equal(L.contextRefusal({ refusal: 'draining', attempts: 1 }).action, 'retry');
  const exhausted = L.contextRefusal({ refusal: 'draining', attempts: 2 });
  assert.equal(exhausted.action, 'fail');
  assert.equal(L.openFailure(exhausted.reason), 'Previous capture-context check is still stopping');
  assert.equal(L.contextRefusal({ refusal: 'draining', attempts: 0, maxAttempts: 0 }).action, 'fail');
  // A run that already serves this open is left alone; any other one is reported.
  assert.deepEqual(L.contextRefusal({ refusal: 'pending', purpose: 'open' }), { action: 'wait', reason: '' });
  assert.deepEqual(L.contextRefusal({ refusal: 'pending', purpose: 'recheck' }), { action: 'fail', reason: 'pending' });
  assert.equal(L.contextRefusal({ refusal: '' }).reason, 'unknown');
  assert.equal(L.contextRefusal({}).action, 'fail');
  // The three causes must not share one message any more.
  const messages = ['output', 'draining', 'pending'].map(L.openFailure);
  assert.equal(new Set(messages).size, 3);
});
test('the visible recheck never runs during an open, a close or a shutdown', () => {
  const idle = { panelVisible: true, shown: true, opening: false, closing: false, shutdownRequested: false, canBegin: true };
  assert.equal(L.recheckAllowed(idle), true);
  assert.equal(L.recheckAllowed({ ...idle, opening: true }), false);
  assert.equal(L.recheckAllowed({ ...idle, closing: true }), false);
  assert.equal(L.recheckAllowed({ ...idle, shutdownRequested: true }), false);
  // A session that is "shown" with no mapped panel must not poll the helper.
  assert.equal(L.recheckAllowed({ ...idle, panelVisible: false }), false);
  assert.equal(L.recheckAllowed({ ...idle, shown: false }), false);
  // The guard's own documented gate still applies.
  assert.equal(L.recheckAllowed({ ...idle, canBegin: false }), false);
  assert.equal(L.recheckAllowed({}), false);
});
test('a capture-context verdict only ever drives the session that asked for it', () => {
  const ok = { ok: true, reason: '', opening: true, shown: false, closing: false, shutdownRequested: false };
  assert.deepEqual(L.guardVerdict({ ...ok, purpose: 'open' }), { action: 'present', reason: '' });
  assert.equal(L.guardVerdict({ ...ok, purpose: 'recheck' }).action, 'ignore');
  assert.equal(L.guardVerdict({ ...ok, purpose: 'recheck', opening: false, shown: true }).action, 'allow');
  assert.equal(L.guardVerdict({ ...ok, purpose: 'open', opening: false, shown: true }).action, 'ignore');
  // An untagged verdict belongs to no session and may not close or present one.
  assert.equal(L.guardVerdict({ ...ok, purpose: '', shown: true }).action, 'ignore');
  assert.equal(L.guardVerdict({ ...ok, purpose: 'open', closing: true }).action, 'ignore');
  assert.equal(L.guardVerdict({ ...ok, purpose: 'recheck', opening: false, shown: true, closing: true }).action, 'ignore');
  assert.equal(L.guardVerdict({ ...ok, purpose: 'open', shutdownRequested: true }).action, 'ignore');
  const bad = { ...ok, ok: false, reason: 'Capture context check timed out' };
  assert.deepEqual(L.guardVerdict({ ...bad, purpose: 'open' }), { action: 'fail', reason: 'Capture context check timed out' });
  assert.equal(L.guardVerdict({ ...bad, purpose: 'recheck', opening: false, shown: true }).action, 'fail');
  // A recheck failure during an open cannot cancel the open (the wrong session).
  assert.equal(L.guardVerdict({ ...bad, purpose: 'recheck', opening: true, shown: true }).action, 'ignore');
  // A helper that reports no reason still produces a truthful default.
  assert.equal(L.guardVerdict({ ...ok, ok: false, purpose: 'open' }).reason, 'Capture context unavailable');
});
test('captures need a mapped panel, a granted context and a settled topology', () => {
  const live = { shown: true, framePresented: true, contextAllowed: true, topologyReady: true };
  assert.equal(L.captureEnabled(live), true);
  for (const key of ['shown', 'framePresented', 'contextAllowed', 'topologyReady'])
    assert.equal(L.captureEnabled({ ...live, [key]: false }), false, key + ' did not gate capture');
  assert.equal(L.captureEnabled({}), false);
  // Zero captures while hidden, whatever the rest of the session believes.
  assert.equal(L.capturePlan([nativeWindow()], ['a'], outputs).length, 1);
  assert.equal(L.canCapture(L.captureEnabled({ ...live, shown: false }), true, nativeWindow(), outputs), false);
  // A topology with no usable output can never be reported as settled, so a
  // capture cannot be created before map + context + topology.
  assert.equal(L.settleOutcome({ screens: 0, opening: true }).topologyReady, false);
  assert.equal(L.captureEnabled({ ...live, topologyReady: L.settleOutcome({ screens: 0, opening: true }).topologyReady }), false);
});
test('every open failure code has one distinct, truthful message', () => {
  const codes = ['noOutput', 'noTopology', 'noContext', 'output', 'draining', 'pending'];
  const messages = codes.map(L.openFailure);
  assert.equal(new Set(messages).size, codes.length);
  for (const message of messages) assert.ok(message.length > 8 && !/undefined/.test(message), message);
  assert.equal(L.openFailure(''), 'Overview could not open');
  assert.equal(L.openFailure('nonsense'), 'Overview could not open');
  assert.equal(L.openFailure(undefined), 'Overview could not open');
  assert.equal(L.openFailure('toString'), 'Overview could not open');
});
test('the open path walkthrough: churn, resume, present, recheck, close', () => {
  // A cold open whose outputs are still settling waits, then proceeds.
  let state = { screens: 0, opening: true, resumeOpen: false, shown: false, shutdownRequested: false, attempts: 0 };
  let settle = L.settleOutcome(state);
  assert.equal(settle.action, 'retry');
  settle = L.settleOutcome({ ...state, screens: 1, attempts: settle.attempts });
  assert.equal(settle.action, 'context');
  assert.equal(settle.topologyReady, true);
  // The guard is busy draining the previous helper: retry, do not fail the open.
  let attempt = L.contextRefusal({ refusal: 'draining', attempts: 0, purpose: '' });
  assert.equal(attempt.action, 'retry');
  // readyToBegin() fires, the run is accepted and tagged, the verdict presents.
  assert.equal(L.guardVerdict({ purpose: 'open', ok: true, opening: true, shown: false, closing: false }).action, 'present');
  assert.equal(L.presentBlocked({ opening: true, screens: 1, topologyReady: true, contextAllowed: true }), '');
  // Visible session: the recheck may run and only refreshes the permission.
  const visible = { panelVisible: true, shown: true, opening: false, closing: false, canBegin: true };
  assert.equal(L.recheckAllowed(visible), true);
  assert.equal(L.guardVerdict({ purpose: 'recheck', ok: true, opening: false, shown: true, closing: false }).action, 'allow');
  // Monitor churn while visible: the session closes and is not resurrected.
  assert.equal(L.settleOutcome({ screens: 1, opening: false, resumeOpen: false, shown: false }).action, 'none');
  // Churn during the next open: the open is remembered and restarted once.
  assert.equal(L.settleOutcome({ screens: 1, opening: false, resumeOpen: true, shown: false }).action, 'resume');
  // The user closes: nothing pending may reopen or poll.
  assert.equal(L.recheckAllowed({ ...visible, closing: true }), false);
  assert.equal(L.guardVerdict({ purpose: 'recheck', ok: false, reason: 'x', opening: false, shown: true, closing: true }).action, 'ignore');
});

// --- Close, shutdown and activation policy (Workstream B: AUDIT.md F-03, F-04,
// --- F-07 and the refuted F-08). Each test fails against the pre-fix inline
// --- shell.qml policy transcribed into the same signatures.
test('a blocked shutdown still terminates: every latch is named, the watchdog forces the quit', () => {
  const ready = { shutdownRequested: true, busy: false, preparing: false, activating: false, saving: false };
  // Naming the latch is what lets the shell re-arm on the one that clears (only
  // `busy` had no re-arm at all) and report the one that never did.
  assert.equal(L.shutdownBlocker(ready), '');
  assert.equal(L.shutdownBlocker({ ...ready, busy: true }), 'busy');
  assert.equal(L.shutdownBlocker({ ...ready, preparing: true }), 'preparing');
  assert.equal(L.shutdownBlocker({ ...ready, activating: true }), 'activating');
  assert.equal(L.shutdownBlocker({ ...ready, saving: true }), 'saving');
  assert.equal(L.shutdownBlocker({ ...ready, busy: true, preparing: true, activating: true, saving: true }), 'busy');
  // A shutdown nobody requested has nothing to block, whatever else is running.
  assert.equal(L.shutdownBlocker({ busy: true, saving: true }), '');
  assert.equal(L.shutdownBlocker({}), '');
  // Every named latch is exactly one that stops the quit ...
  for (const latch of ['busy', 'preparing', 'activating', 'saving']) {
    assert.notEqual(L.shutdownReady({ ...ready, [latch]: true }), 'quit', latch + ' did not delay the quit');
    assert.equal(L.shutdownBlocker({ ...ready, [latch]: true }), latch);
  }
  // ... and none of them survives the watchdog deadline: a latch may delay the
  // quit, never cancel it, so the service's six-second wait cannot fail.
  for (const latch of ['busy', 'preparing', 'activating', 'saving'])
    assert.equal(L.shutdownReady({ ...ready, [latch]: true, expired: true }), 'quit', latch + ' outlived the watchdog');
  assert.equal(L.shutdownReady({ ...ready, busy: true, preparing: true, activating: true, saving: true, expired: true }), 'quit');
  // The deadline is meaningless without a request: no shutdown, no quit.
  assert.equal(L.shutdownReady({ ...ready, shutdownRequested: false, expired: true }), 'wait');
  assert.equal(L.shutdownReady({ expired: true }), 'wait');
  // The unblocked verdicts are unchanged by the new flag.
  assert.equal(L.shutdownReady(ready), 'quit');
  assert.equal(L.shutdownReady({ ...ready, saving: true }), 'flush');
});
test('an explicit activation happens exactly once and never from the preview path', () => {
  const chosen = { pendingWindow: true, source: 'close', shutdownRequested: false, activating: false };
  assert.deepEqual(L.activationHandoff(chosen), { action: 'activate', reason: '' });
  // A monitor or config event invalidates captures, not the window the user
  // clicked: the close that owns the handoff still runs.
  assert.deepEqual(L.activationHandoff({ ...chosen, source: 'pause' }), { action: 'keep', reason: '' });
  // Exactly once: a second finishClose() while the timer is armed must not
  // re-arm it, and once the timer consumed the window nothing activates again.
  assert.equal(L.activationHandoff({ ...chosen, activating: true }).action, 'wait');
  assert.equal(L.activationHandoff({ ...chosen, pendingWindow: false }).action, 'none');
  assert.equal(L.activationHandoff({ ...chosen, pendingWindow: false, activating: true }).action, 'none');
  // Quick Look and the keyboard selection never hand a window to activation;
  // only choose()'s pendingWindow can.
  assert.equal(L.activationHandoff({ pendingWindow: false, source: 'close',
    previewAddress: '0x1', selectedAddress: '0x2' }).action, 'none');
  assert.equal(L.activationHandoff({}).action, 'none');
  // The two deliberate losses stay losses, but they are reported now.
  const locked = L.activationHandoff({ ...chosen, source: 'lock' });
  const quitting = L.activationHandoff({ ...chosen, shutdownRequested: true });
  assert.equal(locked.action, 'discard');
  assert.equal(quitting.action, 'discard');
  assert.ok(locked.reason.length > 8 && quitting.reason.length > 8);
  assert.notEqual(locked.reason, quitting.reason);
  // A lock surface outranks an armed timer; a shutdown outranks the churn 'keep'.
  assert.equal(L.activationHandoff({ ...chosen, source: 'lock', activating: true }).action, 'discard');
  assert.equal(L.activationHandoff({ ...chosen, source: 'pause', shutdownRequested: true }).action, 'discard');
  assert.equal(L.activationHandoff({ ...chosen, source: 'lock', pendingWindow: false }).action, 'none');
  // Only a loss carries a reason, so nothing else can be reported as one.
  for (const source of ['close', 'pause'])
    assert.equal(L.activationHandoff({ ...chosen, source: source }).reason, '');
});
test('a close motion or its watchdog only finishes the session it was started for', () => {
  const closing = { closing: true, session: 4, openCount: 4, source: 'motion' };
  assert.deepEqual(L.closeVerdict(closing), { action: 'finish', reason: '' });
  // A newer open owns the shell: a motion landing afterwards tears nothing down.
  assert.equal(L.closeVerdict({ ...closing, openCount: 5 }).action, 'ignore');
  // finishClose() already ran (an immediate close, a pause, a lock): nothing left.
  assert.equal(L.closeVerdict({ ...closing, closing: false }).action, 'ignore');
  assert.equal(L.closeVerdict({ ...closing, closing: false, openCount: 5 }).action, 'ignore');
  assert.equal(L.closeVerdict({}).action, 'ignore');
  // The watchdog bounds `closing` and says why it acted; a stale one stays quiet.
  const forced = L.closeVerdict({ ...closing, source: 'watchdog' });
  assert.equal(forced.action, 'finish');
  assert.ok(forced.reason.length > 8);
  assert.equal(L.closeVerdict({ ...closing, source: 'watchdog', openCount: 5 }).action, 'ignore');
  assert.equal(L.closeVerdict({ ...closing, source: 'watchdog', closing: false }).reason, '');
  // The motion path stays silent on the normal close, so no session logs noise.
  assert.equal(L.closeVerdict(closing).reason, '');
  assert.equal(L.closeVerdict({ ...closing, source: 'unknown' }).action, 'finish');
});
test('a desktop-state refresh never clobbers a queued close or undo (F-08, refuted)', () => {
  // Recorded and deliberately NOT changed: the audit refuted F-08 and downgraded
  // it to low, because runAction() refuses while busy and the refresh defers
  // while an action or an open is in flight, so actionName/closeWhenDone always
  // describe the single live action. The extraction keeps that checked here; the
  // residual (no client-side ceiling on `busy`) lives in BackendClient.qml, which
  // this task does not own - the shutdown watchdog above bounds its only
  // cross-cutting consequence, a quit that never happens.
  assert.equal(L.refreshAction({ ready: true, busy: false, preparing: false }), 'run');
  assert.equal(L.refreshAction({ ready: true, busy: true, preparing: false }), 'defer');
  assert.equal(L.refreshAction({ ready: true, busy: false, preparing: true }), 'defer');
  assert.equal(L.refreshAction({ ready: true, busy: true, preparing: true }), 'defer');
  // A worker that is not ready yet is announced by onReadyChanged, not polled.
  assert.equal(L.refreshAction({ ready: false, busy: false, preparing: false }), 'skip');
  assert.equal(L.refreshAction({ ready: false, busy: true, preparing: true }), 'skip');
  assert.equal(L.refreshAction({}), 'skip');
  // Escape while busy queues the close, and the refresh cannot turn that into a
  // closeWhenDone:false "state" action, because it never runs while busy.
  const busyClose = { opening: false, shutdownRequested: false, busy: true, closing: false, shown: true, motion: true };
  assert.equal(L.closeMode(busyClose), 'deferToBusy');
  assert.equal(L.refreshAction({ ready: true, busy: true, preparing: false }), 'defer');
});
test('the close walkthrough: choose, churn, activate once, then a bounded shutdown', () => {
  // choose() stores the window and starts the animated close of session 7.
  assert.equal(L.closeMode({ opening: false, shutdownRequested: false, busy: false, closing: false,
    shown: true, motion: true }), 'animate');
  assert.equal(L.closeVerdict({ closing: true, session: 7, openCount: 7, source: 'motion' }).action, 'finish');
  // A monitor event lands mid-animation: captures die, the chosen window does not.
  assert.equal(L.activationHandoff({ pendingWindow: true, source: 'pause' }).action, 'keep');
  assert.equal(L.captureEnabled({ shown: false, framePresented: true, contextAllowed: true, topologyReady: true }), false);
  assert.equal(L.canCapture(false, true, nativeWindow(), outputs), false);
  assert.deepEqual(L.liveSelection({ windows: [{ address: 'a' }], priority: ['a'], limit: 0,
    previewAddress: '', closing: true, planned: ['a'] }), []);
  // finishClose() hands the window over exactly once ...
  assert.equal(L.activationHandoff({ pendingWindow: true, source: 'close' }).action, 'activate');
  assert.equal(L.activationHandoff({ pendingWindow: true, source: 'close', activating: true }).action, 'wait');
  // ... and while the handoff is armed a queued shutdown waits for it, then the
  // activation timer re-arms the quit.
  const arming = { shutdownRequested: true, busy: false, preparing: false, activating: true, saving: false };
  assert.equal(L.shutdownReady(arming), 'wait');
  assert.equal(L.shutdownBlocker(arming), 'activating');
  assert.equal(L.activationHandoff({ pendingWindow: true, source: 'close', shutdownRequested: true }).action, 'discard');
  assert.equal(L.shutdownReady({ ...arming, activating: false }), 'quit');
  // A "state" reply that never arrives delays the quit; the watchdog ends it.
  const wedged = { ...arming, activating: false, busy: true };
  assert.equal(L.shutdownBlocker(wedged), 'busy');
  assert.equal(L.shutdownReady(wedged), 'wait');
  assert.equal(L.shutdownReady({ ...wedged, expired: true }), 'quit');
  // The stale exit motion of session 7 finally lands after a newer open: ignored.
  assert.equal(L.closeVerdict({ closing: true, session: 7, openCount: 8, source: 'motion' }).action, 'ignore');
  assert.equal(L.closeVerdict({ closing: false, session: 7, openCount: 7, source: 'motion' }).action, 'ignore');
});

// --- The IPC guard matrix, the launcher contract and status-payload safety
// --- (Workstream B/D: AUDIT.md F-44, F-45, F-46, F-47, F-50, F-51 and F-09's
// --- navigateDesktop abort). The ten replies are a contract with
// --- integrations/omarchy-overview, so every cell is pinned here. Each test
// --- fails against the pre-fix inline shell.qml guards.
const ipcCalls = ['openOverview', 'toggle', 'shutdown', 'captureReady', 'close', 'setQuery',
  'togglePreview', 'showSettings', 'navigateDesktop', 'status'];
const hidden = { shown: false, opening: false, closing: false, busy: false, settingsShown: false,
  dragging: false, activating: false, shutdownRequested: false, pendingWindow: false, ready: true,
  desktops: 3, previewAddress: '', hasSelection: true };
const open = { ...hidden, shown: true };
function ipcArg(call) { return call === 'navigateDesktop' ? 'next' : call === 'setQuery' ? 'kitty' : ''; }
function guard(call, state, arg) {
  return L.ipcGuard({ call: call, arg: arg === undefined ? ipcArg(call) : arg, state: state });
}
function replyOf(call, state, arg) { return guard(call, state, arg).reply; }
function actionOf(call, state, arg) { return guard(call, state, arg).action; }
test('every IPC handler answers one documented reply, and a refusal never acts', () => {
  const vocabulary = ['ok', 'shutdown', 'closing', 'opening', 'shown', 'hidden', 'busy', 'dragging',
    'settings', 'activating', 'empty', 'unavailable', 'invalid'];
  const states = [hidden, open];
  for (const flag of ['shown', 'opening', 'closing', 'busy', 'settingsShown', 'dragging', 'activating',
    'shutdownRequested', 'pendingWindow'])
    states.push({ ...hidden, [flag]: true }, { ...open, [flag]: true });
  states.push({ ...hidden, ready: false }, { ...open, ready: false }, { ...open, desktops: 0 },
    { ...open, hasSelection: false }, { ...open, previewAddress: '0x1' }, {});
  for (const state of states)
    for (const call of ipcCalls) {
      const verdict = guard(call, state);
      assert.ok(vocabulary.indexOf(verdict.reply) >= 0, call + ' answered ' + verdict.reply);
      assert.ok(['open', 'close', 'filter', 'step', 'run', 'refuse'].indexOf(verdict.action) >= 0,
        call + ' asked for ' + verdict.action);
      // 'ok' is only ever the answer of a request that was accepted, and a
      // refusal is exactly an action with no side effect.
      assert.equal(verdict.action === 'refuse', verdict.reply !== 'ok', call + ' -> ' + JSON.stringify(verdict));
    }
  // An unknown function name resolves like an unvalidated argument, never as a call.
  assert.deepEqual(L.ipcGuard({ call: 'openOverviewNow', state: hidden }), { action: 'refuse', reply: 'invalid' });
  assert.deepEqual(L.ipcGuard({}), { action: 'refuse', reply: 'invalid' });
  assert.deepEqual(L.ipcGuard(), { action: 'refuse', reply: 'invalid' });
  // Arguments outside the documented set are refused instead of silently meaning
  // the default ('' for toggle, 'previous' for navigateDesktop).
  assert.equal(replyOf('toggle', hidden, 'app'), 'ok');
  assert.equal(replyOf('toggle', hidden, ''), 'ok');
  assert.equal(replyOf('toggle', hidden, undefined), 'ok');
  assert.equal(replyOf('toggle', hidden, 'App'), 'invalid');
  assert.equal(actionOf('toggle', hidden, 'plain'), 'refuse');
  assert.equal(replyOf('navigateDesktop', open, 'previous'), 'ok');
  assert.equal(replyOf('navigateDesktop', open, 'PREVIOUS'), 'invalid');
  assert.equal(replyOf('navigateDesktop', open, ''), 'invalid');
  assert.equal(actionOf('navigateDesktop', hidden, 'forward'), 'refuse');
  // setQuery drives windows -> layoutKey -> Layout.arrange(), so an unbounded
  // string is refused rather than packed.
  assert.equal(replyOf('setQuery', open, ''), 'ok');
  assert.equal(replyOf('setQuery', open, 'x'.repeat(200)), 'ok');
  assert.equal(replyOf('setQuery', open, 'x'.repeat(201)), 'invalid');
  assert.equal(actionOf('setQuery', open, 'x'.repeat(1000000)), 'refuse');
  // The two unguarded calls stay unguarded in every state: status() is the
  // launcher's liveness probe and captureReady() answers for a capture object.
  for (const state of states) {
    assert.deepEqual(guard('status', state), { action: 'run', reply: 'ok' });
    assert.deepEqual(guard('captureReady', state), { action: 'run', reply: 'ok' });
    assert.deepEqual(guard('shutdown', state), { action: 'run', reply: 'ok' });
  }
});
test('a call arriving mid-transition is refused with the documented value', () => {
  // shutdownRequested outranks every request but the probes and a second
  // shutdown. The 3 s watchdog bounds it, so this is a state, not the F-44 latch.
  const quitting = { ...open, shutdownRequested: true };
  for (const call of ['openOverview', 'toggle', 'close', 'setQuery', 'togglePreview', 'showSettings',
    'navigateDesktop'])
    assert.equal(replyOf(call, quitting), 'shutdown', call);
  assert.equal(replyOf('shutdown', quitting), 'ok');
  // `closing` is the 130 ms exit motion, bounded by the close watchdog: it owns
  // the session, and every handler says so instead of acting inside it.
  const closing = { ...open, closing: true };
  for (const call of ['openOverview', 'toggle', 'close', 'setQuery', 'togglePreview', 'showSettings',
    'navigateDesktop'])
    assert.equal(replyOf(call, closing), 'closing', call);
  // `opening`: refused, and nothing aborts the open any more (that was F-09).
  const opening = { ...hidden, opening: true };
  assert.equal(replyOf('openOverview', opening), 'opening');
  assert.deepEqual(guard('navigateDesktop', opening), { action: 'refuse', reply: 'opening' });
  for (const call of ['setQuery', 'togglePreview', 'showSettings'])
    assert.equal(replyOf(call, opening), 'hidden', call);
  // A toggle is the one request that may cancel an in-flight open: that is what
  // pressing the toggle key during a cold open means.
  assert.deepEqual(guard('toggle', opening), { action: 'close', reply: 'ok' });
  // `preparing` is `opening` under the name status() reports; same cell.
  assert.equal(L.ipcGuard({ call: 'navigateDesktop', arg: 'next',
    state: { ...hidden, opening: true, preparing: true } }).reply, 'opening');
  // `busy` is a desktop action in flight: an open is not blocked by it, and a
  // close is queued (closeWhenDone), which is an acceptance and not a refusal.
  const busy = { ...open, busy: true };
  for (const call of ['setQuery', 'togglePreview', 'showSettings', 'navigateDesktop'])
    assert.equal(replyOf(call, busy), 'busy', call);
  assert.deepEqual(guard('close', busy), { action: 'close', reply: 'ok' });
  assert.deepEqual(guard('toggle', busy), { action: 'close', reply: 'ok' });
  assert.deepEqual(guard('openOverview', { ...hidden, busy: true }), { action: 'open', reply: 'ok' });
  // The settings panel owns the keyboard; showSettings itself stays idempotent.
  const settings = { ...open, settingsShown: true };
  for (const call of ['setQuery', 'togglePreview', 'navigateDesktop'])
    assert.equal(replyOf(call, settings), 'settings', call);
  assert.deepEqual(guard('showSettings', settings), { action: 'run', reply: 'ok' });
  // activateTimer.running, and the pendingWindow that arms it: a chosen window is
  // being focused, so nothing may open or navigate in that same instant.
  assert.equal(replyOf('openOverview', { ...hidden, activating: true }), 'activating');
  assert.equal(replyOf('toggle', { ...hidden, activating: true }), 'activating');
  assert.equal(replyOf('navigateDesktop', { ...hidden, activating: true }), 'activating');
  assert.equal(replyOf('navigateDesktop', { ...hidden, pendingWindow: true }), 'activating');
  // A visible session is already open, and the calls that need one say so.
  assert.equal(replyOf('openOverview', open), 'shown');
  for (const call of ['setQuery', 'togglePreview', 'showSettings'])
    assert.equal(replyOf(call, hidden), 'hidden', call);
  // A drag belongs to the user's hands: nothing moves under them ...
  const dragging = { ...open, dragging: true };
  for (const call of ['togglePreview', 'showSettings', 'navigateDesktop'])
    assert.equal(replyOf(call, dragging), 'dragging', call);
  // ... except a query, because the drag ghost deliberately survives filtering.
  assert.deepEqual(guard('setQuery', dragging), { action: 'run', reply: 'ok' });
  // Nothing to act on: no desktop in the strip, no card under the selection.
  assert.equal(replyOf('navigateDesktop', { ...open, desktops: 0 }), 'empty');
  assert.equal(replyOf('togglePreview', { ...open, hasSelection: false }), 'empty');
  // Dismissing Quick Look is the way back out, so it is never refused - not even
  // while an action is in flight or a drag is running.
  assert.equal(actionOf('togglePreview', { ...open, previewAddress: '0x1', busy: true, dragging: true }), 'run');
  assert.equal(replyOf('togglePreview', { ...open, previewAddress: '0x1', closing: true }), 'closing');
  // close() is idempotent: a hidden session answers the same as a visible one,
  // because both end with "the session is gone".
  assert.deepEqual(guard('close', hidden), { action: 'close', reply: 'ok' });
  assert.deepEqual(guard('close', open), { action: 'close', reply: 'ok' });
  assert.deepEqual(guard('close', { ...hidden, opening: true }), { action: 'close', reply: 'ok' });
});
test('navigateDesktop keeps the launcher contract: only `unavailable` may dispatch a real switch', () => {
  // integrations/omarchy-overview answers a call Overview never answered (its
  // `quickshell ipc call` exited non-zero: not running, or killed by `timeout
  // 1`), or exactly the reply 'unavailable', with `controller.py step
  // <direction>` - a REAL compositor workspace switch. Every other reply must
  // therefore mean "Overview is running and owns this request".
  const dispatches = (reply, answered = true) => !answered || reply === 'unavailable';
  // Hidden and able: the shell takes the step itself, so the launcher stays out.
  assert.deepEqual(guard('navigateDesktop', hidden), { action: 'step', reply: 'ok' });
  assert.equal(dispatches('ok'), false);
  // Hidden and unable: no worker yet, or an action already in flight. This is the
  // one case the CLI fallback exists for, and it is what today's 'hidden' meant.
  assert.equal(replyOf('navigateDesktop', { ...hidden, ready: false }), 'unavailable');
  assert.equal(replyOf('navigateDesktop', { ...hidden, busy: true }), 'unavailable');
  assert.equal(dispatches('unavailable'), true);
  // A visible session moves its own desktop filter; the compositor's workspace is
  // never switched behind it, and no refusal there reaches the fallback either.
  for (const state of [open, { ...open, busy: true }, { ...open, dragging: true },
    { ...open, settingsShown: true }, { ...open, desktops: 0 }, { ...open, closing: true },
    { ...open, shutdownRequested: true }])
    assert.equal(dispatches(replyOf('navigateDesktop', state)), false, JSON.stringify(state));
  // The hard contract: while opening, one key press neither aborts the open nor
  // switches a desktop under the session that is about to appear (F-09).
  assert.deepEqual(guard('navigateDesktop', { ...hidden, opening: true }), { action: 'refuse', reply: 'opening' });
  assert.equal(dispatches('opening'), false);
  // A chosen window is being focused: neither the shell nor the CLI switches now.
  for (const state of [{ ...hidden, activating: true }, { ...hidden, pendingWindow: true }])
    assert.equal(dispatches(replyOf('navigateDesktop', state)), false, JSON.stringify(state));
  // A shutdown in flight is not the launcher's business either.
  assert.equal(dispatches(replyOf('navigateDesktop', { ...hidden, shutdownRequested: true })), false);
  // An unvalidated direction must not reach a compositor dispatch.
  assert.equal(dispatches(replyOf('navigateDesktop', hidden, 'forward')), false);
  assert.equal(dispatches(replyOf('navigateDesktop', hidden, '')), false);
  // Only an unanswered call - the process is gone - leaves the fallback as the
  // only way to honour the key press. `--shutdown` relies on the same fact
  // through `ipc status`, which is why status() may never refuse.
  assert.equal(dispatches('', false), true);
  assert.equal(dispatches('Could not connect to instance', false), true);
  assert.deepEqual(guard('status', { ...open, closing: true, shutdownRequested: true, busy: true }),
    { action: 'run', reply: 'ok' });
});
test('the status payload never carries pixels, paths or preview content', () => {
  // status() is a debug/verification surface any process in the session can call
  // (F-51): it may contain already-user-visible metadata only. Hostile extra
  // fields on every input must be dropped, not copied.
  const hostile = { ...statusState,
    previewSource: { serial: 12, hasContent: true, image: 'data:image/png;base64,AAAA',
      filePath: '/home/sehun/.cache/overview/0x1.png', source: 'file:///tmp/frame.png', pixels: [1, 2, 3] },
    zones: [{ kind: 'window', key: 'window:0x1', address: '0x1', index: 0, x: 1, y: 2, width: 3, height: 4,
      window: { title: 'Bank statement.pdf', lastIpcObject: { class: 'org.pwmt.zathura' } } }],
    wallpaper: 'file:///home/sehun/.local/state/omarchy/current/background',
    thumbnail: 'data:image/png;base64,BBBB', secret: 'file:///etc/shadow', clipboard: 'hunter2' };
  const cards = [L.statusCard({ address: '0x1', title: 'Bank statement.pdf' },
    { hasContent: true, serial: 12, fresh: true, generation: 3, capturedAt: 1700,
      image: 'data:image/png;base64,CCCC', filePath: '/tmp/0x1.png', textureSize: { width: 800, height: 600 } },
    true, 'Loading window preview…')];
  const payload = L.statusPayload(hostile, cards);
  const json = JSON.stringify(payload);
  for (const leak of ['data:', 'file://', 'base64', '.png', '.jpg', 'grabToImage', 'toDataURL', 'title',
    'Bank statement', 'zathura', 'hunter2', 'shadow', 'wallpaper', 'clipboard', 'pixels', 'textureSize',
    'filePath', '/home/', '/tmp/', '/etc/'])
    assert.equal(json.indexOf(leak), -1, 'status payload leaked ' + leak);
  // The whole payload is the same 42 keys as before this task, in order, with no
  // key added for any state introduced by the guard matrix.
  assert.equal(Object.keys(payload).length, 42);
  assert.deepEqual(Object.keys(payload), Object.keys(L.statusPayload(statusState, [])));
  for (const key of ['image', 'images', 'pixels', 'thumbnail', 'thumbnails', 'frame', 'frames', 'wallpaper',
    'path', 'paths', 'file', 'preview', 'title', 'titles', 'guard', 'ipc'])
    assert.equal(Object.prototype.hasOwnProperty.call(payload, key), false, 'unexpected key ' + key);
  // The retired and constant fields the verifiers rely on are still exactly these.
  assert.deepEqual(payload.primed, []);
  assert.equal(payload.captureBackend, 'native-window');
  assert.equal(payload.captureViews, 2);
  assert.equal(payload.cachedFrames, 1);
  // A capture object is reported by serial, generation and freshness only; never
  // by its image, its texture or where it came from.
  assert.equal(payload.previewSourceId, 12);
  assert.deepEqual(Object.keys(payload.windows[0]), ['address', 'thumbnail', 'imageReady', 'sourceId', 'live',
    'reason', 'fresh', 'generation', 'capturedAt']);
  // A card's `reason` is one of Logic.captureReason()/previewReason()'s fixed
  // literals, so it can never quote a path or a window title.
  assert.equal(payload.windows[0].reason, 'Loading window preview…');
  // Zones keep geometry and identity, never the toplevel object behind them.
  assert.deepEqual(Object.keys(payload.zones[0]), ['kind', 'id', 'address', 'x', 'y', 'width', 'height']);
  assert.equal(payload.zones[0].window, undefined);
  assert.equal(payload.zones[0].key, undefined);
  // Present and deliberate, because all of it is already on screen or in
  // `hyprctl clients`: the search text, the app filter, addresses, the monitor
  // and its desktop labels, the stage geometry and the settings.
  assert.deepEqual([payload.query, payload.appFilter, payload.monitor, payload.selectedAddress],
    [statusState.query, statusState.appFilter, statusState.monitor, statusState.selectedAddress]);
  assert.deepEqual(payload.desktopLabels, statusState.desktopLabels);
  assert.deepEqual(payload.layout, statusState.layout);
  assert.deepEqual(payload.settings, statusState.settings);
});
test('a transient toplevel reset keeps the selection anchored and Quick Look open', () => {
  // AUDIT.md F-17: Hyprland.refreshToplevels() runs on every open and on every
  // movewindow, and a turn that republishes an empty collection must not be read
  // as "every window closed".
  const list = [{ address: 'a' }, { address: 'b' }, { address: 'c' }];
  const steady = { windows: list, allWindows: list, selected: 1, selectedAddress: 'b', previewAddress: 'b' };
  assert.deepEqual(L.selectionAnchor(steady),
    { selected: 1, selectedAddress: 'b', dismissPreview: false, transient: false });
  const reset = L.selectionAnchor({ ...steady, windows: [], allWindows: [] });
  assert.deepEqual(reset, { selected: 1, selectedAddress: 'b', dismissPreview: false, transient: true });
  // The same list returns: the same window is still selected, still at its index,
  // and still previewed.
  const restored = L.selectionAnchor({ ...steady, selected: reset.selected,
    selectedAddress: reset.selectedAddress });
  assert.deepEqual(restored, { selected: 1, selectedAddress: 'b', dismissPreview: false, transient: false });
  // Identity, not position: a reorder or a removal moves the index, never the
  // selected window.
  const reordered = L.selectionAnchor({ ...steady, windows: [{ address: 'c' }, { address: 'b' }] });
  assert.equal(reordered.selectedAddress, 'b');
  assert.equal(reordered.selected, 1);
  // The previewed window really closed: Quick Look is dismissed, and only then.
  const gone = [{ address: 'a' }, { address: 'c' }];
  assert.equal(L.selectionAnchor({ ...steady, windows: gone, allWindows: gone }).dismissPreview, true);
  assert.equal(L.selectionAnchor({ ...steady, windows: gone, allWindows: gone, previewAddress: '' })
    .dismissPreview, false);
  // The lost window's slot is inherited by the window that took its place, so
  // the next arrow key moves from there instead of jumping to the first card.
  assert.equal(L.selectionAnchor({ ...steady, windows: gone, allWindows: gone }).selectedAddress, 'c');
  assert.equal(L.selectionAnchor({ ...steady, windows: [{ address: 'a' }], allWindows: [{ address: 'a' }] })
    .selectedAddress, 'a');
  // An empty filtered scope while windows still exist is a real empty scope (a
  // query that matches nothing), not a transient.
  assert.deepEqual(L.selectionAnchor({ ...steady, windows: [] }),
    { selected: 0, selectedAddress: '', dismissPreview: true, transient: false });
  // Nothing selected and nothing previewed: nothing to restore or dismiss.
  assert.deepEqual(L.selectionAnchor({ windows: [], allWindows: [] }),
    { selected: 0, selectedAddress: '', dismissPreview: false, transient: true });
  assert.deepEqual(L.selectionAnchor({}),
    { selected: 0, selectedAddress: '', dismissPreview: false, transient: true });
  // A selection that outlived its window falls back inside the new list.
  assert.equal(L.selectionAnchor({ windows: [{ address: 'z' }], allWindows: [{ address: 'z' }],
    selected: 4, selectedAddress: 'b', previewAddress: '' }).selectedAddress, 'z');
});
test('a renamed or removed desktop re-selects the nearest surviving slot', () => {
  // AUDIT.md F-55: filterWorkspace is a key, not an index. Nothing remapped it
  // when the key stopped existing, which left an empty grid, a stale strip slot
  // and arrow navigation jumping to desktop 1.
  const live = [1, 2, 3, 4];
  assert.equal(L.reselectDesktop(3, live), 3);
  assert.equal(L.reselectDesktop(0, live), 0); // "All" is never remapped.
  // Renamed: the per-monitor plugin keeps the slot number, so the renamed slot is
  // the nearest surviving one - not desktop 1.
  assert.equal(L.reselectDesktop('name:DP-2:2', ['name:DP-2:1', 'name:office:2', 'name:DP-2:3']), 'name:office:2');
  // Removed from the middle: the desktop that moved into its place.
  assert.equal(L.reselectDesktop(3, [1, 2, 4, 5]), 4);
  // The last slot removed: the new last one, never a wrap to the first.
  assert.equal(L.reselectDesktop(5, [1, 2, 3, 4]), 4);
  assert.equal(L.reselectDesktop('name:LG Electronics 17MT70 502NZRP066334:9', [1, 2]), 2);
  // No workspaces left: "All", which shows every window instead of an empty grid.
  assert.equal(L.reselectDesktop(3, []), 0);
  assert.equal(L.reselectDesktop('name:gone', []), 0);
  assert.equal(L.reselectDesktop(3, undefined), 0);
  // A key with no slot number at all resolves to the first surviving desktop,
  // deterministically rather than to whatever the strip happens to show.
  assert.equal(L.reselectDesktop('name:office', ['name:home', 'name:work']), 'name:home');
  assert.equal(L.reselectDesktop(2, ['name:home', 'name:work']), 'name:home');
  // The slot is read out of the key, never out of its position in the strip.
  assert.equal(L.desktopSlot(7), 7);
  assert.equal(L.desktopSlot('name:LG Electronics 17MT70 502NZRP066334:2'), 2);
  assert.equal(L.desktopSlot('3'), 3);
  assert.ok(Number.isNaN(L.desktopSlot('name:office')));
  assert.ok(Number.isNaN(L.desktopSlot(undefined)));
  assert.ok(Number.isNaN(L.desktopSlot(NaN)));
  // Re-selection only ever answers a desktop key: it is a filter change, and it
  // must never be read as a request to switch the compositor's workspace.
  assert.equal(typeof L.reselectDesktop('name:gone', [4]), 'number');
  assert.equal(L.reselectDesktop('name:gone', ['name:home']), 'name:home');
});
test('the stage always says why it is empty, including a layout it could not fill', () => {
  assert.equal(L.stageMessage({ windows: 3, placements: 3, stageReady: true }), '');
  // Layout.arrange() answers [] for a stage it cannot fill: that must read as one
  // short message, not as invisible zero-size cards.
  assert.equal(L.stageMessage({ windows: 3, placements: 0, stageReady: true }),
    'Not enough room to show these windows');
  // A stage with no size yet is not a refusal, so no message flashes on open.
  assert.equal(L.stageMessage({ windows: 3, placements: 0, stageReady: false }), '');
  // The four empty-scope messages are unchanged, in the same precedence order.
  assert.equal(L.stageMessage({ windows: 0, placements: 0, stageReady: true }), 'No open windows');
  assert.equal(L.stageMessage({ windows: 0, query: 'ter', appFilter: 'kitty', monitorOnly: true,
    stageReady: true }), 'No windows match your search');
  assert.equal(L.stageMessage({ windows: 0, appFilter: 'kitty', monitorOnly: true, stageReady: true }),
    'No windows for this app');
  assert.equal(L.stageMessage({ windows: 0, monitorOnly: true, stageReady: true }),
    'No windows on this desktop and monitor');
  assert.equal(L.stageMessage({}), 'No open windows');
  // One state, one string: every message is short and none of them is ambiguous.
  const messages = [L.stageMessage({ windows: 3, placements: 0, stageReady: true }),
    L.stageMessage({ windows: 0 }), L.stageMessage({ windows: 0, query: 'x' }),
    L.stageMessage({ windows: 0, appFilter: 'kitty' }), L.stageMessage({ windows: 0, monitorOnly: true })];
  assert.equal(new Set(messages).size, messages.length);
  for (const message of messages) assert.ok(message.length > 10 && message.length < 48, message);
});
test('capture planning fills the pixel budget greedily and never drops a priority window', () => {
  // AUDIT.md F-59, accepted as intended and deliberately NOT changed: when a
  // window does not fit the remaining budget, capturePlan skips it and keeps
  // filling with later, smaller windows. That is sound because the previewed,
  // dragged and selected addresses are processed first and claim budget first.
  const big = nativeWindow('big');
  big.lastIpcObject.size = [1400, 900]; // 1 260 000 scaled px vs 480 000 for the rest
  const small = nativeWindow('small', 900);
  assert.deepEqual(L.capturePlan([big, small], ['big', 'small'], outputs, 32, 1000000), ['small']);
  // Both fit: priority order is preserved exactly.
  assert.deepEqual(L.capturePlan([big, small], ['big', 'small'], outputs, 32, 2000000), ['big', 'small']);
  assert.deepEqual(L.capturePlan([big, small], ['small', 'big'], outputs, 32, 2000000), ['small', 'big']);
  // A priority address claims its budget before any lower-priority window, so it
  // is never dropped in favour of a smaller one ...
  assert.deepEqual(L.capturePlan([small, big], ['big'], outputs, 32, 1400000), ['big']);
  // ... and it keeps its place when both of them fit.
  assert.deepEqual(L.capturePlan([small, big], ['big'], outputs, 32, 1740000), ['big', 'small']);
  // maxViews truncates strictly in prefix order (a `break`, not a `continue`).
  const list = [nativeWindow('a'), nativeWindow('b', 800), nativeWindow('c', 100)];
  assert.deepEqual(L.capturePlan(list, ['c', 'b'], outputs, 2), ['c', 'b']);
  assert.deepEqual(L.capturePlan(list, ['c', 'b'], outputs, 32, 960000), ['c', 'b']);
});
test('the IPC walkthrough: a navigate during a cold open, then a bounded shutdown', () => {
  // A key press arrives while a cold open is still in flight. Before this task it
  // returned 'hidden', which aborted the open AND made the launcher dispatch a
  // real workspace switch - one press, two unwanted effects (F-09, F-46).
  const opening = { ...hidden, opening: true };
  assert.deepEqual(guard('navigateDesktop', opening), { action: 'refuse', reply: 'opening' });
  assert.equal(replyOf('openOverview', opening), 'opening');
  // The open finishes on its own and the session is visible: now the same key
  // moves this session's desktop filter and nothing else.
  assert.deepEqual(guard('navigateDesktop', open), { action: 'filter', reply: 'ok' });
  // The user chooses a window: the close is animated and everything is refused
  // inside it, with the reason named.
  assert.equal(L.closeMode({ opening: false, shutdownRequested: false, busy: false, closing: false,
    shown: true, motion: true }), 'animate');
  for (const call of ['toggle', 'setQuery', 'navigateDesktop'])
    assert.equal(replyOf(call, { ...open, closing: true }), 'closing', call);
  // The chosen window is being focused; a workspace switch would fight it.
  assert.equal(L.activationHandoff({ pendingWindow: true, source: 'close' }).action, 'activate');
  assert.equal(replyOf('navigateDesktop', { ...hidden, activating: true }), 'activating');
  // Hidden again: the shell owns the step itself, so the launcher stays out ...
  assert.deepEqual(guard('navigateDesktop', hidden), { action: 'step', reply: 'ok' });
  // ... unless its worker cannot take it, the single case the CLI fallback is for.
  assert.equal(replyOf('navigateDesktop', { ...hidden, ready: false }), 'unavailable');
  // `--shutdown` then latches the request; every call but the probes is refused
  // with one truthful code, and the watchdog still guarantees the quit, so the
  // refusal can never become F-44's permanent "Overview never opens again".
  const quitting = { ...hidden, shutdownRequested: true };
  assert.equal(replyOf('openOverview', quitting), 'shutdown');
  assert.equal(replyOf('toggle', quitting), 'shutdown');
  assert.equal(replyOf('status', quitting), 'ok');
  assert.equal(L.shutdownReady({ shutdownRequested: true, busy: true, preparing: false, activating: false,
    saving: false }), 'wait');
  assert.equal(L.shutdownReady({ shutdownRequested: true, busy: true, preparing: false, activating: false,
    saving: false, expired: true }), 'quit');
  // The launcher reads a refusal as "not accepted" and retries the toggle instead
  // of reporting a silent no-op as success (F-45).
  assert.notEqual(replyOf('toggle', quitting), 'ok');
  assert.notEqual(replyOf('toggle', { ...open, closing: true }), 'ok');
});
