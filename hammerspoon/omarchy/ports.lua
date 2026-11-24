-- omarchy.ports: loads Omarchy plugins converted by `omarchy-port` (~/.config/omarchy-mac/bin).
-- Every installed port is a module in ~/.hammerspoon/omarchy/ports/<id>.lua returning:
--   { id = "audio", actions = { ["audio.toggle-mute"] = { fn = function(x) end, desc = "..." }, ... },
--     start = function() end, stop = function() end }
-- A port that fails to load or start is logged and skipped; it never stops the rest.
local M = {}

local log = require("omarchy.log")
local DIR = os.getenv("HOME") .. "/.hammerspoon/omarchy/ports"

M.loaded = {}

local function loadOne(file)
  local id = file:match("^(.-)%.lua$")
  if not id or not id:match("^[%w%-]+$") then return end
  local modname = "omarchy.ports." .. id
  package.loaded[modname] = nil
  local ok, mod = pcall(require, modname)
  if not ok or type(mod) ~= "table" then
    log.e("ports: %s failed to load: %s", id, tostring(mod))
    return
  end
  local actions = require("omarchy.actions")
  for name, a in pairs(mod.actions or {}) do
    local okDef, err = pcall(actions.define, name, a.fn, a.desc)
    if not okDef then log.e("ports: %s action %s rejected: %s", id, tostring(name), tostring(err)) end
  end
  if mod.start then
    local okStart, err = pcall(mod.start)
    if not okStart then log.e("ports: %s start failed: %s", id, tostring(err)) return end
  end
  M.loaded[id] = mod
  log.i("ports: %s loaded", id)
end

function M.stopAll()
  for id, mod in pairs(M.loaded) do
    if mod.stop then pcall(mod.stop) end
    M.loaded[id] = nil
  end
end

function M.start()
  M.stopAll()
  if not hs.fs.attributes(DIR) then hs.fs.mkdir(DIR) end
  local files = {}
  for f in hs.fs.dir(DIR) do if f:match("%.lua$") then files[#files + 1] = f end end
  table.sort(files)
  for _, f in ipairs(files) do loadOne(f) end
  return M
end

return M
