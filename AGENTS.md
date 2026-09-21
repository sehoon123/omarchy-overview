# Scope boundary (explicit user instruction, 2026-09-21)

- Change only omarchy-overview: this repository and its installed application
  files under ~/.config/omarchy/overview. Restart only its own service if needed.
- Do NOT modify, rebuild, replace or install Hyprland, Quickshell, other packages,
  compositor plugins, system services, Hyprland configuration or other Omarchy
  plugins. Do not reinstall the withdrawn compositor patch from Git history.
- The supported compositor is the official distribution package. Installed and
  running versions are distinct; never restart/logout the user's desktop.
- The user rejected output snapshots and requested Mac-like Exposé behavior;
  omarchy-expose is a reference, not the product specification. Use real window
  previews, stable cards, correct proportions, and direct selection/return.
- Native capture belongs only to a visible Overview session with validated
  window/monitor state. Release sources AND objects on close/topology changes;
  never keep background capture, retry loops, or cross-session image caches.
- Client lifecycle guards do not fix Hyprland 0.56.2's monitor-lifetime defect.
  Do not reproduce it or claim hotplug safety. Fully off-viewport native frames
  are compositor-limited; do not hide this with screen crops or fake thumbnails.
- No automatic focus, workspace switching, viewport scrolling or output
  reconfiguration to obtain previews. Those require a separate user decision.
- Existing explicit user actions (select/move/reorder windows and desktops) are
  allowed; preview generation itself must be read-only.
- Preview images stay in memory, not files, logs, screenshots committed to Git,
  clipboard or external services. Respect lock, visibility and capture errors.
- Preserve personal settings/state and unrelated changes. Tests must use mocks
  or synthetic images. Any visible smoke check must be bounded and restore only
  the Overview's own UI without moving/closing user windows.
- Validate, describe snapshot limitations honestly, and commit/push only reviewed
  project changes. Never infer that offline tests prove physical hotplug safety.

## Clarifications (additive; no rule above is relaxed)

- During a hardening or review pass the rules above are further narrowed, not
  widened: work only inside this repository's working tree. Do not write to the
  deployed copy under ~/.config/omarchy/overview, do not start/stop/restart any
  service, and leave Git writes (add, commit, push, checkout, stash, reset) to
  whoever reviews the change. Reading the deployed copy is fine.
- Never run tests/verify_*.py, the omarchy-overview launcher, worker.py, or
  controller.py with an action argument as part of routine work: each one either
  stages a visible UI or performs a real desktop change. `./validate` is the
  routine check and is fully offline.
- hyprctl is read-only here: `-j monitors|clients|layers|workspaces|version` only.
  No dispatch, keyword, reload or eval. Overview's own openOverview/toggle/close
  IPC calls change visible state, so they are not probes; `status` is.
- Do not reintroduce anything RESEARCH.md marks as removed: output snapshots or
  screen crops, covered-viewport scrolling/priming, background capture outside a
  visible session, cross-session frame caches, double-buffered frames, the
  resident-worker `prime` protocol, or the withdrawn compositor patch.
- Do not rename keys in the IPC `status` payload or in settings.json, even the
  historical ones (`primed`, `cachedFrames`, `keepCache`): the opt-in checks and
  existing installations read them.
- Settings open from the **Settings** button in the window grid or the
  `showSettings` IPC call. There is no settings keyboard shortcut, and there is no
  drag target that removes a desktop; describe only the bindings that exist.
