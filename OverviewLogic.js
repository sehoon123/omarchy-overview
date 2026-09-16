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
  return priority.concat(windows.map(w => w.address)).filter((a, i, list) => a && list.indexOf(a) === i).slice(0, limit);
}
function defaults() {
  return { followTheme: true, blur: true, dim: 40, motion: true,
    liveLimit: 6, keepCache: true, monitorOnly: false };
}
function setting(name, value) {
  const base = defaults();
  if (!Object.prototype.hasOwnProperty.call(base, name)) return undefined;
  if (typeof base[name] === "boolean") return typeof value === "boolean" ? value : undefined;
  if (typeof value !== "number" || !isFinite(value)) return undefined;
  if (name === "liveLimit") return [1, 6, 12].indexOf(value) >= 0 ? value : undefined;
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
if (typeof module !== "undefined") module.exports = { normalize, workspaceKey, workspaceKeys, matches, selectionIndex, revealOffset, liveAddresses, defaults, setting, settings, palette };
