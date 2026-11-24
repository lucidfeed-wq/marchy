-- Omarchy on macOS (Hammerspoon side). Everything lives in omarchy/;
-- start with omarchy/core.lua. Logs: ~/.local/state/omarchy-mac/hs.log
require("hs.ipc")
hs.window.animationDuration = 0
omarchy = require("omarchy.core").start()
