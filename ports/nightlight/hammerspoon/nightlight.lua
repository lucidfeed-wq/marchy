-- omarchy nightlight: port of the Omarchy 4.5 service plugin `omarchy.nightlight`.
--
-- Omarchy's service owns the hyprsunset temperature (night 4000 K, day 6500 K, anything
-- below 6000 K counts as "night light on") for the bar's NightLight indicator and the
-- `nightlight` IPC target (status / refresh / enable / disable / toggle).
--
-- On macOS the equivalent is Night Shift. Apple has no public CLI for it; the Homebrew
-- formula `smudge/smudge/nightlight` installs /opt/homebrew/bin/nightlight, which drives the
-- same private CoreBrightness client System Settings uses. When it is installed this module
-- reads and toggles Night Shift with it (no shell, absolute path, fixed arguments). When it
-- is missing, every action opens System Settings > Displays (where the Night Shift button
-- lives) and says what to install.
--
-- State is published to the OmniShell var `omarchy_nightlight` for the omarchy-nightlight
-- bar indicator: {v, available, loaded, enabled, strength}. `strength` is Night Shift's own
-- 0-100 warmth slider, not a colour temperature in Kelvin (macOS exposes no Kelvin value).
--
-- No action takes a URL argument; nothing from `x` reaches a process.
local M = { id = "nightlight" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local NIGHTLIGHT = "/opt/homebrew/bin/nightlight"
local VAR = "omarchy_nightlight"
local DISPLAYS_PANE = "com.apple.Displays-Settings.extension"
local POLL_SECONDS = 30    -- Night Shift also changes on its own schedule / from Control Center

local S = { available = false, loaded = false, enabled = false, strength = nil }
local lastPush, pollTimer, wakeWatcher
local statusTask, applyTask
local pendingApply = nil   -- "on" | "off" queued while an apply is running
local refreshQueued = false

local function installed()
  local perms = hs.fs.attributes(NIGHTLIGHT, "permissions")
  return perms ~= nil and perms:sub(3, 3) == "x"
end

local function publish()
  local text = hs.json.encode({
    v = 1, available = S.available, loaded = S.loaded, enabled = S.enabled,
    strength = S.strength,
  })
  if not text or text == lastPush then return end
  lastPush = text
  if not hs.fs.attributes(CTL) then return end
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("nightlight: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

-- `nightlight status` prints the schedule, then the on/off state, then (newer versions) the
-- strength. Read leniently: the first line that is (or ends in) a bare on/off word, skipping
-- schedule lines; a "temp"/"temperature"/"strength" line with a number gives the strength.
local function parseStatus(out)
  local enabled, strength = nil, nil
  for raw in tostring(out or ""):gmatch("[^\r\n]+") do
    local line = raw:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local isSchedule = line:find("schedule", 1, true) or line:sub(1, 2) == "=>"
    if enabled == nil and not isSchedule then
      local word = line:match("^(o[nf]f?)$") or line:match("[%s:]+(o[nf]f?)$")
      if word == "on" then enabled = true elseif word == "off" then enabled = false end
    end
    if strength == nil then
      local n = line:match("^te?mp[%a]*[%s:=]+(%d+)") or line:match("^strength[%s:=]+(%d+)")
      if n then strength = tonumber(n) end
    end
  end
  return enabled, strength
end

local function readStrength(done)
  local t = hs.task.new(NIGHTLIGHT, function(code, out)
    local n = code == 0 and tonumber(tostring(out or ""):match("(%d+)")) or nil
    done(n)
  end, { "temp" })
  if not t:start() then done(nil) end
end

function M.refresh()
  S.available = installed()
  if not S.available then
    S.loaded, S.enabled, S.strength = true, false, nil
    return publish()
  end
  if statusTask then refreshQueued = true return end
  statusTask = hs.task.new(NIGHTLIGHT, function(code, out, err)
    statusTask = nil
    if code ~= 0 then
      log.w("nightlight: status exited %s: %s", tostring(code), tostring(err):sub(1, 160))
      S.loaded, S.enabled = true, false
      publish()
    else
      local enabled, strength = parseStatus(out)
      S.loaded = true
      if enabled == nil then
        log.w("nightlight: could not read the on/off state from `nightlight status`")
        enabled = false
      end
      S.enabled = enabled
      if strength then
        S.strength = math.max(0, math.min(100, strength))
        publish()
      else
        readStrength(function(n)
          if n then S.strength = math.max(0, math.min(100, n)) end
          publish()
        end)
      end
    end
    if refreshQueued then
      refreshQueued = false
      hs.timer.doAfter(0, M.refresh)
    end
  end, { "status" })
  if not statusTask:start() then
    statusTask = nil
    log.e("nightlight: could not start %s", NIGHTLIGHT)
  end
end

local function openDisplays(reason)
  toast.warn(reason)
  pcall(function() require("omarchy.actions").run("settings", DISPLAYS_PANE) end)
end

local function missing()
  openDisplays("Night Shift: brew install smudge/smudge/nightlight to toggle it from here")
end

local function apply(word)
  if not installed() then return missing() end
  -- Optimistic, like Omarchy's service: the indicator flips at once, the probe confirms.
  S.available, S.loaded, S.enabled = true, true, word == "on"
  publish()
  if applyTask then pendingApply = word return end
  applyTask = hs.task.new(NIGHTLIGHT, function(code, _, err)
    applyTask = nil
    if code ~= 0 then
      log.w("nightlight: %s exited %s: %s", word, tostring(code), tostring(err):sub(1, 160))
      openDisplays("Night Shift could not be changed; opening Displays settings")
    end
    if pendingApply then
      local nextWord = pendingApply
      pendingApply = nil
      if nextWord ~= word then return apply(nextWord) end
    end
    M.refresh()
  end, { word })
  if not applyTask:start() then
    applyTask = nil
    log.e("nightlight: could not start %s", NIGHTLIGHT)
    missing()
  end
end

function M.setNightlight(on) apply(on and "on" or "off") end
function M.toggle() apply(S.enabled and "off" or "on") end
function M.state() return { enabled = S.enabled, available = S.available, strength = S.strength } end

M.actions = {
  ["nightlight.toggle"] = { fn = function() M.toggle() end, desc = "Night Shift: toggle (Omarchy night light)" },
  ["nightlight.enable"] = { fn = function() M.setNightlight(true) end, desc = "Night Shift: turn on" },
  ["nightlight.disable"] = { fn = function() M.setNightlight(false) end, desc = "Night Shift: turn off" },
  ["nightlight.refresh"] = { fn = function() M.refresh() end, desc = "Night Shift: re-read the state for the bar" },
  ["nightlight.status"] = { fn = function()
    if not installed() then return missing() end
    toast.show(S.enabled and "Night Shift on" or "Night Shift off", 1.2)
  end, desc = "Night Shift: show the current state" },
  ["nightlight.settings"] = { fn = function()
    pcall(function() require("omarchy.actions").run("settings", DISPLAYS_PANE) end)
  end, desc = "Night Shift: open System Settings > Displays" },
}

function M.start()
  M.stop()
  M.refresh()
  pollTimer = hs.timer.doEvery(POLL_SECONDS, function() if installed() then M.refresh() end end)
  wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake or event == hs.caffeinate.watcher.screensDidUnlock then
      hs.timer.doAfter(2, M.refresh)
    end
  end)
  wakeWatcher:start()
end

function M.stop()
  if pollTimer then pollTimer:stop() pollTimer = nil end
  if wakeWatcher then wakeWatcher:stop() wakeWatcher = nil end
  if statusTask then pcall(function() statusTask:terminate() end) statusTask = nil end
  if applyTask then pcall(function() applyTask:terminate() end) applyTask = nil end
  pendingApply, refreshQueued = nil, false
end

return M
