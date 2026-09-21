const assert = require('node:assert/strict');
const { aspectFor, animationOrigin, arrange, neighbor } = require('./Layout.js');

for (const [width, height] of [[2304, 1114], [1260, 680], [740, 1100], [132, 68]]) {
  for (let count = 1; count <= 40; count++) {
    const ratios = Array.from({ length: count }, (_, i) => [0.9, 1.8, 0.6, 2.4][i % 4]);
    const rects = arrange(ratios, width, height, width === 132);
    assert.equal(rects.length, count);
    rects.forEach((r, i) => {
      assert(r.width > 0 && r.height > 0);
      assert(r.x >= -1e-7 && r.y >= -1e-7);
      assert(r.x + r.width <= width + 1e-7);
      assert(r.y + r.height <= height + 1e-7);
      assert(Math.abs(r.width / r.height - ratios[i]) < 1e-7);
      for (const other of rects.slice(i + 1)) {
        assert(r.x + r.width <= other.x + 1e-7 || other.x + other.width <= r.x + 1e-7 ||
          r.y + r.height <= other.y + 1e-7 || other.y + other.height <= r.y + 1e-7);
      }
      for (const direction of ['left', 'right', 'up', 'down']) {
        const next = neighbor(rects, i, direction);
        assert(next >= 0 && next < count);
      }
    });
  }
}
assert.deepEqual(arrange([], 100, 100), []);
assert.deepEqual(arrange([1], 0, 100), []);
const rects = arrange([1, 1], 1000, 400);
assert.equal(neighbor(rects, 0, 'right'), 1);
assert.equal(neighbor(rects, 1, 'left'), 0);
// Captures can arrive late or disagree with Hyprland's stale IPC dimensions.
const window = { lastIpcObject: { size: [1600, 1000] } };
assert.equal(aspectFor(window, null), 1.6);
assert.equal(aspectFor(window, { sourceSize: { width: 800, height: 1000 } }), .8);
assert.equal(aspectFor(window, { sourceSize: { width: 0, height: 1000 } }), 1.6);
assert.equal(aspectFor(window, { sourceSize: { width: Infinity, height: 1000 } }), 1.6);
assert.equal(aspectFor({}, null), 1.6);
assert.equal(aspectFor({ lastIpcObject: { size: [-100, 100] } }, null), 1.6);
// Missing images must not turn window cards into unreadable thin strips.
assert.equal(aspectFor({ lastIpcObject: { size: [20, 1000] } }, null), .7);
assert.equal(aspectFor({ lastIpcObject: { size: [8000, 100] } }, null), 2.4);
// Actual captured content is still aspect-preserving, including portrait crops.
assert.equal(aspectFor(window, { sourceSize: { width: 100, height: 1000 } }), .1);
assert.deepEqual(arrange([1], NaN, 100), []);
for (const compact of [false, true]) {
  for (const ratios of [[.8, .95, 1.1], [.1, 1, 8], [.005, .8, 20]]) {
    const width = compact ? 132 : 2304, height = compact ? 68 : 900;
    const gap = Math.min(compact ? 6 : 44, width / 20, height / 20);
    const fitted = arrange(ratios, width, height, compact);
    assert.equal(fitted.length, ratios.length);
    fitted.forEach((r, i) => assert(Math.abs(r.width / r.height - ratios[i]) < 1e-9));
    for (const row of new Set(fitted.map(r => r.row))) {
      const group = fitted.filter(r => r.row === row);
      const last = group[group.length - 1];
      assert(Math.abs(group[0].x - (width - last.x - last.width)) < 1e-9, 'Row must be centered');
      for (let i = 1; i < group.length; i++) {
        assert.equal(group[i].y, group[0].y);
        assert(Math.abs(group[i].x - group[i - 1].x - group[i - 1].width - gap) < 1e-9, 'Visible gaps must match');
      }
    }
  }
}
const output = { id: 0, x: -1600, y: 200, width: 1600, height: 1000 };
const fallback = { x: 100, y: 50, width: 400, height: 300 };
const native = { lastIpcObject: { monitor: 0, at: [-1500, 300], size: [800, 600] } };
assert.deepEqual(animationOrigin(native, output, { x: 40, y: 180 }, fallback), { x: 60, y: -80, width: 800, height: 600 });
assert.equal(animationOrigin(native, { ...output, id: 2 }, { x: 0, y: 0 }, fallback), fallback);
assert.equal(animationOrigin({ lastIpcObject: { monitor: 0, at: [-3000, 300], size: [800, 600] } }, output, { x: 0, y: 0 }, fallback), fallback);
assert.equal(animationOrigin({}, output, { x: 0, y: 0 }, fallback), fallback);
// ---------------------------------------------------------------------------
// Frozen shape, degenerate stages and extreme inputs (AUDIT A.5: F-56, F-57).
// ---------------------------------------------------------------------------
// arrange() may only answer with aspects.length cells or with []: shell.qml:104
// feeds placements to the window repeater, shell.qml:223 pairs placements[i] with
// windows[i], and DesktopPreview.qml:18-19 indexes miniLayout[index]. Any third
// shape (short array, holes, zero-size cards) silently mis-pairs windows.
const PACK_MIN = .005, PACK_MAX = 20; // packing-only ratio bounds
const FLOOR_LABELLED = 8, FLOOR_COMPACT = 4; // below this arrange() refuses
function packRatio(aspect) {
  const ratio = Number(aspect);
  return ratio > 0 && isFinite(ratio) ? Math.min(PACK_MAX, Math.max(PACK_MIN, ratio)) : 1.6;
}
// Every case below goes through this so the contract is asserted everywhere.
function contract(aspects, stageWidth, stageHeight, compact, note) {
  const cells = arrange(aspects, stageWidth, stageHeight, compact);
  const expected = aspects && aspects.length || 0;
  assert(Array.isArray(cells), note + ': arrange must return an array');
  assert(cells.length === expected || cells.length === 0,
    note + ': length must be ' + expected + ' or 0, got ' + cells.length);
  const gap = Math.min(compact ? 6 : 44, stageWidth / 20, stageHeight / 20);
  const floor = compact ? FLOOR_COMPACT : FLOOR_LABELLED;
  cells.forEach((cell, i) => {
    assert([cell.x, cell.y, cell.width, cell.height, cell.row].every(Number.isFinite),
      note + ': every field must be finite');
    assert(Number.isInteger(cell.row) && cell.row >= 0, note + ': row must be a row index');
    assert(cell.width > 0 && cell.height >= floor - 1e-9,
      note + ': cell ' + cell.width + 'x' + cell.height + ' is below the usable minimum');
    assert(Math.abs(cell.height - cells[0].height) < 1e-9, note + ': all cards share one scale');
    assert(cell.x >= -1e-7 && cell.y >= -1e-7 && cell.x + cell.width <= stageWidth + 1e-7 &&
      cell.y + cell.height <= stageHeight + 1e-7, note + ': cell must stay on the stage');
    assert(Math.abs(cell.width / cell.height - packRatio(aspects[i])) < 1e-7,
      note + ': packed aspect must be preserved');
    for (const other of cells.slice(i + 1)) {
      assert(cell.x + cell.width <= other.x + 1e-7 || other.x + other.width <= cell.x + 1e-7 ||
        cell.y + cell.height <= other.y + 1e-7 || other.y + other.height <= cell.y + 1e-7,
        note + ': cells must not overlap');
    }
    for (const direction of ['left', 'right', 'up', 'down']) {
      const next = neighbor(cells, i, direction);
      assert(Number.isInteger(next) && next >= 0 && next < cells.length,
        note + ': neighbor must stay inside the grid');
    }
  });
  for (const row of new Set(cells.map(cell => cell.row))) {
    const group = cells.filter(cell => cell.row === row);
    const last = group[group.length - 1];
    assert(Math.abs(group[0].x - (stageWidth - last.x - last.width)) < 1e-7, note + ': rows must stay centered');
    for (let i = 1; i < group.length; i++) {
      assert.equal(group[i].y, group[0].y, note + ': a row shares one top edge');
      assert(Math.abs(group[i].x - group[i - 1].x - group[i - 1].width - gap) < 1e-7,
        note + ': visible gaps must match');
    }
  }
  return cells;
}
function sameCells(actual, expected, note) {
  assert.equal(actual.length, expected.length, note + ': cell count changed');
  actual.forEach((cell, i) => {
    for (const key of ['x', 'y', 'width', 'height', 'row']) {
      assert(Math.abs(cell[key] - expected[i][key]) < 1e-9,
        note + ': ' + key + ' of cell ' + i + ' moved (' + cell[key] + ' vs ' + expected[i][key] + ')');
    }
  });
}
const cycle = n => Array.from({ length: n }, (_, i) => [0.9, 1.8, 0.6, 2.4][i % 4]);

