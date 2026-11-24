-- Workspace layout guard.
--
-- 1. Toasts whenever a workspace changes layout (dwindle <-> scrolling) from any source:
--    Super+L, the bar, omniwmctl, OmniWM's own UI. OmniWM saves every layout change into
--    settings.toml, so a silent change looks like "the layout keeps changing".
-- 2. Undoes changes nobody asked for: OmniWM 0.8.0 flips workspaces back to an old
--    layout a few seconds after a monitor is connected/disconnected (verified 2026-11-23:
--    Dell unplugged 16:36:55, workspace 1 dwindle -> niri 16:37:00). A change that lands
--    within GRACE seconds of a screen change is reverted to the layout the user last chose.
--    `set-workspace-layout` only acts on the focused workspace, so a revert for another
--    workspace waits until that workspace is focused.
--
-- Listens to `omniwmctl subscribe layout-changed` (one long-running process, restarted
-- if it exits). No keyboard access involved.
local M = {}

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local NAMES = { dwindle = "Tiling (dwindle) layout", niri = "Scrolling layout" }
local GRACE = 20 -- seconds after a monitor change during which layout changes are not the user's

M.layouts = nil      -- rawName -> layout, from the latest event
M.intended = {}      -- rawName -> layout the user last chose (or had at start)
M.pending = {}       -- rawName -> layout to restore once that workspace is focused
M.expect = {}        -- rawName -> layout we just asked OmniWM for (suppress its toast)
M.lastScreenChange = 0
M.buffer = ""
M.restarts = 0

local STATE = os.getenv("HOME") .. "/.local/state/omarchy-mac/layouts.json"

local function now() return hs.timer.secondsSinceEpoch() end

local function saveIntended()
  pcall(hs.json.write, M.intended, STATE, true, true)
end

local function loadIntended()
  local ok, data = pcall(hs.json.read, STATE)
  if ok and type(data) == "table" then
    for k, v in pairs(data) do if v == "dwindle" or v == "niri" then M.intended[k] = v end end
  end
end

local function setLayout(rawName, layout)
  M.expect[rawName] = layout
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("layout: set %s -> %s failed: %s", rawName, layout, tostring(err)) end
  end, { "command", "set-workspace-layout", layout }):start()
end

local function handleLine(line)
  if line == "" then return end
  local ok, msg = pcall(hs.json.decode, line)
  if not ok or type(msg) ~= "table" or msg.channel ~= "layout-changed" then return end
  local list = msg.result and msg.result.payload and msg.result.payload.workspaces
  if type(list) ~= "table" then return end

  local current = {}
  for _, w in ipairs(list) do
    if w.rawName and w.layout then current[w.rawName] = w.layout end
  end
  local before = M.layouts
  M.layouts = current
  if not before then -- first snapshot: keep saved choices, fill in the rest from what is live
    for name, layout in pairs(current) do
      if not M.intended[name] then M.intended[name] = layout end
      if M.intended[name] ~= layout then M.pending[name] = M.intended[name] end
    end
    saveIntended()
    for _, w in ipairs(list) do
      if w.isFocused and M.pending[w.rawName] then
        local want = M.pending[w.rawName]; M.pending[w.rawName] = nil
        setLayout(w.rawName, want)
      end
    end
    return
  end

  local afterScreenChange = (now() - M.lastScreenChange) < GRACE
  for _, w in ipairs(list) do
    local name, old, new = w.rawName, before[w.rawName], w.layout
    local label = w.displayName or name
    if old and new and old ~= new then
      if M.expect[name] == new then
        M.expect[name] = nil -- our own revert landed
        log.i("layout: workspace %s restored to %s", name, new)
      elseif afterScreenChange and M.intended[name] and M.intended[name] ~= new then
        log.w("layout: workspace %s %s -> %s right after a monitor change; reverting to %s",
          name, old, new, M.intended[name])
        if w.isFocused then
          setLayout(name, M.intended[name])
          toast.show(string.format("Workspace %s kept in %s\n(OmniWM changed it after the monitor change)",
            label, NAMES[M.intended[name]] or M.intended[name]), 2.5)
        else
          M.pending[name] = M.intended[name]
        end
      else
        M.intended[name] = new -- a real choice (Super+L etc.)
        M.pending[name] = nil
        saveIntended()
        log.i("layout: workspace %s %s -> %s", name, old, new)
        toast.show(string.format("Workspace %s: %s\nSuper+L switches it back", label, NAMES[new] or new), 2.5)
      end
    end
    -- A deferred revert for a workspace that is now focused.
    if w.isFocused and M.pending[name] then
      local want = M.pending[name]
      M.pending[name] = nil
      if new ~= want then
        setLayout(name, want)
        toast.show(string.format("Workspace %s restored to %s", label, NAMES[want] or want), 2)
      end
    end
  end
end

local function onChunk(_, out, _)
  if not out or out == "" then return true end
  M.buffer = M.buffer .. out
  while true do
    local nl = M.buffer:find("\n", 1, true)
    if not nl then break end
    local line = M.buffer:sub(1, nl - 1)
    M.buffer = M.buffer:sub(nl + 1)
    local ok, err = pcall(handleLine, line)
    if not ok then log.w("layout: bad event: %s", tostring(err)) end
  end
  if #M.buffer > 4 * 1024 * 1024 then M.buffer = "" end -- never grow without bound
  return true
end

function M.start()
  if not next(M.intended) then loadIntended() end
  if not M.screenWatcher then
    M.screenWatcher = hs.screen.watcher.newWithActiveScreen(function(activeChanged)
      if activeChanged then return end -- focus moving between screens is not a reconfiguration
      M.lastScreenChange = now()
      log.i("layout: monitor configuration changed; guarding layouts for %ds", GRACE)
    end)
    M.screenWatcher:start()
  end
  if M.task and M.task:isRunning() then return M end
  M.buffer = ""
  -- Without --no-send-initial the first event is a snapshot, which seeds M.layouts/M.intended.
  M.task = hs.task.new(CTL, function(code)
    log.w("layout: subscriber exited (%s)", tostring(code))
    M.task = nil
    M.restarts = M.restarts + 1
    if M.restarts <= 20 then
      M.timer = hs.timer.doAfter(math.min(30, 2 * M.restarts), function() M.start() end)
    end
  end, onChunk, { "subscribe", "layout-changed", "--reconnect", "--format", "ndjson" })
  if M.task and M.task:start() then
    log.i("layout: watching layout changes")
  else
    log.w("layout: could not start subscriber")
  end
  return M
end

function M.stop()
  if M.timer then M.timer:stop() M.timer = nil end
  if M.task then M.task:terminate() M.task = nil end
  if M.screenWatcher then M.screenWatcher:stop() M.screenWatcher = nil end
end

return M
