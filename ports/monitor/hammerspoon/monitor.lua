-- omarchy.monitor: port of the Omarchy 4.5 shell plugin `omarchy.monitor` (Display panel).
--
-- Omarchy's bar item (󰍹, or 󰍺 with more than one display) scrolls brightness in 5 % steps and
-- opens a panel with: a "Display" header and a brightness mood name (Night owl … Sun blast, or
-- FIXED BRIGHTNESS), a brightness slider (1–100 %) for the focused display, a text-size slider,
-- six scale presets (1x 1.25x 1.6x 2x 3x 4x, filtered to those that fit the focused mode), and,
-- with more than one display, a list to turn displays on and off (never the last one).
--
-- Here the bar item and panel are the OmniShell widget omarchy-monitor. Built-in brightness
-- uses OmniWM's own ctx.data.brightness / `brightness set` command. This module supplies what
-- OmniShell cannot see, published as JSON in the shell var "omarchy_monitor":
--   * every display (hs.screen): name, built-in or not, focused, on;
--   * scale presets for the focused display, mapped to the macOS display modes
--     (hs.screen:availableModes / setMode) whose logical size is native / scale;
--   * external-display brightness, only if BetterDisplay's CLI is installed
--     (/opt/homebrew/bin/betterdisplaycli; brew install waydabber/betterdisplay/betterdisplaycli);
--   * turning displays off/on, through the same CLI.
-- URL arguments are indices/numbers checked against what was last published. No polling:
-- screens are watched with hs.screen.watcher.
local M = { id = "monitor" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local BDCLI = "/opt/homebrew/bin/betterdisplaycli"
local VAR = "omarchy_monitor"
local WIDGET = "omarchy-monitor"

-- Model.js scale presets.
local PRESETS = { 1, 1.25, 1.6, 2, 3, 4 }
local MATCH_TOLERANCE = 0.07   -- a mode counts as a preset within 7 % of its logical size

local last = nil              -- last published JSON
local displays = {}           -- published list: { name, builtin, enabled, focused, id }
local scales = {}             -- published presets for the focused display: { label, mode, screenId, active }
local disabled = {}           -- name -> true: displays this session turned off (to offer them back)
local extBrightness = nil     -- focused external display brightness (BetterDisplay), percent
local extName = nil
local mirroredFrom = nil      -- session flag: built-in mirroring an external
local watcher, debounce
local bdBusy, bdQueued = false, nil

local function clamp(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end
local function round(v) return math.floor(v + 0.5) end

local function hasBD() return hs.fs.attributes(BDCLI) ~= nil end

local function isBuiltin(screen)
  local ok, name = pcall(function() return screen:name() end)
  return ok and type(name) == "string" and name:lower():find("built%-in") ~= nil
end

local function screenName(screen)
  local ok, name = pcall(function() return screen:name() end)
  if ok and type(name) == "string" and name ~= "" then return name end
  return "Display"
end

local function push(tbl)
  local ok, text = pcall(hs.json.encode, tbl)
  if not ok or not text or text == last then return end
  last = text
  local okT = pcall(function()
    hs.task.new(CTL, function(code, _, err)
      if code ~= 0 then log.w("monitor: shell set failed: %s", tostring(err):sub(1, 160)) end
    end, { "shell", "set", VAR, text }):start()
  end)
  if not okT then log.w("monitor: could not start omniwmctl") end
end

-- "1.60" -> "1.6", "2.00" -> "2"
local function fmtScale(v)
  local s = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
  return s
end

---------------------------------------------------------------- scale presets
-- macOS calls Omarchy's scale "Looks like": a mode whose logical width is native / scale.
local function scalePresets(screen)
  local okM, modes = pcall(function() return screen:availableModes() end)
  local okC, cur = pcall(function() return screen:currentMode() end)
  if not okM or type(modes) ~= "table" or not okC or type(cur) ~= "table" then return {} end
  -- Native pixels: the widest 1x mode (HiDPI modes can render above the panel's resolution
  -- and downsample, so their backing size is not the panel's).
  local list, nativeW, backingW = {}, 0, 0
  for _, m in pairs(modes) do
    if type(m) == "table" and tonumber(m.w) and tonumber(m.h) and tonumber(m.scale) then
      list[#list + 1] = m
      if m.scale == 1 then nativeW = math.max(nativeW, m.w) end
      backingW = math.max(backingW, m.w * m.scale)
    end
  end
  if nativeW <= 0 then nativeW = backingW end
  if nativeW <= 0 then return {} end
  local curFreq, curDepth = tonumber(cur.freq), tonumber(cur.depth)
  local out, used = {}, {}
  for _, p in ipairs(PRESETS) do
    local best, bestScore = nil, nil
    for _, m in ipairs(list) do
      local eff = nativeW / m.w
      local err = math.abs(eff - p) / p
      -- same aspect as the current mode, sharpest (HiDPI) first, same refresh rate
      local sameAspect = math.abs(m.w / m.h - cur.w / cur.h) < 0.02
      if err <= MATCH_TOLERANCE and sameAspect then
        local score = err * 10
          + ((m.scale >= 2 or p == 1) and 0 or 1)
          + ((curFreq and tonumber(m.freq) and math.abs(m.freq - curFreq) > 0.5) and 0.5 or 0)
          + ((curDepth and tonumber(m.depth) and m.depth ~= curDepth) and 0.25 or 0)
        if not bestScore or score < bestScore then best, bestScore = m, score end
      end
    end
    if best then
      local key = tostring(math.floor(best.w)) .. "x" .. tostring(math.floor(best.h)) .. "@" .. tostring(best.scale)
      if not used[key] then
        used[key] = true
        out[#out + 1] = {
          label = fmtScale(nativeW / best.w) .. "x",
          mode = { w = best.w, h = best.h, scale = best.scale, freq = best.freq, depth = best.depth },
          active = best.w == cur.w and best.h == cur.h and best.scale == cur.scale,
        }
      end
    end
  end
  return out
end

---------------------------------------------------------------- BetterDisplay (optional)
local function bdRun(args, cb)
  local ok = pcall(function()
    hs.task.new(BDCLI, function(code, out, err)
      if cb then pcall(cb, code, out or "", err or "") end
    end, args):start()
  end)
  if not ok and cb then pcall(cb, -1, "", "could not start") end
end

local publish -- forward

local function readExternalBrightness(name)
  if not hasBD() or not name then extBrightness, extName = nil, nil return end
  bdRun({ "get", "-name=" .. name, "-brightness" }, function(code, out)
    if code ~= 0 then extBrightness, extName = nil, nil publish() return end
    local num = tonumber((out:match("([%d%.]+)")) or "")
    if num then
      -- the CLI may answer 0..1 or a percentage
      if not out:find("%%") and num <= 1 then num = num * 100 end
      extBrightness, extName = clamp(round(num), 0, 100), name
    else
      extBrightness, extName = nil, nil
    end
    publish()
  end)
end

local function setExternalBrightness(pct)
  if not (hasBD() and extName) then return toast.warn("External brightness needs betterdisplaycli") end
  extBrightness = pct
  if bdBusy then bdQueued = pct return end
  bdBusy = true
  local name = extName
  bdRun({ "set", "-name=" .. name, "-brightness=" .. tostring(pct) .. "%" }, function(code)
    bdBusy = false
    if code ~= 0 then log.w("monitor: betterdisplaycli brightness exited %s", tostring(code)) end
    if bdQueued then
      local q = bdQueued
      bdQueued = nil
      setExternalBrightness(q)
    else
      publish()
    end
  end)
end

---------------------------------------------------------------- state
publish = function()
  local screens = hs.screen.allScreens() or {}
  local main = hs.screen.mainScreen()
  local okMid, mainId = pcall(function() return main and main:id() end)
  if not okMid then mainId = nil end
  displays = {}
  local seenNames = {}
  local focusedScreen = nil
  for _, s in ipairs(screens) do
    local okId, id = pcall(function() return s:id() end)
    local name = screenName(s)
    seenNames[name] = true
    disabled[name] = nil
    local focused = okId and id == mainId
    if focused then focusedScreen = s end
    displays[#displays + 1] = { name = name, builtin = isBuiltin(s), enabled = true, focused = focused, id = okId and id or nil }
  end
  for name in pairs(disabled) do
    if not seenNames[name] then
      displays[#displays + 1] = { name = name, builtin = name:lower():find("built%-in") ~= nil, enabled = false, focused = false }
    end
  end
  focusedScreen = focusedScreen or screens[1]

  scales = {}
  if focusedScreen then
    local okSid, sid = pcall(function() return focusedScreen:id() end)
    for _, p in ipairs(scalePresets(focusedScreen)) do
      p.screenId = okSid and sid or nil
      scales[#scales + 1] = p
    end
  end

  local enabledCount = 0
  for _, d in ipairs(displays) do if d.enabled then enabledCount = enabledCount + 1 end end
  local bd = hasBD()
  local outDisplays = {}
  for i, d in ipairs(displays) do
    outDisplays[i] = { n = d.name, b = d.builtin, f = d.focused, e = d.enabled,
      t = bd and (not d.enabled or enabledCount > 1) or false }
  end
  local outScales = {}
  for i, p in ipairs(scales) do outScales[i] = { l = p.label, a = p.active } end
  local focusedExternal = focusedScreen and not isBuiltin(focusedScreen)
  push({
    v = 1,
    displays = outDisplays,
    scales = outScales,
    focusedName = focusedScreen and screenName(focusedScreen) or "",
    focusedBuiltin = focusedScreen and isBuiltin(focusedScreen) or false,
    enabledCount = enabledCount,
    bd = bd,
    ext = (focusedExternal and extName == screenName(focusedScreen)) and extBrightness or nil,
  })
end

local function refresh()
  publish()
  local main = hs.screen.mainScreen()
  if main and not isBuiltin(main) then readExternalBrightness(screenName(main)) else extBrightness, extName = nil, nil end
end

---------------------------------------------------------------- actions
local function intArg(x, lo, hi)
  local n = tonumber(tostring(x or ""):match("^%s*(%-?%d+)%s*$") or "")
  if not n then return nil end
  if n < lo or n > hi then return nil end
  return n
end

local function screenById(id)
  for _, s in ipairs(hs.screen.allScreens() or {}) do
    local ok, sid = pcall(function() return s:id() end)
    if ok and sid == id then return s end
  end
  return nil
end

local function applyScale(index)
  local p = scales[index]
  if not p then return toast.warn("That scale is not available any more") end
  local screen = p.screenId and screenById(p.screenId)
  if not screen then return toast.warn("That display is gone") end
  local m = p.mode
  local ok, done = pcall(function() return screen:setMode(m.w, m.h, m.scale, m.freq, m.depth) end)
  if not ok or not done then
    log.w("monitor: setMode %dx%d@%s failed", math.floor(m.w), math.floor(m.h), tostring(m.scale))
    return toast.warn("Could not change the display scale")
  end
  log.i("monitor: scale %s (%dx%d@%s)", p.label, math.floor(m.w), math.floor(m.h), tostring(m.scale))
  toast.show("Display scale " .. p.label, 1.2)
  hs.timer.doAfter(1, publish)
end

-- Omarchy's Super+/ and Super+Alt+/: next / previous preset for the focused display.
local function stepScale(delta)
  publish()
  if #scales == 0 then return toast.warn("No scale presets for this display") end
  local at = nil
  for i, p in ipairs(scales) do if p.active then at = i end end
  local nextI
  if not at then nextI = delta > 0 and 1 or #scales else nextI = clamp(at + delta, 1, #scales) end
  if at == nextI then return toast.show("Display scale " .. scales[nextI].label, 1.2) end
  applyScale(nextI)
end

local function setDisplay(index)
  local d = displays[index]
  if not d then return toast.warn("That display is not in the list any more") end
  if not hasBD() then return toast.warn("Turning displays on and off needs betterdisplaycli") end
  local enabledCount = 0
  for _, x in ipairs(displays) do if x.enabled then enabledCount = enabledCount + 1 end end
  if d.enabled and enabledCount <= 1 then return toast.warn("The last display stays on") end
  local turnOn = not d.enabled
  local name = d.name
  bdRun({ "set", "-name=" .. name, "-connected=" .. (turnOn and "on" or "off") }, function(code)
    if code ~= 0 then
      log.w("monitor: betterdisplaycli connected exited %s", tostring(code))
      toast.warn("Could not turn " .. name .. (turnOn and " on" or " off"))
      return
    end
    if turnOn then disabled[name] = nil else disabled[name] = true end
    toast.show(name .. (turnOn and " on" or " off"), 1.2)
    hs.timer.doAfter(1.5, refresh)
  end)
end

local function builtinIndex()
  for i, d in ipairs(displays) do if d.builtin then return i end end
  return nil
end

-- Omarchy Super+Ctrl+Delete: laptop display off/on (only with another display).
local function toggleInternal()
  publish()
  local i = builtinIndex()
  if not i then return toast.warn("No built-in display") end
  setDisplay(i)
end

-- Omarchy Super+Ctrl+Alt+Delete: mirror the laptop display to the external one, or stop.
local function toggleMirror()
  local screens = hs.screen.allScreens() or {}
  if mirroredFrom then
    for _, s in ipairs(screens) do pcall(function() s:mirrorStop() end) end
    mirroredFrom = nil
    toast.show("Display mirroring off", 1.2)
    hs.timer.doAfter(1.5, refresh)
    return
  end
  local builtin, external = nil, nil
  for _, s in ipairs(screens) do
    if isBuiltin(s) then builtin = s elseif not external then external = s end
  end
  if not (builtin and external) then return toast.warn("Mirroring needs the built-in and one external display") end
  local ok, done = pcall(function() return builtin:mirrorOf(external) end)
  if not ok or done == false then return toast.warn("Could not mirror the displays") end
  mirroredFrom = screenName(external)
  toast.show("Mirroring " .. mirroredFrom, 1.2)
  hs.timer.doAfter(1.5, refresh)
end

-- Show the brightness OSD through the osd port when it is installed (Omarchy's scroll OSD).
local function osd(x)
  local pct = intArg(x, 0, 100)
  if not pct then return end
  local o = package.loaded["omarchy.ports.osd"]
  if type(o) == "table" and type(o.showTable) == "function" then
    pcall(o.showTable, { icon = "brightness", value = pct })
  end
end

M.actions = {
  ["monitor.refresh"] = { fn = function() refresh() end, desc = "Re-read displays, scale presets and external brightness" },
  ["monitor.open"] = { fn = function()
    hs.task.new(CTL, function(code)
      if code ~= 0 then toast.warn("Add omarchy-monitor to the bar to open the Display panel") end
    end, { "shell", "toggle", WIDGET }):start()
    refresh()
  end, desc = "Open/close the Display panel in the bar" },
  ["monitor.scale"] = { fn = function(x)
    local i = intArg(x, 1, #scales)
    if not i then return toast.warn("Unknown scale preset") end
    applyScale(i)
  end, desc = "Apply a scale preset of the focused display (x = index from the panel)" },
  ["monitor.scale-up"] = { fn = function() stepScale(1) end, desc = "Next (larger) display scale preset" },
  ["monitor.scale-down"] = { fn = function() stepScale(-1) end, desc = "Previous (smaller) display scale preset" },
  ["monitor.display"] = { fn = function(x)
    local i = intArg(x, 1, #displays)
    if not i then return toast.warn("Unknown display") end
    setDisplay(i)
  end, desc = "Turn a display off/on via BetterDisplay (x = index from the panel)" },
  ["monitor.toggle-internal"] = { fn = function() toggleInternal() end, desc = "Turn the laptop display off/on (BetterDisplay)" },
  ["monitor.mirror-internal"] = { fn = function() toggleMirror() end, desc = "Mirror the laptop display to the external display, or stop" },
  ["monitor.brightness"] = { fn = function(x)
    local pct = intArg(x, 1, 100)
    if not pct then return end
    setExternalBrightness(pct)
  end, desc = "Brightness of the focused external display, 1-100 (BetterDisplay)" },
  ["monitor.osd"] = { fn = function(x) osd(x) end, desc = "Show the brightness OSD (x = 0-100; needs the osd port)" },
}

function M.start()
  M.stop()
  debounce = hs.timer.delayed.new(0.5, function()
    local ok, err = pcall(refresh)
    if not ok then log.e("monitor: refresh failed: %s", tostring(err)) end
  end)
  -- fires on display changes and when the focused display changes
  watcher = hs.screen.watcher.newWithActiveScreen(function() debounce:start() end)
  watcher:start()
  hs.timer.doAfter(1, function() pcall(refresh) end)
  return M
end

function M.stop()
  if watcher then watcher:stop() watcher = nil end
  if debounce then debounce:stop() debounce = nil end
  bdBusy, bdQueued = false, nil
end

return M
