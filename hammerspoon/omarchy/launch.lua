-- Launchers: terminal, TUIs, browser, web apps, Finder, apps.
-- Everything is either an hs.task (async) or a quick AppKit/AX call that the
-- action registry already runs outside the hotkey callback.
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")
local toast = require("omarchy.toast")

local function installed(bundleID)
  return hs.application.pathForBundleID(bundleID) ~= nil
end

-- Focus the first window of app that was not in `before`, polling briefly.
local function focusNewWindow(app, before)
  local tries = 0
  local function poll()
    tries = tries + 1
    if not app:isRunning() then return end
    for _, w in ipairs(app:allWindows()) do
      if not before[w:id()] then
        w:focus()
        return
      end
    end
    if tries < 15 then hs.timer.doAfter(0.1, poll) end
  end
  hs.timer.doAfter(0.1, poll)
end

-- The user's normal Ghostty process. M.tui starts one Ghostty process per TUI
-- with --title=omarchy-float-<name>, which Ghostty forces on every window of
-- that process, so a new window there would float and keep the TUI process
-- alive. Skip any process that has such a window. Titles are never logged.
local function mainGhostty()
  for _, a in ipairs(hs.application.applicationsForBundleID(u.GHOSTTY_BUNDLE) or {}) do
    local tui = false
    for _, w in ipairs(a:allWindows()) do
      if (w:title() or ""):find("^omarchy%-float%-") then tui = true break end
    end
    if not tui then return a end
  end
  return nil
end
M._mainGhostty = mainGhostty

-- A new Ghostty window every time (Super+Return).
function M.terminal()
  if not installed(u.GHOSTTY_BUNDLE) then return toast.warn("Ghostty is not installed") end
  local app = mainGhostty()
  if not app then
    -- Nothing running, or only TUI processes: start a plain Ghostty process.
    log.i("launch: no main Ghostty process; starting one")
    u.run(u.OPEN, { "-na", "Ghostty" })
    return
  end
  local before = {}
  for _, w in ipairs(app:allWindows()) do before[w:id()] = true end
  -- Asking through the menu does not activate the app first, so OmniWM does
  -- not jump to whichever workspace Ghostty's last window is on.
  if app:selectMenuItem({ "File", "New Window" }) then
    focusNewWindow(app, before)
  else
    log.w("launch: Ghostty File > New Window not found; opening a new instance")
    u.run(u.OPEN, { "-na", "Ghostty" })
  end
end

-- "nvim ~/x" -> "nvim"; used for the omarchy-float-<name> window title.
local function tuiName(command)
  local first = tostring(command):match("^%s*(%S+)") or "tui"
  first = first:match("([^/]+)$") or first
  first = first:gsub("[^%w%-_]", "")
  if first == "" then first = "tui" end
  return first
end
M.tuiName = tuiName

-- A terminal program in its own floating Ghostty window.
function M.tui(command, name)
  if not command or u.trim(command) == "" then return toast.warn("No command given") end
  if not installed(u.GHOSTTY_BUNDLE) then return toast.warn("Ghostty is not installed") end
  name = name or tuiName(command)
  log.i("launch: tui %s", name)
  u.run(u.OPEN, {
    "-na", "Ghostty", "--args",
    "--title=omarchy-float-" .. name,
    "--quit-after-last-window-closed=true",
    "-e", "/bin/zsh", "-lic", command,
  })
end

local function chrome(args, what)
  if not installed(u.CHROME_BUNDLE) then return toast.warn("Google Chrome is not installed") end
  local argv = { "-n", "-b", u.CHROME_BUNDLE, "--args" }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  log.i("launch: chrome %s", what)
  u.run(u.OPEN, argv)
end

function M.browser()
  chrome({ "--new-window" }, "new window")
end

function M.browserPrivate()
  chrome({ "--incognito" }, "incognito")
end

function M.webapp(url)
  url = u.trim(url)
  if not url:match("^https?://") then return toast.warn("Web app needs an http(s) URL") end
  chrome({ "--app=" .. url }, "app " .. (url:match("^https?://([^/]+)") or ""))
end

-- Async osascript: hs.osascript would block Hammerspoon's main thread (and so
-- every hotkey and the scroll tap) for up to the AppleScript timeout, and on
-- the first run for as long as the Automation permission prompt is open.
function M.finder()
  u.run("/usr/bin/osascript", {
    "-e", "with timeout of 3 seconds",
    "-e", 'tell application "Finder" to make new Finder window to home',
    "-e", 'tell application "Finder" to activate',
    "-e", "end timeout",
  }, function(code, _, errOut)
    if code ~= 0 then
      log.w("launch: Finder AppleScript failed (%s); using open", u.trim(errOut):sub(1, 200))
      u.run(u.OPEN, { u.HOME })
    end
  end, { quiet = true })
end

local APP_DIRS = {
  "/Applications", "/Applications/Utilities", "/System/Applications",
  "/System/Applications/Utilities", (os.getenv("HOME") or "") .. "/Applications",
}

-- Real ids can end in ".app" (dev.herdr.app); a dotted string that is not an
-- installed bundle id falls through to the name lookup in M.app anyway.
local function looksLikeBundleID(x)
  return x:find("^[%w%-]+%.[%w%-]+[%w%.%-]*$") ~= nil
end
M._looksLikeBundleID = looksLikeBundleID

-- x: an app name ("Calculator") or a bundle id ("com.apple.calculator").
-- Skipped with a toast if it is not installed.
function M.app(x)
  x = u.trim(x)
  if x == "" then return toast.warn("No app given") end
  if looksLikeBundleID(x) then
    if installed(x) then
      log.i("launch: app %s", x)
      if not hs.application.launchOrFocusByBundleID(x) then toast.warn("Could not open " .. x) end
      return
    end
    -- A dotted name that is not a known bundle id: fall through to names.
  end
  x = x:gsub("%.app$", "") -- "Calculator.app" -> "Calculator"
  if x == "" then return toast.warn("No app given") end
  local found = false
  for _, dir in ipairs(APP_DIRS) do
    if u.exists(dir .. "/" .. x .. ".app") then found = true break end
  end
  if not found and hs.application.get(x) then found = true end
  if not found then
    log.i("launch: app %s not installed", x)
    return toast.show("Not installed  " .. x)
  end
  log.i("launch: app %s", x)
  if not hs.application.launchOrFocus(x) then toast.warn("Could not open " .. x) end
end

-- A System Settings pane, e.g. "com.apple.BluetoothSettings".
function M.settings(pane)
  u.run(u.OPEN, { "x-apple.systempreferences:" .. pane })
end

function M.openURL(url)
  u.run(u.OPEN, { url })
end

return M
