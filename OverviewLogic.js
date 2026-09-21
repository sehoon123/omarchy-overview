// Pure, shared UI policy. No shell commands and no regular-expression queries.
function normalize(text) {
  text = String(text || "");
  return (typeof text.normalize === "function" ? text.normalize("NFKC") : text).toLowerCase();
}
function workspaceKey(workspace) {
  if (!workspace) return 0;
  const name = String(workspace.name || "");
  if (name === "special" || name.startsWith("special:") || workspace.special) return 0;
  if (workspace.id > 0 && (!name || name === String(workspace.id))) return workspace.id;
  return name ? "name:" + name : 0;
}
function workspaceKeys(order, live, info, monitor, perMonitor) {
  const keys = [...new Set(order.concat(live.map(workspaceKey).filter(Boolean)))];
  return keys.filter(key => {
    if (!perMonitor) return true;
    const workspace = live.find(w => workspaceKey(w) === key);
    const owner = workspace && workspace.monitor ? workspace.monitor.name : (info[String(key)] || {}).monitor;
    return owner === monitor;
  });
}
function matches(window, query) {
  if (!String(query || "").trim()) return true;
  const ipc = window.lastIpcObject || {};
  const haystack = normalize([window.title, ipc.class, ipc.initialClass,
    window.workspace ? "Desktop " + (window.workspace.name || window.workspace.id) + " Desktop " + String(window.workspace.name || window.workspace.id).split(":").pop() : ""].join(" "));
  return normalize(query).trim().split(/\s+/).every(word => haystack.indexOf(word) >= 0);
}
function focusedWindow(active, windows) {
  // Hyprland's activeToplevel can be empty until its first focus event.
  return active || windows.find(w => w.wayland && w.wayland.activated) || null;
}
function spatialCompare(a, b) {
  const workspace = a.workspace.id - b.workspace.id;
  if (workspace) return workspace;
  const aa = (a.lastIpcObject || {}).at || [], ba = (b.lastIpcObject || {}).at || [];
  return (aa[1] || 0) - (ba[1] || 0) || (aa[0] || 0) - (ba[0] || 0) || String(a.address).localeCompare(String(b.address));
}
function selectionIndex(windows, address, fallback) {
  const found = windows.findIndex(w => w.address === address);
  return found >= 0 ? found : Math.max(0, Math.min(fallback, windows.length - 1));
}
function revealOffset(offset, viewportWidth, contentWidth, start, itemWidth, margin) {
  if (viewportWidth <= 0) return 0;
  const left = Math.max(0, start - margin), right = Math.min(contentWidth, start + itemWidth + margin);
  if (right - left > viewportWidth || left < offset) offset = left;
  else if (right > offset + viewportWidth) offset = right - viewportWidth;
  return Math.max(0, Math.min(Math.max(0, contentWidth - viewportWidth), offset));
}
function liveAddresses(windows, priority, limit) {
  const ordered = priority.concat(windows.map(w => w.address)).filter((a, i, list) => a && list.indexOf(a) === i);
  return limit > 0 ? ordered.slice(0, limit) : ordered;
}
// Qt creates an unnamed placeholder when the last Wayland output disappears.
// Neither it nor Hyprland's emergency fallback is a safe preview destination.
function previewScreens(screens) {
  return screens.filter(s => s && s.name && s.width > 0 && s.height > 0 &&
    !/^(HEADLESS-|FALLBACK)/.test(s.name));
}
function captureReason(window, screens) {
  if (!window || !window.wayland || !workspaceKey(window.workspace)) return 'Waiting for window metadata';
  const ipc = window.lastIpcObject || {}, monitor = window.monitor;
  // The window's monitor, not its workspace's remembered monitor, owns capture.
  if (ipc.mapped !== true || ipc.hidden || !monitor || ipc.monitor !== monitor.id)
    return 'Window is not captureable';
  const output = previewScreens(screens).find(s => s.name === monitor.name && s.id === monitor.id);
  if (!output) return 'Display is unavailable';
  const at = ipc.at || [], size = ipc.size || [];
  if (at.length !== 2 || size.length !== 2 || !at.concat(size).every(Number.isFinite) || Math.min(...size) <= 0)
    return 'Waiting for window geometry';
  const scale = output.scale || 1;
  if (size[0] * size[1] * scale * scale > 16000000) return 'Window exceeds preview memory budget';
  // Hyprland 0.56.2 does not deliver fully off-viewport window frames. Do not
  // allocate an indefinitely pending stream, crop the screen, or move a window.
  if (at[0] + size[0] <= output.x || at[1] + size[1] <= output.y ||
      at[0] >= output.x + output.width || at[1] >= output.y + output.height)
    return 'Off-screen preview unavailable';
  return '';
}
function canCapture(shown, settled, window, screens) {
  return !!shown && !!settled && captureReason(window, screens) === '';
}
function capturePlan(windows, priority, screens, maxViews = 32, maxPixels = 64000000) {
  if (maxViews <= 0 || maxPixels <= 0) return [];
  const result = [], byAddress = new Map(windows.map(w => [w.address, w]));
  let pixels = 0;
  for (const address of liveAddresses(windows, priority, 0)) {
    const window = byAddress.get(address);
    if (captureReason(window, screens)) continue;
    const output = screens.find(s => s.name === window.monitor.name);
    const size = window.lastIpcObject.size, scale = output.scale || 1;
    const area = Math.ceil(size[0] * scale) * Math.ceil(size[1] * scale);
    if (pixels + area > maxPixels) continue;
    result.push(address); pixels += area;
    if (result.length >= maxViews) break;
  }
  return result;
}
function defaults() {
  return { followTheme: true, blur: true, dim: 40, motion: true,
    liveLimit: 0, keepCache: true, monitorOnly: false };
}
function setting(name, value) {
  const base = defaults();
  if (!Object.prototype.hasOwnProperty.call(base, name)) return undefined;
  if (typeof base[name] === "boolean") return typeof value === "boolean" ? value : undefined;
  if (typeof value !== "number" || !isFinite(value)) return undefined;
  if (name === "liveLimit") return [0, 1, 6, 12].indexOf(value) >= 0 ? value : undefined;
  return Math.max(0, Math.min(80, Math.round(value)));
}
function settings(document) {
  const result = defaults();
  Object.keys(result).forEach(key => {
    const value = setting(key, document[key]);
    if (value !== undefined) result[key] = value;
  });
  return result;
}
// Only the three public scalar palette tokens we need, not a general TOML parser.
// Section-scoped keys, expressions, URLs and malformed values are never evaluated.
function palette(text) {
  const colors = { accent: "#76b5ff", background: "#202633", foreground: "#ecf0f7" };
  const lines = String(text).split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*\[/.test(lines[i])) break;
    const match = /^\s*(accent|background|foreground)\s*=\s*["'](#[0-9a-fA-F]{6})["']\s*(?:#.*)?$/.exec(lines[i]);
    if (match) colors[match[1]] = match[2];
  }
  return colors;
}
if (typeof module !== "undefined") module.exports = { normalize, workspaceKey, workspaceKeys, matches, focusedWindow, spatialCompare, selectionIndex, revealOffset, liveAddresses, previewScreens, captureReason, canCapture, capturePlan, defaults, setting, settings, palette };
