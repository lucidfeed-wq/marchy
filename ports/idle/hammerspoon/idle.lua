-- omarchy.idle: port of the Omarchy 4.5 shell service `omarchy.idle` (idle detection for
-- screensaver, lock and display wake).
--
-- Omarchy's behaviour (Service.qml / IdleModel.js), reproduced here:
--   * timeouts from shell.json `idle.screensaver` / `idle.lock` (defaults 150 s / 300 s;
--     0 disables that step). An idle cycle starts at the first enabled timeout; each step
--     fires at its own deadline, counted from the last input.
--   * screensaver step: start the screensaver (unless turned off, or the session is locked).
--   * lock step: lock the session. It may fire while the screensaver is up; that is the point.
--   * any input before the lock cancels the cycle, except right after the screensaver was
--     launched (3 s grace) or while it is running; dismissing the screensaver cancels it.
--   * "Stay awake" (Omarchy's idle inhibitor toggle) and apps that inhibit idle stop the cycle.
--
-- macOS mapping:
--   idle time        hs.host.idleTime() (HID idle), checked by an adaptive one-shot timer:
--                    it sleeps until the first deadline could be reached (at most 30 s), and
--                    polls every 2 s only during an idle cycle.
--   screensaver      hs.caffeinate.startScreensaver(); start/stop seen via hs.caffeinate.watcher
--   lock             hs.caffeinate.lockScreen() (the same call as the built-in `lock` action)
--   stay awake       the built-in Hammerspoon action `stay-awake` (hs.caffeinate displayIdle),
--                    read with hs.caffeinate.get("displayIdle"); OmniWM's `session awake ...`
--                    and any other app's display-sleep assertion (video, calls) are read from
--                    hs.caffeinate.currentAssertions(). This module never creates assertions.
--   display wake     nothing to do: macOS wakes the displays on input itself.
--
-- Safety (clinical machine): this only ever ADDS an earlier screensaver/lock on top of macOS's
-- own settings. It never writes power settings (no pmset, no sudo), never declares user
-- activity (which would postpone macOS's own lock), and never disables macOS's screen lock.
local M = { id = "idle" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CONFIG = os.getenv("HOME") .. "/.config/omarchy-mac/shell.json"
local DEFAULT_SCREENSAVER = 150
local DEFAULT_LOCK = 300
local MIN_TIMEOUT = 5          -- a configured 1..4 s becomes 5 s (0 still disables)
local MAX_TIMEOUT = 86400
local POLL_CYCLE = 2           -- seconds between checks during an idle cycle
local POLL_MAX = 30            -- longest sleep between checks otherwise
local GRACE = 3                -- screensaverLaunchGraceTimer
local SCREENSAVER_OFF_KEY = "omarchy.idle.screensaverOff"
local OMNIWM_BUNDLE = "com.barut.OmniWM"
local SCREENSAVER_BUNDLE = "com.apple.ScreenSaver.Engine"
local SCREENSAVER_GLYPH = "\u{F1104}"

local DISPLAY_ASSERTIONS = { PreventUserIdleDisplaySleep = true, NoDisplaySleepAssertion = true }

local cfg = { screensaver = DEFAULT_SCREENSAVER, lock = DEFAULT_LOCK }
local st = {
  cycle = false,            -- idledThisCycle
  ssStarted = false,        -- screensaverStartedThisCycle
  ssRunning = false,        -- macOS reports the screensaver running
  locked = false,           -- screens locked or session switched away
  asleep = false,           -- displays asleep
  awaitActivity = false,    -- after a lock: no new cycle until input is seen
  lastIdle = 0,
  lastEvent = "starting",
  lastEventAt = nil,
}
local tick, ssTimer, lockTimer, graceTimer, watcher = nil, nil, nil, nil, nil
local startedAt = 0
local check   -- forward declaration

local function logEvent(event, details)
  st.lastEvent = event .. ((details and details ~= "") and (": " .. details) or "")
  st.lastEventAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
  log.i("idle: %s", st.lastEvent)
end

local function stopTimer(t) if t then t:stop() end return nil end

-- Idle seconds, counted from this module's start at most (like Omarchy's IdleMonitor, which
-- starts counting when the shell loads): a reload never locks on the spot, and still locks
-- `lock` seconds later if nobody touches the machine.
local function idleSeconds()
  local ok, idle = pcall(hs.host.idleTime)
  idle = (ok and type(idle) == "number") and idle or 0
  return math.min(idle, math.max(0, hs.timer.secondsSinceEpoch() - startedAt))
end

---------------------------------------------------------------- config (IdleModel.js)
local function secondsFrom(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n or n < 0 or n == math.huge then return fallback end
  n = math.floor(n)
  if n > 0 and n < MIN_TIMEOUT then n = MIN_TIMEOUT end
  if n > MAX_TIMEOUT then n = MAX_TIMEOUT end
  return n
end

local function loadConfig()
  local screensaver, lock = DEFAULT_SCREENSAVER, DEFAULT_LOCK
  local size = hs.fs.attributes(CONFIG, "size")
  if size and size < 262144 then
    local fh = io.open(CONFIG, "r")
    if fh then
      local raw = fh:read("*a")
      fh:close()
      local ok, data = pcall(hs.json.decode, raw or "")
      local idle = ok and type(data) == "table" and type(data.idle) == "table" and data.idle or nil
      if idle then
        screensaver = secondsFrom(idle.screensaver, DEFAULT_SCREENSAVER)
        lock = secondsFrom(idle.lock, DEFAULT_LOCK)
      elseif not ok then
        log.w("idle: could not parse %s, using defaults", CONFIG)
      end
    end
  end
  cfg.screensaver, cfg.lock = screensaver, lock
end

-- firstIdleTimeout(): the smaller enabled timeout; 0 when both are off.
local function firstIdle()
  local a, b = cfg.screensaver, cfg.lock
  if a > 0 and b > 0 then return math.min(a, b) end
  if a > 0 then return a end
  if b > 0 then return b end
  return 0
end

---------------------------------------------------------------- inhibitors
local function pidOf(bundle)
  local ok, app = pcall(hs.application.get, bundle)
  if ok and app then
    local okP, pid = pcall(function() return app:pid() end)
    if okP then return pid end
  end
  return nil
end

-- Display-sleep assertions currently held, split into OmniWM's ("session awake") and others.
local function displayAssertions()
  local found = { omniwm = false, other = false }
  local ok, all = pcall(hs.caffeinate.currentAssertions)
  if not ok or type(all) ~= "table" then return found end
  local omni = pidOf(OMNIWM_BUNDLE)
  local saver = pidOf(SCREENSAVER_BUNDLE)   -- the screensaver itself is not an inhibitor
  local function holds(list, depth)
    if type(list) ~= "table" or depth > 3 then return false end
    if list.AssertType ~= nil then
      local level = tonumber(list.AssertLevel)
      return DISPLAY_ASSERTIONS[tostring(list.AssertType)] == true and (level == nil or level > 0)
    end
    for _, v in pairs(list) do
      if holds(v, depth + 1) then return true end
    end
    return false
  end
  for pid, list in pairs(all) do
    if holds(list, 1) and not (saver and tostring(pid) == tostring(saver)) then
      if omni and tostring(pid) == tostring(omni) then found.omniwm = true else found.other = true end
    end
  end
  return found
end

local function stayAwake()
  local ok, on = pcall(hs.caffeinate.get, "displayIdle")
  return ok and on == true
end

-- Why idle handling is off right now, or nil when it is on.
local function inhibitor()
  if stayAwake() then return "stay-awake" end
  local a = displayAssertions()
  if a.omniwm then return "omniwm-awake" end
  if a.other then return "app-inhibitor" end
  return nil
end

local function screensaverOff()
  local ok, v = pcall(hs.settings.get, SCREENSAVER_OFF_KEY)
  return ok and v == true
end

---------------------------------------------------------------- cycle
local function stopCycleTimers()
  ssTimer = stopTimer(ssTimer)
  lockTimer = stopTimer(lockTimer)
  graceTimer = stopTimer(graceTimer)
end

local function cancelCycle(reason)
  if st.cycle then logEvent("idle-cycle-cancel", reason) end
  stopCycleTimers()
  st.cycle = false
  st.ssStarted = false
end

local function lockSystem(reason)
  logEvent("lock-system", reason)
  stopCycleTimers()
  st.cycle = false
  st.ssStarted = false
  st.awaitActivity = true
  local ok, err = pcall(hs.caffeinate.lockScreen)
  if not ok then log.e("idle: lockScreen failed: %s", tostring(err)) end
end

local function launchScreensaver()
  if screensaverOff() then logEvent("screensaver-skip", "turned off") return end
  if st.locked then return end
  -- Starting the screensaver could light up displays macOS has already put to sleep.
  if st.asleep then logEvent("screensaver-skip", "displays asleep") return end
  st.ssStarted = true
  graceTimer = stopTimer(graceTimer)
  graceTimer = hs.timer.doAfter(GRACE, function()
    graceTimer = nil
    if st.cycle and st.ssStarted and not st.ssRunning and idleSeconds() < firstIdle() then
      cancelCycle("screensaver-not-running")
    end
  end)
  logEvent("screensaver-start")
  local ok, err = pcall(hs.caffeinate.startScreensaver)
  if not ok then log.w("idle: startScreensaver failed: %s", tostring(err)) end
end

-- handleActiveSignal(): input during a cycle.
local function onActivity()
  if not st.cycle then return end
  if st.ssStarted and (st.ssRunning or graceTimer ~= nil) then return end   -- cycle stays armed
  cancelCycle("activity")
end

-- True when there was input since the cycle started, i.e. the idle time is well short of the
-- deadline that just fired (polling every 2 s could otherwise miss input in the last seconds).
local function inputBefore(deadline)
  return idleSeconds() < deadline - 2
end

-- Deadlines are set once per cycle, from the idle time actually observed, so a late check can
-- only bring a step forward, never push it back.
local function startCycle(idle)
  if st.cycle then return end
  st.cycle = true
  st.ssStarted = false
  logEvent("idle-cycle-start", string.format("screensaver=%d lock=%d idle=%d",
    cfg.screensaver, cfg.lock, math.floor(idle)))
  if cfg.screensaver > 0 then
    local delay = cfg.screensaver - idle
    if delay <= 0 then
      launchScreensaver()
    else
      ssTimer = hs.timer.doAfter(delay, function()
        ssTimer = nil
        if not (st.cycle and cfg.screensaver > 0) then return end
        if inputBefore(cfg.screensaver) then onActivity() return end
        launchScreensaver()
      end)
    end
  end
  if cfg.lock > 0 then
    local delay = cfg.lock - idle
    if delay <= 0 then
      lockSystem("lock-timeout-immediate")
    else
      lockTimer = hs.timer.doAfter(delay, function()
        lockTimer = nil
        if not st.cycle then return end
        local why = inhibitor()
        if why then cancelCycle(why) return end
        if inputBefore(cfg.lock) then
          onActivity()
          if not st.cycle then return end
        end
        lockSystem("lock-timeout")
      end)
    end
  end
end

---------------------------------------------------------------- the check loop
local function schedule(seconds)
  tick = stopTimer(tick)
  tick = hs.timer.doAfter(math.max(POLL_CYCLE, seconds), function()
    tick = nil
    check()
  end)
end

local function step()
  local idle = idleSeconds()
  local active = idle + 0.5 < st.lastIdle
  st.lastIdle = idle
  if st.locked then return POLL_MAX end

  -- Pick up shell.json edits between cycles (a cycle keeps the deadlines it started with).
  if not st.cycle then loadConfig() end
  local first = firstIdle()
  if active or (first > 0 and idle < first) then st.awaitActivity = false end

  local why = inhibitor()
  if why or first == 0 then
    if st.cycle then cancelCycle(why or "idle-timers-disabled") end
    return POLL_MAX
  end

  if st.cycle then
    if active or idle < first then onActivity() end
    return POLL_CYCLE
  end
  if st.awaitActivity then return POLL_MAX end
  if idle >= first then
    startCycle(idle)
    return POLL_CYCLE
  end
  return math.min(POLL_MAX, first - idle)
end

check = function()
  local ok, nextIn = pcall(step)
  if not ok then
    log.e("idle: check failed: %s", tostring(nextIn))
    nextIn = POLL_MAX
  end
  schedule(nextIn)
end

local function checkSoon(seconds)
  schedule(seconds or POLL_CYCLE)
end

---------------------------------------------------------------- macOS events
local W = hs.caffeinate.watcher
local function onEvent(event)
  if event == W.screensaverDidStart then
    st.ssRunning = true
    graceTimer = stopTimer(graceTimer)
  elseif event == W.screensaverDidStop then
    st.ssRunning = false
    if st.cycle and st.ssStarted then cancelCycle("screensaver-dismissed") end
    checkSoon()
  elseif event == W.screensDidLock or event == W.sessionDidResignActive then
    st.locked = true
    cancelCycle("locked")
  elseif event == W.screensDidUnlock or event == W.sessionDidBecomeActive then
    st.locked = false
    st.awaitActivity = false
    st.lastIdle = 0
    checkSoon()
  elseif event == W.screensDidSleep then
    st.asleep = true
  elseif event == W.screensDidWake then
    st.asleep = false
  elseif event == W.systemWillSleep then
    cancelCycle("system-sleep")
  elseif event == W.systemDidWake then
    st.asleep = false
    checkSoon(5)
  end
end

---------------------------------------------------------------- stay awake (coordination)
local function runBuiltin(name)
  local actions = require("omarchy.actions")
  if not actions.exists(name) then
    toast.warn("Hammerspoon action " .. name .. " is missing")
    return false
  end
  actions.run(name)
  hs.timer.doAfter(1, function() checkSoon() end)
  return true
end

local OMNIWM_AWAKE_MSG = "OmniWM Stay Awake is on; turn it off from the bar to allow idle lock"

-- omarchy-toggle-idle: one switch, shared with the built-in `stay-awake` action.
function M.toggle()
  if stayAwake() then return runBuiltin("stay-awake") end
  if displayAssertions().omniwm then return toast.warn(OMNIWM_AWAKE_MSG) end
  return runBuiltin("stay-awake")
end

-- ShellIpc idle.enable / idle.disable.
function M.setEnabled(on)
  if on then
    if stayAwake() then runBuiltin("stay-awake") end
    local a = displayAssertions()
    if a.omniwm then toast.warn(OMNIWM_AWAKE_MSG)
    elseif not stayAwake() and not a.other then toast.show("Idle screensaver and lock are on") end
  else
    if not stayAwake() then runBuiltin("stay-awake") else toast.show("Already staying awake") end
  end
end

local function clock(seconds)
  if seconds <= 0 then return "off" end
  return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

-- ShellIpc idle.status (as a table; the action shows a summary toast).
function M.status()
  local why = inhibitor()
  return {
    enabled = why == nil and firstIdle() > 0,
    inhibitedBy = why,
    stayAwake = stayAwake(),
    idle = math.floor(st.lastIdle),
    inIdleCycle = st.cycle,
    screensaverStarted = st.ssStarted,
    screensaverRunning = st.ssRunning,
    screensaverOff = screensaverOff(),
    locked = st.locked,
    screensaver = cfg.screensaver,
    lock = cfg.lock,
    timers = { screensaver = ssTimer ~= nil, lock = lockTimer ~= nil, screensaverLaunchGrace = graceTimer ~= nil },
    lastEvent = st.lastEvent,
    lastEventAt = st.lastEventAt,
  }
end

local function showStatus()
  loadConfig()
  local s = M.status()
  local head
  if s.inhibitedBy == "stay-awake" then head = "Idle lock off (staying awake)"
  elseif s.inhibitedBy == "omniwm-awake" then head = "Idle lock off (OmniWM Stay Awake)"
  elseif s.inhibitedBy == "app-inhibitor" then head = "Idle lock paused (an app is keeping the display on)"
  elseif not s.enabled then head = "Idle lock off (both timeouts are 0)"
  else head = "Idle lock on" end
  local ss = s.screensaverOff and "off" or clock(s.screensaver)
  toast.show(head .. "\nScreensaver " .. ss .. " · Lock " .. clock(s.lock), 3)
end

function M.toggleScreensaver()
  local off = not screensaverOff()
  pcall(hs.settings.set, SCREENSAVER_OFF_KEY, off)
  toast.show(SCREENSAVER_GLYPH .. "  " .. (off and "Screensaver disabled" or "Screensaver enabled"), 2)
end

---------------------------------------------------------------- actions
M.actions = {
  ["idle.toggle"] = { fn = function() M.toggle() end, desc = "Toggle locking on idle (shares the stay-awake switch)" },
  ["idle.enable"] = { fn = function() M.setEnabled(true) end, desc = "Allow idle screensaver and lock" },
  ["idle.disable"] = { fn = function() M.setEnabled(false) end, desc = "Stay awake: no idle screensaver or lock" },
  ["idle.status"] = { fn = function() showStatus() end, desc = "Show the idle settings and state" },
  ["idle.screensaver"] = { fn = function()
    local ok = pcall(hs.caffeinate.startScreensaver)
    if not ok then toast.warn("Could not start the screensaver") end
  end, desc = "Start the screensaver now" },
  ["idle.screensaver-toggle"] = { fn = function() M.toggleScreensaver() end, desc = "Turn the idle screensaver on or off" },
}

---------------------------------------------------------------- lifecycle
function M.start()
  M.stop()
  loadConfig()
  local okP, props = pcall(hs.caffeinate.sessionProperties)
  st.locked = okP and type(props) == "table" and props.CGSSessionScreenIsLocked == true or false
  st.ssRunning, st.asleep, st.cycle, st.ssStarted, st.awaitActivity = false, false, false, false, false
  startedAt = hs.timer.secondsSinceEpoch()
  st.lastIdle = 0
  watcher = hs.caffeinate.watcher.new(function(event)
    local ok, err = pcall(onEvent, event)
    if not ok then log.e("idle: event failed: %s", tostring(err)) end
  end)
  watcher:start()
  logEvent("service-ready", string.format("screensaver=%d lock=%d", cfg.screensaver, cfg.lock))
  checkSoon(POLL_CYCLE)
  return M
end

function M.stop()
  tick = stopTimer(tick)
  stopCycleTimers()
  if watcher then watcher:stop() watcher = nil end
  st.cycle = false
  st.ssStarted = false
end

return M
