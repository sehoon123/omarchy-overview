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
test('selection is address-stable across reorder and removal', () => {
  assert.equal(L.selectionIndex([...windows].reverse(), 'a', 0), 1);
  assert.equal(L.selectionIndex(windows.slice(0, 1), 'b', 1), 0);
  assert.equal(L.selectionIndex([], 'a', 5), 0);
});
test('live budget deduplicates and always prioritizes preview/drag/selection', () => {
  assert.deepEqual(L.liveAddresses(windows, ['b', 'b', '', 'a'], 1), ['b']);
  assert.deepEqual(L.liveAddresses(windows, ['drag', 'b'], 6), ['drag', 'b', 'a']);
  assert.deepEqual(L.liveAddresses([], ['a', '', 'a'], 6), ['a']);
});
test('settings validate types, ranges and stream caps without coercion', () => {
  const result = L.settings({ keepCache: 'false', dim: 999, liveLimit: 1000 });
  assert.equal(result.keepCache, true);
  assert.equal(result.dim, 80);
  assert.equal(result.liveLimit, 6);
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