// Realistic stages must be bit-for-bit what they were before this pass.
sameCells(arrange([1.6, 1.6, 1.6], 1504, 730, false), [
  { x: 233.3499999999999, y: 0, width: 500.40000000000003, height: 312.75, row: 0 },
  { x: 770.25, y: 0, width: 500.40000000000003, height: 312.75, row: 0 },
  { x: 501.79999999999995, y: 383.25, width: 500.40000000000003, height: 312.75, row: 1 }],
  'three 16:10 windows on the live stage');
sameCells(arrange([.5, 3.5], 1504, 730, false), [
  { x: 0, y: 164.5625, width: 183.4375, height: 366.875, row: 0 },
  { x: 219.9375, y: 164.5625, width: 1284.0625, height: 366.875, row: 0 }],
  'portrait plus ultrawide stay unclamped');
sameCells(arrange([.9, 1.8, .6, 2.4], 132, 68, true), [
  { x: 20.695, y: 0, width: 29.069999999999997, height: 32.3, row: 0 },
  { x: 53.165, y: 0, width: 58.13999999999999, height: 32.3, row: 0 },
  { x: 15.850000000000001, y: 35.699999999999996, width: 19.38, height: 32.3, row: 1 },
  { x: 38.629999999999995, y: 35.699999999999996, width: 77.52, height: 32.3, row: 1 }],
  'strip thumbnails at the DesktopPreview size');
