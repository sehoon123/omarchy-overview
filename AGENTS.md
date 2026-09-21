# Scope boundary (explicit user instruction, 2026-09-21)

- Change only omarchy-overview: this repository and its installed application
  files under ~/.config/omarchy/overview. Restart only its own service if needed.
- Do NOT modify, rebuild, replace or install Hyprland, Quickshell, other packages,
  compositor plugins, system services, Hyprland configuration or other Omarchy
  plugins. Do not reinstall the withdrawn compositor patch from Git history.
- The supported compositor is the official distribution package. Installed and
  running versions are distinct; never restart/logout the user's desktop.
- Do not use native window/toplevel capture on affected Hyprland. Output-only
  screenshots are the preview fallback; no automatic focus, workspace switching,
  viewport scrolling or output reconfiguration to obtain previews.
- Existing explicit user actions (select/move/reorder windows and desktops) are
  allowed; preview generation itself must be read-only.
- Preview images stay in memory, not files, logs, screenshots committed to Git,
  clipboard or external services. Respect lock, visibility and capture errors.
- Preserve personal settings/state and unrelated changes. Tests must use mocks
  or synthetic images. Any visible smoke check must be bounded and restore only
  the Overview's own UI without moving/closing user windows.
- Validate, describe snapshot limitations honestly, and commit/push only reviewed
  project changes. Never infer that offline tests prove physical hotplug safety.
