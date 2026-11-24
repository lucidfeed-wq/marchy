-- omarchy.audio: port of the Omarchy 4.5 shell plugin `omarchy.audio` (bar widget: volume
-- slider, output picker, per-app mixer).
--
-- The bar widget omarchy-audio draws everything. OmniShell already gives it the output volume,
-- mute, the output device list, the default microphone's level/mute and (with System Audio
-- Recording permission for OmniWM) the per-app mixer, and it changes them with OmniWM's own
-- `volume ...` / `microphone ...` commands. The one thing it cannot do is list and pick INPUT
-- devices, which Omarchy's panel does. This module fills that gap:
--   * publishes the input devices with `omniwmctl shell set omarchy_audio <json>`
--       { v = 1, inputs = { { u = <uid>, n = <label>, g = <glyph>, d = <is default> }, ... } }
--   * audio.input   x = <uid>  makes that device the default input (uid must be in the last list)
--   * audio.toggle             opens/closes the widget's popout (Omarchy SUPER+CTRL+A)
--   * audio.refresh            re-reads the device list
--
-- Device changes arrive through hs.audiodevice.watcher (event-driven, debounced); a 30 s
-- refresh catches anything the watcher misses. URL arguments are untrusted: a uid is only
-- accepted if it was in the list this module published. Nothing here reads audio content.
local M = { id = "audio" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local VAR = "omarchy_audio"
local WIDGET = "omarchy-audio"
local REFRESH_EVERY = 30
local MAX_INPUTS = 16

-- Nerd Font code points from Omarchy's Model.js sourceGlyph().
local G = {
  mic = "\u{F036C}", headset = "\u{F02CB}", bluetooth = "\u{F00AF}", camera = "\u{F0100}",
}

local lastJSON = nil
local known = {}      -- uid -> true, from the last published list
local timer, kick, debounce, watcherOwned = nil, nil, nil, false

local function push(tbl)
  local text = hs.json.encode(tbl)
  if not text or text == lastJSON then return end
  lastJSON = text
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("audio: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

---------------------------------------------------------------- Model.js (labels, glyphs)
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Case-insensitive strip of a Lua pattern (written in lower case). string.lower keeps byte
-- positions, so the match on the lowered copy indexes the original.
local function stripCI(s, pattern)
  local a, b = s:lower():find(pattern)
  if not a then return s end
  return s:sub(1, a - 1) .. s:sub(b + 1)
end

-- friendlyDeviceLabel()
local function friendly(label)
  local s = trim(label)
  s = stripCI(s, "^sof%-soundwire%s+")
  s = stripCI(s, "^built%-?in audio%s+")
  s = stripCI(s, "%s+output$")
  s = stripCI(s, "%s+input$")
  s = s:gsub("Microphones", "Microphone")
  return s
end

-- sourceGlyph(): headset, Bluetooth, webcam/camera, else a microphone.
local function sourceGlyph(name, transport)
  local blob = (tostring(name or "") .. " " .. tostring(transport or "")):lower()
  if blob:find("headset", 1, true) then return G.headset end
  if blob:find("bluetooth", 1, true) then return G.bluetooth end
  if blob:find("webcam", 1, true) or blob:find("camera", 1, true) then return G.camera end
  return G.mic
end

---------------------------------------------------------------- devices
function M.refresh()
  local okDef, def = pcall(hs.audiodevice.defaultInputDevice)
  local defUID = nil
  if okDef and def then
    local okU, u = pcall(function() return def:uid() end)
    if okU then defUID = u end
  end
  local okAll, devices = pcall(hs.audiodevice.allInputDevices)
  local list, ids = {}, {}
  for _, dev in ipairs((okAll and devices) or {}) do
    local okI, uid, name, transport = pcall(function() return dev:uid(), dev:name(), dev:transportType() end)
    -- OmniWM's per-app volume taps are private aggregate devices; never offer them.
    if okI and type(uid) == "string" and uid ~= "" and not uid:find("^com%.barut%.OmniWM%.")
      and #list < MAX_INPUTS then
      local label = friendly(name)
      if label == "" then label = "Unknown" end
      list[#list + 1] = { u = uid, n = label, g = sourceGlyph(name, transport), d = (uid == defUID) }
      ids[uid] = true
    end
  end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n < b.n end
    return a.u < b.u
  end)
  known = ids
  push({ v = 1, inputs = list })
end

local function refreshSoon()
  if debounce then debounce:start() else M.refresh() end
end

function M.setInput(uid)
  if type(uid) ~= "string" or #uid > 512 or not known[uid] then
    log.w("audio: input refused, not a listed device")
    return
  end
  local ok, dev = pcall(hs.audiodevice.findDeviceByUID, uid)
  if not ok or not dev then
    toast.warn("That input device is gone")
    refreshSoon()
    return
  end
  local okSet, done = pcall(function() return dev:setDefaultInputDevice() end)
  if not okSet or not done then
    toast.warn("Could not switch the input device")
    log.w("audio: setDefaultInputDevice failed")
  end
  refreshSoon()
end

function M.togglePanel()
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then
      log.w("audio: shell toggle failed: %s", tostring(err):sub(1, 160))
      toast.warn("Could not open the audio panel (is the omarchy-audio widget installed?)")
    end
  end, { "shell", "toggle", WIDGET }):start()
end

---------------------------------------------------------------- actions
M.actions = {
  ["audio.input"] = { fn = function(x) M.setInput(x) end, desc = "Make an input device the default (x = device uid from the panel)" },
  ["audio.toggle"] = { fn = function() M.togglePanel() end, desc = "Open or close the audio panel" },
  ["audio.refresh"] = { fn = function() M.refresh() end, desc = "Re-read the audio input devices" },
}

---------------------------------------------------------------- lifecycle
function M.start()
  M.stop()
  debounce = hs.timer.delayed.new(0.3, function()
    local ok, err = pcall(M.refresh)
    if not ok then log.e("audio: refresh failed: %s", tostring(err)) end
  end)
  -- hs.audiodevice.watcher is a single global callback; this port is its only user here.
  local ok = pcall(function()
    hs.audiodevice.watcher.setCallback(function() refreshSoon() end)
    hs.audiodevice.watcher.start()
  end)
  watcherOwned = ok
  if not ok then log.w("audio: device watcher unavailable, polling only") end
  timer = hs.timer.doEvery(REFRESH_EVERY, function() pcall(M.refresh) end)
  kick = hs.timer.doAfter(1, function() kick = nil pcall(M.refresh) end)
  return M
end

function M.stop()
  if timer then timer:stop() timer = nil end
  if kick then kick:stop() kick = nil end
  if debounce then debounce:stop() debounce = nil end
  if watcherOwned then
    pcall(function()
      hs.audiodevice.watcher.stop()
      hs.audiodevice.watcher.setCallback(nil)
    end)
    watcherOwned = false
  end
end

return M
