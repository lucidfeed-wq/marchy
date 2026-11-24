-- omarchy.power: port of the Omarchy 4.5 shell plugin `omarchy.power` (battery, power
-- profile and system stats bar widget).
--
-- The bar widget omarchy-power draws everything from OmniWM's own feeds (ctx.data.battery,
-- ctx.data.charging, ctx.data.power: source, minutes left/to full, cycles, watts, Low Power
-- Mode). This backend adds what those feeds lack and what a widget cannot do:
--   * battery size in Wh (Omarchy's "Battery size"), from `ioreg -rn AppleSmartBattery`
--     (nominal capacity mAh x voltage), refreshed every 5 minutes and on power events;
--   * the power mode from `pmset -g` (lowpowermode / powermode), so Macs with High Power
--     Mode show three profiles like powerprofilesctl does;
--   * Omarchy's right-click "togglePercentage" (shows NN% next to the icon), remembered in
--     hs.settings;
--   * power.toggle for the Omarchy hotkey SUPER+CTRL+P (`omniwmctl shell toggle omarchy-power`).
-- Changing the power mode needs `sudo pmset`, which this port never runs: the profile
-- buttons in the widget open Battery settings instead.
--
-- Publishes `omniwmctl shell set omarchy_power <json>` only when the JSON changed.
-- Nothing from a URL is used except a fixed action name (no arguments are accepted).
local M = { id = "power" }

local log = require("omarchy.log")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local PMSET = "/usr/bin/pmset"
local IOREG = "/usr/sbin/ioreg"
local VAR = "omarchy_power"
local WIDGET = "omarchy-power"
local SETTINGS_PCT = "omarchy.power.showPercentage"
local CAPACITY_EVERY = 300
local MODE_EVERY = 60

local state = { size = nil, mode = nil, high = false }
local last = nil
local timers = {}
local tasks = {}
local watcher = nil

local function publish()
  local out = {
    v = 1,
    pct = hs.settings.get(SETTINGS_PCT) == true,
    size = state.size,
    mode = state.mode,
    high = state.high,
  }
  local ok, text = pcall(hs.json.encode, out)
  if not ok or not text or text == last then return end
  last = text
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("power: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

local function start(kind, path, args, cb)
  if tasks[kind] then return end
  local task
  local ok = pcall(function()
    task = hs.task.new(path, function(code, out)
      tasks[kind] = nil
      pcall(cb, code, out or "")
    end, args)
    if not task:start() then error("start failed") end
  end)
  if ok then tasks[kind] = task else tasks[kind] = nil log.w("power: could not start %s", kind) end
end

-- Battery size (Wh). Only the capacity and voltage numbers are read; the ioreg output
-- (which also holds serial numbers) is never logged or stored.
local function readCapacity()
  start("ioreg", IOREG, { "-rn", "AppleSmartBattery" }, function(code, out)
    if code ~= 0 then return end
    local function num(key)
      local v = out:match('"' .. key .. '"%s*=%s*(%d+)')
      return v and tonumber(v) or nil
    end
    local mah = num("AppleRawMaxCapacity") or num("NominalChargeCapacity") or num("FullChargeCapacity")
    local mv = num("Voltage") or num("AppleRawBatteryVoltage")
    if mah and mv and mah > 200 and mv > 1000 then
      state.size = math.floor(mah * mv / 1000000 + 0.5)
    else
      state.size = nil
    end
    publish()
  end)
end

-- Power mode: powermode 0/1/2 (automatic/low/high) where High Power Mode exists, else
-- lowpowermode 0/1. Read-only.
local function readMode()
  start("pmset", PMSET, { "-g" }, function(code, out)
    if code ~= 0 then return end
    local pm = out:match("\n%s*powermode%s+(%d)")
    local low = out:match("\n%s*lowpowermode%s+(%d)")
    local high = out:match("\n%s*highpowermode%s+(%d)")
    if pm then
      state.high = true
      state.mode = (pm == "1" and "low") or (pm == "2" and "high") or "auto"
    elseif high then
      state.high = true
      state.mode = (low == "1" and "low") or (high == "1" and "high") or "auto"
    elseif low then
      state.high = false
      state.mode = low == "1" and "low" or "auto"
    else
      state.high = false
      state.mode = nil
    end
    publish()
  end)
end

local function refresh()
  readMode()
  readCapacity()
end

local function togglePercentage()
  hs.settings.set(SETTINGS_PCT, not (hs.settings.get(SETTINGS_PCT) == true))
  publish()
end

local function toggle()
  refresh()
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("power: shell toggle failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "toggle", WIDGET }):start()
end

M.actions = {
  ["power.toggle"] = { fn = function() toggle() end, desc = "Power: open or close the power panel" },
  ["power.toggle-percentage"] = { fn = function() togglePercentage() end, desc = "Power: show/hide the battery percentage in the bar" },
  ["power.refresh"] = { fn = function() refresh() end, desc = "Power: re-read power mode and battery size" },
}

function M.start()
  M.stop()
  timers.mode = hs.timer.doEvery(MODE_EVERY, readMode)
  timers.capacity = hs.timer.doEvery(CAPACITY_EVERY, readCapacity)
  -- Power source / charge changes: re-read soon (debounced; the watcher fires often).
  watcher = hs.battery.watcher.new(function()
    if timers.debounce then return end
    timers.debounce = hs.timer.doAfter(3, function()
      timers.debounce = nil
      readMode()
    end)
  end)
  watcher:start()
  timers.first = hs.timer.doAfter(1, function()
    timers.first = nil
    refresh()
  end)
  publish()
  return M
end

function M.stop()
  for name, t in pairs(timers) do
    pcall(function() t:stop() end)
    timers[name] = nil
  end
  if watcher then pcall(function() watcher:stop() end) watcher = nil end
  for kind, t in pairs(tasks) do
    pcall(function() t:terminate() end)
    tasks[kind] = nil
  end
end

return M
