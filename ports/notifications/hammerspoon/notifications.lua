-- omarchy.notifications: port of the Omarchy 4.5 shell plugin `omarchy.notifications`
-- (notification daemon: grouped stacks, inline actions, Do Not Disturb, history).
--
-- Omarchy owns org.freedesktop.Notifications and draws every app's notifications as cards in
-- a deck hanging from the top-right corner under the bar: 380 px cards (accent border, bold
-- summary, two body lines, a relative time that turns into ✕ on hover, a row of action
-- buttons), stacked per app with the cards behind peeking 10 px below the front one; hovering
-- opens the deck under the pointer and holds new cards back while you read. Low urgency lasts
-- 5 s, normal 8 s (up to 30 s if the sender asks), critical until dismissed. Do Not Disturb
-- silences cards (straight to history) except Omarchy's own action toasts and bare critical
-- alerts. Keybindings act on / dismiss the newest card, dismiss all, replay history, hand the
-- keyboard to the deck, and toggle Do Not Disturb.
--
-- macOS: reading other apps' notifications needs Full Disk Access, which this machine does not
-- grant. So this port is the daemon for omarchy-mac's OWN notifications: other Hammerspoon
-- modules post cards with
--     require("omarchy.ports.notifications").post{ summary = "...", body = "...", ... }
-- (there is deliberately no URL action that takes text: url.lua logs every URL argument).
-- Do Not Disturb silences these cards, and can drive a macOS Focus through two Shortcuts the
-- user creates (see PORT.md). Notification Center opens through the built-in
-- `notification-center` action.
--
-- Privacy: notification text lives in memory only (the deck and a 100-entry session history).
-- It is never logged, never written to disk and never sent to OmniShell (the bar only gets
-- counts and the Do Not Disturb flag). Only the Do Not Disturb flag is saved, in
-- ~/.local/state/omarchy-mac/notifications.json.
local M = { id = "notifications" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local HOME = os.getenv("HOME") or ""
local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local SHORTCUTS = "/usr/bin/shortcuts"
local STATE_DIR = HOME .. "/.local/state/omarchy-mac"
local STATE_FILE = STATE_DIR .. "/notifications.json"
local VAR = "omarchy_notifications"
-- Optional macOS Focus sync: Shortcuts the user makes with the "Set Focus" action.
local FOCUS_ON = "Omarchy Focus On"
local FOCUS_OFF = "Omarchy Focus Off"

---------------------------------------------------------------- geometry (Omarchy Style)
local W = 380                 -- Style.space(380)
local BORDER = 2              -- max(1, Style.space(2))
local PAD_X = 12              -- Style.space(12)
local PAD_Y_BODY = 10         -- contentPaddingY with a body
local PAD_Y = 7               -- without
local THUMB = 40              -- Style.space(40)
local THUMB_GAP = 12
local THUMB_GAP_COMPACT = 8
local COL_GAP = 3             -- Style.space(3)
local RIGHT_GAP = 8
local TITLE_SIZE = 14         -- Style.font.title (bold)
local BODY_SIZE = 14          -- Style.font.title
local STAMP_SIZE = 11         -- Style.font.bodySmall
local CLOSE_SIZE = 14         -- round(Style.font.caption * 1.44)
local DEED_SIZE = 12          -- Style.font.body
local LETTER_SIZE = 12
local GLYPH_BIG = 28          -- Style.font.displayLarge
local GLYPH_SMALL = 14        -- Style.font.icon
local RULE = 1
local SEG_H = 34              -- controlHeight 28 + Style.space(6)
local PEEK = 10               -- Layout.js
local SHRINK = 0.035
local VISIBLE = 3
local FADE = 0.55
local CARD_GAP = 6
local DECK_GAP = 12
local EDGE = 5                -- Style.gapsOut

local LOW_MS, NORMAL_MS, MAX_MS = 5000, 8000, 30000
local MAX_LIVE = 100
local HISTORY_LIMIT = 100
local REPLAY = 6
local HELD_MAX = 30           -- seconds a parked pointer may hold new cards back
local COLLAPSE_GRACE = 0.12
local KEYBOARD_IDLE = 10
local MAX_SUMMARY, MAX_BODY, MAX_LABEL, MAX_APP = 512, 4096, 64, 64
local MAX_ACTIONS = 9

local G_BELL = "\u{F009A}"    -- 󰂚 (history placeholder)
local G_BELL_OFF = "\u{F009B}" -- 󰂛 (Do Not Disturb)

---------------------------------------------------------------- state
local toasts = {}             -- on screen, newest first
local history = {}            -- session only, newest first
local held = {}               -- keys waiting while the deck is held open
local pending = {}            -- key -> row waiting in `held`
local seed = 0
local dnd = false
local focusShortcuts = false
local deckScreen = nil
local pointerIn, expanded, openDeck, hoverKey, hotPart = false, false, nil, nil, nil
local keyboard = { on = false, key = nil, modal = nil, idle = nil }
local press = nil
local last = nil              -- last JSON published to the bar
local canvas, clockTimer, collapseTimer, heldTimer, saveTimer
local geom = nil

local function now() return hs.timer.secondsSinceEpoch() end
local function clamp(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end
local function round(v) return math.floor(v + 0.5) end

---------------------------------------------------------------- fonts, colours, text
local fonts = nil
local function firstFont(list, fallback)
  for _, f in ipairs(list) do
    local ok, valid = pcall(hs.styledtext.validFont, f)
    if ok and valid then return f end
  end
  return fallback
end

local function getFonts()
  if not fonts then
    local mono = theme.font or ".AppleSystemUIFont"
    fonts = {
      sans = firstFont({ "LiberationSans", "Liberation Sans", "ArialMT", "Helvetica" }, ".AppleSystemUIFont"),
      bold = firstFont({ "LiberationSans-Bold", "Liberation Sans Bold", "Arial-BoldMT", "Helvetica-Bold" }, mono),
      mono = mono,
      monoBold = firstFont({ "JetBrainsMonoNF-Bold", "JetBrainsMonoNerdFont-Bold", "JetBrainsMono Nerd Font Bold" }, mono),
    }
  end
  return fonts
end

local measureCache = {}
local measureCount = 0
local function textW(s, font, size)
  local k = font .. "\1" .. size .. "\1" .. s
  local c = measureCache[k]
  if c then return c end
  local ok, sz = pcall(hs.drawing.getTextDrawingSize, s, { font = font, size = size })
  local w = (ok and sz and sz.w) or (#s * size * 0.55)
  measureCount = measureCount + 1
  if measureCount > 4000 then measureCache, measureCount = {}, 0 end
  measureCache[k] = w
  return w
end

local lineHeights = {}
local function lineH(font, size)
  local k = font .. "\1" .. size
  if not lineHeights[k] then
    local ok, sz = pcall(hs.drawing.getTextDrawingSize, "Ag", { font = font, size = size })
    lineHeights[k] = math.ceil((ok and sz and sz.h) or size * 1.25)
  end
  return lineHeights[k]
end

local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"

-- Greedy word wrap into at most maxLines lines; the last one ends in … when text is left over.
local function wrap(text, font, size, width, maxLines)
  local tokens = {}
  local para = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    para = para + 1
    if para > 1 then tokens[#tokens + 1] = false end    -- a hard line break
    for word in line:gmatch("%S+") do tokens[#tokens + 1] = word end
  end
  local lines, cur = {}, ""
  local i = 1
  local overflow = false
  while i <= #tokens do
    local t = tokens[i]
    if t == false then
      lines[#lines + 1] = cur
      cur = ""
      i = i + 1
    else
      local cand = cur == "" and t or (cur .. " " .. t)
      if textW(cand, font, size) <= width then
        cur = cand
        i = i + 1
      elseif cur ~= "" then
        lines[#lines + 1] = cur
        cur = ""
      else
        -- one word wider than the line: break it by characters
        local piece = ""
        local rest = t
        for ch in t:gmatch(UTF8_CHAR) do
          if textW(piece .. ch, font, size) > width and piece ~= "" then break end
          piece = piece .. ch
        end
        rest = t:sub(#piece + 1)
        lines[#lines + 1] = piece
        if rest ~= "" then tokens[i] = rest else i = i + 1 end
      end
    end
    if #lines >= maxLines then
      overflow = i <= #tokens or cur ~= ""
      break
    end
  end
  if #lines < maxLines and cur ~= "" then lines[#lines + 1] = cur end
  while #lines > maxLines do table.remove(lines) overflow = true end
  if overflow and #lines > 0 then
    local l = lines[#lines]
    while l ~= "" and textW(l .. "…", font, size) > width do
      l = l:gsub(UTF8_CHAR .. "$", "")
    end
    lines[#lines] = l .. "…"
  end
  -- trailing empty lines from hard breaks carry nothing
  while #lines > 1 and lines[#lines] == "" do table.remove(lines) end
  return lines, overflow
end

local function rgb(hex)
  local h = tostring(hex or ""):gsub("^#", "")
  local r, g, b = h:sub(1, 2), h:sub(3, 4), h:sub(5, 6)
  return (tonumber(r, 16) or 255) / 255, (tonumber(g, 16) or 255) / 255, (tonumber(b, 16) or 255) / 255
end

-- Qt.darker(color, factor): same hue and saturation, value / factor.
local function darker(role, factor, alpha)
  local r, g, b = rgb(theme.hex(role))
  return { red = r / factor, green = g / factor, blue = b / factor, alpha = alpha or 1 }
end

local function col(role, alpha) return theme.color(role, alpha) end

local function withAlpha(c, a)
  local out = {}
  for k, v in pairs(c) do out[k] = v end
  out.alpha = (out.alpha or 1) * a
  return out
end

-- Bound and clean a string from a caller: no control characters except newlines.
local function clean(s, limit, keepNewlines)
  if type(s) ~= "string" then
    if type(s) == "number" then s = tostring(s) else return "" end
  end
  if #s > limit then
    s = s:sub(1, limit):gsub("[\192-\255][\128-\191]*$", "")
  end
  if keepNewlines then
    s = s:gsub("\r\n?", "\n"):gsub("[^\n\32-\126\128-\255]", " ")
  else
    s = s:gsub("[^\32-\126\128-\255]", " ")
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------- bar state
local function push()
  local ok, text = pcall(hs.json.encode, { v = 1, dnd = dnd, shown = #toasts, history = #history, focus = focusShortcuts })
  if not ok or not text or text == last then return end
  last = text
  pcall(function()
    hs.task.new(CTL, function(code, _, err)
      if code ~= 0 then log.w("notifications: shell set failed: %s", tostring(err):sub(1, 160)) end
    end, { "shell", "set", VAR, text }):start()
  end)
end

local function saveState()
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
      hs.json.write({ dnd = dnd }, STATE_FILE, true, true)
    end)
  end)
end

---------------------------------------------------------------- rows
local function rowIndex(key)
  for i, r in ipairs(toasts) do if r.key == key then return i end end
  return nil
end

local function liveCount() return #toasts + #held end

local function groupKey(row) return row.app ~= "" and row.app or "omarchy" end

-- Omarchy's durationFor(): critical waits for you, the rest get their urgency's minimum,
-- stretched up to 30 s when the caller asks for longer.
local function durationFor(urgency, requested)
  if urgency == 2 then return 0 end
  local base = urgency == 0 and LOW_MS or NORMAL_MS
  local req = tonumber(requested) or 0
  if req < 0 then req = 0 end
  return math.min(MAX_MS, math.max(base, req))
end

local function urgencyOf(u)
  if u == 0 or u == "low" then return 0 end
  if u == 2 or u == "critical" then return 2 end
  return 1
end

-- What a card offers: buttons, and whether a click does something of its own.
local function deedsOf(row) return row.actions or {} end
local function clickable(row) return row.onClick ~= nil or row.bundle ~= nil end

local render -- forward

---------------------------------------------------------------- expiry (one-shot timers, paused while read)
local function paused() return pointerIn or keyboard.on end

local function armExpiry(row)
  if row.timer then row.timer:stop() row.timer = nil end
  if not row.duration or row.duration <= 0 or paused() then return end
  local secs = math.max(0.05, (row.remaining or row.duration) / 1000)
  row.deadline = now() + secs
  local key = row.key
  row.timer = hs.timer.doAfter(secs, function()
    row.timer = nil
    M.close(key, "expired")
  end)
end

local function pauseAll()
  for _, r in ipairs(toasts) do
    if r.timer then
      r.timer:stop()
      r.timer = nil
      r.remaining = math.max(0, (r.deadline - now()) * 1000)
    end
  end
end

local function resumeAll()
  if paused() then return end
  for _, r in ipairs(toasts) do armExpiry(r) end
end

---------------------------------------------------------------- arrival / departure
local function screenForDeck()
  if deckScreen then
    for _, s in ipairs(hs.screen.allScreens() or {}) do
      if s:id() == deckScreen then return s end
    end
  end
  local s = hs.screen.mainScreen() or hs.screen.primaryScreen()
  deckScreen = s and s:id() or nil
  return s
end

local function remember(row)
  if row.transient or row.restored then return end
  local copy = { key = row.key, app = row.app, glyph = row.glyph, summary = row.summary, body = row.body,
    urgency = row.urgency, ts = row.ts, bundle = row.bundle }
  for i = #history, 1, -1 do if history[i].key == row.key then table.remove(history, i) end end
  table.insert(history, 1, copy)
  while #history > HISTORY_LIMIT do table.remove(history) end
end

local function holding() return (pointerIn or keyboard.on) and expanded end

local function startHeldTimer()
  if heldTimer then return end
  heldTimer = hs.timer.doAfter(HELD_MAX, function()
    heldTimer = nil
    M.releaseHeld()
  end)
end

local function showRow(row)
  local at = rowIndex(row.key)
  if at then
    -- an update, in place, with a fresh display period
    local old = toasts[at]
    if old.timer then old.timer:stop() end
    row.remaining = row.duration
    toasts[at] = row
  else
    if #toasts == 0 then deckScreen = nil end
    row.remaining = row.duration
    table.insert(toasts, 1, row)
  end
  armExpiry(row)
  if not clockTimer then
    clockTimer = hs.timer.doEvery(20, function() if #toasts > 0 then render() end end)
  end
  render()
end

function M.releaseHeld()
  if heldTimer then heldTimer:stop() heldTimer = nil end
  local queue = held
  held = {}
  for _, key in ipairs(queue) do
    local row = pending[key]
    pending[key] = nil
    if row then showRow(row) end
  end
end

local function stopKeyboard() end -- forward placeholder, replaced below

function M.close(key, reason)
  local at = rowIndex(key)
  if not at then
    if pending[key] then
      pending[key] = nil
      for i = #held, 1, -1 do if held[i] == key then table.remove(held, i) end end
    end
    return false
  end
  local row = table.remove(toasts, at)
  if row.timer then row.timer:stop() row.timer = nil end
  if row.onClose then pcall(row.onClose, reason or "dismissed") end
  if #toasts == 0 then
    deckScreen = nil
    if clockTimer then clockTimer:stop() clockTimer = nil end
    expanded, openDeck, hoverKey = false, nil, nil
  end
  if keyboard.on then
    if keyboard.key == key then
      local nextRow = toasts[math.min(at, #toasts)]
      keyboard.key = nextRow and nextRow.key or nil
      if not keyboard.key then stopKeyboard() end
    end
  end
  render()
  return true
end

---------------------------------------------------------------- the public Lua API
-- post{ summary, body, app, glyph, urgency = "low"|"normal"|"critical" (or 0/1/2),
--       duration (ms), actions = { { label = "...", fn = function() end }, ... },
--       onClick = function() end, bundle = "<bundle id to focus on click>",
--       image = hs.image, transient = bool, replaces = key, bypassQuiet = bool,
--       onClose = function(reason) end }
-- Returns the card's key (to replace or close it), or nil.
function M.post(opts)
  if type(opts) ~= "table" then return nil end
  local summary = clean(opts.summary, MAX_SUMMARY, false)
  local body = clean(opts.body, MAX_BODY, true)
  if summary == "" and body == "" then return nil end
  local key = (type(opts.replaces) == "string" and (rowIndex(opts.replaces) or pending[opts.replaces])) and opts.replaces
  if not key then
    if liveCount() >= MAX_LIVE then return nil end
    seed = seed + 1
    key = "n" .. seed
  end
  local urgency = urgencyOf(opts.urgency)
  local acts = {}
  if type(opts.actions) == "table" then
    for _, a in ipairs(opts.actions) do
      if #acts >= MAX_ACTIONS then break end
      if type(a) == "table" and type(a.fn) == "function" then
        local label = clean(a.label, MAX_LABEL, false)
        if label ~= "" then acts[#acts + 1] = { label = label, fn = a.fn } end
      end
    end
  end
  local bundle = opts.bundle
  if type(bundle) ~= "string" or not bundle:match("^[%w%-]+%.[%w%.%-]+$") then bundle = nil end
  local row = {
    key = key,
    app = clean(opts.app, MAX_APP, false),
    glyph = clean(opts.glyph, 16, false),
    summary = summary,
    body = body,
    urgency = urgency,
    duration = durationFor(urgency, opts.duration),
    ts = os.time(),
    actions = acts,
    onClick = type(opts.onClick) == "function" and opts.onClick or nil,
    onClose = type(opts.onClose) == "function" and opts.onClose or nil,
    bundle = bundle,
    image = (type(opts.image) == "userdata" or type(opts.image) == "table") and opts.image or nil,
    transient = opts.transient == true,
    bypass = opts.bypassQuiet == true or (opts.app == nil and urgency == 2),
  }
  -- Do Not Disturb: straight to history (unless transient). A card already on screen that
  -- this replaces stays as it was.
  if dnd and not row.bypass then
    remember(row)
    push()
    return key
  end
  remember(row)
  if holding() and not rowIndex(key) then
    if not pending[key] then held[#held + 1] = key end
    pending[key] = row
    startHeldTimer()
    push()
    return key
  end
  showRow(row)
  return key
end

function M.dismiss(key) return M.close(key, "dismissed") end

function M.dismissAll()
  local keys = {}
  for _, r in ipairs(toasts) do keys[#keys + 1] = r.key end
  for _, k in ipairs(held) do keys[#keys + 1] = k end
  for _, k in ipairs(keys) do M.close(k, "dismissed") end
  held, pending = {}, {}
  render()
  return #keys
end

function M.isDnd() return dnd end

local function runShortcut(name)
  if not focusShortcuts then return end
  pcall(function()
    hs.task.new(SHORTCUTS, function(code)
      if code ~= 0 then
        log.w("notifications: Focus shortcut exited %s", tostring(code))
        toast.warn("The macOS Focus shortcut failed")
      end
    end, { "run", name }):start()
  end)
end

function M.setDoNotDisturb(value)
  local on = value and true or false
  if on == dnd then return dnd end
  dnd = on
  saveState()
  runShortcut(on and FOCUS_ON or FOCUS_OFF)
  log.i("notifications: do not disturb %s", on and "on" or "off")
  push()
  return dnd
end

---------------------------------------------------------------- layout (Toast.qml + Layout.js)
local function ago(ts)
  local s = math.max(0, os.time() - (ts or os.time()))
  if s < 300 then return "" end
  if s < 3600 then return tostring(round(s / 60)) .. "m" end
  if os.date("%Y-%m-%d", ts) == os.date("%Y-%m-%d") then return os.date("%H:%M", ts) end
  if os.date("%Y-%m-%d", ts) == os.date("%Y-%m-%d", os.time() - 86400) then return "yesterday" end
  return os.date("%a", ts)
end

local function appIcon(row)
  if row.image then return row.image end
  if row.bundle then
    if row.icon == nil then
      local ok, img = pcall(hs.image.imageFromAppBundle, row.bundle)
      row.icon = (ok and img) or false
    end
    return row.icon or nil
  end
  return nil
end

-- Card geometry for one row in one state. Measured text is cached on the row by state.
local function measureCard(row, opts)
  local f = getFonts()
  local hasBody = row.body ~= ""
  local padY = hasBody and PAD_Y_BODY or PAD_Y
  local pictured = appIcon(row) ~= nil
  local glyphed = not pictured and row.glyph ~= ""
  local anonymous = row.app == ""
  local lettered = not pictured and not glyphed and not anonymous
  local compact = glyphed and not hasBody
  local thumbW, thumbH = 0, 0
  if pictured or lettered then thumbW, thumbH = THUMB, THUMB
  elseif glyphed then
    if compact then
      thumbW = math.ceil(textW(row.glyph, f.mono, GLYPH_SMALL)) + 2
      thumbH = lineH(f.mono, GLYPH_SMALL)
    else
      thumbW, thumbH = THUMB, THUMB
    end
  end
  local spacing = compact and THUMB_GAP_COMPACT or THUMB_GAP
  local inner = W - BORDER * 2 - PAD_X * 2
  local colW = inner - (thumbW > 0 and (thumbW + spacing) or 0)
  local stamp = ago(row.ts)
  local rightW = math.max(stamp ~= "" and textW(stamp, f.mono, STAMP_SIZE) or 0, textW("✕", f.mono, CLOSE_SIZE) + 6)
  local titleW = math.max(20, colW - rightW - RIGHT_GAP)
  local bodyOpen = opts.bodyOpen
  local titleLines = wrap(row.summary ~= "" and row.summary or " ", f.bold, TITLE_SIZE, titleW, bodyOpen and 8 or 3)
  local tLH = lineH(f.bold, TITLE_SIZE)
  local titleH = #titleLines * tLH
  local bodyLines, bodyH, restH = {}, 0, 0
  local bLH = lineH(f.sans, BODY_SIZE)
  if hasBody then
    bodyLines = wrap(row.body, f.sans, BODY_SIZE, colW, bodyOpen and 8 or 2)
    bodyH = #bodyLines * bLH
    restH = math.min(2, #bodyLines) * bLH
  end
  local textBlock = titleH + (hasBody and (COL_GAP + bodyH) or 0)
  local restingBlock = titleH + (hasBody and (COL_GAP + restH) or 0)
  local textOffset = math.max(0, (thumbH - restingBlock) / 2)
  local fixedH = BORDER * 2 + padY * 2 + math.max(thumbH, textOffset + textBlock)
  local deeds = deedsOf(row)
  local columns = math.max(1, math.min(3, #deeds))
  local deedRows = #deeds > 0 and math.ceil(#deeds / columns) or 0
  local deedsShown = #deeds > 0 and opts.deedsShown
  local deedH = deedsShown and deedRows * (RULE + SEG_H) or 0
  return {
    height = math.ceil(fixedH + deedH), fixedH = fixedH, padY = padY, hasBody = hasBody,
    pictured = pictured, glyphed = glyphed, lettered = lettered, compact = compact,
    thumbW = thumbW, thumbH = thumbH, spacing = spacing, colW = colW, titleW = titleW, rightW = rightW,
    stamp = stamp, titleLines = titleLines, tLH = tLH, titleH = titleH, bodyLines = bodyLines, bLH = bLH,
    textOffset = textOffset, restingBlock = restingBlock, deedsShown = deedsShown, columns = columns,
    deedRows = deedRows, deedH = deedH,
  }
end

-- Layout.compute(): decks newest first; a shut deck shows its front card with up to two
-- more peeking below it; the open deck lists every card.
local function computeLayout()
  local order, byKey = {}, {}
  for _, r in ipairs(toasts) do
    local g = groupKey(r)
    if not byKey[g] then byKey[g] = { key = g, rows = {} } order[#order + 1] = g end
    local d = byKey[g]
    d.rows[#d.rows + 1] = r
  end
  local sole = #toasts == 1
  local places = {}
  local y = 0
  for k, g in ipairs(order) do
    local deck = byKey[g]
    local open = expanded and (openDeck == nil or openDeck == g)
    local deckTop = y
    local front = deck.rows[1]
    local frontHovered = hoverKey == front.key
    local frontM = measureCard(front, {
      bodyOpen = open or (frontHovered and sole),
      deedsShown = (open and (frontHovered or (keyboard.on and keyboard.key == front.key))) or (not open),
    })
    for r, row in ipairs(deck.rows) do
      if open then
        local hovered = hoverKey == row.key or (keyboard.on and keyboard.key == row.key)
        local m = measureCard(row, { bodyOpen = true, deedsShown = hovered })
        places[#places + 1] = { row = row, m = m, y = y, height = m.height, scale = 1, opacity = 1,
          front = r == 1, content = true, deck = g, z = k * 1000 - r }
        y = y + m.height + CARD_GAP
      else
        local drawn = r <= VISIBLE
        places[#places + 1] = { row = row, m = frontM, y = deckTop + (r - 1) * PEEK, height = frontM.height,
          scale = math.max(0.7, 1 - (r - 1) * SHRINK),
          opacity = r == 1 and 1 or (drawn and ((r == VISIBLE) and FADE or 0.85) or 0),
          front = r == 1, content = r == 1, hidden = not drawn, deck = g, z = k * 1000 - r }
      end
    end
    if open then y = y - CARD_GAP
    else y = deckTop + frontM.height + math.min(#deck.rows - 1, VISIBLE - 1) * PEEK end
    if k < #order then y = y + DECK_GAP end
  end
  return places, math.max(0, y)
end

local barCache = { at = -1000, value = 0 }
local function barOffset()
  if now() - barCache.at < 30 then return barCache.value end
  barCache.at = now()
  barCache.value = 0
  local ok, actions = pcall(require, "omarchy.actions")
  if not ok or type(actions.omniwmSetting) ~= "function" then return 0 end
  local okP, pos = pcall(actions.omniwmSetting, "workspaceBar", "position")
  local okH, h = pcall(actions.omniwmSetting, "workspaceBar", "height")
  pos = okP and pos and pos:gsub('"', "") or ""
  h = okH and tonumber(h or "") or 0
  if pos == "belowMenuBar" then barCache.value = h end
  return barCache.value
end

---------------------------------------------------------------- drawing
local function cardElements(els, p, ox)
  local f = getFonts()
  local row, m = p.row, p.m
  local w = W * p.scale
  local h = p.height * p.scale
  local x = ox + (W - w) / 2
  local y = p.y
  local alpha = p.opacity
  local fg = col("foreground")
  -- plate
  els[#els + 1] = { type = "rectangle", action = "strokeAndFill",
    fillColor = col("background", alpha), strokeColor = col("accent", alpha), strokeWidth = BORDER,
    frame = { x = x + BORDER / 2, y = y + BORDER / 2, w = w - BORDER, h = h - BORDER } }
  local rects = { card = { x = x, y = y, w = w, h = h } }
  if not p.content then return rects end
  if keyboard.on and keyboard.key == row.key then
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col("foreground", 0.08),
      frame = { x = x + BORDER, y = y + BORDER, w = w - BORDER * 2, h = h - BORDER * 2 } }
  end
  local left = x + BORDER + PAD_X
  local top = y + BORDER + m.padY
  local dim = darker("foreground", 1.4)
  -- thumb
  if m.thumbW > 0 then
    local ty = top + math.max(0, (m.restingBlock - m.thumbH) / 2)
    local tf = { x = left, y = ty, w = m.thumbW, h = m.thumbH }
    if m.pictured then
      els[#els + 1] = { type = "image", image = appIcon(row), imageScaling = "scaleProportionally", frame = tf }
    elseif m.glyphed then
      local size = m.compact and GLYPH_SMALL or GLYPH_BIG
      local gh = lineH(f.mono, size)
      els[#els + 1] = { type = "text", text = row.glyph, textFont = f.mono, textSize = size, textColor = fg,
        textAlignment = "center", textLineBreak = "clip",
        frame = { x = tf.x - 10, y = tf.y + (tf.h - gh) / 2, w = tf.w + 20, h = gh } }
    else
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col("foreground", 0.04), frame = tf }
      local letter = (row.app:match(UTF8_CHAR) or "?"):upper()
      local lh = lineH(f.monoBold, LETTER_SIZE)
      els[#els + 1] = { type = "text", text = letter, textFont = f.monoBold, textSize = LETTER_SIZE, textColor = dim,
        textAlignment = "center", frame = { x = tf.x, y = tf.y + (tf.h - lh) / 2, w = tf.w, h = lh } }
    end
  end
  local cx = left + (m.thumbW > 0 and (m.thumbW + m.spacing) or 0)
  local cy = top + m.textOffset
  -- headline
  for i, line in ipairs(m.titleLines) do
    els[#els + 1] = { type = "text", text = line, textFont = f.bold, textSize = TITLE_SIZE, textColor = fg,
      textLineBreak = "clip", frame = { x = cx, y = cy + (i - 1) * m.tLH, w = m.titleW + 4, h = m.tLH } }
  end
  -- relative time, or ✕ while hovered
  local hovered = hoverKey == row.key
  local firstMid = cy + m.tLH / 2
  local rx = cx + m.colW - m.rightW
  if hovered then
    local closeH = lineH(f.mono, CLOSE_SIZE)
    local hot = hotPart == "close"
    els[#els + 1] = { type = "text", text = "✕", textFont = f.mono, textSize = CLOSE_SIZE,
      textColor = hot and fg or dim, textAlignment = "right",
      frame = { x = rx, y = firstMid - closeH / 2, w = m.rightW, h = closeH } }
    rects.close = { x = rx - 3, y = firstMid - closeH / 2 - 3, w = m.rightW + 6, h = closeH + 6 }
  elseif m.stamp ~= "" then
    local sh = lineH(f.mono, STAMP_SIZE)
    els[#els + 1] = { type = "text", text = m.stamp, textFont = f.mono, textSize = STAMP_SIZE, textColor = dim,
      textAlignment = "right", frame = { x = rx, y = firstMid - sh / 2, w = m.rightW, h = sh } }
  end
  -- body
  if m.hasBody then
    local by = cy + m.titleH + COL_GAP
    local bodyColor = darker("foreground", 1.15)
    for i, line in ipairs(m.bodyLines) do
      els[#els + 1] = { type = "text", text = line, textFont = f.sans, textSize = BODY_SIZE, textColor = bodyColor,
        textLineBreak = "clip", frame = { x = cx, y = by + (i - 1) * m.bLH, w = m.colW + 4, h = m.bLH } }
    end
  end
  -- buttons
  local deeds = deedsOf(row)
  if m.deedsShown and #deeds > 0 then
    rects.deeds = {}
    local areaX = x + BORDER
    local areaW = w - BORDER * 2
    local areaTop = y + h - BORDER - m.deedH
    local rule = withAlpha(dim, 0.35)
    local dh = lineH(f.mono, DEED_SIZE)
    for i, d in ipairs(deeds) do
      local line = math.floor((i - 1) / m.columns)
      local slot = (i - 1) % m.columns
      local perLine = (line < m.deedRows - 1) and m.columns or (#deeds - line * m.columns)
      local start = round(slot * areaW / perLine)
      local bw = round((slot + 1) * areaW / perLine) - start
      local bx = areaX + start
      local byy = areaTop + line * (RULE + SEG_H)
      local r = { x = bx, y = byy, w = bw, h = RULE + SEG_H }
      local hot = hotPart == ("deed" .. i) and hoverKey == row.key
      if hot then
        els[#els + 1] = { type = "rectangle", action = "fill", fillColor = col("foreground", 0.08), frame = r }
      end
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = rule, frame = { x = bx, y = byy, w = bw, h = RULE } }
      if slot > 0 then
        els[#els + 1] = { type = "rectangle", action = "fill", fillColor = rule, frame = { x = bx, y = byy, w = RULE, h = RULE + SEG_H } }
      end
      local hint = (keyboard.on and keyboard.key == row.key and i <= 9) and (tostring(i) .. " ") or ""
      local label = d.label
      local room = bw - 8 - (hint ~= "" and textW(hint, f.monoBold, DEED_SIZE) or 0)
      if textW(label, f.mono, DEED_SIZE) > room then
        while label ~= "" and textW(label .. "…", f.mono, DEED_SIZE) > room do label = label:gsub(UTF8_CHAR .. "$", "") end
        label = label .. "…"
      end
      local tw = (hint ~= "" and textW(hint, f.monoBold, DEED_SIZE) or 0) + textW(label, f.mono, DEED_SIZE)
      local tx = bx + (bw - tw) / 2
      local ty = byy + RULE + (SEG_H - dh) / 2
      if hint ~= "" then
        els[#els + 1] = { type = "text", text = hint, textFont = f.monoBold, textSize = DEED_SIZE, textColor = col("accent"),
          frame = { x = tx, y = ty, w = textW(hint, f.monoBold, DEED_SIZE) + 2, h = dh } }
        tx = tx + textW(hint, f.monoBold, DEED_SIZE)
      end
      els[#els + 1] = { type = "text", text = label, textFont = f.mono, textSize = DEED_SIZE,
        textColor = hot and fg or darker("foreground", 1.15), textLineBreak = "clip",
        frame = { x = tx, y = ty, w = textW(label, f.mono, DEED_SIZE) + 4, h = dh } }
      rects.deeds[i] = r
    end
  end
  return rects
end

local onMouse -- forward

local function ensureCanvas()
  if canvas then return end
  canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = 10 })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary", "ignoresCycle" })
  canvas:clickActivating(false)
  canvas:canvasMouseEvents(true, true, true, true)
  canvas:mouseCallback(function(_, msg, _, x, y)
    local ok, err = pcall(onMouse, msg, x, y)
    if not ok then log.e("notifications: mouse handler failed: %s", tostring(err)) end
  end)
end

render = function()
  push()
  if #toasts == 0 then
    geom = nil
    if canvas then canvas:hide() end
    return
  end
  local ok, err = pcall(function()
    local places, height = computeLayout()
    local screen = screenForDeck()
    if not screen then return end
    local sf = screen:frame()
    local top = sf.y + barOffset() + EDGE
    local maxH = sf.y + sf.h - top - EDGE
    local h = math.min(height, maxH)
    local frame = { x = sf.x + sf.w - EDGE - W, y = top, w = W, h = math.max(1, h) }
    ensureCanvas()
    canvas:frame(frame)
    -- draw behind cards first (lowest z), the front ones last
    local sorted = {}
    for i, p in ipairs(places) do sorted[i] = p end
    table.sort(sorted, function(a, b) return a.z < b.z end)
    local els = {}
    local hits = {}
    for _, p in ipairs(sorted) do
      if not p.hidden and p.opacity > 0 then
        local rects = cardElements(els, p, 0)
        hits[#hits + 1] = { p = p, rects = rects }
      end
    end
    canvas:replaceElements(els)
    canvas:show()
    geom = { hits = hits, frame = frame }
  end)
  if not ok then log.e("notifications: could not draw: %s", tostring(err)) end
end

---------------------------------------------------------------- pointer (the deck owns hover)
local function within(r, x, y) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

-- The top-most card under the point and the part of it (close, deedN, card).
local function hitAt(x, y)
  if not geom then return nil, nil end
  for i = #geom.hits, 1, -1 do
    local h = geom.hits[i]
    if within(h.rects.card, x, y) then
      if not h.p.content then return h.p, "card" end
      if within(h.rects.close, x, y) then return h.p, "close" end
      for d, r in ipairs(h.rects.deeds or {}) do
        if within(r, x, y) then return h.p, "deed" .. d end
      end
      return h.p, "card"
    end
  end
  return nil, nil
end

local function collapse()
  if keyboard.on then return end
  expanded, openDeck, hoverKey, hotPart = false, nil, nil, nil
  M.releaseHeld()
  render()
end

local function activate(key)
  local at = rowIndex(key)
  if not at then return end
  local row = toasts[at]
  if row.onClick then
    local ok, err = pcall(row.onClick)
    if not ok then log.e("notifications: click handler failed: %s", tostring(err)) end
  elseif row.bundle then
    pcall(function() hs.application.launchOrFocusByBundleID(row.bundle) end)
  end
  M.close(key, "activated")
end

local function runDeed(key, index)
  local at = rowIndex(key)
  if not at then return false end
  local d = deedsOf(toasts[at])[index]
  if not d then return false end
  M.close(key, "activated")
  local ok, err = pcall(d.fn)
  if not ok then log.e("notifications: button handler failed: %s", tostring(err)) end
  return true
end

onMouse = function(msg, x, y)
  if msg == "mouseEnter" then
    if collapseTimer then collapseTimer:stop() collapseTimer = nil end
    if not pointerIn then
      pointerIn = true
      pauseAll()
    end
    return
  end
  if msg == "mouseExit" then
    pointerIn = false
    hoverKey, hotPart = nil, nil
    press = nil
    resumeAll()
    if collapseTimer then collapseTimer:stop() end
    collapseTimer = hs.timer.doAfter(COLLAPSE_GRACE, function()
      collapseTimer = nil
      if not pointerIn then collapse() end
    end)
    render()
    return
  end
  local p, part = hitAt(x, y)
  if msg == "mouseMove" then
    if not pointerIn then pointerIn = true pauseAll() end
    local key = p and p.row.key or nil
    local changed = key ~= hoverKey or part ~= hotPart
    hoverKey, hotPart = key, part
    if p and (not expanded or openDeck ~= p.deck) then
      expanded, openDeck = true, p.deck
      changed = true
    end
    if changed then render() end
    return
  end
  if msg == "mouseDown" then
    local ok, b = pcall(hs.eventtap.checkMouseButtons)
    b = (ok and type(b) == "table") and b or {}
    press = { key = p and p.row.key, part = part, other = (b.right or b[2] or b.middle or b[3]) and true or false }
    return
  end
  if msg == "mouseUp" then
    local pr = press
    press = nil
    if not (pr and p and pr.key == p.row.key and pr.part == part) then return end
    if not p.content then return end
    local key = p.row.key
    if pr.other then M.close(key, "dismissed") return end
    if part == "close" then M.close(key, "dismissed") return end
    local d = part and part:match("^deed(%d+)$")
    if d then runDeed(key, tonumber(d)) return end
    activate(key)
  end
end

---------------------------------------------------------------- keyboard (Super+Ctrl+,)
-- Cards in the order they stand: deck by deck, front to back.
local function keyboardOrder()
  local order, byKey, out = {}, {}, {}
  for _, r in ipairs(toasts) do
    local g = groupKey(r)
    if not byKey[g] then byKey[g] = {} order[#order + 1] = g end
    local list = byKey[g]
    list[#list + 1] = r.key
  end
  for _, g in ipairs(order) do for _, k in ipairs(byKey[g]) do out[#out + 1] = k end end
  return out
end

local function deckOf(key)
  local at = rowIndex(key)
  return at and groupKey(toasts[at]) or nil
end

local function selectCard(key)
  if not rowIndex(key) then return false end
  keyboard.key = key
  hoverKey = key
  expanded, openDeck = true, deckOf(key)
  render()
  return true
end

local function touchKeyboard()
  if keyboard.idle then keyboard.idle:stop() end
  keyboard.idle = hs.timer.doAfter(KEYBOARD_IDLE, function() keyboard.idle = nil stopKeyboard() end)
end

stopKeyboard = function()
  if not keyboard.on then return end
  keyboard.on = false
  keyboard.key = nil
  if keyboard.idle then keyboard.idle:stop() keyboard.idle = nil end
  if keyboard.modal then pcall(function() keyboard.modal:exit() end) end
  if not pointerIn then
    hoverKey = nil
    resumeAll()
    collapse()
  else
    render()
  end
end

local function moveSelection(step)
  local order = keyboardOrder()
  local at = nil
  for i, k in ipairs(order) do if k == keyboard.key then at = i end end
  if not at then return end
  local nxt = order[at + step]
  if nxt then selectCard(nxt) end
end

local function ensureModal()
  if keyboard.modal then return keyboard.modal end
  local modal = hs.hotkey.modal.new()
  local function bind(mods, key, fn)
    modal:bind(mods, key, function()
      local ok, err = pcall(function() touchKeyboard() fn() end)
      if not ok then log.e("notifications: keyboard handler failed: %s", tostring(err)) end
    end)
  end
  bind({}, "escape", function() stopKeyboard() end)
  for _, k in ipairs({ "down", "j", "tab" }) do bind({}, k, function() moveSelection(1) end) end
  for _, k in ipairs({ "up", "k" }) do bind({}, k, function() moveSelection(-1) end) end
  bind({ "shift" }, "tab", function() moveSelection(-1) end)
  for _, k in ipairs({ "return", "padenter" }) do
    bind({}, k, function()
      local key = keyboard.key
      stopKeyboard()
      if key then activate(key) end
    end)
  end
  for _, k in ipairs({ "delete", "forwarddelete" }) do
    bind({}, k, function()
      local key = keyboard.key
      if key then
        local order = keyboardOrder()
        local at = 1
        for i, x in ipairs(order) do if x == key then at = i end end
        M.close(key, "dismissed")
        local again = keyboardOrder()
        local nxt = again[math.min(at, #again)]
        if nxt and keyboard.on then selectCard(nxt) else stopKeyboard() end
      end
    end)
  end
  for n = 1, 9 do
    bind({}, tostring(n), function()
      local key = keyboard.key
      local at = key and rowIndex(key)
      if at and n <= #deedsOf(toasts[at]) then
        stopKeyboard()
        runDeed(key, n)
      end
    end)
  end
  keyboard.modal = modal
  return modal
end

local function startKeyboard(key)
  local order = keyboardOrder()
  if #order == 0 then return false end
  local pick = order[1]
  for _, k in ipairs(order) do if k == key then pick = k end end
  keyboard.on = true
  pauseAll()
  ensureModal():enter()
  touchKeyboard()
  selectCard(pick)
  return true
end

---------------------------------------------------------------- IPC equivalents
local function newestLive() return toasts[1] and toasts[1].key or nil end

-- Super+,: with nothing to do it is dismissed, with one thing that is done, with more it
-- takes the keyboard so you can pick.
local function actOnNewest()
  local key = newestLive()
  if not key then return false end
  local row = toasts[1]
  local deeds = #deedsOf(row)
  local click = clickable(row)
  if deeds + (click and 1 or 0) > 1 then startKeyboard(key)
  elseif click then activate(key)
  elseif deeds > 0 then runDeed(key, 1)
  else M.close(key, "dismissed") end
  return true
end

local function showPlaceholder()
  seed = seed + 1
  showRow({ key = "placeholder" .. seed, app = "", glyph = G_BELL, summary = "No recent notifications", body = "",
    urgency = 0, duration = LOW_MS, ts = os.time(), actions = {}, transient = true, restored = true })
end

-- Put the last few back on screen (no buttons: their sender is gone).
local function replayHistory()
  local onScreen = {}
  for _, r in ipairs(toasts) do onScreen[r.origin or r.key] = true end
  local rows = {}
  for _, h in ipairs(history) do
    if #rows >= REPLAY then break end
    if not onScreen[h.key] then rows[#rows + 1] = h end
  end
  if #rows == 0 then return showPlaceholder() end
  for i = #rows, 1, -1 do
    local h = rows[i]
    seed = seed + 1
    showRow({ key = "r" .. seed, origin = h.key, app = h.app, glyph = h.glyph, summary = h.summary, body = h.body,
      urgency = h.urgency == 2 and 1 or h.urgency, duration = LOW_MS, ts = h.ts, bundle = h.bundle, actions = {},
      restored = true })
  end
end

local function toggleExpand()
  if expanded then
    expanded, openDeck, hoverKey = false, nil, nil
    M.releaseHeld()
  elseif #toasts > 0 then
    expanded, openDeck, hoverKey = true, groupKey(toasts[1]), toasts[1].key
  end
  render()
end

local function sample()
  M.post{
    app = "Omarchy",
    glyph = G_BELL,
    summary = "Notifications are working",
    body = "This card comes from omarchy-mac. Hover the deck to open it; click ✕ to dismiss.",
    actions = {
      { label = "Notification Center", fn = function() require("omarchy.actions").run("notification-center") end },
    },
  }
end

M.actions = {
  ["notifications.act"] = { fn = function() if not actOnNewest() then toast.show("No notifications", 1.2) end end,
    desc = "Dismiss, invoke, or focus the newest notification" },
  ["notifications.dismiss-one"] = { fn = function()
    local key = newestLive()
    if key then M.close(key, "dismissed") end
  end, desc = "Dismiss the newest notification" },
  ["notifications.dismiss-all"] = { fn = function() M.dismissAll() end, desc = "Dismiss all notifications" },
  ["notifications.invoke-last"] = { fn = function()
    local key = newestLive()
    if key then activate(key) end
  end, desc = "Click the newest notification" },
  ["notifications.invoke"] = { fn = function(x)
    local n = tonumber(tostring(x or ""):match("^%s*(%d)%s*$") or "")
    local key = newestLive()
    if not (n and key and n >= 1) then return end
    runDeed(key, n)
  end, desc = "Press button n (1-9) on the newest notification" },
  ["notifications.keyboard"] = { fn = function()
    if keyboard.on then stopKeyboard() return end
    if not startKeyboard() then toast.show("No notifications", 1.2) end
  end, desc = "Control notifications with the keyboard (arrows/j/k, Return, Delete, 1-9, Esc)" },
  ["notifications.history"] = { fn = function() replayHistory() end, desc = "Show recent notifications again" },
  ["notifications.clear-history"] = { fn = function()
    history = {}
    push()
    toast.show("Notification history cleared", 1.2)
  end, desc = "Forget this session's notification history" },
  ["notifications.expand"] = { fn = function() toggleExpand() end, desc = "Open/close the notification deck" },
  ["notifications.toggle-dnd"] = { fn = function()
    M.setDoNotDisturb(not dnd)
    toast.show(dnd and "Notifications silenced" or "Notifications allowed", 1.2)
  end, desc = "Toggle Do Not Disturb (silence omarchy-mac notifications; macOS Focus via Shortcuts)" },
  ["notifications.dnd"] = { fn = function(x)
    local v = tostring(x or ""):lower():gsub("%s+", "")
    if v == "on" or v == "true" or v == "1" or v == "yes" then M.setDoNotDisturb(true)
    elseif v == "off" or v == "false" or v == "0" or v == "no" then M.setDoNotDisturb(false)
    else return toast.warn("notifications.dnd takes on or off") end
  end, desc = "Set Do Not Disturb (x = on|off)" },
  ["notifications.center"] = { fn = function() require("omarchy.actions").run("notification-center") end,
    desc = "Open macOS Notification Center" },
  ["notifications.focus-settings"] = { fn = function()
    require("omarchy.actions").run("settings", "com.apple.Focus-Settings.extension")
  end, desc = "Open Focus settings (macOS Do Not Disturb)" },
  ["notifications.test"] = { fn = function() sample() end, desc = "Show a sample notification" },
}

---------------------------------------------------------------- lifecycle
local function detectShortcuts()
  if not hs.fs.attributes(SHORTCUTS) then focusShortcuts = false return end
  pcall(function()
    hs.task.new(SHORTCUTS, function(code, out)
      local have = {}
      if code == 0 then
        for line in (out or ""):gmatch("[^\n]+") do have[(line:gsub("%s+$", ""))] = true end
      end
      focusShortcuts = have[FOCUS_ON] == true and have[FOCUS_OFF] == true
      push()
    end, { "list" }):start()
  end)
end

function M.start()
  M.stop()
  fonts, measureCache, measureCount, lineHeights = nil, {}, 0, {}
  local ok, data = pcall(hs.json.read, STATE_FILE)
  dnd = ok and type(data) == "table" and data.dnd == true or false
  detectShortcuts()
  push()
  return M
end

function M.stop()
  stopKeyboard()
  if keyboard.modal then pcall(function() keyboard.modal:delete() end) keyboard.modal = nil end
  for _, r in ipairs(toasts) do if r.timer then r.timer:stop() r.timer = nil end end
  if clockTimer then clockTimer:stop() clockTimer = nil end
  if collapseTimer then collapseTimer:stop() collapseTimer = nil end
  if heldTimer then heldTimer:stop() heldTimer = nil end
  if saveTimer then saveTimer:stop() saveTimer = nil end
  if canvas then local c = canvas canvas = nil pcall(function() c:delete() end) end
  toasts, held, pending, history = {}, {}, {}, {}
  pointerIn, expanded, openDeck, hoverKey, hotPart, press, geom, deckScreen = false, false, nil, nil, nil, nil, nil, nil
  last = nil
end

return M
