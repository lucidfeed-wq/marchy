-- omarchy.netpanel: data + actions behind the interactive Wi-Fi and Bluetooth panels in the
-- Omarchy bar (OmniShell widgets omarchy-wifi / omarchy-bluetooth). OmniWM's own panels are
-- read-only, so this module:
--   * publishes state with `omniwmctl shell set omarchy_wifi|omarchy_bt <json>`
--   * performs clicks that arrive as hammerspoon://omarchy?a=<action>&x=<arg>
--
-- Wi-Fi: hs.wifi (scan/associate/power). macOS hides SSIDs unless Hammerspoon has Location
-- Services permission; without it the panel says so and offers the settings pane.
-- Bluetooth: /opt/homebrew/bin/blueutil (power, paired devices, connect/disconnect).
--
-- URL arguments are untrusted (any local app can open hammerspoon:// links): SSIDs must be in
-- the last scan, Bluetooth addresses must be paired devices from the last listing.
local M = {}

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local BLUEUTIL = "/opt/homebrew/bin/blueutil"
local NETWORKSETUP = "/usr/sbin/networksetup"
local IFACE = "en0"
local REFRESH_EVERY = 30

local last = { wifi = nil, bt = nil }
local scanned = {}   -- ssid -> network record (from the last scan)
local paired = {}    -- address -> device record
local known = {}     -- ssid -> true (preferred networks)
local timer, wifiWatcher

local function push(var, tbl)
  local text = hs.json.encode(tbl)
  if not text or text == last[var] then return end
  last[var] = text
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("netpanel: shell set %s failed: %s", var, tostring(err):sub(1, 160)) end
  end, { "shell", "set", var, text }):start()
end

local function locationOK()
  local ok, status = pcall(function() return hs.location.authorizationStatus() end)
  return ok and (status == "authorized" or status == "authorizedAlways" or status == "authorizedWhenInUse")
end

---------------------------------------------------------------- Wi-Fi
local function readKnown(done)
  hs.task.new(NETWORKSETUP, function(_, out)
    local k = {}
    for line in (out or ""):gmatch("[^\n]+") do
      local ssid = line:match("^%s+(.-)%s*$")
      if ssid and ssid ~= "" then k[ssid] = true end
    end
    known = k
    if done then done() end
  end, { "-listpreferredwirelessnetworks", IFACE }):start()
end

