-- omarchy.dock: port of the Omarchy 4.5 shell plugin `omarchy.dock` (app dock + app grid).
--
-- Omarchy shows a small, transparent icon strip along a screen edge on *floating*
-- workspaces: an "all apps" button (a 3x3 grid of squares), then pinned apps in pin order,
-- then running apps that are not pinned. Pinned apps that are not running are drawn at 70 %
-- opacity, a launching app pulses until it opens a window (10 s at most), a hovered icon pops
-- out 1.15x away from the edge. Click: bring the app's next window forward (launch it when it
-- has none); middle click: launch again; right click: New Window / Keep in Dock /
-- Remove from Dock / Quit. Right click on the apps button: position (top/bottom/left/right)
-- and Auto-hide. Icons can be dragged along the dock to reorder (which pins them).
-- The app grid (Super+Alt+Space, ShellIpc `omarchy.dock apps`) is a full-screen scrim with a
-- card of every app: type to filter, arrows to move, Return to launch, Esc to close,
-- right click for Open / Keep in Dock.
--
-- macOS has no floating-workspace layout (OmniWM 0.8 workspaces are niri or dwindle), so the
-- dock is shown and hidden explicitly (dock.toggle / dock.show / dock.hide).
--
-- Here:
--   * the strip is an hs.canvas at dock level with clickActivating(false): clicking it never
--     takes focus from the app you are in (the EMR included);
--   * the grid is a borderless hs.webview like omarchy/picker.lua;
--   * apps are launched with /usr/bin/open -b <bundle id>, where the id must come from this
--     module's own lists (installed apps it scanned, pins, running apps). Nothing from a URL
--     ever reaches a command line.
-- Window titles are never read. Pins, position, auto-hide and shown/hidden are saved in
-- ~/.local/state/omarchy-mac/dock.json (bundle ids and settings only).
local M = { id = "dock" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local HOME = os.getenv("HOME") or ""
local OPEN = "/usr/bin/open"
local STATE_DIR = HOME .. "/.local/state/omarchy-mac"
local STATE_FILE = STATE_DIR .. "/dock.json"
local UCC = "omarchy_dock"

---------------------------------------------------------------- geometry (Omarchy Style)
local GAP = 3                 -- Style.spacing.xs: dock <-> screen edge, dock <-> menu
local ICON = 36               -- round(36 * Style.fontScale)
local INSET = 6               -- Style.spacing.md
local SLOT = ICON + INSET * 2 -- square slot per app
local POP = 1.15              -- hover / lifted scale
local IDLE = 0.7              -- pinned, not running
local ROW_H = 28              -- Style.spacing.popupRowHeight
local MENU_PAD = 4            -- Style.spacing.sm
local MENU_BORDER = 2
local MENU_MIN_W = 140        -- Style.space(140)
local PAD_X = 10              -- Style.spacing.controlPaddingX
local MENU_FONT_SIZE = 12     -- Style.font.body
local EDGE_DEPTH = GAP + 2    -- auto-hide trigger strip (gap + Style.spacing.xxs)
local DRAG_START = 6          -- Style.space(6)
local LAUNCH_TIMEOUT = 10     -- seconds a launching icon may pulse
local PULSE_EVERY = 0.5       -- Omarchy: 500 ms each way
local HIDE_GRACE = 0.15       -- Omarchy hideTimer
local MENU_GRACE = 0.6        -- pointer away from the dock closes its menu

local POSITIONS = { top = true, bottom = true, left = true, right = true }

-- Omarchy's default pins (Files, browser, terminal, calculator, writer, ...) mapped to Mac apps.
local DEFAULT_PINS = {
  "com.apple.finder", "com.google.Chrome", "com.mitchellh.ghostty", "com.apple.calculator", "com.apple.TextEdit",
}

local APP_DIRS = {
  "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
  HOME .. "/Applications",
}

---------------------------------------------------------------- state
local cfg = { pinned = nil, position = "bottom", autohide = false, shown = false }
local order = {}        -- session order (bundle ids), set when the user moves an app (DockModel order)
local seen = {}         -- running, unpinned apps in the order they were first seen
local launches = {}     -- bid -> { at = seconds, windows = n }
local items = {}        -- current dock items: { bid, pinned, running }
local hoverSlot = nil   -- 0 = apps button, i = items[i]
local hoverRow = nil
local menu = nil        -- { kind = "app"|"settings", slot = n, bid = ?, rows = {...} }
local press = nil       -- { slot, x, y, right, middle }
local drag = nil        -- { from, offset, to }
local revealed = false
local pulseOn = true
local geom = nil        -- last layout (canvas frame + rects, in canvas coordinates)
local dirty = true      -- items need rebuilding (apps launched/quit, pins or order changed)

local canvas, edge, appWatcher, screenWatcher, pulseTimer, hideTimer, menuTimer, saveTimer
local iconCache = {}    -- bid -> hs.image

local function clamp(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end
local function round(v) return math.floor(v + 0.5) end

local function isBundleId(s)
  return type(s) == "string" and #s <= 255 and s:match("^[%w%-]+[%w%.%-]*$") ~= nil and s:find("%.") ~= nil
end

local function installed(bid)
  local ok, path = pcall(hs.application.pathForBundleID, bid)
  return ok and path ~= nil and path ~= ""
end

---------------------------------------------------------------- persistence
local function save()
  if saveTimer then saveTimer:stop() end
  saveTimer = hs.timer.doAfter(0.3, function()
    saveTimer = nil
    pcall(function()
      if hs.fs.attributes(STATE_DIR, "mode") ~= "directory" then
        local acc = ""
        for part in STATE_DIR:gmatch("[^/]+") do
          acc = acc .. "/" .. part
          if hs.fs.attributes(acc, "mode") ~= "directory" then hs.fs.mkdir(acc) end
        end
      end
      hs.json.write({ pinned = cfg.pinned, position = cfg.position, autohide = cfg.autohide, shown = cfg.shown },
        STATE_FILE, true, true)
    end)
  end)
end

local function loadSettings()
  local ok, data = pcall(hs.json.read, STATE_FILE)
  if ok and type(data) == "table" then
    if type(data.pinned) == "table" then
      local pins, dup = {}, {}
      for _, bid in ipairs(data.pinned) do
        if isBundleId(bid) and not dup[bid] and #pins < 64 then pins[#pins + 1] = bid dup[bid] = true end
      end
      cfg.pinned = pins
    end
    if POSITIONS[data.position] then cfg.position = data.position end
    cfg.autohide = data.autohide == true
    cfg.shown = data.shown == true
  end
  if not cfg.pinned then
    cfg.pinned = {}
    for _, bid in ipairs(DEFAULT_PINS) do cfg.pinned[#cfg.pinned + 1] = bid end
  end
end

local function isPinned(bid)
  for _, p in ipairs(cfg.pinned) do if p == bid then return true end end
  return false
end

---------------------------------------------------------------- the model (DockModel.js)
local function regularApps()
  local out, byBid = {}, {}
  local ok, apps = pcall(hs.application.runningApplications)
  if not ok or type(apps) ~= "table" then return out, byBid end
  for _, app in ipairs(apps) do
    local okK, kind = pcall(function() return app:kind() end)
    local okB, bid = pcall(function() return app:bundleID() end)
    if okK and kind == 1 and okB and isBundleId(bid) and not byBid[bid] then
      byBid[bid] = app
      out[#out + 1] = bid
    end
  end
  return out, byBid
end

-- orderItems(): the session order first, then whatever it does not know yet.
local function orderItems(list)
  local byKey, result, placed = {}, {}, {}
  for _, it in ipairs(list) do byKey[it.bid] = it end
  for _, key in ipairs(order) do
    if byKey[key] and not placed[key] then result[#result + 1] = byKey[key] placed[key] = true end
  end
  for _, it in ipairs(list) do
    if not placed[it.bid] then result[#result + 1] = it end
  end
  return result
end

local function buildItems()
  local running, byBid = regularApps()
  -- keep `seen` in first-seen order, dropping apps that quit
  local still = {}
  for _, bid in ipairs(seen) do if byBid[bid] then still[#still + 1] = bid end end
  local known = {}
  for _, bid in ipairs(still) do known[bid] = true end
  for _, bid in ipairs(running) do if not known[bid] then still[#still + 1] = bid known[bid] = true end end
  seen = still

  local list, have = {}, {}
  for _, bid in ipairs(cfg.pinned) do
    -- A pinned app that is not installed has nothing to launch: left out until it is.
    if not have[bid] and (byBid[bid] or installed(bid)) then
      list[#list + 1] = { bid = bid, pinned = true, running = byBid[bid] ~= nil }
      have[bid] = true
    end
  end
  for _, bid in ipairs(seen) do
    if not have[bid] then
      list[#list + 1] = { bid = bid, pinned = false, running = true }
      have[bid] = true
    end
  end
  items = orderItems(list)
  dirty = false
  return byBid
end

local function shownKeys()
  local keys = {}
  for i, it in ipairs(items) do keys[i] = it.bid end
  return keys
end

-- orderWithKeyAt(): the order with key moved to index (0-based, counted once it left its slot).
local function orderWithKeyAt(keys, key, index)
  local rest = {}
  for _, k in ipairs(keys) do if k ~= key then rest[#rest + 1] = k end end
  local at = clamp(index, 0, #rest)
  table.insert(rest, at + 1, key)
  return rest
end

-- pinsInOrder(): pinned apps in dock order, then pins the dock is not showing, as they were.
local function pinsInOrder(newOrder, pinnedSet, allPinned)
  local result, inOrder = {}, {}
  for _, k in ipairs(newOrder) do
    inOrder[k] = true
    if pinnedSet[k] then result[#result + 1] = k end
  end
  local inResult = {}
  for _, k in ipairs(result) do inResult[k] = true end
  for _, k in ipairs(allPinned) do
    if not inResult[k] and not inOrder[k] then result[#result + 1] = k end
  end
  return result
end

local render -- forward

local function placeAt(bid, index)
  if not bid then return end
  dirty = true
  order = orderWithKeyAt(shownKeys(), bid, index)
  local pinnedSet = {}
  for _, p in ipairs(cfg.pinned) do pinnedSet[p] = true end
  pinnedSet[bid] = true
  cfg.pinned = pinsInOrder(order, pinnedSet, cfg.pinned)
  save()
end

local function setPinned(bid, pinned)
  if not isBundleId(bid) then return end
  dirty = true
  if pinned then
    buildItems()
    placeAt(bid, #shownKeys())
  else
    local rest = {}
    for _, p in ipairs(cfg.pinned) do if p ~= bid then rest[#rest + 1] = p end end
    cfg.pinned = rest
    save()
  end
  if render then render() end
end

---------------------------------------------------------------- apps and windows
local function appFor(bid)
  local ok, list = pcall(hs.application.applicationsForBundleID, bid)
  if ok and type(list) == "table" then
    for _, app in ipairs(list) do
      local okK, kind = pcall(function() return app:kind() end)
      if okK and kind == 1 then return app end
    end
    return list[1]
  end
  return nil
end

local function standardWindows(app)
  local out = {}
  local ok, wins = pcall(function() return app:allWindows() end)
  if not ok or type(wins) ~= "table" then return out end
  for _, w in ipairs(wins) do
    local okS, std = pcall(function() return w:isStandard() end)
    if okS and std then out[#out + 1] = w end
  end
  return out
end

local function onAnyScreen(w)
  local ok, f = pcall(function() return w:frame() end)
  if not ok or not f then return false end
  for _, s in ipairs(hs.screen.allScreens()) do
    local sf = s:fullFrame()
    if f.x < sf.x + sf.w and f.x + f.w > sf.x and f.y < sf.y + sf.h and f.y + f.h > sf.y then return true end
  end
  return false
end

-- pickWindow(): windows in front of the user first, then minimized ones (they come back),
-- then the rest (OmniWM parks other workspaces' windows off screen). Clicking again while
-- one of them is focused moves on to the next in that order.
local function pickWindow(wins)
  if #wins == 0 then return nil end
  local ranked = {}
  for i, w in ipairs(wins) do
    local okM, minimized = pcall(function() return w:isMinimized() end)
    local r = (okM and minimized) and 1 or (onAnyScreen(w) and 0 or 2)
    ranked[#ranked + 1] = { w = w, r = r, i = i }
  end
  table.sort(ranked, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.i < b.i end)
  local focused = hs.window.focusedWindow()
  local okF, fid = pcall(function() return focused and focused:id() end)
  if not okF then fid = nil end
  for i, e in ipairs(ranked) do
    local okI, wid = pcall(function() return e.w:id() end)
    if fid and okI and wid == fid then return ranked[(i % #ranked) + 1].w end
  end
  return ranked[1].w
end

local function startPulse()
  if pulseTimer then return end
  pulseTimer = hs.timer.doEvery(PULSE_EVERY, function()
    pulseOn = not pulseOn
    -- settleLaunches(): a new window arrived, or the launch timed out
    local now = hs.timer.secondsSinceEpoch()
    local any = false
    for bid, l in pairs(launches) do
      local app = appFor(bid)
      local n = app and #standardWindows(app) or 0
      if n > l.windows or now - l.at > LAUNCH_TIMEOUT then launches[bid] = nil else any = true end
    end
    if not any then
      pulseTimer:stop()
      pulseTimer = nil
      pulseOn = true
    end
    if render then render() end
  end)
end

-- Launch (or re-open) an app by bundle id. Only ids from our own lists get here.
local function launch(bid)
  if not isBundleId(bid) then return end
  local app = appFor(bid)
  launches[bid] = { at = hs.timer.secondsSinceEpoch(), windows = app and #standardWindows(app) or 0 }
  startPulse()
  local ok = pcall(function()
    hs.task.new(OPEN, function(code)
      if code ~= 0 then
        launches[bid] = nil
        toast.warn("Could not open " .. bid)
        log.w("dock: open -b %s exited %s", bid, tostring(code))
      end
    end, { "-b", bid }):start()
  end)
  if not ok then launches[bid] = nil toast.warn("Could not open " .. bid) end
  if render then render() end
end

-- "New Window": the app's own File > New Window, else ask it to reopen.
local function newWindow(bid)
  local app = appFor(bid)
  if not app then return launch(bid) end
  local before = #standardWindows(app)
  local ok, done = pcall(function()
    return app:selectMenuItem({ "File", "New Window" }) or app:selectMenuItem("New Window")
  end)
  if ok and done then
    launches[bid] = { at = hs.timer.secondsSinceEpoch(), windows = before }
    startPulse()
    if render then render() end
    pcall(function() app:activate() end)
  else
    launch(bid)
  end
end

local function activate(bid)
  local app = appFor(bid)
  if not app then return launch(bid) end
  local wins = standardWindows(app)
  if #wins == 0 then return launch(bid) end   -- Omarchy: no windows -> launch
  local w = pickWindow(wins)
  local okM, minimized = pcall(function() return w:isMinimized() end)
  if okM and minimized then pcall(function() w:unminimize() end) end
  pcall(function() w:focus() end)
end

local function quit(bid)
  local app = appFor(bid)
  if app then pcall(function() app:kill() end) end
end

---------------------------------------------------------------- drawing
local function hex(role) return theme.hex(role) end
local function col(role, alpha) return theme.color(role, alpha) end

local menuFont
local function getMenuFont()
  if not menuFont then menuFont = theme.font or ".AppleSystemUIFont" end
  return menuFont
end

local function measure(text)
  local ok, sz = pcall(hs.drawing.getTextDrawingSize, text, { font = getMenuFont(), size = MENU_FONT_SIZE })
  if ok and sz and sz.w then return sz end
  return { w = #text * MENU_FONT_SIZE * 0.6, h = MENU_FONT_SIZE * 1.3 }
end

local function iconFor(bid)
  if iconCache[bid] == nil then
    local ok, img = pcall(hs.image.imageFromAppBundle, bid)
    iconCache[bid] = (ok and img) or false
  end
  return iconCache[bid] or nil
end

local function targetScreen()
  return hs.screen.mainScreen() or hs.screen.primaryScreen()
end

local function vertical() return cfg.position == "left" or cfg.position == "right" end

local function menuRows()
  if not menu then return {} end
  local rows = {}
  if menu.kind == "settings" then
    for _, p in ipairs({ { "top", "Top" }, { "bottom", "Bottom" }, { "left", "Left" }, { "right", "Right" } }) do
      local pos = p[1]
      rows[#rows + 1] = { label = p[2], checked = cfg.position == pos, fn = function() M.setPosition(pos) end }
    end
    rows[#rows + 1] = { label = "Auto-hide", checked = cfg.autohide, fn = function() M.setAutohide(not cfg.autohide) end }
  else
    local bid = menu.bid
    local it
    for _, x in ipairs(items) do if x.bid == bid then it = x end end
    if not it then return rows end
    if it.running then rows[#rows + 1] = { label = "New Window", fn = function() newWindow(bid) end } end
    rows[#rows + 1] = { label = it.pinned and "Remove from Dock" or "Keep in Dock",
      fn = function() setPinned(bid, not it.pinned) end }
    if it.running then rows[#rows + 1] = { label = "Quit", fn = function() quit(bid) end } end
  end
  return rows
end

-- Everything in screen coordinates first, then the canvas frame is their bounding box.
local function layout()
  local sf = targetScreen():frame()
  local count = #items + 1
  local len = count * SLOT
  local strip
  if cfg.position == "bottom" then
    strip = { x = sf.x + round((sf.w - len) / 2), y = sf.y + sf.h - GAP - SLOT, w = len, h = SLOT }
  elseif cfg.position == "top" then
    strip = { x = sf.x + round((sf.w - len) / 2), y = sf.y + GAP, w = len, h = SLOT }
  elseif cfg.position == "left" then
    strip = { x = sf.x + GAP, y = sf.y + round((sf.h - len) / 2), w = SLOT, h = len }
  else
    strip = { x = sf.x + sf.w - GAP - SLOT, y = sf.y + round((sf.h - len) / 2), w = SLOT, h = len }
  end
  local L = { sf = sf, strip = strip, slots = {}, rows = {} }
  for i = 0, count - 1 do
    local r
    if vertical() then r = { x = strip.x, y = strip.y + i * SLOT, w = SLOT, h = SLOT }
    else r = { x = strip.x + i * SLOT, y = strip.y, w = SLOT, h = SLOT } end
    L.slots[i] = r
  end
  local box = { x1 = strip.x - GAP, y1 = strip.y - GAP, x2 = strip.x + strip.w + GAP, y2 = strip.y + strip.h + GAP }
  local rows = menuRows()
  if menu and #rows > 0 and L.slots[menu.slot] then
    local widest = 0
    for _, row in ipairs(rows) do widest = math.max(widest, measure(row.label).w + PAD_X * 2 + 18) end
    local mw = math.max(MENU_MIN_W, math.ceil(widest)) + MENU_PAD * 2 + MENU_BORDER * 2
    local mh = #rows * ROW_H + MENU_PAD * 2 + MENU_BORDER * 2
    local s = L.slots[menu.slot]
    local mx, my
    if cfg.position == "left" then mx = strip.x + strip.w + GAP
    elseif cfg.position == "right" then mx = strip.x - GAP - mw
    else mx = clamp(s.x + s.w / 2 - mw / 2, sf.x + GAP, sf.x + sf.w - mw - GAP) end
    if cfg.position == "top" then my = strip.y + strip.h + GAP
    elseif cfg.position == "bottom" then my = strip.y - GAP - mh
    else my = clamp(s.y + s.h / 2 - mh / 2, sf.y + GAP, sf.y + sf.h - mh - GAP) end
    L.menu = { x = mx, y = my, w = mw, h = mh }
    for i, row in ipairs(rows) do
      L.rows[i] = { x = mx + MENU_BORDER + MENU_PAD, y = my + MENU_BORDER + MENU_PAD + (i - 1) * ROW_H,
        w = mw - (MENU_BORDER + MENU_PAD) * 2, h = ROW_H, row = row }
    end
    box.x1 = math.min(box.x1, mx) box.y1 = math.min(box.y1, my)
    box.x2 = math.max(box.x2, mx + mw) box.y2 = math.max(box.y2, my + mh)
  end
  L.frame = { x = box.x1, y = box.y1, w = box.x2 - box.x1, h = box.y2 - box.y1 }
  -- to canvas coordinates
  local ox, oy = L.frame.x, L.frame.y
  local function loc(r) return { x = r.x - ox, y = r.y - oy, w = r.w, h = r.h } end
  L.local_strip = loc(strip)
  L.local_slots = {}
  for i = 0, count - 1 do L.local_slots[i] = loc(L.slots[i]) end
  if L.menu then
    L.local_menu = loc(L.menu)
    L.local_rows = {}
    for i, r in ipairs(L.rows) do
      local lr = loc(r)
      lr.row = r.row
      L.local_rows[i] = lr
    end
  end
  return L
end

-- The icon pops away from the screen edge.
local function iconFrame(slot, scale, shift)
  local s = ICON * scale
  local cx, cy = slot.x + slot.w / 2, slot.y + slot.h / 2
  local x, y = cx - s / 2, cy - s / 2
  if cfg.position == "bottom" then y = slot.y + INSET + ICON - s
  elseif cfg.position == "top" then y = slot.y + INSET
  elseif cfg.position == "left" then x = slot.x + INSET
  else x = slot.x + INSET + ICON - s end
  if vertical() then y = y + shift else x = x + shift end
  return { x = x, y = y, w = s, h = s }
end

-- Where each slot is drawn while an icon is dragged: the dragged one follows the pointer,
-- the ones between step aside.
local function shiftFor(i)
  if not drag then return 0 end
  if i == drag.from then return drag.offset end
  if drag.from < i and i <= drag.to then return -SLOT end
  if drag.to <= i and i < drag.from then return SLOT end
  return 0
end

local function elements(L)
  local els = {}
  -- an (almost) invisible plate so the whole strip takes the pointer
  els[#els + 1] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 0.01 },
    frame = L.local_strip }
  -- apps button: 3x3 squares in the bar text colour
  local s0 = L.local_slots[0]
  local scale0 = (hoverSlot == 0 and not drag) and POP or 1
  local box = iconFrame(s0, scale0, 0)
  local sq = round(box.w * 0.22)
  local sp = round(box.w * 0.1)
  local total = sq * 3 + sp * 2
  local gx, gy = box.x + (box.w - total) / 2, box.y + (box.h - total) / 2
  local rad = math.max(1, round(sq * 0.2))
  for r = 0, 2 do
    for c = 0, 2 do
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col("foreground"),
        roundedRectRadii = { xRadius = rad, yRadius = rad },
        frame = { x = gx + c * (sq + sp), y = gy + r * (sq + sp), w = sq, h = sq } }
    end
  end
  -- app icons
  for i, it in ipairs(items) do
    local slot = L.local_slots[i]
    local img = iconFor(it.bid)
    local lifted = drag and drag.from == i
    local scale = (lifted or (hoverSlot == i and not drag)) and POP or 1
    local alpha = it.running and 1 or IDLE
    if launches[it.bid] then alpha = pulseOn and 1 or IDLE end
    local f = iconFrame(slot, scale, shiftFor(i))
    if img then
      els[#els + 1] = { type = "image", image = img, imageScaling = "scaleProportionally", imageAlpha = alpha, frame = f }
    else
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col("foreground", 0.2 * alpha), frame = f }
    end
  end
  -- menu
  if L.local_menu then
    local m = L.local_menu
    els[#els + 1] = { type = "rectangle", action = "strokeAndFill", fillColor = col("background"),
      strokeColor = col("accent"), strokeWidth = MENU_BORDER,
      frame = { x = m.x + MENU_BORDER / 2, y = m.y + MENU_BORDER / 2, w = m.w - MENU_BORDER, h = m.h - MENU_BORDER } }
    local th = measure("Ag").h
    for i, r in ipairs(L.local_rows) do
      if hoverRow == i then
        els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col("foreground", 0.08), frame = r }
      end
      els[#els + 1] = { type = "text", text = r.row.label, textFont = getMenuFont(), textSize = MENU_FONT_SIZE,
        textColor = col("foreground"), textLineBreak = "clip",
        frame = { x = r.x + PAD_X, y = r.y + (r.h - th) / 2, w = r.w - PAD_X * 2 - 14, h = th } }
      if r.row.checked then
        els[#els + 1] = { type = "text", text = "✓", textFont = getMenuFont(), textSize = MENU_FONT_SIZE,
          textColor = col("accent"), textAlignment = "right",
          frame = { x = r.x + r.w - PAD_X - 20, y = r.y + (r.h - th) / 2, w = 20, h = th } }
      end
    end
  end
  return els
end

local function hit(L, x, y)
  if L.local_rows then
    for i, r in ipairs(L.local_rows) do
      if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return "row", i end
    end
    local m = L.local_menu
    if x >= m.x and x < m.x + m.w and y >= m.y and y < m.y + m.h then return "menu", nil end
  end
  for i = 0, #items do
    local s = L.local_slots[i]
    if s and x >= s.x and x < s.x + s.w and y >= s.y and y < s.y + s.h then return "slot", i end
  end
  return nil, nil
end

local function tucked()
  return cfg.autohide and not (revealed or menu or drag or press)
end

local onMouse -- forward

local function ensureCanvas()
  if canvas then return end
  canvas = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
  canvas:level(hs.canvas.windowLevels.dock)
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  canvas:clickActivating(false)
  canvas:canvasMouseEvents(true, true, true, true)
  canvas:mouseCallback(function(c, msg, id, x, y)
    local ok, err = pcall(onMouse, msg, x, y)
    if not ok then log.e("dock: mouse handler failed: %s", tostring(err)) end
  end)
end

local function edgeFrame(L)
  local s = L.strip
  local sf = L.sf
  if cfg.position == "bottom" then return { x = s.x, y = sf.y + sf.h - EDGE_DEPTH, w = s.w, h = EDGE_DEPTH } end
  if cfg.position == "top" then return { x = s.x, y = sf.y, w = s.w, h = EDGE_DEPTH } end
  if cfg.position == "left" then return { x = sf.x, y = s.y, w = EDGE_DEPTH, h = s.h } end
  return { x = sf.x + sf.w - EDGE_DEPTH, y = s.y, w = EDGE_DEPTH, h = s.h }
end

local function ensureEdge(L)
  if not edge then
    edge = hs.canvas.new(edgeFrame(L))
    edge:level(hs.canvas.windowLevels.dock)
    edge:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
    edge:clickActivating(false)
    edge:canvasMouseEvents(false, false, true, false)
    edge[1] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 0.01 } }
    edge:mouseCallback(function(_, msg)
      if msg == "mouseEnter" then
        revealed = true
        if hideTimer then hideTimer:stop() hideTimer = nil end
        render()
      end
    end)
  else
    edge:frame(edgeFrame(L))
  end
end

render = function()
  if not cfg.shown then
    if canvas then canvas:hide() end
    if edge then edge:hide() end
    return
  end
  if dirty then buildItems() end
  local ok, err = pcall(function()
    local L = layout()
    geom = L
    ensureCanvas()
    canvas:frame(L.frame)
    canvas:replaceElements(elements(L))
    if cfg.autohide then
      ensureEdge(L)
      edge:show()
    elseif edge then
      edge:hide()
    end
    if tucked() then canvas:hide() else canvas:show() end
  end)
  if not ok then log.e("dock: could not draw: %s", tostring(err)) end
end

local function closeMenu()
  if menuTimer then menuTimer:stop() menuTimer = nil end
  menu = nil
  hoverRow = nil
end

local function scheduleHide()
  if hideTimer then hideTimer:stop() end
  hideTimer = hs.timer.doAfter(HIDE_GRACE, function()
    hideTimer = nil
    if not (menu or drag or press) and hoverSlot == nil then
      revealed = false
      render()
    end
  end)
end

local function alongOffset(x, y)
  if not press then return 0 end
  return vertical() and (y - press.y) or (x - press.x)
end

-- dropIndex(): its own slot moved by however many slots the pointer travelled.
local function dropIndex(from, offset)
  local count = #items
  if count <= 0 then return from end
  return clamp(from + round(offset / SLOT), 1, count)
end

onMouse = function(msg, x, y)
  local L = geom
  if not L then return end
  if msg == "mouseEnter" then
    if hideTimer then hideTimer:stop() hideTimer = nil end
    if menuTimer then menuTimer:stop() menuTimer = nil end
    return
  end
  if msg == "mouseExit" then
    hoverSlot, hoverRow = nil, nil
    if menu then
      if menuTimer then menuTimer:stop() end
      menuTimer = hs.timer.doAfter(MENU_GRACE, function()
        menuTimer = nil
        closeMenu()
        if cfg.autohide then scheduleHide() end
        render()
      end)
    elseif cfg.autohide then
      scheduleHide()
    end
    render()
    return
  end
  local kind, idx = hit(L, x, y)
  if msg == "mouseMove" then
    local newSlot = kind == "slot" and idx or nil
    local newRow = kind == "row" and idx or nil
    local changed = newSlot ~= hoverSlot or newRow ~= hoverRow
    hoverSlot, hoverRow = newSlot, newRow
    -- a press that wanders along the dock is a drag
    if press and press.slot and press.slot >= 1 and not press.right and not press.middle then
      local off = alongOffset(x, y)
      if drag or math.abs(off) >= DRAG_START then
        drag = drag or { from = press.slot }
        drag.offset = off
        drag.to = dropIndex(drag.from, off)
        closeMenu()
        changed = true
      end
    end
    if changed then render() end
    return
  end
  if msg == "mouseDown" then
    local ok, b = pcall(hs.eventtap.checkMouseButtons)
    b = (ok and type(b) == "table") and b or {}
    press = { slot = kind == "slot" and idx or nil, row = kind == "row" and idx or nil, x = x, y = y,
      right = (b.right or b[2]) and true or false, middle = (b.middle or b[3]) and true or false }
    return
  end
  if msg == "mouseUp" then
    local p = press
    press = nil
    if not p then return end
    -- a release away from where the press started, along the dock, is a drop
    if p.slot and p.slot >= 1 and not p.right and not p.middle then
      local off = alongOffset(x, y)
      if drag or math.abs(off) >= DRAG_START then
        local from = p.slot
        local to = dropIndex(from, (drag and drag.offset) or off)
        drag = nil
        if from ~= to and items[from] then placeAt(items[from].bid, to - 1) end
        render()
        return
      end
    end
    drag = nil
    if p.row then
      local r = L.local_rows and L.local_rows[p.row]
      if r and kind == "row" and idx == p.row then
        local fn = r.row.fn
        closeMenu()
        render()
        local okFn, err = pcall(fn)
        if not okFn then log.e("dock: menu row failed: %s", tostring(err)) end
        render()
      end
      return
    end
    if kind ~= "slot" or idx ~= p.slot then return end
    if idx == 0 then
      if p.right then
        menu = { kind = "settings", slot = 0 }
        render()
        return
      end
      closeMenu()
      render()
      M.openApps()
      return
    end
    local it = items[idx]
    if not it then return end
    if p.right then
      menu = { kind = "app", slot = idx, bid = it.bid }
      render()
      return
    end
    closeMenu()
    if p.middle then launch(it.bid) else activate(it.bid) end
    render()
  end
end

---------------------------------------------------------------- dock commands
function M.show()
  cfg.shown = true
  dirty = true
  save()
  render()
end

function M.hide()
  cfg.shown = false
  closeMenu()
  save()
  render()
end

function M.toggle()
  if cfg.shown then M.hide() else M.show() end
end

function M.setPosition(pos)
  if not POSITIONS[pos] then return end
  cfg.position = pos
  revealed = false
  save()
  render()
end

function M.setAutohide(on)
  cfg.autohide = on and true or false
  revealed = false
  if not cfg.autohide and edge then edge:hide() end
  save()
  render()
end

---------------------------------------------------------------- the app grid (AppGrid.qml)
local view, ucc
local grid = { apps = {}, byBid = {}, scanned = 0, prevWin = nil, iconQueue = nil, iconTimer = nil, launched = false }
local SCAN_TTL = 30
local GRID_ICON_PX = 112

local function scanApps()
  local now = hs.timer.secondsSinceEpoch()
  if #grid.apps > 0 and now - grid.scanned < SCAN_TTL then return end
  local list, byBid = {}, {}
  local function addBundle(path, file)
    local ok, info = pcall(hs.application.infoForBundlePath, path)
    if not ok or type(info) ~= "table" then return end
    local bid = info.CFBundleIdentifier
    if not isBundleId(bid) or byBid[bid] then return end
    if info.LSUIElement == true or info.LSUIElement == "1" or info.LSBackgroundOnly == true then return end
    local name = file:gsub("%.app$", "")
    local app = { bid = bid, name = name }
    byBid[bid] = app
    list[#list + 1] = app
  end
  local function scan(dir, depth)
    local okDir, iter, obj = pcall(hs.fs.dir, dir)
    if not okDir or not iter then return end
    for file in iter, obj do
      if file:sub(1, 1) ~= "." then
        local path = dir .. "/" .. file
        if file:match("%.app$") then
          addBundle(path, file)
        elseif depth > 0 and hs.fs.attributes(path, "mode") == "directory" then
          scan(path, depth - 1)
        end
      end
    end
  end
  for _, dir in ipairs(APP_DIRS) do scan(dir, dir == "/Applications" and 1 or 0) end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  grid.apps, grid.byBid, grid.scanned = list, byBid, now
end

local gridIconCache = {} -- bid -> data URL (PNG)

local function gridIcon(bid)
  if gridIconCache[bid] ~= nil then return gridIconCache[bid] or nil end
  local ok, url = pcall(function()
    local img = hs.image.imageFromAppBundle(bid)
    if not img then return nil end
    local small = img:setSize({ w = GRID_ICON_PX, h = GRID_ICON_PX }, true) or img
    return small:encodeAsURLString(false, "PNG")
  end)
  gridIconCache[bid] = (ok and type(url) == "string" and url:sub(1, 11) == "data:image/") and url or false
  return gridIconCache[bid] or nil
end

local function js(code)
  if not view then return end
  pcall(function() view:evaluateJavaScript(code) end)
end

local function stopIconFeed()
  if grid.iconTimer then grid.iconTimer:stop() grid.iconTimer = nil end
  grid.iconQueue = nil
end

-- Icons arrive in small batches after the grid is on screen, so opening it never stalls.
local function feedIcons()
  stopIconFeed()
  local queue = {}
  for i, app in ipairs(grid.apps) do
    if gridIconCache[app.bid] == nil then queue[#queue + 1] = i end
  end
  if #queue == 0 then return end
  grid.iconQueue = queue
  local pos = 1
  local function step()
    grid.iconTimer = nil
    if not view or grid.iconQueue ~= queue then return end
    local batch = {}
    local stop = math.min(#queue, pos + 11)
    for k = pos, stop do
      local i = queue[k]
      local app = grid.apps[i]
      local url = app and gridIcon(app.bid)
      if url then batch[#batch + 1] = { i = i, u = url } end
    end
    pos = stop + 1
    if #batch > 0 then
      local okEnc, text = pcall(hs.json.encode, batch)
      if okEnc and text then js("window.dockIcons(" .. text .. ")") end
    end
    if pos <= #queue then grid.iconTimer = hs.timer.doAfter(0.02, step) else grid.iconQueue = nil end
  end
  grid.iconTimer = hs.timer.doAfter(0.05, step)
end

local function gridData()
  local rows = {}
  for i, app in ipairs(grid.apps) do
    rows[i] = { n = app.name, p = isPinned(app.bid), u = gridIconCache[app.bid] or nil }
  end
  local ok, text = pcall(hs.json.encode, rows)
  if not ok or not text then text = "[]" end
  -- safe inside <script>: no "</script>" breakout, no stray line separators
  return (text:gsub("</", "<\\/"):gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029"))
end

local function gridPage(frame)
  local c = function(n) return theme.hex(n) end
  local cellW = math.floor(56 * 2.2 + 0.5)
  local inset = 18 + 2
  local cardW = math.min(frame.w - 80, 7 * cellW + inset * 2)
  local cols = math.max(1, math.floor((cardW - inset * 2) / cellW))
  local gridW = cols * cellW
  return [=[<!doctype html><html><head><meta charset="utf-8"><style>
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden;cursor:default;-webkit-user-select:none;user-select:none;
  font-family:"JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace}
body{background:]=] .. c("background") .. [=[80;display:flex;align-items:center;justify-content:center}
#card{width:]=] .. cardW .. [=[px;max-height:calc(100% - 80px);height:518px;background:]=] .. c("background") .. [=[;
  border:2px solid ]=] .. c("foreground") .. [=[;padding:18px;display:flex;flex-direction:column;gap:10px;position:relative}
#head{width:]=] .. (gridW - 8) .. [=[px;margin:0 auto;height:36px;flex:none;background:]=] .. c("foreground") .. [=[0f;
  display:flex;align-items:center;padding:0 10px;font-size:16px;color:]=] .. c("foreground") .. [=[;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#head.empty{opacity:.58}
#grid{width:]=] .. gridW .. [=[px;margin:0 auto;flex:1;overflow-y:auto;display:grid;
  grid-template-columns:repeat(]=] .. cols .. [=[,]=] .. cellW .. [=[px);grid-auto-rows:108px;align-content:start}
#grid::-webkit-scrollbar{display:none}
.c{display:flex;flex-direction:column;align-items:center;padding-top:8px;cursor:pointer}
.c .i{width:56px;height:56px;flex:none;display:flex;align-items:center;justify-content:center}
.c img{width:56px;height:56px;object-fit:contain}
.c .l{margin-top:6px;max-width:]=] .. (cellW - 20) .. [=[px;padding:3px 6px;font-size:12px;line-height:15px;text-align:center;
  color:]=] .. c("foreground") .. [=[;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;
  word-break:break-word}
.c.sel .l{background:]=] .. c("foreground") .. [=[14;color:]=] .. c("accent") .. [=[}
#none{position:absolute;left:0;right:0;top:50%;text-align:center;font-size:14px;color:]=] .. c("foreground") .. [=[;opacity:.7;display:none}
#menu{position:fixed;display:none;min-width:168px;background:]=] .. c("background") .. [=[;border:2px solid ]=] .. c("accent") .. [=[;padding:4px;z-index:5}
#menu div{height:28px;line-height:28px;padding:0 10px;font-size:12px;color:]=] .. c("foreground") .. [=[;cursor:pointer;white-space:nowrap}
#menu div:hover{background:]=] .. c("foreground") .. [=[14}
</style></head><body>
<div id="card"><div id="head" class="empty">Search apps…</div><div id="grid"></div><div id="none"></div></div>
<div id="menu"><div id="mOpen">Open</div><div id="mPin"></div></div>
<script>
const APPS = ]=] .. gridData() .. [=[;
const send=(m)=>window.webkit.messageHandlers.]=] .. UCC .. [=[.postMessage(m);
const grid=document.getElementById('grid'), head=document.getElementById('head'), none=document.getElementById('none');
const menu=document.getElementById('menu'), mPin=document.getElementById('mPin');
let filter='', shown=[], sel=0, menuFor=-1;
const cells=APPS.map((a,i)=>{const d=document.createElement('div');d.className='c';
  const ic=document.createElement('div');ic.className='i';if(a.u){const im=document.createElement('img');im.src=a.u;ic.appendChild(im)}
  const l=document.createElement('div');l.className='l';l.textContent=a.n;d.appendChild(ic);d.appendChild(l);
  d.addEventListener('mouseenter',()=>{const k=shown.indexOf(i);if(k>=0){sel=k;mark(false)}});
  d.addEventListener('click',e=>{e.stopPropagation();if(menuFor>=0){closeMenu();return}send({launch:i+1})});
  d.addEventListener('contextmenu',e=>{e.preventDefault();e.stopPropagation();openMenu(i,e.clientX,e.clientY)});
  return d});
window.dockIcons=(list)=>{for(const x of list){const a=APPS[x.i-1];if(!a)continue;a.u=x.u;const ic=cells[x.i-1].firstChild;
  if(!ic.firstChild){const im=document.createElement('img');im.src=x.u;ic.appendChild(im)}}};
function rank(n,q){n=n.toLowerCase();if(!q)return 0;if(n.startsWith(q))return 1;
  if(n.split(/[\s\-_.]+/).some(w=>w.startsWith(q)))return 2;if(n.includes(q))return 3;return 0}
function rebuild(){const q=filter.toLowerCase();const r=[];APPS.forEach((a,i)=>{const k=rank(a.n,q);if(!q||k>0)r.push([k,i])});
  r.sort((a,b)=>a[0]-b[0]||a[1]-b[1]);shown=r.map(x=>x[1]);grid.replaceChildren(...shown.map(i=>cells[i]));
  sel=Math.max(0,Math.min(sel,shown.length-1));head.textContent=filter||'Search apps…';head.className=filter?'':'empty';
  none.textContent='No apps match “'+filter+'”';none.style.display=shown.length?'none':'block';mark(true)}
function cols(){const c=getComputedStyle(grid).gridTemplateColumns.split(' ').length;return Math.max(1,c)}
function mark(scroll){cells.forEach(c=>c.classList.remove('sel'));if(!shown.length)return;const c=cells[shown[sel]];c.classList.add('sel');
  if(scroll)c.scrollIntoView({block:'nearest'})}
function move(d){if(!shown.length)return;sel=Math.max(0,Math.min(shown.length-1,sel+d));mark(true)}
function openMenu(i,x,y){menuFor=i;mPin.textContent=APPS[i].p?'Remove from Dock':'Keep in Dock';menu.style.display='block';
  const w=menu.offsetWidth,h=menu.offsetHeight;menu.style.left=Math.min(x,innerWidth-w-5)+'px';menu.style.top=Math.min(y,innerHeight-h-5)+'px'}
function closeMenu(){menuFor=-1;menu.style.display='none'}
document.getElementById('mOpen').addEventListener('click',e=>{e.stopPropagation();const i=menuFor;closeMenu();if(i>=0)send({launch:i+1})});
mPin.addEventListener('click',e=>{e.stopPropagation();const i=menuFor;closeMenu();if(i>=0){APPS[i].p=!APPS[i].p;send({pin:i+1,on:APPS[i].p})}});
document.getElementById('card').addEventListener('click',e=>{e.stopPropagation();closeMenu()});
document.body.addEventListener('click',()=>{if(menuFor>=0)closeMenu();else send({close:true})});
document.body.addEventListener('contextmenu',e=>{e.preventDefault();if(menuFor>=0)closeMenu();else send({close:true})});
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){e.preventDefault();if(menuFor>=0)closeMenu();else if(filter){filter='';sel=0;rebuild()}else send({close:true});return}
  if(e.metaKey||e.ctrlKey)return;
  if(e.key==='Enter'){e.preventDefault();if(shown.length)send({launch:shown[sel]+1});return}
  if(e.key==='ArrowLeft'){e.preventDefault();move(-1);return}
  if(e.key==='ArrowRight'){e.preventDefault();move(1);return}
  if(e.key==='ArrowUp'){e.preventDefault();move(-cols());return}
  if(e.key==='ArrowDown'){e.preventDefault();move(cols());return}
  if(e.key==='Backspace'){e.preventDefault();if(filter){filter=filter.slice(0,-1);sel=0;rebuild()}return}
  if(e.key.length===1&&e.key>=' '&&filter.length<64){e.preventDefault();filter+=e.key;sel=0;rebuild()}});
window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({close:true})},150));
rebuild();
</script></body></html>]=]
end

function M.closeApps(refocus)
  stopIconFeed()
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
  local prev = grid.prevWin
  grid.prevWin = nil
  if refocus and prev then pcall(function() prev:focus() end) end
end

local function onGridMessage(msg)
  local body = msg and msg.body
  if type(body) ~= "table" then return end
  local function app(i)
    local n = tonumber(i)
    if not n or n ~= math.floor(n) then return nil end
    return grid.apps[n]
  end
  if body.launch ~= nil then
    local a = app(body.launch)
    M.closeApps(false)
    if a then launch(a.bid) end
  elseif body.pin ~= nil then
    local a = app(body.pin)
    if a then setPinned(a.bid, body.on == true) end
  elseif body.close then
    M.closeApps(true)
  end
end

function M.openApps()
  if view then return end
  scanApps()
  if #grid.apps == 0 then return toast.warn("No apps found") end
  grid.prevWin = hs.window.frontmostWindow()
  if not ucc then
    ucc = hs.webview.usercontent.new(UCC)
    ucc:setCallback(function(msg)
      local ok, err = pcall(onGridMessage, msg)
      if not ok then log.e("dock: app grid message failed: %s", tostring(err)) end
    end)
  end
  local screen = hs.mouse.getCurrentScreen() or targetScreen()
  local frame = screen:fullFrame()
  local ok, err = pcall(function()
    view = hs.webview.new(frame, { developerExtrasEnabled = false }, ucc)
      :windowStyle({ "borderless" })
      :transparent(true)
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.modalPanel)
      :shadow(false)
      :closeOnEscape(false)
      :deleteOnClose(true)
      :html(gridPage(frame))
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
  if not ok then
    log.e("dock: could not open the app grid: %s", tostring(err))
    M.closeApps(false)
    return
  end
  feedIcons()
end

function M.toggleApps()
  if view then M.closeApps(true) else M.openApps() end
end

---------------------------------------------------------------- actions / lifecycle
M.actions = {
  ["dock.apps"] = { fn = function() M.toggleApps() end, desc = "Show/hide the app grid (all apps)" },
  ["dock.toggle"] = { fn = function() M.toggle() end, desc = "Show/hide the Omarchy dock" },
  ["dock.show"] = { fn = function() M.show() end, desc = "Show the Omarchy dock" },
  ["dock.hide"] = { fn = function() M.hide() end, desc = "Hide the Omarchy dock" },
  ["dock.position"] = { fn = function(x)
    local p = tostring(x or ""):lower():gsub("%s+", "")
    if not POSITIONS[p] then return toast.warn("Dock position must be top, bottom, left or right") end
    M.setPosition(p)
  end, desc = "Dock position (x = top|bottom|left|right)" },
  ["dock.autohide"] = { fn = function(x)
    local v = tostring(x or "toggle"):lower():gsub("%s+", "")
    if v == "on" then M.setAutohide(true)
    elseif v == "off" then M.setAutohide(false)
    elseif v == "toggle" or v == "" then M.setAutohide(not cfg.autohide)
    else return toast.warn("Dock auto-hide must be on, off or toggle") end
    toast.show(cfg.autohide and "Dock auto-hide turned on" or "Dock auto-hide turned off", 1.2)
  end, desc = "Dock auto-hide (x = on|off|toggle)" },
}

function M.start()
  M.stop()
  loadSettings()
  menuFont = nil
  appWatcher = hs.application.watcher.new(function(_, event)
    if event == hs.application.watcher.launched or event == hs.application.watcher.terminated then
      dirty = true
      hs.timer.doAfter(0.2, function() if cfg.shown then render() end end)
    end
  end)
  appWatcher:start()
  screenWatcher = hs.screen.watcher.new(function()
    hs.timer.doAfter(0.5, function() if cfg.shown then render() end end)
  end)
  screenWatcher:start()
  dirty = true
  if cfg.shown then hs.timer.doAfter(0.5, render) end
  return M
end

function M.stop()
  if appWatcher then appWatcher:stop() appWatcher = nil end
  if screenWatcher then screenWatcher:stop() screenWatcher = nil end
  if pulseTimer then pulseTimer:stop() pulseTimer = nil end
  if hideTimer then hideTimer:stop() hideTimer = nil end
  if menuTimer then menuTimer:stop() menuTimer = nil end
  if saveTimer then saveTimer:stop() saveTimer = nil end
  M.closeApps(false)
  if canvas then local c = canvas canvas = nil pcall(function() c:delete() end) end
  if edge then local e = edge edge = nil pcall(function() e:delete() end) end
  launches, menu, press, drag, hoverSlot, hoverRow, revealed, geom = {}, nil, nil, nil, nil, nil, false, nil
  iconCache = {}
end

return M
