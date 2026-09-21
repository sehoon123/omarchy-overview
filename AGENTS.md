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
