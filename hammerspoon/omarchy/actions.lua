-- The registry of named Omarchy actions.
--
-- Every hotkey (omarchy/generated/bindings.lua), every hammerspoon://omarchy
-- URL (from Karabiner) and every menu row ends up in actions.run(name, arg).
-- run() never does the work inline: it schedules it with hs.timer.doAfter(0)
-- inside a pcall/xpcall, and anything slow is an hs.task.
--
-- Contract names (do not rename): menu, menu-system, menu-theme,
-- menu-background, menu-capture, menu-toggle, menu-setup, keybindings,
-- terminal, browser, browser-private, finder, tui, app, webapp, pop-out,
-- minimize, toggle-gaps, toggle-transparency, toggle-focus-follows-mouse,
-- screenshot-region, screenshot-window, screenrecord, color-picker,
-- stay-awake, show-time, show-battery, notification-center, agents, lock,
-- next-background, wm, diag, reload.
-- Extras: settings (x = System Settings pane id), theme-set (x = theme name).
--
-- Each action is declared with def("<name>", ...) on one line so that
-- omarchy-keys can also find the names with a regex; core.lua additionally
-- writes the list to ~/.local/state/omarchy-mac/hs-actions.json.
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")
local toast = require("omarchy.toast")

local defs, order = {}, {}

