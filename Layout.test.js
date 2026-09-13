const assert = require('node:assert/strict');
const { arrange, neighbor } = require('./Layout.js');

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
console.log('Layout tests passed (160 screen/window-count combinations).');
