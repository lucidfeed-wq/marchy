-- hammerspoon://omarchy?a=<action>&x=<url-encoded argument>
--
-- This is how Karabiner's shell_command rules (Super+Ctrl/Alt layers, and
-- every binding while Citrix Viewer is frontmost) and OmniShell bar widgets
-- reach Hammerspoon, without the `hs` command-line tool:
--   /usr/bin/open -g "hammerspoon://omarchy?a=menu"
--   /usr/bin/open -g "hammerspoon://omarchy?a=tui&x=btop"
-- Encode spaces in x as %20 (a literal "+" stays a "+").
--
-- Any local app (or a web page the user lets open the link) can send these
-- URLs, so `tui` (which runs a shell command) only accepts commands that
-- appear in the generated bindings or the small built-in list in core.lua.
local M = {}

local log = require("omarchy.log")
local toast = require("omarchy.toast")

function M.handle(params)
  params = params or {}
  local a = params.a or params.action
  local x = params.x
  if not a or a == "" then
    log.w("url: missing a=")
    return toast.warn("Omarchy URL without an action")
  end
  local core = require("omarchy.core")
  if a == "tui" and not core.tuiAllowed(x) then
    log.w("url: blocked tui command not in bindings: %s", tostring(x):sub(1, 120))
    return toast.warn("Blocked: that command is not in bindings.toml")
  end
  log.i("url: %s%s", a, x and (" " .. tostring(x):sub(1, 120)) or "")
  require("omarchy.actions").run(a, x)
end

function M.start()
  hs.urlevent.bind("omarchy", function(_, params)
    local ok, err = pcall(M.handle, params)
    if not ok then log.e("url: handler failed: %s", tostring(err)) end
  end)
  log.i("url: hammerspoon://omarchy bound")
end

return M
