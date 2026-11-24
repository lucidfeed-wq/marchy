-- omarchy.osd: port of the Omarchy 4.5 shell plugin `omarchy.osd` (On-screen display).
--
-- Omarchy draws a small click-through card near the bottom centre of the focused output:
--   [icon]  [==========------]  42%        (progress OSD: volume, brightness, ...)
--   [icon]  Some message                   (status OSD: "Microphone muted", ...)
-- It is opened over IPC (`omarchy-osd` -> ShellIpc target "osd": show(json) / close()),
-- auto-hides after `duration` ms (default 1200; 0 = stay until closed) and animates the
-- bar (140 ms, OutCubic) when it is updated while already open.
--
-- Here the card is an hs.canvas (non-interactive, no focus) and the IPC is:
--   osd.show   x = the same JSON payload Omarchy takes:
--                  {"icon","message","value","max","progressText","duration"}
--   osd.close
-- plus the Omarchy key actions that feed it (they change the setting, then show the OSD):
--   osd.volume-up / osd.volume-down (x = optional step 1..25, default 5), osd.volume-mute,
--   osd.mic-mute, osd.brightness-up / osd.brightness-down (x = optional step).
--
-- URL arguments are untrusted (any local app can open hammerspoon:// links): payloads are
-- size-limited, numbers clamped, and a URL can never pin the card on screen for good.
-- Message text is never logged.
local M = { id = "osd" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

---------------------------------------------------------------- geometry (Omarchy Style)
local PAD = 16              -- Style.space(16): border -> content on every side
local GAP = 16              -- Style.space(16): icon | bar | readout
local MSG_GAP = 11          -- round(GAP * 2 / 3): icon | message
local BAR_W = 142           -- Style.space(142)
local BAR_H = 6             -- max(Style.space(6), Style.spacing.sm)
local MAX_MSG = 190         -- Style.space(190)
local MAX_MSG_MEDIA = 325   -- Style.space(325) for media/player OSDs
local BORDER = 2            -- max(1, Style.space(2))
local BOTTOM = 67           -- Style.space(67) above the bottom edge
local ICON_SIZE = 32        -- Style.font.displayLarge
local TEXT_SIZE = 16        -- Style.font.title (bold)
local RADIUS = 0            -- Style.cornerRadius (Omarchy: square)
local ANIM_MS = 140

local DEFAULT_DURATION = 1200
local URL_MAX_DURATION = 10000   -- a URL may not keep the card up longer than this
local MAX_MESSAGE_BYTES = 240
local MAX_ICON_BYTES = 32
local MAX_PAYLOAD_BYTES = 2048

local STEP_DEFAULT = 5

---------------------------------------------------------------- OsdModel.js
-- Glyphs are the exact Nerd Font code points Omarchy uses.
local G = {
  volMuted = "\u{EEE8}", volLow = "\u{F026}", volMed = "\u{F027}", volHigh = "\u{F028}",
  micMuted = "\u{F036D}", mic = "\u{F036C}", keyboard = "\u{F030C}", display = "\u{F0379}",
  touchpad = "\u{F07F8}", touch = "\u{F0741}", reboot = "\u{F0709}", power = "\u{F0425}",
  logout = "\u{F0343}", media = "\u{F075A}", play = "\u{F040A}", pause = "\u{F03E4}",
  next = "\u{F04AD}", previous = "\u{F04AE}",
}
local WIDEST_ICON = G.volHigh

local NAMED = {
  ["volume-muted"] = G.volMuted, ["volume-mute"] = G.volMuted, muted = G.volMuted, mute = G.volMuted,
  ["volume-low"] = G.volLow, ["volume-medium"] = G.volMed,
  ["volume-high"] = G.volHigh, volume = G.volHigh,
  ["microphone-muted"] = G.micMuted, ["microphone-off"] = G.micMuted, ["mic-muted"] = G.micMuted, ["mic-off"] = G.micMuted,
  microphone = G.mic, mic = G.mic,
  keyboard = G.keyboard,
  brightness = G.display, display = G.display,
  touchpad = G.touchpad,
  touch = G.touch, touchscreen = G.touch,
  reboot = G.reboot, restart = G.reboot,
  shutdown = G.power, power = G.power, poweroff = G.power,
  logout = G.logout, ["sign-out"] = G.logout, leave = G.logout,
  media = G.media, player = G.media, ["media-source"] = G.media, ["player-source"] = G.media,
  ["media-play"] = G.play, ["player-play"] = G.play,
  ["media-pause"] = G.pause, ["player-pause"] = G.pause,
  ["media-next"] = G.next, ["player-next"] = G.next,
  ["media-previous"] = G.previous, ["player-previous"] = G.previous,
}

local function iconFor(name, percent)
  local n = tostring(name or ""):lower()
  if NAMED[n] then return NAMED[n] end
  if #n > 0 then return tostring(name) end   -- a literal glyph passed by the caller
  if percent <= 0 then return G.volMuted end
  if percent <= 33 then return G.volLow end
  if percent <= 66 then return G.volMed end
  return G.volHigh
end

-- JavaScript parseInt(s, 10): leading integer or nil (NaN).
local function parseInt(s)
  local d = tostring(s or ""):match("^%s*([+-]?%d+)")
  return d and tonumber(d) or nil
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v) return math.floor(v + 0.5) end

local function stateForShow(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration)
  local maxValue = math.max(1, parseInt(rawMax ~= "" and rawMax or "100") or 1)
  local parsedValue = parseInt(rawValue ~= "" and rawValue or "0")
  local hasProgress = rawValue ~= "" and parsedValue ~= nil and rawMessage == ""
  local value = hasProgress and clamp(parsedValue, 0, maxValue) or 0
  local percent = hasProgress and round(value * 100 / maxValue) or -1
  local parsedDuration = parseInt(rawDuration ~= "" and rawDuration or "1200")
  local message = rawMessage
  if message == "" and hasProgress then
    message = (rawProgressText ~= "" and rawProgressText) or (tostring(percent) .. "%")
  end
  return {
    iconKey = tostring(iconName or ""):lower(),
    maxValue = maxValue,
    hasProgress = hasProgress,
    value = value,
    message = message,
    icon = iconFor(iconName, percent),
    duration = parsedDuration == nil and DEFAULT_DURATION or math.max(0, parsedDuration),
  }
end

---------------------------------------------------------------- fonts / measuring
local function firstFont(list, fallback)
  for _, f in ipairs(list) do
    local ok, valid = pcall(hs.styledtext.validFont, f)
    if ok and valid then return f end
  end
  return fallback
end

local fonts = nil
local function getFonts()
  if not fonts then
    local regular = theme.font or ".AppleSystemUIFont"
    fonts = {
      icon = regular,
      bold = firstFont({ "JetBrainsMonoNF-Bold", "JetBrainsMonoNerdFont-Bold", "JetBrainsMono Nerd Font Bold",
        "JetBrainsMono-Bold" }, regular),
    }
  end
  return fonts
end

local function measure(text, font, size)
  local ok, sz = pcall(hs.drawing.getTextDrawingSize, text, { font = font, size = size })
  if ok and sz and sz.w then return sz end
  return { w = #text * size * 0.6, h = size * 1.3 }
end

-- Nerd Font glyphs overflow their advance width; Hammerspoon cannot read the ink box, so the
-- icon column is the larger of the advance and an em-based ink estimate.
local function iconInk(glyph)
  local f = getFonts()
  local adv = measure(glyph, f.icon, ICON_SIZE).w
  -- Private-use glyphs (U+E000.., U+F0000..) start with byte 0xEE/0xEF/0xF3.
  local b = glyph:byte(1) or 0
  local isNerd = #glyph >= 3 and (b == 0xEE or b == 0xEF or b == 0xF3)
  local est = isNerd and ICON_SIZE * 1.1 or adv
  return math.ceil(math.max(adv, est)), adv
end

---------------------------------------------------------------- state + canvas
local st = { opened = false, icon = "", message = "", iconKey = "", value = 0, maxValue = 100,
  hasProgress = true, duration = DEFAULT_DURATION }
local canvas, hideTimer, animTimer, fadeTimer
local fading = false
local FADE_OUT = 0.12
local fillFrom, fillTo, animStart = 0, 0, 0
local currentFrac = nil  -- what the bar shows right now (mid-animation included)
local layout = nil   -- last computed geometry (bar position)

local function stopAnim()
  if animTimer then animTimer:stop() animTimer = nil end
end

local function targetScreen()
  return hs.screen.mainScreen() or hs.mouse.getCurrentScreen() or hs.screen.primaryScreen()
end

local function compute()
  local f = getFonts()
  local mediaOsd = st.iconKey:sub(1, 5) == "media" or st.iconKey:sub(1, 6) == "player"
  local maxMsg = mediaOsd and MAX_MSG_MEDIA or MAX_MSG
  local inkW, adv = iconInk(st.icon)
  local iconW = inkW
  if st.hasProgress then iconW = math.max(inkW, (iconInk(WIDEST_ICON))) end
  local msgAdv = math.ceil(measure(st.message, f.bold, TEXT_SIZE).w)
  local valueW = math.ceil(math.max(measure("100%", f.bold, TEXT_SIZE).w, msgAdv))
  local msgW = math.min(msgAdv, maxMsg)
  local contentW
  if st.hasProgress then
    contentW = iconW + GAP + BAR_W + GAP + valueW
  elseif st.message == "" then
    contentW = iconW
  else
    contentW = iconW + MSG_GAP + msgW
  end
  local w = BORDER + PAD + contentW + PAD + BORDER
  local h = BORDER + PAD + ICON_SIZE + PAD + BORDER
  return { w = w, h = h, iconW = iconW, iconAdv = adv, valueW = valueW, msgW = msgW, contentW = contentW }
end

local function fillWidth(frac) return math.max(0, BAR_W * frac) end

local function build()
  local f = getFonts()
  local L = compute()
  layout = L
  local sf = targetScreen():frame()
  local frame = { x = math.floor(sf.x + (sf.w - L.w) / 2), y = math.floor(sf.y + sf.h - BOTTOM - L.h), w = L.w, h = L.h }

  -- A canvas still fading out would order itself out after we re-show it: start fresh.
  if canvas and fading then
    local old = canvas
    canvas = nil
    pcall(function() old:delete() end)
  end
  fading = false
  if fadeTimer then fadeTimer:stop() fadeTimer = nil end

  if not canvas then
    canvas = hs.canvas.new(frame)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary", "ignoresCycle" })
    canvas:clickActivating(false)
  else
    canvas:frame(frame)
  end

  local fg = theme.color("foreground")
  local left = BORDER + PAD
  local midY = L.h / 2
  local els = {
    { type = "rectangle", action = "strokeAndFill",
      frame = { x = BORDER / 2, y = BORDER / 2, w = L.w - BORDER, h = L.h - BORDER },
      fillColor = theme.color("background", 0.97), strokeColor = theme.color("accent"),
      strokeWidth = BORDER, roundedRectRadii = { xRadius = RADIUS, yRadius = RADIUS } },
  }

  -- icon, centred in its column
  local iconH = measure(st.icon, f.icon, ICON_SIZE).h
  els[#els + 1] = { type = "text", text = st.icon, textFont = f.icon, textSize = ICON_SIZE, textColor = fg,
    textAlignment = "center", textLineBreak = "clip",
    frame = { x = left + (L.iconW - L.iconAdv) / 2 - ICON_SIZE, y = midY - iconH / 2, w = L.iconAdv + ICON_SIZE * 2, h = iconH } }

  local x = left + L.iconW
  local textH = measure("100%", f.bold, TEXT_SIZE).h
  if st.hasProgress then
    x = x + GAP
    local barY = math.floor(midY - BAR_H / 2)
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = theme.color("foreground", 0.45),
      frame = { x = x, y = barY, w = BAR_W, h = BAR_H } }
    els[#els + 1] = { id = "fill", type = "rectangle", action = "fill", fillColor = theme.color("accent"),
      frame = { x = x, y = barY, w = fillWidth(fillFrom), h = BAR_H } }
    L.barX, L.barY = x, barY
    x = x + BAR_W + GAP
    els[#els + 1] = { type = "text", text = st.message, textFont = f.bold, textSize = TEXT_SIZE, textColor = fg,
      textAlignment = "right", textLineBreak = "truncateTail",
      frame = { x = x, y = midY - textH / 2, w = L.valueW, h = textH } }
  elseif st.message ~= "" then
    x = x + MSG_GAP
    els[#els + 1] = { type = "text", text = st.message, textFont = f.bold, textSize = TEXT_SIZE, textColor = fg,
      textAlignment = "left", textLineBreak = "truncateTail",
      frame = { x = x, y = midY - textH / 2, w = L.msgW + 1, h = textH } }
  end
  canvas:replaceElements(els)
end

local function setFill(frac)
  currentFrac = frac
  if not (canvas and layout and layout.barX) then return end
  for i = 1, #canvas do
    if canvas[i].id == "fill" then
      canvas[i].frame = { x = layout.barX, y = layout.barY, w = fillWidth(frac), h = BAR_H }
      return
    end
  end
end

-- Behavior on width { NumberAnimation { duration: 140; easing: OutCubic } } while open.
local function animateFill()
  stopAnim()
  if fillFrom == fillTo then setFill(fillTo) return end
  animStart = hs.timer.secondsSinceEpoch()
  animTimer = hs.timer.doEvery(1 / 60, function()
    local t = (hs.timer.secondsSinceEpoch() - animStart) * 1000 / ANIM_MS
    if t >= 1 or not st.opened then
      stopAnim()
      fillFrom = fillTo
      setFill(fillTo)
      return
    end
    local e = 1 - (1 - t) ^ 3
    setFill(fillFrom + (fillTo - fillFrom) * e)
  end)
end

function M.close()
  stopAnim()
  if hideTimer then hideTimer:stop() hideTimer = nil end
  if not st.opened then return end
  st.opened = false
  if canvas then
    fading = true
    pcall(function() canvas:hide(FADE_OUT) end)
    if fadeTimer then fadeTimer:stop() end
    fadeTimer = hs.timer.doAfter(FADE_OUT + 0.1, function() fading = false fadeTimer = nil end)
  end
end

-- Lua entry point (same arguments as Osd.qml show()). `trusted` callers may pass duration 0.
local function show(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration, trusted)
  local nxt = stateForShow(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration)
  if not trusted then
    if nxt.duration == 0 or nxt.duration > URL_MAX_DURATION then nxt.duration = URL_MAX_DURATION end
  end
  local wasOpen = st.opened and canvas ~= nil
  local prevFrac = nil
  if wasOpen and st.hasProgress and nxt.hasProgress then
    prevFrac = currentFrac or fillFrom
  end
  for k, v in pairs(nxt) do st[k] = v end

  local frac = st.hasProgress and (st.value / st.maxValue) or 0
  if prevFrac then
    -- continue from wherever the bar currently is drawn
    stopAnim()
    fillFrom, fillTo = prevFrac, frac
  else
    stopAnim()
    fillFrom, fillTo = frac, frac
  end

  local ok, err = pcall(build)
  if not ok then
    log.e("osd: could not draw: %s", tostring(err))
    return
  end
  st.opened = true
  canvas:show()
  if prevFrac then animateFill() else setFill(frac) end

  if hideTimer then hideTimer:stop() hideTimer = nil end
  if st.duration > 0 then
    hideTimer = hs.timer.doAfter(st.duration / 1000, M.close)
  end
end

local function str(v, limit)
  if v == nil or v == hs.json.null then return nil end
  local t = type(v)
  if t ~= "string" and t ~= "number" and t ~= "boolean" then return nil end
  local s = tostring(v)
  s = s:gsub("[%c]", " ")
  if #s > limit then
    s = s:sub(1, limit)
    -- drop a trailing partial UTF-8 sequence
    s = s:gsub("[\192-\255][\128-\191]*$", "")
  end
  return s
end

-- Omarchy Osd.qml open(payloadJson).
function M.open(payloadJson, trusted)
  if type(payloadJson) ~= "string" or #payloadJson > MAX_PAYLOAD_BYTES then
    log.w("osd: show refused, payload missing or too large")
    return
  end
  local ok, p = pcall(hs.json.decode, payloadJson ~= "" and payloadJson or "{}")
  if not ok or type(p) ~= "table" then
    log.w("osd: show refused, payload is not a JSON object")
    return
  end
  local icon = str(p.icon, MAX_ICON_BYTES) or ""
  local message = str(p.message, MAX_MESSAGE_BYTES) or ""
  local value = p.value == nil and "" or (str(p.value, 16) or "")
  local max = p.max == nil and "100" or (str(p.max, 16) or "100")
  local progressText = str(p.progressText, 32) or ""
  local duration = p.duration == nil and "1200" or (str(p.duration, 16) or "1200")
  show(icon, message, value, max, progressText, duration, trusted)
  log.i("osd: show icon=%s progress=%s", icon:match("^[%w%-]*$") and icon or "(glyph)", tostring(st.hasProgress))
end

-- Lua convenience for other omarchy modules: M.showTable{ icon = "volume", value = 40 }.
function M.showTable(t)
  local ok, text = pcall(hs.json.encode, t or {})
  if ok and text then M.open(text, true) end
end

function M.state() return st.opened and "open" or "closed" end
function M.ping() return "ok" end

---------------------------------------------------------------- Omarchy key actions
local function stepArg(x)
  local n = parseInt(x)
  if n == nil then return STEP_DEFAULT end
  return clamp(n, 1, 25)
end

local function outputDevice() return hs.audiodevice.defaultOutputDevice() end
local function inputDevice() return hs.audiodevice.defaultInputDevice() end

local function showVolume(dev)
  local vol = dev and dev:outputVolume()
  if not vol then toast.warn("This output has no volume control") return end
  local muted = dev:outputMuted()
  vol = round(vol)
  if muted then
    show("volume-muted", "", tostring(vol), "100", "", "1200", true)
  else
    show("", "", tostring(vol), "100", "", "1200", true)
  end
end

local function changeVolume(delta)
  local dev = outputDevice()
  if not dev then toast.warn("No audio output") return end
  local vol = dev:outputVolume()
  if not vol then toast.warn("This output has no volume control") return end
  if dev:outputMuted() and delta > 0 then dev:setOutputMuted(false) end
  dev:setOutputVolume(clamp(round(vol) + delta, 0, 100))
  showVolume(dev)
end

local function toggleMute()
  local dev = outputDevice()
  if not dev then toast.warn("No audio output") return end
  dev:setOutputMuted(not dev:outputMuted())
  showVolume(dev)
end

local function toggleMic()
  local dev = inputDevice()
  if not dev then toast.warn("No microphone") return end
  local muted = not dev:inputMuted()
  if not dev:setInputMuted(muted) then
    -- some inputs (e.g. built-in mics on recent Macs) have no mute control: fall back to gain
    local ok = dev:setInputVolume(muted and 0 or 75)
    if not ok then toast.warn("This microphone cannot be muted") return end
  end
  if muted then
    show("microphone-muted", "Microphone muted", "", "100", "", "1200", true)
  else
    show("microphone", "Microphone on", "", "100", "", "1200", true)
  end
end

local function changeBrightness(delta)
  local cur = hs.brightness.get()
  if not cur or cur < 0 then
    toast.warn("No built-in display brightness control")
    return
  end
  local target = clamp(round(cur) + delta, 0, 100)
  hs.brightness.set(target)
  show("brightness", "", tostring(target), "100", "", "1200", true)
end

M.actions = {
  ["osd.show"] = { fn = function(x) M.open(x, false) end,
    desc = "Show the on-screen display (x = Omarchy JSON payload: icon, message, value, max, progressText, duration)" },
  ["osd.close"] = { fn = function() M.close() end, desc = "Hide the on-screen display" },
  ["osd.volume-up"] = { fn = function(x) changeVolume(stepArg(x)) end, desc = "Raise output volume and show the OSD" },
  ["osd.volume-down"] = { fn = function(x) changeVolume(-stepArg(x)) end, desc = "Lower output volume and show the OSD" },
  ["osd.volume-mute"] = { fn = function() toggleMute() end, desc = "Toggle output mute and show the OSD" },
  ["osd.mic-mute"] = { fn = function() toggleMic() end, desc = "Toggle microphone mute and show the OSD" },
  ["osd.brightness-up"] = { fn = function(x) changeBrightness(stepArg(x)) end, desc = "Raise display brightness and show the OSD" },
  ["osd.brightness-down"] = { fn = function(x) changeBrightness(-stepArg(x)) end, desc = "Lower display brightness and show the OSD" },
}

---------------------------------------------------------------- lifecycle
function M.start()
  M.stop()
  fonts = nil   -- pick up a font installed since the last load
  return M
end

function M.stop()
  stopAnim()
  if hideTimer then hideTimer:stop() hideTimer = nil end
  if fadeTimer then fadeTimer:stop() fadeTimer = nil end
  fading = false
  currentFrac = nil
  st.opened = false
  if canvas then
    local c = canvas
    canvas = nil
    pcall(function() c:delete() end)
  end
  layout = nil
end

return M
