// Packing and rendering must use the same ratio. IPC sizes can lag captures
// after a resize/monitor change; prefer actual native frame dimensions.
function aspectFor(window, capture) {
  const source = capture && capture.sourceSize;
  const ipc = window && window.lastIpcObject;
  if (source && source.width > 0 && source.height > 0 && isFinite(source.width / source.height))
    return source.width / source.height;
  const size = ipc && ipc.size || [];
  const ratio = size[0] / size[1];
  // Placeholder cards need usable hit areas and readable titles, not slivers
  // from transient/off-screen IPC geometry. Native images keep their ratio.
  if (size[0] > 0 && size[1] > 0 && isFinite(ratio)) return Math.max(.7, Math.min(2.4, ratio));
  return 1.6;
}

// Start the spread from the window's desktop rectangle when it belongs to this
// display. Other displays / fully off-screen windows fade in at their grid slot.
// Hyprland reports logical coordinates, so fractional scale and output rotation
// need no conversion here. Every argument is optional on purpose: a throw inside
// this binding would take the whole open animation with it, and shell.qml:223
// passes placements[i], which is undefined whenever arrange() refuses.
function animationOrigin(window, output, offset, fallback) {
  const ipc = window && window.lastIpcObject || {}, at = ipc.at || [], size = ipc.size || [];
  const shift = offset || {};
  if (!output || ipc.monitor !== output.id || at.length !== 2 || size.length !== 2 ||
      ![at[0], at[1], size[0], size[1]].every(Number.isFinite) || Math.min(size[0], size[1]) <= 0 ||
      at[0] + size[0] <= output.x || at[0] >= output.x + output.width ||
      at[1] + size[1] <= output.y || at[1] >= output.y + output.height) return fallback;
  return { x: at[0] - output.x - (shift.x || 0), y: at[1] - output.y - (shift.y || 0),
    width: size[0], height: size[1] };
}

// Qt-independent geometry for a compact, aspect-preserving window overview.
function arrange(aspects, width, height, compact) {
  // A model that has not arrived yet must refuse, not throw: callers pass
  // JSON.parse(layoutKey) (shell.qml:104) and members.map(...) (DesktopPreview.qml:19).
  if (!aspects || !aspects.length || !aspects.map ||
      !isFinite(width) || !isFinite(height) || width <= 0 || height <= 0) return [];
  // Clamping valid portrait/ultrawide ratios would leave empty space in the cells,
  // so the packing bounds sit far outside anything a real window reports and only
  // catch pathological geometry: all cards share one scale, so a single 64:1 strip
  // used to shrink every other card (477x298 -> 38x24), and a garbage ratio erased
  // the grid entirely. Beyond the bounds the cell is packed at the bound while
  // WindowPreview.qml:24-25 keeps fitting the true image inside it - letterboxed,
  // never distorted.
  const ratios = aspects.map(a => Number(a) > 0 && isFinite(Number(a))
    ? Math.min(20, Math.max(.005, Number(a))) : 1.6);
  const gap = Math.min(compact ? 6 : 44, width / 20, height / 20);
  const labelSpace = compact ? 0 : 34;
  // Cards below this cannot be seen or hit, and a stage shorter than the label
  // space used to pack a literal 1-pixel card. Unlabelled strip tiles stay useful
  // much smaller, so they refuse far later. [] is the single refusal answer: never
  // a sliver, never an off-stage or overlapping card. The count that trips it
  // depends on the ratios and the stage, so it is not a constant: measured with
  // uniform 1.6 ratios, the 132x68 compact strip packs 1..117 and refuses from
  // 118, and a 1504x730 labelled stage packs 1..279 and refuses from 280.
  const minCell = compact ? 4 : 8;
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
  if (!best || best.h < minCell) return [];
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
  if (!rects || !rects.length) return 0;
  // A selection from outside the grid (stale index, refused layout) must never be
  // handed back: the caller uses the result to index windows and placements.
  const from = index >= 0 && index < rects.length ? Math.floor(index) : 0;
  const current = rects[from];
  const cx = current.x + current.width / 2;
  const cy = current.y + current.height / 2;
  let best = from;
  let score = Infinity;
  rects.forEach((r, i) => {
    if (i === from) return;
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

if (typeof module !== "undefined") module.exports = { aspectFor, animationOrigin, arrange, neighbor };
