// Packing and rendering must use the same ratio. IPC sizes can lag captures
// after a resize/monitor change; retain the last frame's geometry while refreshing.
function aspectFor(window, capture) {
  const source = capture && capture.sourceSize;
  const ipc = window && window.lastIpcObject;
  if (source && source.width > 0 && source.height > 0 && isFinite(source.width / source.height))
    return source.width / source.height;
  const size = ipc && ipc.size || [];
  const ratio = size[0] / size[1];
  // Placeholder cards need usable hit areas and readable titles, not slivers
  // from transient/off-screen IPC geometry. Real snapshots keep their ratio.
  if (size[0] > 0 && size[1] > 0 && isFinite(ratio)) return Math.max(.7, Math.min(2.4, ratio));
  return 1.6;
}

// Qt-independent geometry for a compact, aspect-preserving window overview.
function arrange(aspects, width, height, compact) {
  if (!aspects.length || !isFinite(width) || !isFinite(height) || width <= 0 || height <= 0) return [];
  // Clamping valid portrait/ultrawide ratios would leave empty space in the cells.
  const ratios = aspects.map(a => Number(a) > 0 && isFinite(Number(a)) ? Number(a) : 1.6);
  const gap = Math.min(compact ? 6 : 44, width / 20, height / 20);
  const labelSpace = compact ? 0 : 34;
  let best = null;
  for (let rows = 1; rows <= ratios.length; rows++) {
    const available = (height - gap * (rows - 1)) / rows - labelSpace;
    if (available <= 0) break;
    let h = Math.min(available, height * 0.76, 640);
    const groups = [];
    let start = 0;
    for (let row = 0; row < rows; row++) {
      const count = Math.ceil((ratios.length - start) / (rows - row));
      const sum = ratios.slice(start, start + count).reduce((a, b) => a + b, 0);
      h = Math.min(h, (width - gap * (count - 1)) / sum);
      groups.push({ start: start, count: count, sum: sum });
      start += count;
    }
    if (h <= 0) continue;
    const score = h * h; // All windows share the scale; maximize visible area.
    if (!best || score > best.score) best = { score: score, h: h, groups: groups };
  }
  if (!best) return [];
  const totalHeight = best.groups.length * (best.h + labelSpace) + gap * (best.groups.length - 1);
  const result = [];
  best.groups.forEach((group, row) => {
    const rowWidth = group.sum * best.h + gap * (group.count - 1);
    let x = (width - rowWidth) / 2;
    const y = (height - totalHeight) / 2 + row * (best.h + labelSpace + gap);
    for (let j = 0; j < group.count; j++) {
      const w = ratios[group.start + j] * best.h;
      result.push({ x: x, y: y, width: w, height: best.h, row: row });
      x += w + gap;
    }
  });
  return result;
}

function neighbor(rects, index, direction) {
  if (!rects.length) return 0;
  const current = rects[index] || rects[0];
  const cx = current.x + current.width / 2;
  const cy = current.y + current.height / 2;
  let best = index;
  let score = Infinity;
  rects.forEach((r, i) => {
    if (i === index) return;
    const dx = r.x + r.width / 2 - cx;
    const dy = r.y + r.height / 2 - cy;
    const along = direction === "left" ? -dx : direction === "right" ? dx : direction === "up" ? -dy : dy;
    const across = direction === "left" || direction === "right" ? Math.abs(dy) : Math.abs(dx);
    if (along <= 1) return;
    const distance = along + across * 3;
    if (distance < score) { best = i; score = distance; }
  });
  return best;
}

if (typeof module !== "undefined") module.exports = { aspectFor, arrange, neighbor };
