-- omarchy.tray: mirror macOS menu-bar extras (status items) into the OmniShell bar.
-- v2 (scratch only, not installed). Fixes over b_proto: dedupe ignores the timestamp,
-- republish on OmniWM relaunch + every 5 min, per-element AX timeouts, URL key allow-list,
-- Hammerspoon's own item routed to the Omarchy menu (no self-AXPress), icon overrides.
--
-- Data flow
--   Hammerspoon (this file)  --omniwmctl shell set omarchy_tray <json>-->  ctx.data.vars["omarchy_tray"]
--   omarchy-tray widget      --omniwm.open("hammerspoon://omarchy?a=tray&x=<key>")-->  actions "tray" -> M.activate(key)
--
-- Discovery (Accessibility only; no Screen Recording):
--   1. macOS 27 draws every status item in com.apple.MenuBarAgent's menu-bar window.
--      Walking AXWindows -> groups -> items gives every item with its owner pid and x position.
--   2. For each owner pid, the app's AXExtrasMenuBar children carry AXDescription / AXIdentifier /
--      AXValue (e.g. "com.apple.menuextra.wifi", Battery value "91%"). Apple's own items
--      (Wi-Fi, Battery, Control Center, Clock) live under MenuBarAgent's AXExtrasMenuBar.
--   3. If MenuBarAgent is missing (older/newer macOS layout), fall back to all running apps.
--
-- Item key: "<bundleID>@<n>", n = 1-based order of that app's items from left to right.
-- Third-party items have no AXIdentifier, so the key is positional per app (stable for
-- apps with one item, which is nearly all of them).
local M = {}

local ok_u, u = pcall(require, "omarchy.util")
local ok_l, log = pcall(require, "omarchy.log")
if not ok_l then log = { i = function() end, w = function() end, e = function() end } end

local CTL = (ok_u and u.CTL) or "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local VAR = "omarchy_tray"
local AX_TIMEOUT = 0.25            -- seconds per AX message; a hung app cannot stall Hammerspoon long
local REFRESH_EVERY = 20           -- seconds; safety net for items that appear without an app launch
local FORCE_EVERY = 300            -- seconds; re-push even if unchanged (vars may not survive an OmniWM restart)
local OMNIWM = "com.barut.OmniWM"
local VERIFY_AFTER = 0.45          -- seconds after a press before checking that something opened

-- Items the bar already shows natively, or that make no sense mirrored.
M.exclude = {
  ["com.barut.OmniWM"] = true,                -- OmniWM's own item (workspace/title readout)
  ["com.apple.menuextra.clock"] = true,       -- omarchy-clock already shows the time
  ["com.apple.systemuiserver"] = true,        -- one unidentified item on 27.0
}

-- Bundles whose status item lives in a helper with no usable icon: draw this app's icon
-- (i = bundle for ui.icon) or an SF Symbol (s) instead. Karabiner's item is owned by
-- org.pqrs.Karabiner-Console-User-Server (measured 2026-11-23).
M.iconOverride = {
  ["org.pqrs.Karabiner-Console-User-Server"] = { s = "keyboard" },
}

-- Never "open the app" as a fallback for these (helpers / agents with no main window).
M.noAppFallback = {
  ["com.apple.MenuBarAgent"] = true,
  ["com.apple.systemuiserver"] = true,
  ["org.pqrs.Karabiner-Console-User-Server"] = true,
}

-- Status items owned by Hammerspoon itself: an AX press from inside Hammerspoon targets its
-- own main thread (UNVERIFIED whether that blocks), so route the click to an Omarchy action.
M.selfAction = "menu"

-- SF Symbols for Apple items (they have no app icon of their own).
local APPLE_SYMBOLS = {
  ["com.apple.menuextra.wifi"] = "wifi",
  ["com.apple.menuextra.battery"] = "battery.75percent",
  ["com.apple.menuextra.controlcenter"] = "switch.2",
  ["com.apple.menuextra.clock"] = "clock",
  ["com.apple.menuextra.bluetooth"] = "dot.radiowaves.left.and.right",
  ["com.apple.menuextra.sound"] = "speaker.wave.2.fill",
  ["com.apple.menuextra.focusmode"] = "moon.fill",
  ["com.apple.menuextra.display"] = "display",
  ["com.apple.menuextra.airdrop"] = "airplayaudio",
  ["com.apple.menuextra.textinput"] = "keyboard",
  ["com.apple.menuextra.siri"] = "mic.circle",
  ["com.apple.menuextra.spotlight"] = "magnifyingglass",
  ["com.apple.menuextra.timemachine"] = "clock.arrow.circlepath",
  ["com.apple.menuextra.vpn"] = "network.badge.shield.half.filled",
}

