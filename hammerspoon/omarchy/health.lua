-- Keeping the setup healthy:
--   * relaunch OmniWM if it quits (checked 5 s later; at most 3 times in
--     10 minutes; `touch ~/.local/state/omarchy-mac/omniwm-no-restart` to stop).
--     Two detectors: the app watcher, and a 10 s poll, because the watcher's
--     terminated event never arrived when OmniWM crashed on a dock unplug (2026-11-25).
--   * a Secure Input watcher that logs every change and toasts once when it
--     turns on, naming the process that holds it
--   * the `diag` action, writing ~/.local/state/omarchy-mac/diag.json
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")
local toast = require("omarchy.toast")

local RESTART_DELAY = 5
local RESTART_WINDOW = 600
local RESTART_MAX = 3

M.restarts = {}
M.secure = false
M.secureOwner = nil -- { pid = n, process = "name" }

local function omniwmRunning()
  local ok, apps = pcall(hs.application.applicationsForBundleID, u.OMNIWM_BUNDLE)
  return ok and apps ~= nil and #apps > 0
end
M.omniwmRunning = omniwmRunning

local pending = false
local function scheduleRelaunch(how)
  if pending then return end
  pending = true
  log.w("health: OmniWM terminated (%s)", how or "watcher")
  hs.timer.doAfter(RESTART_DELAY, function()
    pending = false
    if omniwmRunning() then return end
    if u.exists(u.STATE .. "/omniwm-no-restart") then
      log.i("health: omniwm-no-restart present; not relaunching")
      return
    end
    local now = hs.timer.secondsSinceEpoch()
    local recent = {}
    for _, t in ipairs(M.restarts) do
      if now - t < RESTART_WINDOW then recent[#recent + 1] = t end
    end
    M.restarts = recent
    if #recent >= RESTART_MAX then
      log.e("health: OmniWM quit %d times in 10 min; giving up", #recent)
      toast.warn("OmniWM keeps quitting. Not restarting it again.")
      return
    end
    M.restarts[#M.restarts + 1] = now
    log.i("health: relaunching OmniWM")
    u.run(u.OPEN, { "-g", "-b", u.OMNIWM_BUNDLE }, function(code)
      if code == 0 then toast.show("OmniWM restarted") else toast.warn("Could not restart OmniWM") end
    end)
  end)
end

-- Who holds Secure Input: ioreg's kCGSSessionSecureInputPID -> process name.
function M.secureInputOwner(cb)
  u.run("/usr/sbin/ioreg", { "-l", "-w", "0", "-d", "1", "-k", "IOConsoleUsers" }, function(code, out)
    local pid = code == 0 and tonumber(out:match('"kCGSSessionSecureInputPID"%s*=%s*(%d+)')) or nil
    if not pid then return cb(nil, nil) end
    local app = hs.application.applicationForPID(pid)
    if app and app:name() then return cb(pid, app:name()) end
    u.run("/bin/ps", { "-p", tostring(pid), "-o", "comm=" }, function(_, psOut)
      local name = u.trim(psOut):match("([^/]+)$")
      cb(pid, name ~= "" and name or nil)
    end, { quiet = true })
  end, { quiet = true })
end

local function checkSecureInput()
  local on = hs.eventtap.isSecureInputEnabled()
  if on == M.secure then return end
  M.secure = on
  if on then
    M.secureInputOwner(function(pid, name)
      M.secureOwner = { pid = pid, process = name }
      log.i("health: Secure Input ON (pid %s, %s)", tostring(pid), tostring(name))
      toast.show("Secure Input on  " .. (name or "unknown app"), 2)
    end)
  else
    log.i("health: Secure Input off")
    M.secureOwner = nil
  end
end

function M.start()
  M.appWatcher = hs.application.watcher.new(function(name, event, app)
    if event ~= hs.application.watcher.terminated then return end
    local bid = nil
    pcall(function() bid = app and app:bundleID() end)
    if name == "OmniWM" or bid == u.OMNIWM_BUNDLE then scheduleRelaunch() end
  end)
  M.appWatcher:start()

  -- Backstop poll: only acts on a running -> gone transition, so quitting OmniWM before
  -- Hammerspoon starts (or keeping it off) is left alone.
  M.omniwmWasRunning = omniwmRunning()
  M.omniwmPoll = hs.timer.doEvery(10, function()
    local now = omniwmRunning()
    if M.omniwmWasRunning and not now then scheduleRelaunch("poll") end
    M.omniwmWasRunning = now
  end)

  M.secureTimer = hs.timer.doEvery(2, function()
    local ok, err = pcall(checkSecureInput)
    if not ok then log.e("health: secure input check failed: %s", tostring(err)) end
  end)
  pcall(checkSecureInput)
end

-- diag.json: everything needed to tell "the key did nothing" apart.
function M.diag(done, quiet)
  -- When run from a hotkey, Caps Lock is still down; wait for release so the
  -- modifier snapshot shows stuck keys, not the chord that asked for diag.
  -- quiet (omarchy-doctor --static: a=diag&x=quiet): no toast, snapshot at once.
  local t0 = hs.timer.secondsSinceEpoch()
  u.afterModifiersReleased(function()
    local core = require("omarchy.core")
    local scroll = require("omarchy.scroll")
    local theme = require("omarchy.theme")
    local d = {
      time = os.date("%Y-%m-%dT%H:%M:%S"),
      versions = {
        hammerspoon = hs.processInfo.version,
        macos = hs.host.operatingSystemVersionString(),
      },
      hotkeys = core.hotkeyCount(),
      hotkeyFailures = core.failures,
      generated = core.generatedInfo(),
      secureInput = {
        enabled = hs.eventtap.isSecureInputEnabled(),
        pid = M.secureOwner and M.secureOwner.pid or nil,
        process = M.secureOwner and M.secureOwner.process or nil,
      },
      modifiers = hs.eventtap.checkKeyboardModifiers(true),
      waitedForReleaseSeconds = hs.timer.secondsSinceEpoch() - t0,
      scrollTap = { enabled = scroll.isEnabled(), switches = scroll.count },
      omniwm = { running = omniwmRunning(), restartsLast10Min = #M.restarts },
      theme = { name = theme.name, mode = theme.mode, wallpaper = theme.background, font = theme.font },
      dispatchLog = u.tail(u.STATE .. "/dispatch.log", 20),
      hsLog = u.tail(log.file, 10),
    }
    local function write()
      u.mkdirp(u.STATE)
      local ok, json = pcall(hs.json.encode, d, true)
      if not ok then json = '{"error":"encode failed"}' end
      local wok, err = u.writeFile(u.STATE .. "/diag.json", json .. "\n")
      if wok then
        log.i("health: diag written")
        if not quiet then toast.show("Diagnostics written  " .. u.STATE .. "/diag.json", 2) end
      else
        log.e("health: diag write failed: %s", tostring(err))
      end
      if done then done(d) end
    end
    u.run(u.CTL, { "version" }, function(code, out)
      d.versions.omniwmctl = code == 0 and u.trim(out) or ("exit " .. tostring(code))
      local kcli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
      if not u.exists(kcli) then return write() end
      u.run(kcli, { "--version" }, function(kcode, kout)
        d.versions.karabiner = kcode == 0 and u.trim(kout) or ("exit " .. tostring(kcode))
        write()
      end, { quiet = true })
    end, { quiet = true })
  end, quiet and 0 or 1.5)
end

return M
