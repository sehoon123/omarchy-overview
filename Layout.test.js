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
console.log('Layout tests passed (160 screen/window-count combinations + capture/spacing/motion regressions).');
