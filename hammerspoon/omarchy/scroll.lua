-- Super+scroll moves through workspaces.
--
-- This tap watches scrollWheel events ONLY (never the keyboard, so Secure
-- Input cannot blind it and it cannot swallow typing). Karabiner holds real
-- Ctrl+Opt+Cmd while Caps Lock is down, so the scroll events carry those
-- flags. Exactly Ctrl+Opt+Cmd (no Shift) switches workspace; Super+Shift
-- scroll is left for OmniWM's own scroll modifier.
--
-- Momentum (fling) events are swallowed but never act. A trackpad gesture
-- acts once per gesture; a mouse wheel acts per notch, at most every 150 ms.
local M = {}

local log = require("omarchy.log")

local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties

local DEBOUNCE = 0.15
local last = 0
local gestureFired = false

M.count = 0 -- workspace switches done, for diag

local function isSuper(flags)
  return flags.ctrl and flags.alt and flags.cmd and not flags.shift
end

-- Replaceable for tests.
function M.dispatch(dir)
  M.count = M.count + 1
  hs.timer.doAfter(0, function()
    require("omarchy.actions").run("wm", "raw switch-workspace " .. dir)
  end)
end

local function handle(e)
  if not isSuper(e:getFlags()) then return false end

  -- Momentum phase: the fling after the fingers lift. Swallow, never act.
  local momentum = e:getProperty(props.scrollWheelEventMomentumPhase) or 0
  if momentum ~= 0 then return true end

  local dy = e:getProperty(props.scrollWheelEventDeltaAxis1) or 0
  if dy == 0 then dy = e:getProperty(props.scrollWheelEventPointDeltaAxis1) or 0 end

  local phase = e:getProperty(props.scrollWheelEventScrollPhase) or 0
  if phase ~= 0 then
    -- Trackpad gesture: 1 = began, 2 = changed, 4 = ended, 8 = cancelled,
    -- 128 = may begin.
    if phase == 1 or phase == 128 then gestureFired = false end
    if phase == 4 or phase == 8 then gestureFired = false return true end
    if gestureFired or math.abs(dy) < 2 then return true end
  end

  if dy == 0 then return true end
  local now = hs.timer.secondsSinceEpoch()
  if now - last < DEBOUNCE then return true end
  last = now
  if phase ~= 0 then gestureFired = true end
  M.dispatch(dy < 0 and "next" or "prev")
  return true
end
M._handle = handle

function M.start()
  if M.tap then M.tap:stop() end
  M.tap = hs.eventtap.new({ types.scrollWheel }, function(e)
    local ok, result = pcall(handle, e)
    if not ok then
      log.e("scroll: handler error: %s", tostring(result))
      return false
    end
    return result
  end)
  M.tap:start()

  -- macOS disables a tap that stalls; turn it back on.
  if M.watchdog then M.watchdog:stop() end
  M.watchdog = hs.timer.doEvery(2, function()
    if M.tap and not M.tap:isEnabled() then
      log.w("scroll: tap was disabled; restarting")
      M.tap:start()
    end
  end)
  log.i("scroll: tap started")
end

function M.stop()
  if M.watchdog then M.watchdog:stop() M.watchdog = nil end
  if M.tap then M.tap:stop() M.tap = nil end
end

function M.isEnabled()
  return M.tap ~= nil and M.tap:isEnabled()
end

return M
