-- omarchy.weather: port of the Omarchy 4.5 shell plugin `omarchy.weather` (weather pill).
--
-- The forecast itself is OmniWM's (ctx.data.weather, Open-Meteo) and is drawn entirely by
-- the bar widget omarchy-weather. This small backend covers the two things a widget cannot
-- do on its own:
--   weather.toggle   open/close the weather popout from a hotkey
--                    (Omarchy: SUPER+CTRL+ALT+W -> omarchy-notification-weather ->
--                    `omarchy-shell shell toggle omarchy.weather`); runs
--                    `omniwmctl shell toggle omarchy-weather`.
--   weather.status   Omarchy's right-click "omarchy-weather-status" notification
--                    ("<Place>  ·  Temp 13°C  ·  Wind 11 km/h") as a toast.
--                    x = "<temp>,<wind>,<c|f>" (integers + unit letter, sent by the widget)
--                    or "none". The place name is read here from OmniWM's [weather] city in
--                    ~/.config/omniwm/shell/shell.toml, never taken from the URL.
--
-- No timers, no network access, nothing persisted.
local M = { id = "weather" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local WIDGET = "omarchy-weather"
local SHELL_TOML = os.getenv("HOME") .. "/.config/omniwm/shell/shell.toml"

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- [weather] city = "..." from shell.toml (simple line scan; nil when coordinates are used).
local function configuredCity()
  local data = readFile(SHELL_TOML)
  if not data then return nil end
  local inSection = false
  for line in data:gmatch("[^\n]+") do
    local header = line:match("^%s*%[([^%]]+)%]%s*$")
    if header then
      inSection = header == "weather"
    elseif inSection then
      local city = line:match('^%s*city%s*=%s*"([^"]*)"') or line:match("^%s*city%s*=%s*'([^']*)'")
      if city then
        city = city:gsub("^%s+", ""):gsub("%s+$", "")
        if city ~= "" and #city <= 80 then return city end
        return nil
      end
    end
  end
  return nil
end

local function status(x)
  x = tostring(x or "")
  local t, w, u = x:match("^(%-?%d+),(%d+),([cf])$")
  if not t then
    if x ~= "none" then log.w("weather: status refused, bad argument") end
    toast.show("Weather unavailable", 2)
    return
  end
  t, w = tonumber(t), tonumber(w)
  if not t or not w or t < -100 or t > 160 or w > 500 then
    toast.show("Weather unavailable", 2)
    return
  end
  local place = configuredCity() or "Weather"
  place = place:sub(1, 1):upper() .. place:sub(2)
  local unit = u == "f" and "°F" or "°C"
  local windUnit = u == "f" and " mph" or " km/h"
  toast.show(string.format("%s  ·  Temp %s%s  ·  Wind %s%s", place, tostring(math.floor(t)), unit,
    tostring(math.floor(w)), windUnit), 3)
end

local function toggle()
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("weather: shell toggle failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "toggle", WIDGET }):start()
end

M.actions = {
  ["weather.toggle"] = { fn = function() toggle() end, desc = "Weather: open or close the weather panel" },
  ["weather.status"] = { fn = function(x) status(x) end, desc = "Weather: show the status line (x = temp,wind,c|f)" },
}

function M.start()
  return M
end

function M.stop()
end

return M
