-- omarchy.media: port of the Omarchy 4.5 shell plugin `omarchy.media` (MPRIS media control
-- service + now-playing bar widget).
--
-- The bar widget omarchy-media reads macOS's system now-playing data straight from OmniWM
-- (ctx.data.media) and controls it with OmniWM's `media ...` commands, so it needs no Apple
-- Events / Automation permission for Music or Spotify and nothing from this module.
--
-- This module is the service half: the keyboard entry points Omarchy exposes over IPC
-- (media.playPause / next / previous, bound to the media keys). Hammerspoon posts the
-- system media key events (NX_KEYTYPE_PLAY / NEXT / PREVIOUS), which macOS routes to the
-- current now-playing app exactly as the keyboard's own media keys would. It never reads
-- track metadata, so no title, artist or album passes through here or into any log.
--
-- If the osd port is installed, each action also shows Omarchy's media OSD with the action
-- name (Omarchy shows "title - artist" there; that text is not available to Hammerspoon
-- without Apple Events, so the OSD falls back to the action label, as Omarchy does when it
-- has no track).
local M = { id = "media" }

local log = require("omarchy.log")

local KEYS = { playPause = "PLAY", next = "NEXT", previous = "PREVIOUS" }
local OSD = {
  playPause = { icon = "media", message = "Play/pause" },
  next = { icon = "media-next", message = "Next" },
  previous = { icon = "media-previous", message = "Previous" },
}

local function pressSystemKey(key)
  local ok, err = pcall(function()
    hs.eventtap.event.newSystemKeyEvent(key, true):post()
    hs.eventtap.event.newSystemKeyEvent(key, false):post()
  end)
  if not ok then log.w("media: posting %s failed: %s", key, tostring(err):sub(1, 160)) end
  return ok
end

local function showOsd(verb)
  local osd = package.loaded["omarchy.ports.osd"]
  local payload = OSD[verb]
  if type(osd) == "table" and type(osd.showTable) == "function" and payload then
    pcall(osd.showTable, { icon = payload.icon, message = payload.message })
  end
end

function M.run(verb)
  local key = KEYS[verb]
  if not key then return false end
  if pressSystemKey(key) then showOsd(verb) end
  return true
end

M.actions = {
  ["media.play-pause"] = { fn = function() M.run("playPause") end, desc = "Play or pause the current media" },
  ["media.next"] = { fn = function() M.run("next") end, desc = "Next track" },
  ["media.previous"] = { fn = function() M.run("previous") end, desc = "Previous track" },
}

function M.start()
  -- Nothing to watch: the widget reads now-playing data from OmniWM directly.
  return M
end

function M.stop()
end

return M