local lastJSON, lastPush, timer, appWatcher, pending = nil, 0, nil, nil, nil
local known = {}                   -- keys from the last snapshot; URL presses must match one

local function attr(el, name)
  local ok, v = pcall(el.attributeValue, el, name)
  if not ok then return nil end
  -- Child elements do not inherit the app element's messaging timeout; bound each one.
  if type(v) == "userdata" and v.setTimeout then pcall(v.setTimeout, v, AX_TIMEOUT) end
  if type(v) == "table" then
    for _, c in ipairs(v) do
      if type(c) == "userdata" and c.setTimeout then pcall(c.setTimeout, c, AX_TIMEOUT) end
    end
  end
  return v
end

local function str(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function bounded(el)
  pcall(el.setTimeout, el, AX_TIMEOUT)
  return el
end

-- Owner pids of status items, in on-screen order, from MenuBarAgent's menu-bar window.
local function hostedPids()
  local agents = hs.application.applicationsForBundleID("com.apple.MenuBarAgent")
  local agent = agents and agents[1]
  if not agent then return nil end
  local root = bounded(hs.axuielement.applicationElement(agent))
  local pids, seen = {}, {}
  for _, win in ipairs(attr(root, "AXWindows") or {}) do
    for _, group in ipairs(attr(win, "AXChildren") or {}) do
      for _, item in ipairs(attr(group, "AXChildren") or {}) do
        local pos = attr(item, "AXPosition")
        local ok, pid = pcall(item.pid, item)
        if ok and pid and pos and not seen[pid] then
          seen[pid] = true
          pids[#pids + 1] = pid
        end
      end
    end
  end
  return pids
end

-- AXExtrasMenuBar children of one app, as { element, record } sorted left to right.
local function extrasOf(app)
  local el = bounded(hs.axuielement.applicationElement(app))
  local bar = attr(el, "AXExtrasMenuBar")
  if not bar then return {} end
  local out = {}
  for _, child in ipairs(attr(bar, "AXChildren") or {}) do
    -- MenuBarAgent wraps Apple items: AXGroup(AXHostingView) -> AXMenuBarItem.
    local item = child
    if attr(child, "AXRole") == "AXGroup" then
      local kids = attr(child, "AXChildren") or {}
      item = kids[1] or child
    end
    local pos = attr(item, "AXPosition") or { x = 0, y = 0 }
    local size = attr(item, "AXSize") or { w = 0, h = 0 }
    out[#out + 1] = { el = item, x = pos.x or 0, y = pos.y or 0, w = size.w or 0, h = size.h or 0 }
  end
  table.sort(out, function(a, b) return a.x < b.x end)
  return out
end

local function candidateApps()
  local pids = hostedPids()
  local apps = {}
  if pids and #pids > 0 then
    for _, pid in ipairs(pids) do
      local app = hs.application.applicationForPID(pid)
      if app then apps[#apps + 1] = app end
    end
  else
    apps = hs.application.runningApplications()
  end
  return apps
end

-- Full snapshot: list of plain records (JSON-safe).
function M.snapshot()
  local items = {}
  for _, app in ipairs(candidateApps()) do
    local bundle = app:bundleID() or ("pid." .. app:pid())
    if not M.exclude[bundle] then
      for n, e in ipairs(extrasOf(app)) do
        local id = str(attr(e.el, "AXIdentifier"))
        if not (id and M.exclude[id]) then
          local actions = {}
          local okA, names = pcall(e.el.actionNames, e.el)
          for _, a in ipairs(okA and names or {}) do actions[a] = true end
          local desc = str(attr(e.el, "AXDescription"))
          local title = str(attr(e.el, "AXTitle"))
          local value = attr(e.el, "AXValue")
          local ov = M.iconOverride[bundle] or {}
          items[#items + 1] = {
            k = bundle .. "@" .. n,
            b = bundle,
            n = app:name() or bundle,
            d = desc,
            t = (title and title ~= "menu") and title:sub(1, 24) or nil,
            v = (type(value) == "string" and value ~= "") and value:sub(1, 16) or nil,
            id = id and not id:match("^_NS:") and id or nil,
            s = ov.s or (id and APPLE_SYMBOLS[id]) or nil,
            i = ov.i,
            x = math.floor(e.x),
            w = math.floor(e.w),
            menu = actions.AXShowMenu or nil,
          }
        end
      end
    end
  end
  table.sort(items, function(a, b) return a.x < b.x end)
  return items
end

local function publish(items, force)
  local text = hs.json.encode({ v = 1, items = items })
  if not text then return end
  local now = hs.timer.secondsSinceEpoch()
  if text == lastJSON and not force and (now - lastPush) < FORCE_EVERY then return end
  lastJSON, lastPush = text, now
  local task = hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("tray: shell set failed (%s): %s", tostring(code), tostring(err):sub(1, 200)) end
  end, { "shell", "set", VAR, text })
  if task then task:start() end
end

function M.refresh(force)
  local ok, items = pcall(M.snapshot)
  if not ok then
    log.e("tray: snapshot failed: %s", tostring(items))
    return
  end
  -- Positions change whenever any item resizes (clock ticks, battery %); publish only
  -- what the widget renders so that does not cause a push every refresh.
  known = {}
  for _, it in ipairs(items) do it.x = nil; it.w = nil; known[it.k] = true end
  publish(items, force)
end

local function refreshSoon(delay)
  if pending then pending:stop() end
  pending = hs.timer.doAfter(delay or 1.5, function() pending = nil; M.refresh(lastJSON == nil) end)
end

-- Re-resolve one key to a live AX element (positions and elements go stale).
local function resolve(key)
  local bundle, n = tostring(key):match("^(.-)@(%d+)$")
  if not bundle then return nil end
  n = tonumber(n)
  for _, app in ipairs(hs.application.applicationsForBundleID(bundle) or {}) do
    local list = extrasOf(app)
    if list[n] then return list[n].el, app, list[n] end
  end
  return nil
end

-- Did the press open anything? Closed NSMenus report size 0x0; an open one has a size.
local function menuOpen(el, app)
  for _, child in ipairs(attr(el, "AXChildren") or {}) do
    if attr(child, "AXRole") == "AXMenu" then
      local s = attr(child, "AXSize")
      if s and (s.w or 0) > 0 and (s.h or 0) > 0 then return true end
    end
  end
  -- Popover / panel style extras (SwiftUI MenuBarExtra .window, NSPopover) show a window.
  local appEl = bounded(hs.axuielement.applicationElement(app))
  for _, w in ipairs(attr(appEl, "AXWindows") or {}) do
    local s = attr(w, "AXSize")
    if s and (s.h or 0) > 40 then return true end
  end
  return false
end

-- how: "press" (left click) or "menu" (right click -> AXShowMenu when offered)
function M.activate(key, how)
  -- hammerspoon://omarchy can be opened by any local app or web page: only act on keys the
  -- last snapshot published, and only ever AXPress / AXShowMenu (never a shell command).
  if type(key) ~= "string" or not known[key] then
    log.w("tray: ignoring unknown key %s", tostring(key):sub(1, 80))
    return false
  end
  if key:match("^org%.hammerspoon%.Hammerspoon@") then
    require("omarchy.actions").run(M.selfAction)
    return true
  end
  local el, app, info = resolve(key)
  if not el then
    log.w("tray: %s not found", tostring(key))
    refreshSoon(0.2)
    return false
  end
  local action = "AXPress"
  if how == "menu" then
    local okA, names = pcall(el.actionNames, el)
    for _, a in ipairs(okA and names or {}) do if a == "AXShowMenu" then action = a end end
  end
  local ok, err = pcall(el.performAction, el, action)
  log.i("tray: %s %s -> %s (item at x=%s y=%s)", tostring(key), action, ok and "ok" or tostring(err),
    tostring(info and info.x), tostring(info and info.y))
  hs.timer.doAfter(VERIFY_AFTER, function()
    local opened = menuOpen(el, app)
    if opened then return end
    -- Some tray icons (e.g. Plaud, Electron) only react to a real mouse click, which cannot reach
    -- an item in the auto-hidden menu bar. Fall back to the app itself: `open -b` sends a
    -- reopen event, which shows the main window of most menu-bar apps.
    local bundle = app and app:bundleID()
    log.w("tray: %s pressed but no menu/window detected; opening %s", tostring(key), tostring(bundle))
    if bundle and not M.noAppFallback[bundle] then
      hs.task.new("/usr/bin/open", nil, { "-b", bundle }):start()
    end
  end)
  return ok
end

function M.start()
  M.stop()
  timer = hs.timer.doEvery(REFRESH_EVERY, M.refresh)
  appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.launched or event == hs.application.watcher.terminated then
      if app and app:bundleID() == OMNIWM then
        lastJSON = nil   -- OmniWM restarted: its vars are gone, push again once it is up
        refreshSoon(4.0)
      else
        refreshSoon(2.0) -- status items appear a moment after launch
      end
    end
  end)
  appWatcher:start()
  refreshSoon(0.5)
  return M
end

function M.stop()
  if timer then timer:stop(); timer = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  if pending then pending:stop(); pending = nil end
end

return M
