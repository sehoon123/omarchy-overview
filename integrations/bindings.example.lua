-- Optional bindings for Omarchy's Lua-based Hyprland configuration.
-- Copy only the bindings you want into ~/.config/hypr/bindings.lua.
-- Check existing bindings first; explicitly hl.unbind a conflicting shortcut
-- before replacing it. Do not replace your entire bindings file.
--
-- The launcher accepts: no argument (toggle), --app, --next, --previous and
-- --shutdown. Do NOT bind --shutdown: it is the user service's ExecStop.

-- Physical backtick key above Tab on the tested keyboard. Omarchy 4.5 binds the
-- same key (as SUPER + grave) to its Quake console; without the unbind both run.
hl.unbind("SUPER + grave")
o.bind("SUPER + code:49", "Toggle window overview", "omarchy-overview")
-- CTRL + UP/DOWN mirror macOS Mission Control. Omarchy 4.5 binds neither, but
-- check `hyprctl binds` for your own bindings on them first.
o.bind("CTRL + UP", "Mission Control", "omarchy-overview")
o.bind("CTRL + DOWN", "App Expose", "omarchy-overview --app")

-- Optional: these override application-level Ctrl+Left/Right word navigation.
-- With Overview open they move its desktop filter only; with Overview closed or
-- not running they switch the compositor's workspace.
-- o.bind("CTRL + LEFT", "Previous desktop", "omarchy-overview --previous")
-- o.bind("CTRL + RIGHT", "Next desktop", "omarchy-overview --next")