sameCells(arrange([1.6, 1.6, .8, 2.4, 1.2], 1260, 680, false), [
  { x: 18, y: 0, width: 462.40000000000003, height: 289, row: 0 },
  { x: 514.4000000000001, y: 0, width: 462.40000000000003, height: 289, row: 0 },
  { x: 1010.8000000000002, y: 0, width: 231.20000000000002, height: 289, row: 0 },
  { x: 92.80000000000007, y: 357, width: 693.6, height: 289, row: 1 },
  { x: 820.4000000000001, y: 357, width: 346.8, height: 289, row: 1 }],
  'five mixed windows on a smaller output');

// Degenerate stages keep exactly one refusal shape and never throw.
for (const [stageWidth, stageHeight] of [[0, 100], [100, 0], [-1, 100], [100, -1], [NaN, 100],
  [100, NaN], [Infinity, 100], [100, Infinity], [-Infinity, -Infinity], [0, 0], [1e-9, 1e-9]]) {
  assert.deepEqual(contract([1.6, .8], stageWidth, stageHeight, false, 'stage ' + stageWidth + 'x' + stageHeight), [],
    'stage ' + stageWidth + 'x' + stageHeight + ' must refuse');
  assert.deepEqual(contract([1.6, .8], stageWidth, stageHeight, true, 'compact stage'), []);
}
// A model that has not arrived yet must refuse, not throw: shell.qml:104 parses
// JSON and DesktopPreview.qml:19 maps members, both of which can be unset.
for (const missing of [[], null, undefined, 0, ''])
  assert.deepEqual(contract(missing, 1504, 730, false, 'aspects ' + JSON.stringify(missing) || 'none'), []);
// Label space (34 px) eating the stage used to answer with a 1.6x1 card at 35 px.
for (const stageHeight of [1, 20, 34, 35, 36, 41])
  assert.deepEqual(contract([1.6], 1504, stageHeight, false, 'label-bound stage h=' + stageHeight), [],
    'a ' + stageHeight + ' px stage must refuse instead of packing a sliver');
const shortestStage = contract([1.6], 1504, 42, false, 'shortest labelled stage that still fits');
assert.equal(shortestStage.length, 1);
assert(shortestStage[0].height >= FLOOR_LABELLED - 1e-9 && shortestStage[0].height < FLOOR_LABELLED + 1);
for (let stageHeight = 1; stageHeight <= 140; stageHeight++) {
  contract([1.6, 1.2], 1504, stageHeight, false, 'labelled sweep h=' + stageHeight);
  contract([1.6, 1.2, .8], 132, stageHeight, true, 'compact sweep h=' + stageHeight);
}
// Very many windows: the stage packs down to the floor and then refuses, with no
// intermediate shape. 288 cards still fit the live stage, 289 cannot.
for (const count of [1, 2, 7, 12, 40, 96, 97, 184, 185, 288, 289, 360, 420, 421, 1200])
  contract(cycle(count), 1504, 730, false, 'n=' + count + ' on the live stage');