local function def(name, fn, desc)
  assert(not defs[name], "duplicate action " .. name)
  defs[name] = { fn = fn, desc = desc }
  order[#order + 1] = name
end

-- Register (or replace) an action at runtime. Used by generated ports (omarchy/ports.lua);
-- names must be namespaced "<port>.<verb>" so they can never shadow a built-in action.
function M.define(name, fn, desc)
  assert(type(name) == "string" and name:match("^[%w%-]+%.[%w%-%.]+$"), "port action must be namespaced: " .. tostring(name))
  if not defs[name] then order[#order + 1] = name end
  defs[name] = { fn = fn, desc = desc }
end

function M.exists(name)
  return defs[name] ~= nil
end

function M.names()
  local out = {}
  for i, n in ipairs(order) do out[i] = n end
  return out
end

function M.describe()
  local out = {}
  for _, n in ipairs(order) do out[#out + 1] = { name = n, desc = defs[n].desc } end
  return out
end

-- Run an action asynchronously. Returns false if the name is unknown.
function M.run(name, arg)
  local d = defs[name]
  if not d then
    log.w("actions: unknown action %s", tostring(name))
    toast.warn("Unknown action: " .. tostring(name))
    return false
  end
  hs.timer.doAfter(0, function()
    local ok, err = xpcall(function() d.fn(arg) end, debug.traceback)
    if not ok then
      log.e("actions: %s failed: %s", name, tostring(err))
      toast.warn("Action failed: " .. name)
    end
  end)
  return true
end

------------------------------------------------------------------ helpers

-- Read one scalar from ~/.config/omniwm/settings.toml (read-only, simple
-- line scan of a [section] table; good enough for booleans and numbers).
local function omniwmSetting(section, key)
  local data = u.readFile(u.HOME .. "/.config/omniwm/settings.toml")
  if not data then return nil end
  local inSection = false
  for line in data:gmatch("[^\n]+") do
    local header = line:match("^%s*%[([^%]]+)%]%s*$")
    if header then
      inSection = header == section
    elseif inSection then
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k == key then return v end
    end
  end
  return nil
end
M.omniwmSetting = omniwmSetting

local function argv(x)
  if type(x) == "table" then return x end
  return u.split(x)
end

-- omarchy-wm <args...>. Falls back to omniwmctl for `raw` when omarchy-wm
-- is not installed yet (cutover).
function M.wm(args, cb)
  args = argv(args)
  if #args == 0 then return toast.warn("wm: no arguments") end
  local bin = u.bin("omarchy-wm")
  local path, real
  if u.isExec(bin) then
    path, real = bin, args
  elseif args[1] == "raw" then
    path, real = u.CTL, { "command" }
    for i = 2, #args do real[#real + 1] = args[i] end
  else
    log.e("actions: omarchy-wm missing for %s", table.concat(args, " "))
    return toast.warn("omarchy-wm is not installed")
  end
  u.run(path, real, function(code, out, err)
    if code ~= 0 then
      toast.show("WM: " .. table.concat(args, " ") .. " failed (" .. tostring(code) .. ")")
    end
    if cb then cb(code, out, err) end
  end, { quiet = false })
end

local function omniwmSet(assignments, cb)
  local bin = u.bin("omarchy-omniwm-set")
  if not u.isExec(bin) then
    toast.warn("omarchy-omniwm-set is not installed")
    return
  end
  u.run(bin, assignments, function(code, out, err)
    if code ~= 0 then toast.warn("Settings write failed: " .. u.trim(err):sub(1, 120)) end
    if cb then cb(code, out, err) end
  end)
end

local function menu() return require("omarchy.menu") end
local function launch() return require("omarchy.launch") end
local function capture() return require("omarchy.capture") end
local function theme() return require("omarchy.theme") end

------------------------------------------------------------------ menus

def("menu", function() menu().toggle() end, "Omarchy menu")
def("menu-system", function() menu().open("system") end, "System menu")
def("menu-theme", function() require("omarchy.picker").themes() end, "Theme picker")
def("menu-background", function() require("omarchy.picker").backgrounds() end, "Background picker")
def("menu-capture", function() menu().open("capture") end, "Capture menu")
def("menu-toggle", function() menu().open("toggle") end, "Toggle menu")
def("menu-setup", function() menu().open("setup") end, "Setup menu")
def("keybindings", function(x) menu().keybindings(x) end, "Keybindings viewer (x = herdr, or a search filter)")
def("app-menu", function() require("omarchy.appmenu").toggle() end, "Search the frontmost app's menu commands")

------------------------------------------------------------------ launching

def("terminal", function() launch().terminal() end, "New terminal window")
def("browser", function() launch().browser() end, "New browser window")
def("browser-private", function() launch().browserPrivate() end, "New private browser window")
def("finder", function() launch().finder() end, "New Finder window")
def("tui", function(x) launch().tui(x) end, "Terminal program in a floating Ghostty window (x = command)")
def("app", function(x) launch().app(x) end, "Open an app (x = name or bundle id)")
def("webapp", function(x) launch().webapp(x) end, "Web app window (x = URL)")
def("agents", function()
  local bin = u.HOME .. "/.local/bin/omarchy-agents"
  if not u.isExec(bin) then return toast.warn("omarchy-agents is not installed") end
  launch().tui(bin, "agents")
end, "AI agent picker")
def("settings", function(x)
  x = u.trim(x)
  if not x:match("^[%w%.%-_]+$") then return toast.warn("settings: bad pane id") end
  launch().settings(x)
end, "System Settings pane (x = pane id)")

------------------------------------------------------------------ windows

def("pop-out", function()
  local win = hs.window.focusedWindow()
  if not win then return toast.show("No focused window") end
  local function place()
    if not win:isVisible() then return end
    local sf = win:screen():frame()
    local w, h = math.min(1300, sf.w - 40), math.min(900, sf.h - 40)
    win:setFrame({ x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h }, 0)
  end
  u.run(u.CTL, { "query", "windows", "--focused", "--fields", "id,mode", "--format", "json" }, function(code, out)
    local mode
    if code == 0 then
      local ok, d = pcall(hs.json.decode, out)
      if ok and d and d.result and d.result.payload and d.result.payload.windows
        and d.result.payload.windows[1] then
        mode = d.result.payload.windows[1].mode
      end
    end
    if mode == nil or mode == "floating" then
      place()
    else
      M.wm({ "raw", "toggle-focused-window-floating" }, function(c)
        if c == 0 then hs.timer.doAfter(0.15, place) end
      end)
    end
  end, { quiet = true })
end, "Pop window out: float, 1300x900, centred")

def("minimize", function()
  local win = hs.window.focusedWindow()
  if win then win:minimize() else toast.show("No focused window") end
end, "Minimize window")

def("wm", function(x) M.wm(x) end, "omarchy-wm <args> (x = space-separated arguments)")

------------------------------------------------------------------ toggles

def("toggle-gaps", function()
  M.wm({ "gaps-toggle" }, function(code)
    if code ~= 0 then return end
    hs.timer.doAfter(0.3, function()
      local size = tonumber(omniwmSetting("gaps", "size") or "")
      if size then toast.show(size > 0 and "Gaps on" or "Gaps off") end
    end)
  end)
end, "Toggle window gaps")

def("toggle-focus-follows-mouse", function()
  local now = omniwmSetting("focus", "followsMouse") == "true"
  local want = not now
  omniwmSet({ "focus.followsMouse=" .. tostring(want) }, function(code)
    if code ~= 0 then return end
    log.i("actions: focus follows mouse -> %s", tostring(want))
    if want then
      toast.warn("Focus follows mouse ON. Focus can leave the EMR if the pointer drifts.")
    else
      toast.show("Focus follows mouse off")
    end
  end)
end, "Toggle focus follows mouse")

-- Ghostty only: background-opacity in current/ghostty-overrides.conf
-- (included by ~/.config/ghostty/config), then SIGUSR2 to reload.
M.ghosttyOverrides = u.CURRENT .. "/ghostty-overrides.conf"

-- Pure: given the overrides file text, return the new text and opacity.
function M._opacityToggle(data)
  data = data or ""
  local cur = tonumber(data:match("background%-opacity%s*=%s*([%d%.]+)") or "") or 1.0
  local new = cur < 1.0 and "1.0" or "0.95"
  local line = "background-opacity = " .. new
  if data:find("background%-opacity%s*=") then
    data = data:gsub("background%-opacity%s*=%s*[%d%.]*", line, 1)
  else
    if data ~= "" and data:sub(-1) ~= "\n" then data = data .. "\n" end
    data = data .. line .. "\n"
  end
  return data, new
end

def("toggle-transparency", function()
  local path = M.ghosttyOverrides
  local data, new = M._opacityToggle(u.readFile(path))
  u.mkdirp(u.CURRENT)
  local ok, err = u.writeFile(path, data)
  if not ok then return toast.warn("Could not write " .. path .. ": " .. tostring(err)) end
  u.run("/usr/bin/pkill", { "-USR2", "-x", "ghostty" }, nil, { quiet = true })
  toast.show(new == "1.0" and "Terminal opaque" or "Terminal transparent")
end, "Toggle terminal transparency")

def("stay-awake", function()
  local on = hs.caffeinate.toggle("displayIdle")
  log.i("actions: stay awake -> %s", tostring(on))
  toast.show(on and "Staying awake (no idle sleep or lock)" or "Idle sleep and lock back on")
end, "Toggle staying awake")

------------------------------------------------------------------ capture

def("screenshot-region", function() capture().region() end, "Screenshot a region")
def("screenshot-window", function() capture().window() end, "Screenshot a window")
def("screenrecord", function() capture().record() end, "Screen recording toolbar")
def("color-picker", function() capture().colorPicker() end, "Colour picker")

------------------------------------------------------------------ notices

def("show-time", function()
  toast.show(os.date("%A %H:%M") .. "\n" .. tonumber(os.date("%d")) .. os.date(" %B %Y  W%V"), 2)
end, "Show the time")

def("show-battery", function()
  local pct = hs.battery.percentage()
  if not pct then return toast.show("No battery") end
  local state = hs.battery.isCharging() and "charging"
    or (hs.battery.powerSource() == "AC Power" and "on power" or "on battery")
  local mins = hs.battery.timeRemaining()
  local extra = (mins and mins > 0) and string.format(", %d:%02d left", math.floor(mins / 60), mins % 60) or ""
  toast.show(string.format("Battery %d%% (%s%s)", math.floor(pct + 0.5), state, extra), 2)
end, "Show battery")

local function pressClock()
  local cc = hs.application.get("com.apple.controlcenter")
  if not cc then return false end
  local ax = hs.axuielement.applicationElement(cc)
  if not ax then return false end
  local bar = ax:attributeValue("AXExtrasMenuBar")
  for _, item in ipairs((bar and bar:attributeValue("AXChildren")) or {}) do
    local id = item:attributeValue("AXIdentifier")
    if id == "com.apple.menuextra.clock" then
      item:performAction("AXPress")
      return true
    end
  end
  return false
end

def("notification-center", function()
  local ok, pressed = pcall(pressClock)
  if ok and pressed then return end
  log.w("actions: clock menu extra not found; trying System Events")
  u.run("/usr/bin/osascript", { "-e", [[
tell application "System Events" to tell application process "ControlCenter"
  click (first menu bar item of menu bar 1 whose description is "Clock")
end tell]] }, function(code)
    if code ~= 0 then toast.show("Could not open Notification Center") end
  end, { quiet = true })
end, "Open Notification Center")

------------------------------------------------------------------ system

def("lock", function() hs.caffeinate.lockScreen() end, "Lock the screen")
def("next-background", function() theme().nextBackground() end, "Next background")
def("theme-set", function(x)
  x = u.trim(x)
  local known = false
  for _, n in ipairs(theme().list()) do if n == x then known = true break end end
  if not known then return toast.warn("No such theme: " .. x) end
  theme().set(x)
end, "Set theme (x = name)")
def("tray", function(x) require("omarchy.tray").activate(x, "press") end, "Click a mirrored menu-bar item")
def("tray-menu", function(x) require("omarchy.tray").activate(x, "menu") end, "Right-click a mirrored menu-bar item")
def("tray-refresh", function() require("omarchy.tray").refresh(true) end, "Re-read menu-bar items")
def("wifi-scan", function() require("omarchy.netpanel").scanWifi() end, "Scan Wi-Fi networks")
def("wifi-power", function() require("omarchy.netpanel").wifiPower() end, "Toggle Wi-Fi")
def("wifi-join", function(x) require("omarchy.netpanel").wifiJoin(x) end, "Join a scanned Wi-Fi network")
def("bt-power", function() require("omarchy.netpanel").btPower() end, "Toggle Bluetooth")
def("bt-device", function(x) require("omarchy.netpanel").btDevice(x) end, "Connect/disconnect a paired Bluetooth device")
def("diag", function(x) require("omarchy.health").diag(nil, x == "quiet") end,
    "Write diag.json (x=quiet: no toast, no wait for modifier release)")
def("reload", function()
  log.i("actions: reload requested")
  hs.timer.doAfter(0.1, hs.reload)
end, "Reload Hammerspoon")

return M
