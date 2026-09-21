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
// Quick Look keeps only the priority entries live; a closing session keeps none.
function liveSelection(state) {
  const scope = state.previewAddress || state.closing ? [] : state.windows || [];
  const priority = state.closing ? [] : (state.priority || []).slice(0, 3);
  const planned = state.planned || [];
  return liveAddresses(scope, priority, state.limit).filter(address => planned.indexOf(address) >= 0);
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
// Why a card has no image, in one of nine distinct sentences: captureReason()'s
// six refusals, or one of the three below. A stopped stream is the honest case
// (AUDIT.md F-11): the compositor ended that screencopy session, an automatic
// re-attempt is forbidden (AGENTS.md) and CaptureStream has no knob for one, and
// only an explicit new Overview session builds a fresh stream - so the card names
// the one thing that actually works instead of a dead end. Never returns ''.
function previewReason(state) {
  const s = state || {};
  if (s.refusal) return String(s.refusal);
  if (s.hasCapture) return s.failed ? 'Live preview stopped \u00b7 reopen Overview to retry' : 'Loading window preview\u2026';
  return !s.captureEnabled || s.planned ? 'Loading window preview\u2026' : 'Preview budget reached';
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
// The exit animation keeps the plan it started with (AUDIT.md F-13, second half).
// `capturePriority` changes during a close - closeOverview() cancels the drag,
// which nulls dragSource - and capturePlan() truncates that priority order under
// the pixel budget, so recomputing the plan mid-animation drops whichever
// addresses the reorder pushed past the budget and blanks those cards for the
// length of the animation, even though CaptureBank keeps the producer.
// Holding is not a promise to start anything: a held address whose window is gone
// is dropped (a window that closed during the animation is not resurrected), a
// window that appeared during the close is never added, and `allowNew`/
// `allowStart` stay false while closing, so nothing new is created either.
function capturePlanHold(state) {
  const s = state || {};
  if (!s.closing) return s.plan || [];
  const present = s.addresses || [];
  return (s.frozen || []).filter(address => present.indexOf(address) >= 0);
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
// Session lifecycle policy. The shell passes plain values in; nothing below
// reads Qt types, timers or the clock.
function openBlocked(state) {
  return state.shutdownRequested ? 'shutdown' : state.activating ? 'activating'
    : state.shown ? 'shown' : state.opening ? 'opening' : '';
}
function closeMode(state) {
  if (state.opening || state.shutdownRequested) return 'immediate';
  if (state.busy) return 'deferToBusy';
  if (state.closing) return 'ignore';
  return state.shown && state.motion ? 'animate' : 'immediate';
}
// 'flush' means the queued settings write is still in flight, so do not quit yet.
// `expired` is the shutdown watchdog's deadline: a latch may delay the quit,
// never cancel it, so `--shutdown` cannot outlive its wait (AUDIT.md F-03).
function shutdownReady(state) {
  if (!state.shutdownRequested) return 'wait';
  if (state.expired) return 'quit';
  if (state.busy || state.preparing || state.activating) return 'wait';
  return state.saving ? 'flush' : 'quit';
}
// Open-path policy. Topology churn, a panel-less present and a refused
// capture-context check each resolve to one explicit outcome, never to a
// silently dropped open (AUDIT.md F-01, F-02, F-05).
// A capture object may exist only for a mapped panel, a granted context and a
// settled topology, so a hidden or unsettled session owns none.
function captureEnabled(state) {
  return !!state.shown && !!state.framePresented && !!state.contextAllowed && !!state.topologyReady;
}
// The settle timer owns both the topology flag and the memory of a requested
// open: 'resume' restarts the paused open, 'retry' waits for a usable output
// list within a bounded budget, 'fail' reports why the open did not happen.
function settleOutcome(state) {
  const ready = (state.screens || 0) > 0;
  const limit = state.maxAttempts === undefined ? 3 : state.maxAttempts;
  const wanted = !!state.opening || !!state.resumeOpen;
  if (!wanted || state.shown || state.shutdownRequested)
    return { topologyReady: ready, attempts: 0, action: 'none', reason: '' };
  if (!ready) {
    const attempts = (state.attempts || 0) + 1;
    if (attempts < limit) return { topologyReady: false, attempts: attempts, action: 'retry', reason: '' };
    return { topologyReady: false, attempts: 0, action: 'fail', reason: 'noOutput' };
  }
  return { topologyReady: true, attempts: 0, action: state.opening ? 'context' : 'resume', reason: '' };
}
// A session must never become visible without a panel to map into, a granted
// capture context and a settled topology.
function presentBlocked(state) {
  if (!state.opening || state.shutdownRequested) return 'ignore';
  if (!((state.screens || 0) > 0)) return 'noOutput';
  if (!state.topologyReady) return 'noTopology';
  if (!state.contextAllowed) return 'noContext';
  return '';
}
// A refused check must name the real cause. Only a draining helper is worth
// waiting for (OpenRequest emits readyToBegin() exactly once); a run that
// already serves this open is simply left alone.
function contextRefusal(state) {
  const limit = state.maxAttempts === undefined ? 2 : state.maxAttempts;
  if (state.refusal === 'pending')
    return state.purpose === 'open' ? { action: 'wait', reason: '' } : { action: 'fail', reason: 'pending' };
  if (state.refusal === 'draining')
    return (state.attempts || 0) < limit ? { action: 'retry', reason: '' } : { action: 'fail', reason: 'draining' };
  if (state.refusal === 'output') return { action: 'fail', reason: 'output' };
  return { action: 'fail', reason: 'unknown' };
}
// The read-only recheck belongs to a mapped, visible session only: it must never
// start a run during an open, a close or a shutdown, so its verdict can never
// land on another session.
function recheckAllowed(state) {
  return !!state.panelVisible && !!state.shown && !state.opening && !state.closing &&
    !state.shutdownRequested && !!state.canBegin;
}
// A verdict may only drive the session that asked for it: an open verdict that
// arrives after its open ended, and a recheck verdict during an open or a close,
// are discarded instead of presenting or closing the wrong session.
function guardVerdict(state) {
  const live = state.purpose === 'open' ? !!state.opening
    : state.purpose === 'recheck' ? (!!state.shown && !state.opening) : false;
  if (!live || state.closing || state.shutdownRequested) return { action: 'ignore', reason: '' };
  if (!state.ok) return { action: 'fail', reason: state.reason || 'Capture context unavailable' };
  return { action: state.purpose === 'open' ? 'present' : 'allow', reason: '' };
}
// One message per refusal code, so no open fails with someone else's reason.
// Own keys only: an inherited name must never be read as a message.
function openFailure(code) {
  const messages = { noOutput: 'No usable display for the overview',
    noTopology: 'Display information is not ready yet',
    noContext: 'Capture context unavailable',
    output: 'No display selected for the overview',
    draining: 'Previous capture-context check is still stopping',
    pending: 'Capture context check is already running' };
  return Object.prototype.hasOwnProperty.call(messages, code) ? messages[code] : 'Overview could not open';
}
// Close, shutdown and activation policy (AUDIT.md F-03, F-04, F-07 and the
// refuted F-08). A requested shutdown always terminates, the window the user
// chose is focused exactly once, and a motion that lands late never tears down
// the session that replaced it.
// Each latch that makes finishShutdown() wait is named here, so the shell can
// re-arm on the one that clears and report the one that did not.
function shutdownBlocker(state) {
  if (!state.shutdownRequested) return '';
  if (state.busy) return 'busy';
  if (state.preparing) return 'preparing';
  if (state.activating) return 'activating';
  if (state.saving) return 'saving';
  return '';
}
// Explicit activation is a contract: only choose()'s pendingWindow reaches the
// activation timer, exactly once ('wait' while it is already armed). A monitor
// or config event is not a reason to forget it; a lock surface and a shutdown
// are, and both now carry a reason instead of discarding it silently.
function activationHandoff(state) {
  if (!state.pendingWindow) return { action: 'none', reason: '' };
  if (state.source === 'lock')
    return { action: 'discard', reason: 'Screen locked before Overview could focus that window' };
  if (state.shutdownRequested)
    return { action: 'discard', reason: 'Overview is shutting down; that window was not focused' };
  if (state.source === 'pause') return { action: 'keep', reason: '' };
  return { action: state.activating ? 'wait' : 'activate', reason: '' };
}
// A close belongs to one session: `session` is the openCount it was started
// for. A motion (or the watchdog that bounds `closing`) landing after that
// session ended must not tear down the shell that a newer open owns.
function closeVerdict(state) {
  if (!state.closing || state.session !== state.openCount) return { action: 'ignore', reason: '' };
  return { action: 'finish',
    reason: state.source === 'watchdog' ? 'Close animation did not finish; closing now' : '' };
}
// F-08 was refuted and downgraded: the desktop-state refresh defers while an
// action or an open is in flight, so it can never overwrite the actionName and
// closeWhenDone of a queued close or undo. Extracted so that stays checked.
function refreshAction(state) {
  if (!state.ready) return 'skip';
  return state.busy || state.preparing ? 'defer' : 'run';
}
// --- The IPC guard matrix (AUDIT.md F-44, F-45, F-46, F-47, F-50). One reply
// vocabulary for all ten handlers, so a caller can tell "accepted" ('ok') from
// "deliberately refused" (a named code) from "Overview is not running" (no reply
// at all, which only the absence of the process produces). 'unavailable' is the
// only code that invites the launcher's CLI fallback, because it is the only one
// that means "hidden and the worker could not take this step".
// `action` is what the shell may then do: 'open', 'close', 'filter', 'step',
// 'run', or 'refuse' — which must have no side effect at all.
function ipcGuard(request) {
  const call = String((request || {}).call || ''), state = (request || {}).state || {};
  const raw = (request || {}).arg;
  const arg = raw === undefined || raw === null ? '' : String(raw);
  // Deliberately unguarded: `--shutdown` polls status() as its liveness probe
  // until it fails, and captureReady() answers for a capture object, not for a
  // session state, so neither may refuse mid-transition.
  if (call === 'status' || call === 'captureReady') return { action: 'run', reply: 'ok' };
  // Arguments outside the documented set are refused instead of silently meaning
  // the default ('' for toggle, 'previous' for navigateDesktop).
  if (call === 'toggle' && arg !== '' && arg !== 'app') return { action: 'refuse', reply: 'invalid' };
  if (call === 'navigateDesktop' && arg !== 'next' && arg !== 'previous') return { action: 'refuse', reply: 'invalid' };
  // setQuery drives windows -> layoutKey -> Layout.arrange(): a multi-megabyte
  // string is refused, never packed.
  if (call === 'setQuery' && arg.length > 200) return { action: 'refuse', reply: 'invalid' };
  // A shutdown is always accepted and is idempotent: it re-arms the watchdog that
  // guarantees the quit.
  if (call === 'shutdown') return { action: 'run', reply: 'ok' };
  // That queued shutdown then outranks every other request. The watchdog bounds
  // it, so this refusal is a state with a deadline, not the F-44 latch.
  if (state.shutdownRequested) return { action: 'refuse', reply: 'shutdown' };
  // The close animation owns the session until finishClose() runs (bounded by the
  // close watchdog), and a close is already what it is doing.
  if (state.closing) return { action: 'refuse', reply: 'closing' };
  if (call === 'close') return { action: 'close', reply: 'ok' };
  if (call === 'openOverview' || (call === 'toggle' && !state.shown && !state.opening)) {
    const blocked = openBlocked({ shutdownRequested: state.shutdownRequested, activating: state.activating,
      shown: state.shown, opening: state.opening });
    return blocked ? { action: 'refuse', reply: blocked } : { action: 'open', reply: 'ok' };
  }
  // A toggle over a visible or opening session closes it; while `busy` the close
  // is queued (closeWhenDone), which is an acceptance, not a refusal.
  if (call === 'toggle') return { action: 'close', reply: 'ok' };
  if (call === 'setQuery') {
    if (!state.shown) return { action: 'refuse', reply: 'hidden' };
    if (state.busy) return { action: 'refuse', reply: 'busy' };
    if (state.settingsShown) return { action: 'refuse', reply: 'settings' };
    // A drag deliberately survives filtering (the ghost is not a card), so a
    // query during a drag stays allowed.
    return { action: 'run', reply: 'ok' };
  }
  if (call === 'togglePreview') {
    if (!state.shown) return { action: 'refuse', reply: 'hidden' };
    if (state.settingsShown) return { action: 'refuse', reply: 'settings' };
    // Dismissing Quick Look is the way back out, so it is never refused.
    if (state.previewAddress) return { action: 'run', reply: 'ok' };
    if (state.dragging) return { action: 'refuse', reply: 'dragging' };
    if (state.busy) return { action: 'refuse', reply: 'busy' };
    return state.hasSelection ? { action: 'run', reply: 'ok' } : { action: 'refuse', reply: 'empty' };
  }
  if (call === 'showSettings') {
    if (!state.shown) return { action: 'refuse', reply: 'hidden' };
    if (state.busy) return { action: 'refuse', reply: 'busy' };
    if (state.dragging) return { action: 'refuse', reply: 'dragging' };
    return { action: 'run', reply: 'ok' };
  }
  if (call === 'navigateDesktop') {
    // A visible session moves its own filter; the compositor's workspace is not
    // switched behind it, and a refusal here must never reach the CLI fallback.
    if (state.shown) {
      if (state.busy) return { action: 'refuse', reply: 'busy' };
      if (state.dragging) return { action: 'refuse', reply: 'dragging' };
      if (state.settingsShown) return { action: 'refuse', reply: 'settings' };
      return (state.desktops || 0) > 0 ? { action: 'filter', reply: 'ok' } : { action: 'refuse', reply: 'empty' };
    }
    // An open in flight is no longer aborted by a navigation request, and the
    // launcher must not switch a desktop under the session about to appear.
    if (state.opening) return { action: 'refuse', reply: 'opening' };
    // A chosen window is being focused: a workspace switch in that same instant
    // would fight the activation, from here or from the CLI.
    if (state.activating || state.pendingWindow) return { action: 'refuse', reply: 'activating' };
    // Hidden and unable: the one reply the launcher answers with a real
    // `controller.py step`, exactly as today's 'hidden' did.
    if (!state.ready || state.busy) return { action: 'refuse', reply: 'unavailable' };
    return { action: 'step', reply: 'ok' };
  }
  return { action: 'refuse', reply: 'invalid' };
}
// A refreshToplevels() turn that publishes an empty collection is a transient,
// not a decision: neither the selection nor Quick Look may follow it, or a window
// moving between desktops loses both (AUDIT.md F-17). Dismissal is an address
// lookup, never the filtered array's length.
function selectionAnchor(state) {
  const windows = state.windows || [], all = state.allWindows || [];
  if (!windows.length && !all.length)
    return { selected: state.selected || 0, selectedAddress: state.selectedAddress || '',
      dismissPreview: false, transient: true };
  const selected = selectionIndex(windows, state.selectedAddress, state.selected || 0);
  return { selected: selected, selectedAddress: windows[selected] ? windows[selected].address : '',
    dismissPreview: !!state.previewAddress && !windows.some(w => w.address === state.previewAddress),
    transient: false };
}
// Desktop keys are either a workspace id or "name:<name>"; the per-monitor plugin
// ends a name with the slot number, which is what survives a rename.
function desktopSlot(key) {
  if (typeof key === 'number') return isFinite(key) ? key : NaN;
  const match = /(?:^|:)(\d+)$/.exec(String(key === undefined || key === null ? '' : key));
  return match ? Number(match[1]) : NaN;
}
// `filterWorkspace` is a key, not an index, and a rename or removal can delete it
// while Overview is open, stranding the grid on a desktop that no longer exists
// (AUDIT.md F-55). Re-select the nearest surviving slot (a renamed desktop keeps
// its slot number; ties take the higher slot, the one that moved into its place),
// else the first surviving desktop, else "All". Never switches the compositor's
// active workspace.
function reselectDesktop(previous, workspaceIds) {
  const ids = workspaceIds || [];
  if (previous === 0 || ids.indexOf(previous) >= 0) return previous;
  if (!ids.length) return 0;
  const slot = desktopSlot(previous);
  let best = ids[0], distance = Infinity;
  if (isFinite(slot)) {
    for (let i = 0; i < ids.length; i++) {
      const candidate = desktopSlot(ids[i]);
      if (!isFinite(candidate)) continue;
      const gap = Math.abs(candidate - slot);
      if (gap < distance || (gap === distance && candidate > desktopSlot(best))) { best = ids[i]; distance = gap; }
    }
  }
  return best;
}
// The stage always says why it is empty. Layout.arrange() answers [] for a stage
// it cannot fill, which must read as a message and not as invisible zero-size
// cards; a stage with no size yet is not a refusal.
function stageMessage(state) {
  if (!(state.windows > 0))
    return state.query ? 'No windows match your search' : state.appFilter ? 'No windows for this app'
      : state.monitorOnly ? 'No windows on this desktop and monitor' : 'No open windows';
  return state.placements > 0 || !state.stageReady ? '' : 'Not enough room to show these windows';
}
// Native Wayland activation is preferred; a bare hex address is the fallback.
function activationTarget(window) {
  if (!window) return { mode: 'none' };
  if (window.wayland) return { mode: 'wayland' };
  const address = String(window.address || "");
  if (!/^(0x)?[0-9a-f]+$/i.test(address)) return { mode: 'none' };
  return { mode: 'dispatch', address: address.indexOf("0x") === 0 ? address : "0x" + address };
}
// Keyboard policy. The shell resolves Qt key codes to names and modifier masks
// to booleans, then dispatches { action, accept, sync } plus direction/step.
function keyIntent(input) {
  const mod = input.modifiers || {}, flags = input.flags || {};
  // Enter/Space/arrows first belong to the IME while composing a syllable.
  const ime = !!(input.editing && input.composing);
  if (input.key === 'escape')
    return { action: ime ? 'clearSearch' : flags.dragging ? 'cancelDrag' : flags.settingsShown ? 'closeSettings'
      : flags.previewAddress ? 'closePreview' : flags.query ? 'clearSearch' : 'closeOverview', accept: true, sync: false };
  if (flags.settingsShown) return { action: 'none', accept: false, sync: false };
  if (flags.busy || flags.dragging) return { action: 'none', accept: true, sync: false };
  if (ime) return { action: 'none', accept: false, sync: false };
  const typing = !!(input.editing && flags.query), act = action => ({ action: action, accept: true, sync: true });
  if (mod.ctrl && input.key === 'f') return act('focusSearch');
  if (input.key === 'space' && (mod.ctrl || !typing)) return act('togglePreview');
  if (mod.ctrl && input.key === 'z' && !typing) return act('undo');
  if (mod.ctrl && (input.key === 'left' || input.key === 'right'))
    return Object.assign(act('navigateDesktop'), { direction: input.key === 'right' ? 'next' : 'previous' });
  if (input.key === 'enter') return flags.windowCount || !flags.query ? act('choose') : { action: 'none', accept: true, sync: true };
  if (input.key === 'tab' || input.key === 'backtab')
    return Object.assign(act('cycleSelection'), { step: input.key === 'backtab' || mod.shift ? -1 : 1 });
  const direction = ({ left: 'left', right: 'right', up: 'up', down: 'down' })[input.key];
  if (!direction || (typing && (direction === 'left' || direction === 'right'))) return { action: 'none', accept: false, sync: false };
  return Object.assign(act('moveSelection'), { direction: direction });
}
// Strip hit targets are clipped with the scrollable viewport, close buttons included.
function zoneVisible(zone, clip) {
  return !(zone.x + zone.width < clip.x || zone.x > clip.x + clip.width);
}
function clipZone(zone, clip) {
  const right = Math.min(zone.x + zone.width, clip.x + clip.width), x = Math.max(zone.x, clip.x);
  return Object.assign({}, zone, { x: x, width: Math.max(0, right - x) });
}
function hitZone(zones, x, y) {
  return zones.find(z => x >= z.x && y >= z.y && x < z.x + z.width && y < z.y + z.height) ||
    { kind: "background", key: "background" };
}
// A Repeater delegate outlives its model entry for a turn: Hyprland.refreshToplevels()
// republishes the whole collection on every open and every movewindow, so a delegate
// can exist with a null `modelData` while the hit-test or the status scan walks it
// (AUDIT.md F-14). Its address is then unusable, and '' is the one value that must
// never match a window, so both callers skip that delegate instead of throwing.
function delegateAddress(item) {
  if (!item || !item.modelData) return '';
  const address = item.modelData.address;
  if (typeof address === 'number') return isFinite(address) ? String(address) : '';
  return typeof address === 'string' ? address : '';
}
// The published window hit zone is the letterboxed surface inside the card, and an
// extreme native ratio (a 1x1000 window, aspect .001) letterboxes that surface to a
// sub-pixel sliver: the card is plainly visible but practically unclickable, and it
// is also what a drop reports. Grow such a zone to a minimum hittable size around
// its own centre, hard-clipped inside the card rect it belongs to, so it can never
// exceed the card or reach a neighbour's packed cell. A zone that is already
// hittable - every normal card - is returned unchanged, as the identical object.
function hittableZone(zone, card, minimum = 24) {
  const box = card || zone;
  const width = Math.min(Math.max(zone.width, minimum), box.width);
  const height = Math.min(Math.max(zone.height, minimum), box.height);
  if (width === zone.width && height === zone.height) return zone;
  const clamp = (value, low, size) => Math.max(low, Math.min(value, low + size));
  return Object.assign({}, zone, { width: width, height: height,
    x: clamp(zone.x + (zone.width - width) / 2, box.x, box.width - width),
    y: clamp(zone.y + (zone.height - height) / 2, box.y, box.height - height) });
}
// IPC surface. Key names and their order are a compatibility contract; the
// caller supplies the reason so a card with content never recomputes it.
function statusCard(window, source, imageReady, reason) {
  return { address: window.address, thumbnail: !!source && source.hasContent, imageReady: imageReady,
    sourceId: source ? source.serial : 0, live: !!source && source.fresh, reason: reason,
    fresh: !!source && source.fresh, generation: source ? source.generation : 0,
    capturedAt: source ? source.capturedAt : 0 };
}
function statusPayload(state, cards) {
  return { visible: state.shown, busy: state.busy, desktop: state.desktop, appFilter: state.appFilter,
    order: state.order, perMonitor: state.perMonitor, monitor: state.monitor,
    desktopLabels: state.desktopLabels, windows: cards, dragging: state.dragging, message: state.message,
    query: state.query, selectedAddress: state.selectedAddress, previewAddress: state.previewAddress,
    previewSourceId: state.previewSource ? state.previewSource.serial : 0,
    settingsShown: state.settingsShown, settings: state.settings, settingsError: state.settingsError,
    liveAddresses: state.liveAddresses, delegateCount: state.delegateCount,
    cachedFrames: state.cachedFrames,
    windowCaptureEnabled: state.windowCaptureEnabled,
    captureTopologyReady: state.captureTopologyReady,
    captureViews: state.captureViews, captureBackend: "native-window", opening: state.opening,
    closing: state.closing, motionProgress: state.motionProgress,
    previewError: state.previewError,
    accent: state.accent, composing: state.composing, searchFocused: state.searchFocused,
    preparing: state.preparing, primed: [], openCount: state.openCount,
    firstFrameMs: state.firstFrameMs, workerPid: state.workerPid, workerRestarts: state.workerRestarts,
    completedRequests: state.completedRequests, lastActionMs: state.lastActionMs,
    layout: state.layout,
    zones: state.zones.map(z => ({ kind: z.kind, id: z.id, address: z.address, x: z.x, y: z.y, width: z.width, height: z.height })) };
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
if (typeof module !== "undefined") module.exports = { normalize, workspaceKey, workspaceKeys, matches, focusedWindow, spatialCompare, selectionIndex, revealOffset, liveAddresses, liveSelection, previewScreens, captureReason, canCapture, previewReason, capturePlan, capturePlanHold, defaults, setting, settings, openBlocked, closeMode, shutdownReady, captureEnabled, settleOutcome, presentBlocked, contextRefusal, recheckAllowed, guardVerdict, openFailure, shutdownBlocker, activationHandoff, closeVerdict, refreshAction, ipcGuard, selectionAnchor, desktopSlot, reselectDesktop, stageMessage, activationTarget, keyIntent, zoneVisible, clipZone, hitZone, delegateAddress, hittableZone, statusCard, statusPayload, palette };
