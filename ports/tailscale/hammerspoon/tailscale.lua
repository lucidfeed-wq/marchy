-- omarchy.tailscale: port of the Omarchy 4.5 shell plugin `omarchy.tailscale` (bar widget).
--
-- Omarchy shows the Tailscale mark in the bar (3x3 dot grid, crossed out when disconnected,
-- "!" badge when the device needs login). Left click opens a panel: hero with an on/off
-- switch, CONNECTIONS (tailscale switch), EXIT NODES (tailnet exit nodes, recent Mullvad
-- regions, a searchable Mullvad region picker), MACHINES (online peers with a copy menu for
-- name / DNS name / IPv6 / IPv4 and a Taildrop "send files" button). Right click toggles
-- Tailscale on/off.
--
-- Here this module is the backend: it polls the macOS app's CLI
-- (/Applications/Tailscale.app/Contents/MacOS/Tailscale) with hs.task, publishes the state
-- as JSON with `omniwmctl shell set omarchy_tailscale <json>` (only when it changed), and
-- performs the clicks that arrive as hammerspoon://omarchy?a=tailscale.<verb>&x=<arg>.
-- The bar widget omarchy-tailscale renders it.
--
-- URL arguments are untrusted (any local app can open hammerspoon:// links): every peer,
-- account, exit node and region id is checked against the state this module last
-- published; nothing from a URL is ever passed to a shell (there is no shell at all, every
-- command is an argv list). Copied values and file paths are never logged.
local M = { id = "tailscale" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local TS = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local OPEN = "/usr/bin/open"
local VAR = "omarchy_tailscale"
local WIDGET = "omarchy-tailscale"
local SETTINGS_REFRESH = "omarchy.tailscale.refreshIntervalSec"
local SETTINGS_RECENT = "omarchy.tailscale.recentMullvadRegions"
local MAX_PEERS = 300          -- published machine rows (the widget has no virtualised list)
local BIG_TAILNET = 500        -- above this many peers, poll light (--peers=false) between refreshes
local FILE_SHARING = "https://tailscale.com/cap/file-sharing"

---------------------------------------------------------------- state
local S = {
  installed = false,
  backendState = "Unknown",
  running = false,
  needsLogin = false,
  authUrl = "",
  selfName = "",
  selfDns = "",
  selfIp = "",
  selfUserId = "",
  fileSharing = false,
  peers = {},              -- normalized online peers, sorted
  peersLoaded = false,
  peerCount = 0,
  tailnetExits = {},
  mullvadNodes = {},
  regions = {},            -- Mullvad region options
  accounts = {},
  selectedAccountId = "",
  switchingAccountId = "",
  settingExitNodeId = "",
  actionStatus = "",
  lastError = "",
  desired = -1,            -- optimistic toggle: -1 follow reality, 0 off, 1 on
  statusText = "Checking…",
}

local byPeer = {}          -- published peer id -> peer
local byExit = {}          -- published exit id -> { kind, target, region? , active }
local byAccount = {}       -- account id -> account
local last = nil           -- last published JSON

local tasks = {}           -- kind -> running hs.task
local timers = {}          -- name -> hs.timer
local lastAccountsAt = 0
local lastFull = false
local pendingFull = false
local login = { active = false, opened = false, preUrl = "" }

---------------------------------------------------------------- helpers
local function isActive()
  if S.desired == -1 then return S.running end
  return S.desired == 1
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function elide(s)
  local v = trim(tostring(s or ""):gsub("%s+", " "))
  if #v > 140 then v = v:sub(1, 137) .. "…" end
  return v
end

local function str(v)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  return ""
end

local function lower(s) return str(s):lower() end

local function endsWith(s, suffix)
  return #s >= #suffix and s:sub(-#suffix) == suffix
end

local function filterIPv4(ips)
  local out = {}
  if type(ips) ~= "table" then return out end
  for _, ip in ipairs(ips) do
    ip = str(ip)
    if ip:match("^100%.") then out[#out + 1] = ip end
  end
  return out
end

local function filterIPv6(ips)
  local out = {}
  if type(ips) ~= "table" then return out end
  for _, ip in ipairs(ips) do
    ip = str(ip)
    if ip:lower():match("^fd7a:115c:a1e0:") then out[#out + 1] = ip end
  end
  return out
end

local function cleanDns(name)
  local v = str(name)
  if v:sub(-1) == "." then v = v:sub(1, -2) end
  return v
end

local function shortDns(name)
  local clean = cleanDns(name)
  if clean == "" then return "" end
  return clean:match("^([^%.]+)") or clean
end

local function displayHostName(host, dns)
  host = str(host)
  if host ~= "" and host:lower() ~= "localhost" then return host end
  local short = shortDns(dns)
  if short ~= "" then return short end
  if host ~= "" then return host end
  return "Unknown"
end

local function isMullvadHost(name)
  local v = lower(name)
  local suffix = ".mullvad.ts.net"
  return #v > #suffix and endsWith(v, suffix)
end

local function hasFileSharing(self)
  if type(self) ~= "table" then return false end
  if type(self.CapMap) == "table" and self.CapMap[FILE_SHARING] ~= nil then return true end
  if type(self.Capabilities) == "table" then
    for _, c in ipairs(self.Capabilities) do
      if str(c) == FILE_SHARING then return true end
    end
  end
  return false
end

-- Tailscale grades Taildrop targets itself (1 = available); older daemons: same owner.
local function isTaildropTarget(peer)
  local t = peer.taildrop
  if type(t) == "number" and t ~= 0 then return t == 1 end
  return peer.userId ~= "" and peer.userId == S.selfUserId
end

local function canSend(peer)
  return S.fileSharing and S.running and peer ~= nil and isTaildropTarget(peer)
end

local function peerAddress(peer)
  if not peer then return "" end
  if peer.dns ~= "" then return peer.dns end
  if peer.host ~= "" then return peer.host end
  return peer.ips[1] or ""
end

-- Byte offset -> rune-aware substring (the CLI pads columns by runes, not bytes).
local function runes(s)
  local list = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = 1
    if c >= 0xF0 then len = 4 elseif c >= 0xE0 then len = 3 elseif c >= 0xC0 then len = 2 end
    list[#list + 1] = s:sub(i, i + len - 1)
    i = i + len
  end
  return list
end

local function column(chars, from, to)
  -- from/to are 1-based rune positions; to = nil means "to the end"
  if from < 1 or from > #chars then return "" end
  local stop = to and math.min(to - 1, #chars) or #chars
  local out = {}
  for i = from, stop do out[#out + 1] = chars[i] end
  return trim(table.concat(out))
end

local function sortBy(list, key)
  table.sort(list, function(a, b)
    local x, y = lower(a[key]), lower(b[key])
    if x == y then return str(a.id) < str(b.id) end
    return x < y
  end)
end

---------------------------------------------------------------- process runner
-- No argument logging (file paths for Taildrop are private); no shell.
local function run(kind, args, cb, streaming)
  local task
  local ok = pcall(function()
    local function done(code, out, errOut)
      if tasks[kind] == task then tasks[kind] = nil end
      local cok, cerr = pcall(cb, code, out or "", errOut or "")
      if not cok then log.e("tailscale: %s callback failed: %s", kind, tostring(cerr)) end
    end
    if streaming then
      task = hs.task.new(TS, done, streaming, args)
    else
      task = hs.task.new(TS, done, args)
    end
    if not task:start() then error("start failed") end
  end)
  if not ok then
    tasks[kind] = nil
    log.e("tailscale: could not start %s", kind)
    pcall(cb, -1, "", "could not start the Tailscale CLI")
    return nil
  end
  tasks[kind] = task
  return task
end

local function busy()
  for _, t in pairs(tasks) do
    if t then return true end
  end
  return false
end

local function openURL(url)
  if type(url) ~= "string" or not url:match("^https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+$") then return false end
  pcall(function() hs.task.new(OPEN, nil, { url }):start() end)
  return true
end

---------------------------------------------------------------- publish
local function publish()
  local active = isActive()
  local out = {
    v = 1,
    installed = S.installed,
    active = active,
    running = S.running,
    login = S.needsLogin,
    state = S.backendState,
    name = S.selfName,
    dns = S.selfDns,
    ip = S.selfIp,
    busy = busy(),
    loaded = S.peersLoaded,
    total = S.peerCount,
    peers = {},
    exits = {},
    regions = {},
    accounts = {},
  }
  if S.actionStatus ~= "" then
    out.msg = S.actionStatus
  elseif S.lastError ~= "" then
    out.msg = S.lastError
    out.err = true
  end

  byPeer = {}
  if S.installed and active then
    for i, p in ipairs(S.peers) do
      if i > MAX_PEERS then break end
      byPeer[p.id] = p
      out.peers[#out.peers + 1] = {
        id = p.id, n = p.name, dns = p.dns, ip = p.ips[1] or "", ip6 = p.ip6s[1] or "",
        os = p.os, send = canSend(p) or nil,
      }
    end
  end

  byExit = {}
  if S.running and active then
    for _, p in ipairs(S.tailnetExits) do
      local id = "peer:" .. p.id
      local target = peerAddress(p)
      byExit[id] = { kind = "peer", target = target, active = p.exitNode }
      out.exits[#out.exits + 1] = { id = id, n = p.name, act = p.exitNode or nil,
        busy = (S.settingExitNodeId == id) or nil }
    end
    -- Recent Mullvad regions: active ones first, then remembered ones (max 5).
    local recent = hs.settings.get(SETTINGS_RECENT)
    if type(recent) ~= "table" then recent = {} end
    local seen, shown = {}, 0
    local regionByKey = {}
    for _, r in ipairs(S.regions) do regionByKey[r.key] = r end
    local function addRecent(r)
      if shown >= 5 or seen[r.key] then return end
      seen[r.key] = true
      shown = shown + 1
      local id = "region:" .. r.key
      out.exits[#out.exits + 1] = { id = id, n = r.city .. ", " .. r.country, mv = true,
        act = r.active or nil, busy = (S.settingExitNodeId == id) or nil }
    end
    for _, r in ipairs(S.regions) do if r.active then addRecent(r) end end
    for _, key in ipairs(recent) do
      local r = regionByKey[str(key)]
      if r then addRecent(r) end
    end
    for _, r in ipairs(S.regions) do
      local id = "region:" .. r.key
      byExit[id] = { kind = "region", target = r.ip, region = r.key, active = r.active }
      out.regions[#out.regions + 1] = { id = id, city = r.city, country = r.country,
        act = r.active or nil, busy = (S.settingExitNodeId == id) or nil }
    end
  end

  byAccount = {}
  if #S.accounts > 1 then
    for _, a in ipairs(S.accounts) do
      byAccount[a.id] = a
      out.accounts[#out.accounts + 1] = { id = a.id, label = a.label, sel = a.selected or nil,
        busy = (S.switchingAccountId == a.id) or nil }
    end
  end

  local okEnc, text = pcall(hs.json.encode, out)
  if not okEnc or not text or text == last then return end
  last = text
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("tailscale: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

local function flash(message)
  S.actionStatus = message or ""
  publish()
  if timers.flash then timers.flash:stop() end
  timers.flash = hs.timer.doAfter(2.2, function()
    timers.flash = nil
    S.actionStatus = ""
    publish()
  end)
end

---------------------------------------------------------------- parsing (Model.js)
local function resetUnavailable(message)
  S.running = false
  S.needsLogin = false
  S.desired = -1
  S.backendState = "Unavailable"
  S.statusText = message
  S.selfName, S.selfDns, S.selfIp, S.selfUserId = "", "", "", ""
  S.fileSharing = false
  S.authUrl = ""
  S.peers, S.tailnetExits, S.mullvadNodes, S.regions = {}, {}, {}, {}
  S.peersLoaded = false
  S.peerCount = 0
  S.accounts = {}
  S.selectedAccountId = ""
  S.switchingAccountId = ""
  S.settingExitNodeId = ""
end

local function normalizePeer(id, raw)
  local dns = cleanDns(raw.DNSName)
  local host = str(raw.HostName)
  local stable = str(raw.ID)
  if stable == "" or not stable:match("^[%w%-_:]+$") then stable = str(id) end
  return {
    id = stable,
    host = displayHostName(host, raw.DNSName),
    name = displayHostName(host, raw.DNSName),
    dns = dns,
    userId = str(raw.UserID),
    taildrop = type(raw.TaildropTarget) == "number" and raw.TaildropTarget or 0,
    ips = filterIPv4(raw.TailscaleIPs),
    ip6s = filterIPv6(raw.TailscaleIPs),
    online = raw.Online == true,
    os = lower(raw.OS),
    exitOption = raw.ExitNodeOption == true,
    exitNode = raw.ExitNode == true,
    mullvad = isMullvadHost(dns) or isMullvadHost(host),
  }
end

local function parseStatus(raw, full)
  local textIn = trim(raw)
  if textIn == "" then resetUnavailable("Disconnected") return end
  local ok, data = pcall(hs.json.decode, textIn)
  if not ok or type(data) ~= "table" then
    resetUnavailable("Status error")
    S.lastError = "Failed to parse tailscale status"
    log.w("tailscale: could not parse status")
    return
  end
  S.backendState = str(data.BackendState) ~= "" and str(data.BackendState) or "Unknown"
  S.running = S.backendState == "Running"
  if S.desired ~= -1 and S.running == (S.desired == 1) then S.desired = -1 end
  S.needsLogin = S.backendState == "NeedsLogin"
  S.authUrl = str(data.AuthURL)
  if S.needsLogin and login.active and not login.opened and S.authUrl ~= "" and S.authUrl ~= login.preUrl then
    if openURL(S.authUrl) then login.opened = true login.active = false S.desired = -1 end
  end
  local self = type(data.Self) == "table" and data.Self or {}
  S.selfName = displayHostName(self.HostName, self.DNSName)
  S.selfDns = cleanDns(self.DNSName)
  local ips = filterIPv4(self.TailscaleIPs or data.TailscaleIPs)
  S.selfIp = ips[1] or ""
  S.selfUserId = str(self.UserID)
  S.fileSharing = hasFileSharing(self)

  if full then
    local peers, exits, count = {}, {}, 0
    if type(data.Peer) == "table" then
      for id, rawPeer in pairs(data.Peer) do
        count = count + 1
        if type(rawPeer) == "table" then
          local p = normalizePeer(id, rawPeer)
          if not p.mullvad and p.online then
            peers[#peers + 1] = p
            if p.exitOption then exits[#exits + 1] = p end
          end
        end
      end
    end
    sortBy(peers, "host")
    sortBy(exits, "host")
    S.peerCount = S.running and #peers or 0
    S.peers = S.running and peers or {}
    S.tailnetExits = S.running and exits or {}
    S.peersLoaded = S.running
    S.bigTailnet = count > BIG_TAILNET
  elseif not S.running then
    S.peers, S.tailnetExits = {}, {}
    S.peersLoaded = false
    S.peerCount = 0
  end

  if S.needsLogin then
    S.statusText = "Needs login"
  elseif S.running then
    S.statusText = "Connected"
    login.active, login.opened, login.preUrl = false, false, ""
    if timers.login then timers.login:stop() timers.login = nil end
  elseif S.backendState == "Stopped" then
    S.statusText = "Disconnected"
  else
    S.statusText = S.backendState
  end
  S.lastError = ""
end

local function parseAccounts(raw)
  local ok, data = pcall(hs.json.decode, trim(raw))
  local list, selected = {}, ""
  if ok and type(data) == "table" then
    for _, a in ipairs(data) do
      if type(a) == "table" then
        local acc = {
          id = str(a.id ~= nil and a.id or a.ID),
          nickname = str(a.nickname or a.Nickname or a.name or a.Name),
          tailnet = str(a.tailnet or a.Tailnet),
          account = str(a.account or a.Account or a.loginName or a.LoginName or a.user or a.User),
          selected = a.selected == true or a.Selected == true,
        }
        acc.label = (acc.nickname ~= "" and acc.nickname) or (acc.tailnet ~= "" and acc.tailnet)
          or (acc.account ~= "" and acc.account) or (acc.id ~= "" and acc.id) or "Unknown account"
        if acc.id ~= "" and acc.id:match("^[%w%-_%.@]+$") then
          list[#list + 1] = acc
          if acc.selected then selected = acc.id end
        end
      end
    end
  end
  S.accounts = list
  S.selectedAccountId = selected
end

-- `tailscale exit-node list`: IP  HOSTNAME  COUNTRY  CITY  STATUS (Mullvad rows only).
local function parseExitNodeList(raw)
  local lines = {}
  for line in (tostring(raw or "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (line:gsub("\r$", "")) end
  local header, headerIndex = nil, nil
  for i, line in ipairs(lines) do
    if line:match("^%s*IP%s+HOSTNAME%s+COUNTRY%s+CITY%s+STATUS%s*$") then header, headerIndex = line, i break end
  end
  if not header then return {} end
  local ipS = header:find("IP", 1, true)
  local hostS = header:find("HOSTNAME", 1, true)
  local countryS = header:find("COUNTRY", 1, true)
  local cityS = header:find("CITY", 1, true)
  local statusS = header:find("STATUS", 1, true)
  local byHost = {}
  for j = headerIndex + 1, #lines do
    local line = lines[j]
    if not line:match("^%s*$") and not line:match("^%s*#") then
      local chars = runes(line)
      local ip = column(chars, ipS, hostS)
      local host = column(chars, hostS, countryS)
      local country = column(chars, countryS, cityS)
      local city = column(chars, cityS, statusS)
      local status = column(chars, statusS, nil)
      if isMullvadHost(host) and ip:match("^100%.[%d%.]+$") then
        byHost[host] = { host = host, ip = ip, country = country, city = city,
          active = status ~= "" and status ~= "-" }
      end
    end
  end
  local out = {}
  for _, n in pairs(byHost) do out[#out + 1] = n end
  table.sort(out, function(a, b)
    if a.country ~= b.country then return a.country < b.country end
    if a.city ~= b.city then return a.city < b.city end
    return a.host < b.host
  end)
  return out
end

local function regionOptions(nodes)
  local byKey, order = {}, {}
  for _, n in ipairs(nodes) do
    if n.country ~= "" and n.city ~= "" and n.city ~= "Any" then
      local key = n.country .. "/" .. n.city
      local r = byKey[key]
      if not r then
        r = { key = key, country = n.country, city = n.city, ip = n.ip, active = false }
        byKey[key] = r
        order[#order + 1] = r
      end
      if n.active then r.active = true r.ip = n.ip end
    end
  end
  return order
end

---------------------------------------------------------------- polling
local function stopWatchdog()
  if timers.watchdog then timers.watchdog:stop() timers.watchdog = nil end
end

local function armWatchdog()
  if timers.watchdog then return end
  -- A hung CLI (network coming and going) must not stop refreshing for good.
  timers.watchdog = hs.timer.doAfter(15, function()
    timers.watchdog = nil
    for _, kind in ipairs({ "status", "accounts", "exitnodes" }) do
      local t = tasks[kind]
      if t then pcall(function() t:terminate() end) tasks[kind] = nil end
    end
  end)
end

function M.refresh(forceAccounts, forceFull)
  S.installed = hs.fs.attributes(TS) ~= nil
  if not S.installed then
    resetUnavailable("Not installed")
    publish()
    return
  end
  local launched = false
  local wantFull = forceFull or pendingFull or not S.bigTailnet
  if not tasks.status then
    pendingFull = false
    lastFull = wantFull
    local args = wantFull and { "status", "--json" } or { "status", "--json", "--peers=false" }
    run("status", args, function(code, out, err)
      if code == 0 then
        parseStatus(out, lastFull)
      else
        resetUnavailable("Disconnected")
        S.lastError = elide(err)
      end
      publish()
      if pendingFull then M.refresh(false, true) end
    end)
    launched = true
  elseif forceFull and not lastFull then
    pendingFull = true
  end
  if not tasks.exitnodes then
    run("exitnodes", { "exit-node", "list" }, function(code, out)
      S.mullvadNodes = code == 0 and parseExitNodeList(out) or {}
      S.regions = regionOptions(S.mullvadNodes)
      publish()
    end)
    launched = true
  end
  local now = hs.timer.secondsSinceEpoch()
  if (forceAccounts or #S.accounts == 0 or now - lastAccountsAt > 60) and not tasks.accounts then
    lastAccountsAt = now
    run("accounts", { "switch", "--list", "--json" }, function(code, out, err)
      if code == 0 then
        parseAccounts(out)
      else
        S.accounts = {}
        S.selectedAccountId = ""
        local why = elide(err ~= "" and err or out)
        S.lastError = why ~= "" and why or "Could not list Tailscale connections"
      end
      publish()
    end)
    launched = true
  end
  if launched then armWatchdog() end
end

local function delayedRefresh()
  if timers.delayed then timers.delayed:stop() end
  timers.delayed = hs.timer.doAfter(0.6, function()
    timers.delayed = nil
    M.refresh(false, true)
  end)
end

---------------------------------------------------------------- actions
local function runAction(kind, args, failure, after)
  if tasks[kind] then return false end
  run(kind, args, function(code, out, err)
    if code ~= 0 then
      local why = elide(err ~= "" and err or out)
      S.lastError = why ~= "" and why or failure
      if after then after(false) end
      flash(S.lastError)
    else
      S.lastError = ""
      S.actionStatus = ""
      if after then after(true) end
    end
    publish()
    delayedRefresh()
  end)
  publish()
  return true
end

function M.down()
  if not S.installed then return end
  S.desired = 0
  publish()
  runAction("action", { "down" }, "Tailscale command failed", function(ok)
    if not ok then S.desired = -1 end
  end)
end

local function handleLoginChunk(chunk)
  if login.active and not login.opened then
    local url = tostring(chunk or ""):match("https?://%S+")
    if url and openURL(url) then
      login.opened = true
      login.active = false
      S.desired = -1
      if timers.login then timers.login:stop() timers.login = nil end
    end
  end
end

function M.up()
  if not S.installed or tasks.login then return end
  S.desired = -1
  -- Model.loginPlan: a pending auth URL is opened in the browser; otherwise `tailscale up`.
  if S.needsLogin and S.authUrl:match("^https?://") then
    login.opened = false
    if openURL(S.authUrl) then login.opened = true end
    return
  end
  if S.needsLogin then S.actionStatus = "Starting Tailscale login…" else S.desired = 1 end
  login.active = S.needsLogin
  login.opened = false
  login.preUrl = S.authUrl
  local collected = {}
  run("login", { "up" }, function(code, out, err)
    collected[#collected + 1] = out
    collected[#collected + 1] = err
    local all = table.concat(collected, "\n")
    local opened = login.opened
    if not opened then
      local url = all:match("https?://%S+") or (S.authUrl ~= "" and S.authUrl or nil)
      if url and (login.active or code ~= 0) and openURL(url) then opened = true login.opened = true end
    end
    if code ~= 0 and not opened then
      S.desired = -1
      login.active = false
      local why = elide(all)
      S.lastError = why ~= "" and why or "tailscale up failed"
      flash(S.lastError)
    elseif not opened then
      S.lastError = ""
      S.actionStatus = ""
    end
    publish()
    delayedRefresh()
  end, function(_, out, err)
    if out and out ~= "" then collected[#collected + 1] = out handleLoginChunk(out) end
    if err and err ~= "" then collected[#collected + 1] = err handleLoginChunk(err) end
    return true
  end)
  publish()
  if S.needsLogin then
    if timers.login then timers.login:stop() end
    timers.login = hs.timer.doAfter(10, function()
      timers.login = nil
      if not login.active or login.opened then return end
      if S.authUrl ~= "" and openURL(S.authUrl) then
        login.opened = true
      else
        login.active = false
        flash("Tailscale login link not available yet")
      end
    end)
  end
end

function M.toggle()
  if not S.installed then return end
  if isActive() then M.down() else M.up() end
end

local function switchAccount(x)
  local a = type(x) == "string" and byAccount[x]
  if not a then log.w("tailscale: switch refused, unknown account id") return end
  if a.id == S.selectedAccountId or tasks.switch then return end
  S.switchingAccountId = a.id
  runAction("switch", { "switch", a.id }, "Account switch failed", function(ok)
    S.switchingAccountId = ""
    if ok then lastAccountsAt = 0 end
  end)
end

local function setExitNode(x)
  local e = type(x) == "string" and byExit[x]
  if not e then log.w("tailscale: exit node refused, unknown id") return end
  if not S.running or tasks.exitnode then return end
  local target = e.active and "" or e.target
  if not e.active then
    if target == "" or not target:match("^[%w%-%.:]+$") then return end
    if e.kind == "region" then
      -- Remember it like Omarchy's recentMullvadRegions (max 5, newest first).
      local recent = hs.settings.get(SETTINGS_RECENT)
      if type(recent) ~= "table" then recent = {} end
      local nextList = { e.region }
      for _, k in ipairs(recent) do
        if #nextList >= 5 then break end
        if type(k) == "string" and k ~= e.region then nextList[#nextList + 1] = k end
      end
      hs.settings.set(SETTINGS_RECENT, nextList)
    end
  end
  S.settingExitNodeId = x
  runAction("exitnode", { "set", "--exit-node=" .. target }, "Exit node selection failed", function()
    S.settingExitNodeId = ""
  end)
end

local COPY_KINDS = { name = "name", dns = "DNS name", ip = "IP", ip6 = "IPv6" }

local function copy(x)
  local kind, id = tostring(x or ""):match("^(%a+%d?):(.+)$")
  local p = id and byPeer[id]
  if not p or not COPY_KINDS[kind] then log.w("tailscale: copy refused, unknown machine or kind") return end
  local value
  if kind == "name" then value = p.name
  elseif kind == "dns" then value = p.dns
  elseif kind == "ip" then value = p.ips[1]
  else value = p.ip6s[1] end
  if not value or value == "" then return end
  hs.pasteboard.setContents(value)
  toast.show("Copied " .. p.name .. " " .. COPY_KINDS[kind], 1.2)
end

local function send(x)
  local p = type(x) == "string" and byPeer[x]
  if not p then log.w("tailscale: send refused, unknown machine") return end
  if not canSend(p) then toast.warn("Taildrop is not available for " .. p.name) return end
  local target = peerAddress(p)
  if target == "" or not target:match("^[%w%-%.:]+$") then return end
  local short = target:match("^([^%.]+)") or target
  pcall(function() hs.focus() end)
  local picked = hs.dialog.chooseFileOrFolder("Send to " .. short, os.getenv("HOME"), true, false, true)
  if type(picked) ~= "table" then return end
  local files = {}
  for _, path in pairs(picked) do
    if type(path) == "string" and path:sub(1, 1) == "/" then files[#files + 1] = path end
  end
  if #files == 0 then return end
  table.sort(files)
  local args = { "file", "cp", "--update-interval=0", "--" }
  for _, f in ipairs(files) do args[#args + 1] = f end
  args[#args + 1] = target .. ":"
  local what = #files == 1 and (files[1]:match("([^/]+)$") or "1 file") or (#files .. " files")
  toast.show("Sending to " .. short .. "…", 1.5)
  run("send", args, function(code, out, err)
    if code == 0 then
      toast.show("Sent to " .. short .. " · " .. what, 2)
    else
      local why = elide(err ~= "" and err or out)
      toast.warn("Could not send to " .. short .. (why ~= "" and (": " .. why) or ""))
      log.w("tailscale: taildrop to a machine failed (exit %s)", tostring(code))
    end
  end)
end

local function panel()
  M.refresh(false, true)
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("tailscale: shell toggle failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "toggle", WIDGET }):start()
end

-- ShellIpc status(): the English status line.
function M.status() return S.statusText end

M.actions = {
  ["tailscale.panel"] = { fn = function() panel() end, desc = "Tailscale: open or close the panel" },
  ["tailscale.toggle"] = { fn = function() M.toggle() end, desc = "Tailscale: turn on/off" },
  ["tailscale.up"] = { fn = function() M.up() end, desc = "Tailscale: connect (log in if needed)" },
  ["tailscale.down"] = { fn = function() M.down() end, desc = "Tailscale: disconnect" },
  ["tailscale.refresh"] = { fn = function() M.refresh(true, true) end, desc = "Tailscale: refresh status" },
  ["tailscale.switch"] = { fn = function(x) switchAccount(x) end, desc = "Tailscale: switch connection (x = account id)" },
  ["tailscale.exit-node"] = { fn = function(x) setExitNode(x) end, desc = "Tailscale: use or stop an exit node (x = exit id)" },
  ["tailscale.copy"] = { fn = function(x) copy(x) end, desc = "Tailscale: copy a machine's name/dns/ip/ip6 (x = kind:id)" },
  ["tailscale.send"] = { fn = function(x) send(x) end, desc = "Tailscale: send files with Taildrop (x = machine id)" },
}

---------------------------------------------------------------- lifecycle
function M.start()
  M.stop()
  local every = tonumber(hs.settings.get(SETTINGS_REFRESH)) or 30
  every = math.max(5, math.min(3600, math.floor(every)))
  timers.poll = hs.timer.doEvery(every, function() M.refresh(false, false) end)
  -- After boot tailscaled may not be up yet: poll every 2 s until it is (max ~30 s).
  local ticks = 0
  timers.ramp = hs.timer.doEvery(2, function()
    ticks = ticks + 1
    if S.running or ticks >= 15 then
      if timers.ramp then timers.ramp:stop() timers.ramp = nil end
    else
      M.refresh(false, false)
    end
  end)
  hs.timer.doAfter(0.5, function() M.refresh(true, true) end)
  return M
end

function M.stop()
  for name, t in pairs(timers) do
    pcall(function() t:stop() end)
    timers[name] = nil
  end
  stopWatchdog()
  for kind, t in pairs(tasks) do
    pcall(function() t:terminate() end)
    tasks[kind] = nil
  end
end

return M