local function publishWifi(networks)
  local power = hs.wifi.interfaceDetails(IFACE)
  power = power and power.power
  local current = hs.wifi.currentNetwork(IFACE)
  local list = {}
  for _, n in ipairs(networks or {}) do
    if n.ssid and n.ssid ~= "" and n.ssid ~= current then
      list[#list + 1] = { s = n.ssid, r = n.rssi, sec = n.secure, k = known[n.ssid] or nil }
    end
  end
  table.sort(list, function(a, b)
    if (a.k and 1 or 0) ~= (b.k and 1 or 0) then return a.k ~= nil end
    return (a.r or -100) > (b.r or -100)
  end)
  while #list > 12 do table.remove(list) end
  push("omarchy_wifi", { v = 1, power = power and true or false, current = current,
    location = locationOK(), networks = list })
end

function M.scanWifi()
  local details = hs.wifi.interfaceDetails(IFACE)
  if not (details and details.power) then publishWifi({}) return end
  readKnown(function()
    local ok = pcall(hs.wifi.backgroundScan, function(found)
      scanned = {}
      local out = {}
      for _, n in ipairs(found or {}) do
        local ssid = n.ssid
        if ssid and ssid ~= "" then
          local sec = n.security and #n.security > 0 and not (n.security[1] or ""):lower():find("none") or false
          if not scanned[ssid] or (n.rssi or -100) > (scanned[ssid].rssi or -100) then
            scanned[ssid] = { ssid = ssid, rssi = n.rssi, secure = sec, raw = n }
          end
        end
      end
      for _, n in pairs(scanned) do out[#out + 1] = n end
      publishWifi(out)
    end, IFACE)
    if not ok then publishWifi({}) end
  end)
end

function M.wifiPower()
  local details = hs.wifi.interfaceDetails(IFACE)
  local on = not (details and details.power)
  hs.task.new(NETWORKSETUP, function()
    toast.show(on and "Wi-Fi on" or "Wi-Fi off", 1.2)
    hs.timer.doAfter(on and 4 or 1, M.scanWifi)
  end, { "-setairportpower", IFACE, on and "on" or "off" }):start()
end

function M.wifiJoin(ssid)
  local n = type(ssid) == "string" and scanned[ssid]
  if not n then log.w("netpanel: join refused, %s not in last scan", tostring(ssid):sub(1, 64)) return end
  local password = nil
  if n.secure and not known[ssid] then
    local button, text = hs.dialog.textPrompt("Join " .. ssid, "Enter the Wi-Fi password.", "", "Join", "Cancel", true)
    if button ~= "Join" then return end
    password = text
  end
  toast.show("Joining " .. ssid .. "…", 1.5)
  hs.timer.doAfter(0.05, function()
    local ok, result
    if password then
      ok, result = pcall(hs.wifi.associate, ssid, password, IFACE)
    else
      -- Known networks: networksetup uses the password saved in the keychain.
      ok, result = true, nil
      hs.task.new(NETWORKSETUP, function(code, out, err)
        local msg = ((out or "") .. (err or "")):gsub("%s+$", "")
        if code ~= 0 or msg:lower():find("could not") or msg:lower():find("error") then
          toast.warn("Could not join " .. ssid)
          log.w("netpanel: join %s failed: %s", ssid, msg:sub(1, 160))
        else
          toast.show("Connected to " .. ssid, 1.5)
        end
        hs.timer.doAfter(3, M.scanWifi)
      end, { "-setairportnetwork", IFACE, ssid }):start()
      return
    end
    if ok and result then toast.show("Connected to " .. ssid, 1.5) else toast.warn("Could not join " .. ssid) end
    hs.timer.doAfter(3, M.scanWifi)
  end)
end

---------------------------------------------------------------- Bluetooth
function M.refreshBluetooth()
  if not hs.fs.attributes(BLUEUTIL) then
    push("omarchy_bt", { v = 1, missing = true })
    return
  end
  hs.task.new(BLUEUTIL, function(_, powerOut)
    local power = (powerOut or ""):match("1") ~= nil
    if not power then
      paired = {}
      push("omarchy_bt", { v = 1, power = false, devices = {} })
      return
    end
    hs.task.new(BLUEUTIL, function(code, out)
      local ok, list = pcall(hs.json.decode, out or "")
      if code ~= 0 or not ok or type(list) ~= "table" then
        push("omarchy_bt", { v = 1, power = true, devices = {}, error = true })
        return
      end
      paired = {}
      local devices = {}
      for _, d in ipairs(list) do
        if d.address then
          paired[d.address] = d
          devices[#devices + 1] = { a = d.address, n = d.name or d.address, c = d.connected and true or false }
        end
      end
      table.sort(devices, function(a, b)
        if a.c ~= b.c then return a.c end
        return (a.n or "") < (b.n or "")
      end)
      push("omarchy_bt", { v = 1, power = true, devices = devices })
    end, { "--paired", "--format", "json" }):start()
  end, { "--power" }):start()
end

function M.btPower()
  hs.task.new(BLUEUTIL, function(_, out)
    local on = not ((out or ""):match("1") ~= nil)
    hs.task.new(BLUEUTIL, function()
      toast.show(on and "Bluetooth on" or "Bluetooth off", 1.2)
      hs.timer.doAfter(1.5, M.refreshBluetooth)
    end, { "--power", on and "1" or "0" }):start()
  end, { "--power" }):start()
end

function M.btDevice(address)
  local d = type(address) == "string" and paired[address]
  if not d then log.w("netpanel: bt refused, %s not a paired device", tostring(address):sub(1, 40)) return end
  local connect = not d.connected
  toast.show((connect and "Connecting " or "Disconnecting ") .. (d.name or address) .. "…", 1.5)
  hs.task.new(BLUEUTIL, function(code, out, err)
    if code ~= 0 then
      toast.warn("Could not " .. (connect and "connect " or "disconnect ") .. (d.name or address))
      log.w("netpanel: bt %s %s failed: %s", connect and "connect" or "disconnect", address, ((out or "") .. (err or "")):sub(1, 160))
    end
    hs.timer.doAfter(1, M.refreshBluetooth)
  end, { connect and "--connect" or "--disconnect", address }):start()
end

---------------------------------------------------------------- lifecycle
function M.refresh()
  M.scanWifi()
  M.refreshBluetooth()
end

function M.start()
  M.stop()
  -- Ask macOS for Location Services once so Wi-Fi network names are visible (Apple requires it).
  if not locationOK() then pcall(function() hs.location.start(); hs.timer.doAfter(2, hs.location.stop) end) end
  timer = hs.timer.doEvery(REFRESH_EVERY, M.refresh)
  wifiWatcher = hs.wifi.watcher.new(function() hs.timer.doAfter(1, M.scanWifi) end)
  pcall(function() wifiWatcher:watchingFor({ "SSIDChange", "powerChange", "linkChange" }) end)
  wifiWatcher:start()
  hs.timer.doAfter(1, M.refresh)
  return M
end

function M.stop()
  if timer then timer:stop() timer = nil end
  if wifiWatcher then wifiWatcher:stop() wifiWatcher = nil end
end

return M
