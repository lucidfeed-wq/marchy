-- Screenshots, screen recording and the colour picker, with macOS's own
-- tools (no third-party upload path).
--
-- Screenshot: saved to ~/Pictures/Screenshots/screenshot-YYYY-MM-DD_HH-MM-SS.png,
-- copied to the clipboard, and announced with a notification whose "Edit"
-- button opens it in Preview. The notification carries no thumbnail, so a
-- screenshot of a chart never shows up in Notification Center.
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")
local toast = require("omarchy.toast")

M.dir = u.HOME .. "/Pictures/Screenshots"
local SCREENCAPTURE = "/usr/sbin/screencapture"
local live = {} -- keep notification objects alive until they are used

local function notify(path)
  local name = path:match("([^/]+)$")
  local note
  note = hs.notify.new(function()
    live[note] = nil
    u.run(u.OPEN, { "-a", "Preview", path })
  end, {
    title = "Screenshot saved",
    informativeText = "Copied to the clipboard. " .. name,
    hasActionButton = true,
    actionButtonTitle = "Edit",
    withdrawAfter = 15,
  })
  live[note] = true
  hs.timer.doAfter(60, function() live[note] = nil end)
  note:send()
end

local function shot(flags, what)
  -- screencapture -i reads Control as "send to clipboard instead of a file",
  -- so wait for Caps Lock (Ctrl+Opt+Cmd) to be let go before starting.
  u.afterModifiersReleased(function()
    if not u.mkdirp(M.dir) then return toast.warn("Cannot create " .. M.dir) end
    local file = M.dir .. "/screenshot-" .. u.stamp() .. ".png"
    local args = {}
    for _, f in ipairs(flags) do args[#args + 1] = f end
    args[#args + 1] = "-t"
    args[#args + 1] = "png"
    args[#args + 1] = file
    u.run(SCREENCAPTURE, args, function()
      if not u.exists(file) then
        log.i("capture: %s cancelled", what)
        return
      end
      local img = hs.image.imageFromPath(file)
      if img then hs.pasteboard.writeObjects(img) end
      log.i("capture: %s saved %s", what, file)
      notify(file)
    end, { quiet = true })
  end)
end

function M.region()
  shot({ "-i" }, "region")
end

function M.window()
  shot({ "-i", "-W" }, "window")
end

-- macOS's capture toolbar (record a region or the screen; stop from the
-- menu bar or by pressing ⇧⌘5 again). Posting a keystroke is not a tap.
function M.record()
  u.afterModifiersReleased(function()
    hs.eventtap.keyStroke({ "cmd", "shift" }, "5", 0)
  end)
end

function M.colorPicker()
  if not hs.application.launchOrFocusByBundleID("com.apple.DigitalColorMeter") then
    toast.warn("Digital Color Meter not found")
  end
end

return M