assert.equal(arrange(cycle(288), 1504, 730, false).length, 288);
assert.deepEqual(arrange(cycle(289), 1504, 730, false), []);
assert.deepEqual(arrange(cycle(1200), 1504, 730, false), []);
// The unlabelled strip degrades much further before it refuses (128 members).
assert.equal(arrange(cycle(127), 132, 68, true).length, 127);
assert.deepEqual(arrange(cycle(128), 132, 68, true), []);

// F-56: one pathological ratio must not collapse every other card. Packing uses
// the bounded ratio; WindowPreview keeps the true ratio and letterboxes.
const threeNormal = contract([1.6, 1.6, 1.6], 1504, 730, false, 'three normal cards');
for (const pathological of [64, 200, 1e6, 1e12, Number.MAX_VALUE]) {
  const cells = contract([1.6, 1.6, 1.6, pathological], 1504, 730, false, 'pathological ' + pathological);
  assert.equal(cells.length, 4);
  for (const cell of cells.slice(0, 3)) {
    assert(cell.width >= 100 && cell.height >= 60, 'a ' + pathological + ':1 window must not shrink real cards to ' +
      cell.width.toFixed(1) + 'x' + cell.height.toFixed(1));
  }
  assert(cells[0].height > threeNormal[0].height / 5, 'the grid must not lose an order of magnitude of area');
  assert(Math.abs(cells[3].width / cells[3].height - PACK_MAX) < 1e-7, 'the odd card packs at the bound');
}
for (const sliver of [1e-6, 1e-12, Number.MIN_VALUE]) {
  const cells = contract([1.6, 1.6, 1.6, sliver], 1504, 730, false, 'sliver ' + sliver);
  assert(Math.abs(cells[3].width / cells[3].height - PACK_MIN) < 1e-7, 'the sliver packs at the bound');
  assert(cells[0].width >= 100 && cells[0].height >= 60);
}
// Ratios inside the bounds - including every valid portrait and ultrawide window
// and the extreme crops the suite already pinned - are still never clamped.
for (const ratio of [PACK_MIN, .1, .5, .7, 1, 1.6, 2.4, 3.5, 8, PACK_MAX]) {
  const cells = contract([ratio, 1.6, .9], 1504, 730, false, 'ratio ' + ratio + ' must pass through');
  assert(Math.abs(cells[0].width / cells[0].height - ratio) < 1e-9, 'ratio ' + ratio + ' must not be clamped');
}
// Garbage entries fall back to the 1.6 placeholder, as before.
for (const garbage of [0, -1, NaN, Infinity, -Infinity, null, undefined, 'wide', {}]) {
  const cells = contract([garbage, 1.6], 1504, 730, false, 'garbage aspect ' + String(garbage));
  assert(Math.abs(cells[0].width / cells[0].height - 1.6) < 1e-9);
}

// aspectFor: a missing or lagging capture, broken source sizes, and native ratios
// that stay unclamped because rendering must keep the real image ratio.
assert.equal(aspectFor(null, null), 1.6);
assert.equal(aspectFor(undefined, undefined), 1.6);
assert.equal(aspectFor({ lastIpcObject: null }, { sourceSize: null }), 1.6);
assert.equal(aspectFor({ lastIpcObject: {} }, {}), 1.6);
assert.equal(aspectFor({ lastIpcObject: { size: [1600] } }, null), 1.6);
// A string payload is indexed per character, so it lands on the clamp floor - a
// usable placeholder card either way, and never an exception.
assert.equal(aspectFor({ lastIpcObject: { size: '1600x1000' } }, null), .7);
assert.equal(aspectFor({ lastIpcObject: { size: [1600, 0] } }, null), 1.6);
assert.equal(aspectFor({ lastIpcObject: { size: [0, 0] } }, null), 1.6);
assert.equal(aspectFor({ lastIpcObject: { size: [NaN, 1000] } }, null), 1.6);
assert.equal(aspectFor({ lastIpcObject: { size: [Infinity, 1000] } }, null), 1.6);
assert.equal(aspectFor({ lastIpcObject: { size: [1600, -1000] } }, null), 1.6);
// A capture whose frame has not sized yet must not win over usable IPC geometry.
assert.equal(aspectFor({ lastIpcObject: { size: [1000, 500] } }, { sourceSize: { width: 1000, height: 0 } }), 2);
assert.equal(aspectFor({ lastIpcObject: { size: [800, 1000] } }, { sourceSize: { width: 0, height: 0 } }), .8);
assert.equal(aspectFor({ lastIpcObject: { size: [800, 1000] } }, { sourceSize: { width: NaN, height: 100 } }), .8);
assert.equal(aspectFor({ lastIpcObject: { size: [800, 1000] } }, { sourceSize: { width: -800, height: 100 } }), .8);
// The placeholder clamp is inclusive at both ends and only applies without a frame.
assert.equal(aspectFor({ lastIpcObject: { size: [700, 1000] } }, null), .7);
assert.equal(aspectFor({ lastIpcObject: { size: [2400, 1000] } }, null), 2.4);
assert.equal(aspectFor({ lastIpcObject: { size: [3840, 60] } }, null), 2.4);
assert.equal(aspectFor({ lastIpcObject: { size: [60, 3840] } }, null), .7);
// Native frames keep their true ratio; arrange() bounds it for packing instead.
assert.equal(aspectFor({}, { sourceSize: { width: 3840, height: 60 } }), 64);
assert.equal(aspectFor({}, { sourceSize: { width: 60, height: 3840 } }), 60 / 3840);

