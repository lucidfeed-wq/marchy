-- omarchy.battery: port of the Omarchy 4.5 shell service `omarchy.battery` (low battery
-- warning).
--
-- Omarchy checks the battery every 30 s and whenever the power source changes. When the
-- battery is discharging at 10 % or less it sends one warning ("Time to recharge!" /
-- "Battery is down to N%", glyph U+F140B, shown for 30 s) and stays quiet until the battery
-- is no longer low (charging, on AC, or above 10 %), so the next drop warns again. The
-- "already warned" flag survives a shell reload (PersistentProperties); here it survives a
-- Hammerspoon reload through hs.settings.
--
-- macOS mapping: hs.battery for level / source / charging, hs.battery.watcher for power
-- source changes, a 30 s hs.timer, and an Omarchy-styled hs.alert (the same look as
-- omarchy.toast) for the warning. hs.notify is not used: it could make macOS ask for a new
-- notification permission, which this machine does not grant.
local M = { id = "battery" }

local log = require("omarchy.log")

local THRESHOLD = 10          -- BatteryModel: batteryThreshold
local CHECK_EVERY = 30        -- Service.qml Timer interval (30000 ms)
local WARNING_SECONDS = 30    -- omarchy-battery-low: -t 30000
local SETTINGS_KEY = "omarchy.battery.notifiedLow"
local GLYPH = "\u{F140B}"     -- omarchy-battery-low: -g 󱐋

local timer, kick, watcher, alertId = nil, nil, nil, nil
local lastSource = nil

---------------------------------------------------------------- BatteryModel.js
-- batteryPercentage(): -1 when there is no battery.
function M.level()
  local ok, pct = pcall(hs.battery.percentage)
  if not ok or type(pct) ~= "number" then return -1 end
  return math.floor(pct + 0.5)
end

local function onBattery()
  local ok, src = pcall(hs.battery.powerSource)
  return ok and src == "Battery Power"
end

-- isDischarging(): on battery power and not charging.
function M.isDischarging()
  if M.level() < 0 then return false end
  local okC, charging = pcall(hs.battery.isCharging)
  return onBattery() and not (okC and charging)
end

-- shouldWarnLowBattery(): pure, so it can be tried from the console.
function M.evaluate(level, discharging, threshold, alreadyNotified)
  if level < 0 then return { level = level, notify = false, notifiedLowBattery = false } end
  local low = discharging and level <= threshold
  return { level = level, notify = low and not alreadyNotified, notifiedLowBattery = low }
end

---------------------------------------------------------------- warning
local function notified()
  local ok, v = pcall(hs.settings.get, SETTINGS_KEY)
  return ok and v == true
end

local function setNotified(v)
  if v == notified() then return end
  pcall(hs.settings.set, SETTINGS_KEY, v and true or false)
end

local function closeWarning()
  if alertId then
    pcall(hs.alert.closeSpecific, alertId, 0)
    alertId = nil
  end
end

-- omarchy-battery-low <level>: notification "Time to recharge!" / "Battery is down to N%".
function M.warn(level)
  closeWarning()
  local text = GLYPH .. "  Time to recharge!\nBattery is down to " .. tostring(math.floor(level)) .. "%"
  local ok = pcall(function()
    local style = require("omarchy.toast").style()
    alertId = hs.alert.show(text, style, hs.screen.mainScreen(), WARNING_SECONDS)
  end)
  log.i("battery: low battery warning at %d%%", math.floor(level))
  if not ok then log.w("battery: could not show the warning") end
end

function M.check()
  local state = M.evaluate(M.level(), M.isDischarging(), THRESHOLD, notified())
  setNotified(state.notifiedLowBattery)
  if state.notify then M.warn(state.level) end
  -- Plugging in clears a warning that is still on screen.
  if not state.notifiedLowBattery then closeWarning() end
  return state
end

---------------------------------------------------------------- actions
M.actions = {
  ["battery.check"] = { fn = function() M.check() end, desc = "Check the battery now (low battery warning at 10 %)" },
}

---------------------------------------------------------------- lifecycle
function M.start()
  M.stop()
  local okS, src = pcall(hs.battery.powerSource)
  lastSource = okS and src or nil
  timer = hs.timer.doEvery(CHECK_EVERY, function()
    local ok, err = pcall(M.check)
    if not ok then log.e("battery: check failed: %s", tostring(err)) end
  end)
  -- The watcher fires on every battery change; Omarchy re-checks on power source changes.
  watcher = hs.battery.watcher.new(function()
    local ok, now = pcall(hs.battery.powerSource)
    now = ok and now or nil
    if now ~= lastSource then
      lastSource = now
      pcall(M.check)
    end
  end)
  watcher:start()
  kick = hs.timer.doAfter(2, function() kick = nil pcall(M.check) end)   -- triggeredOnStart
  return M
end

function M.stop()
  if timer then timer:stop() timer = nil end
  if kick then kick:stop() kick = nil end
  if watcher then watcher:stop() watcher = nil end
  closeWarning()
end

return M
