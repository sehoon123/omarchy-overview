-- Optional bindings for Omarchy's Lua-based Hyprland configuration.
-- Copy only the bindings you want into ~/.config/hypr/bindings.lua.
-- Check existing bindings first; explicitly hl.unbind a conflicting shortcut
-- before replacing it. Do not replace your entire bindings file.

-- Physical backtick key above Tab on the tested keyboard.
o.bind("SUPER + code:49", "Toggle window overview", "omarchy-overview")
o.bind("CTRL + UP", "Mission Control", "omarchy-overview")
o.bind("CTRL + DOWN", "App Expose", "omarchy-overview --app")

-- Optional: these override application-level Ctrl+Left/Right word navigation.
-- o.bind("CTRL + LEFT", "Previous desktop", "omarchy-overview --previous")
-- o.bind("CTRL + RIGHT", "Next desktop", "omarchy-overview --next")