// animationOrigin: other outputs, off-viewport windows, broken IPC payloads and
// missing arguments must all degrade to the fallback without throwing.
const monitor = { id: 1, x: -1600, y: 200, width: 1600, height: 1000 };
const slot = { x: 10, y: 20, width: 300, height: 200 };
const onMonitor = at => ({ lastIpcObject: { monitor: 1, at: at, size: [800, 600] } });
assert.deepEqual(animationOrigin(onMonitor([-1500, 300]), monitor, { x: 0, y: 0 }, slot),
  { x: 100, y: 100, width: 800, height: 600 });
// Half-open viewport bounds: touching the edge from outside is off-screen.
assert.equal(animationOrigin(onMonitor([-2400, 300]), monitor, { x: 0, y: 0 }, slot), slot);
assert.deepEqual(animationOrigin(onMonitor([-2399, 300]), monitor, { x: 0, y: 0 }, slot),
  { x: -799, y: 100, width: 800, height: 600 });
assert.equal(animationOrigin(onMonitor([0, 300]), monitor, { x: 0, y: 0 }, slot), slot);
assert.deepEqual(animationOrigin(onMonitor([-1, 300]), monitor, { x: 0, y: 0 }, slot),
  { x: 1599, y: 100, width: 800, height: 600 });
assert.equal(animationOrigin(onMonitor([-1500, -400]), monitor, { x: 0, y: 0 }, slot), slot);
assert.deepEqual(animationOrigin(onMonitor([-1500, -399]), monitor, { x: 0, y: 0 }, slot),
  { x: 100, y: -599, width: 800, height: 600 });
assert.equal(animationOrigin(onMonitor([-1500, 1200]), monitor, { x: 0, y: 0 }, slot), slot);
assert.deepEqual(animationOrigin(onMonitor([-1500, 1199]), monitor, { x: 0, y: 0 }, slot),
  { x: 100, y: 999, width: 800, height: 600 });
// Other output, unset monitor, and a string id that does not match strictly.
for (const other of [{ monitor: 0, at: [-1500, 300], size: [800, 600] },
  { monitor: '1', at: [-1500, 300], size: [800, 600] },
  { monitor: null, at: [-1500, 300], size: [800, 600] },
  { at: [-1500, 300], size: [800, 600] }])
  assert.equal(animationOrigin({ lastIpcObject: other }, monitor, { x: 0, y: 0 }, slot), slot);
// Broken IPC payloads.
for (const broken of [{ monitor: 1, at: [NaN, 300], size: [800, 600] },
  { monitor: 1, at: [Infinity, 300], size: [800, 600] },
  { monitor: 1, at: [-1500, 300], size: [NaN, 600] },
  { monitor: 1, at: [-1500, 300], size: [800, Infinity] },
  { monitor: 1, at: [-1500, 300], size: [0, 600] },
  { monitor: 1, at: [-1500, 300], size: [800, -600] },
  { monitor: 1, at: [-1500], size: [800, 600] },
  { monitor: 1, at: [-1500, 300, 0], size: [800, 600] },
  { monitor: 1, at: '..', size: [800, 600] },
  { monitor: 1 }])
  assert.equal(animationOrigin({ lastIpcObject: broken }, monitor, { x: 0, y: 0 }, slot), slot,
    'broken IPC geometry must fall back: ' + JSON.stringify(broken));
// The payload is duck-typed, not required to be a literal Array: Quickshell hands
// over converted Hyprland values, and any pair of finite numbers is usable.
assert.deepEqual(animationOrigin({ lastIpcObject: { monitor: 1, at: [-1500, 300], size: { 0: 800, 1: 600, length: 2 } } },
  monitor, { x: 0, y: 0 }, slot), { x: 100, y: 100, width: 800, height: 600 });
// Missing output, window, fallback and offset must never throw.
assert.equal(animationOrigin(onMonitor([-1500, 300]), null, { x: 0, y: 0 }, slot), slot);
assert.equal(animationOrigin(null, monitor, { x: 0, y: 0 }, slot), slot);
assert.equal(animationOrigin(undefined, undefined, undefined, undefined), undefined);
assert.equal(animationOrigin({}, monitor, { x: 0, y: 0 }), undefined);
assert.deepEqual(animationOrigin(onMonitor([-1500, 300]), monitor, undefined, slot),
  { x: 100, y: 100, width: 800, height: 600 });
assert.deepEqual(animationOrigin(onMonitor([-1500, 300]), monitor, {}, slot),
  { x: 100, y: 100, width: 800, height: 600 });
// Fractional scale: hyprctl already reports logical coordinates, so a 2560x1600
// output at scale 1.6 needs no conversion here (live DP-2 geometry).
const scaled = { id: 0, x: 480, y: 1440, width: 1600, height: 1000 };
assert.deepEqual(animationOrigin({ lastIpcObject: { monitor: 0, at: [492, 1452], size: [1000, 600] } },
  scaled, { x: 12, y: 46 }, slot), { x: 0, y: -34, width: 1000, height: 600 });
// A rotated output is just a portrait rectangle at this layer.
const rotated = { id: 0, x: 0, y: 0, width: 1000, height: 1600 };
assert.deepEqual(animationOrigin({ lastIpcObject: { monitor: 0, at: [100, 1500], size: [800, 400] } },
  rotated, { x: 0, y: 0 }, slot), { x: 100, y: 1500, width: 800, height: 400 });
assert.equal(animationOrigin({ lastIpcObject: { monitor: 0, at: [100, 1600], size: [800, 400] } },
  rotated, { x: 0, y: 0 }, slot), slot);

// neighbor: a single card, exact ties, unknown directions and indices that are
// not in the grid at all must all answer with an index the caller can use.
const single = arrange([1.6], 1504, 730, false);
for (const direction of ['left', 'right', 'up', 'down'])
  assert.equal(neighbor(single, 0, direction), 0, 'a lone card has nowhere to go');
assert.equal(neighbor([], 0, 'left'), 0);
const grid = [{ x: 0, y: 0, width: 10, height: 10, row: 0 }, { x: 20, y: 0, width: 10, height: 10, row: 0 },
  { x: 0, y: 20, width: 10, height: 10, row: 1 }, { x: 20, y: 20, width: 10, height: 10, row: 1 }];
assert.equal(neighbor(grid, 0, 'right'), 1);
assert.equal(neighbor(grid, 0, 'down'), 2, 'the aligned candidate wins over the diagonal one');
assert.equal(neighbor(grid, 3, 'up'), 1);
assert.equal(neighbor(grid, 3, 'left'), 2);
// Two candidates at the same distance: the lower index wins, deterministically.
const tied = [{ x: 0, y: 0, width: 10, height: 10, row: 0 }, { x: 20, y: 0, width: 10, height: 10, row: 0 },
  { x: 20, y: 0, width: 10, height: 10, row: 0 }];
assert.equal(neighbor(tied, 0, 'right'), 1);
assert.equal(neighbor(tied, 0, 'right'), neighbor(tied, 0, 'right'));
for (const index of [4, 99, -1, NaN, undefined, null, 1.5, '1']) {
  for (const direction of ['left', 'right', 'up', 'down', 'sideways', undefined]) {
    const next = neighbor(grid, index, direction);
    assert(Number.isInteger(next) && next >= 0 && next < grid.length,
      'neighbor(' + String(index) + ', ' + String(direction) + ') left the grid: ' + String(next));
  }
}
// Non-finite geometry in the grid must not hand back a broken index either.
const brokenGrid = [{ x: 0, y: 0, width: 10, height: 10, row: 0 }, { x: NaN, y: 0, width: 10, height: 10, row: 0 }];
for (const direction of ['left', 'right', 'up', 'down'])
  assert.equal(neighbor(brokenGrid, 0, direction), 0);

console.log('Layout tests passed (160 screen/window-count combinations + capture/spacing/motion regressions');
console.log('  + frozen shape, degenerate stages, 1..1200 cards, ratio bounds, IPC and neighbor extremes).');
