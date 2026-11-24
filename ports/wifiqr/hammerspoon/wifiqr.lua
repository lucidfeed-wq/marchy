-- omarchy.wifiqr: port of the Omarchy 4.5 shell plugin `omarchy.wifiqr` (Wi-Fi QR).
--
-- Omarchy: a centred share overlay with no card, just the QR code floating on a heavy
-- near-black scrim: the network name in small spaced capitals, the code on a white square,
-- "Scan to join this network", and (for secured networks) a "Show password" line that reveals
-- the passphrase in place. Esc or a click on the scrim dismisses it. omarchy-network-qr builds
-- the code with qrencode from NetworkManager's saved secret.
--
-- Here: an hs.webview over the whole screen (transparent, the scrim drawn in the page).
--   * The connected network comes from hs.wifi (SSID + security of the current interface).
--     Without Location permission macOS hides the SSID; the overlay says so (same guidance as
--     netpanel / the omarchy-wifi popout) and offers the Privacy & Security pane.
--   * The QR code is encoded locally by the small encoder below (byte mode, EC level M,
--     versions 1-15). No network, no CDN, no third-party code.
--   * The Wi-Fi password is a secret. It is read only after an explicit click / Return on
--     "Show QR code", with /usr/bin/security find-generic-password -D "AirPort network password"
--     -a <ssid> -w, which makes macOS ask the user to authorise. The SSID is a separate argv
--     element (no shell). The password lives only in this module's memory and in the open page
--     while the overlay is up; it is never logged, persisted or published (this port has no bar
--     widget and never calls omniwmctl). Closing the overlay drops it and kills a pending read.
--   * Open networks need no secret, so their code is drawn immediately.
--
-- Actions: wifiqr.open (re-summon regenerates), wifiqr.toggle, wifiqr.close.
local M = { id = "wifiqr" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local SECURITY = "/usr/bin/security"
local PRIVACY_PANE = "com.apple.settings.PrivacySecurity.extension"

local STR = {
  generateFailed = "Could not generate the Wi-Fi QR code",
  generating = "Generating QR code…",
  passwordFailed = "Could not read the Wi-Fi password",
  scanToJoin = "Scan to join this network",
  showPassword = "Show password",
  showQr = "Show QR code",
  authHint = "macOS asks before Hammerspoon may read the saved Wi-Fi password.",
  authWaiting = "Approve the macOS prompt to read the saved Wi-Fi password.",
  noWifi = "No active Wi-Fi connection",
  wifiOff = "Wi-Fi is off",
  enterprise = "Enterprise Wi-Fi cannot be shared with a password QR code",
  location = "Allow Location for Hammerspoon to see network names",
}

---------------------------------------------------------------- QR encoder (byte mode, EC level M)
-- Self-contained, local, no bitwise operators (runs on Lua 5.4 and LuaJIT). Versions 1-15
-- (up to 412 bytes), which covers any SSID (32 bytes) plus any WPA passphrase (63 bytes) even
-- with every character escaped. Output: rows of "0"/"1" including the 4-module quiet zone.
local QR = {}

local function bxor(a, b)
  local r, bit = 0, 1
  while a > 0 or b > 0 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + bit end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return r
end

local EXP, LOG = {}, {}
do
  local x = 1
  for i = 0, 254 do
    EXP[i] = x
    LOG[x] = i
    x = x * 2
    if x >= 256 then x = bxor(x, 0x11D) end
  end
  for i = 255, 510 do EXP[i] = EXP[i - 255] end
end

local function gmul(a, b)
  if a == 0 or b == 0 then return 0 end
  return EXP[LOG[a] + LOG[b]]
end

local generators = {}
local function generator(n)
  if generators[n] then return generators[n] end
  local g = { 1 }
  for i = 0, n - 1 do
    local ng = {}
    for j = 1, #g + 1 do ng[j] = 0 end
    for j = 1, #g do
      ng[j] = bxor(ng[j], g[j])
      ng[j + 1] = bxor(ng[j + 1], gmul(g[j], EXP[i]))
    end
    g = ng
  end
  generators[n] = g
  return g
end

local function rsRemainder(data, n)
  local g = generator(n)
  local rem = {}
  for i = 1, n do rem[i] = 0 end
  for _, d in ipairs(data) do
    local factor = bxor(d, rem[1])
    for i = 1, n - 1 do rem[i] = rem[i + 1] end
    rem[n] = 0
    if factor ~= 0 then
      for i = 1, n do rem[i] = bxor(rem[i], gmul(g[i + 1], factor)) end
    end
  end
  return rem
end

-- ISO/IEC 18004 table 9, level M: { EC codewords per block, { { blocks, data codewords }, ... } }
local VERSIONS = {
  { 10, { { 1, 16 } } }, { 16, { { 1, 28 } } }, { 26, { { 1, 44 } } }, { 18, { { 2, 32 } } },
  { 24, { { 2, 43 } } }, { 16, { { 4, 27 } } }, { 18, { { 4, 31 } } }, { 22, { { 2, 38 }, { 2, 39 } } },
  { 22, { { 3, 36 }, { 2, 37 } } }, { 26, { { 4, 43 }, { 1, 44 } } }, { 30, { { 1, 50 }, { 4, 51 } } },
  { 22, { { 6, 36 }, { 2, 37 } } }, { 22, { { 8, 37 }, { 1, 38 } } }, { 24, { { 4, 40 }, { 5, 41 } } },
  { 24, { { 5, 41 }, { 5, 42 } } },
}
local ALIGN = {
  {}, { 6, 18 }, { 6, 22 }, { 6, 26 }, { 6, 30 }, { 6, 34 }, { 6, 22, 38 }, { 6, 24, 42 }, { 6, 26, 46 },
  { 6, 28, 50 }, { 6, 30, 54 }, { 6, 32, 58 }, { 6, 34, 62 }, { 6, 26, 46, 66 }, { 6, 26, 48, 70 },
}

local function dataCodewords(v)
  local n = 0
  for _, group in ipairs(VERSIONS[v][2]) do n = n + group[1] * group[2] end
  return n
end

local function pushBits(bits, value, n)
  for i = n - 1, 0, -1 do
    bits[#bits + 1] = math.floor(value / 2 ^ i) % 2
  end
end

local function bitAt(value, i)
  return math.floor(value / 2 ^ i) % 2
end

local function degree(x)
  local d = -1
  while x > 0 do
    x = math.floor(x / 2)
    d = d + 1
  end
  return d
end

local function bchRemainder(value, poly)
  local pd = degree(poly)
  while degree(value) >= pd do
    value = bxor(value, poly * 2 ^ (degree(value) - pd))
  end
  return value
end

local MASKS = {
  [0] = function(i, j) return (i + j) % 2 == 0 end,
  function(i, _) return i % 2 == 0 end,
  function(_, j) return j % 3 == 0 end,
  function(i, j) return (i + j) % 3 == 0 end,
  function(i, j) return (math.floor(i / 2) + math.floor(j / 3)) % 2 == 0 end,
  function(i, j) return (i * j) % 2 + (i * j) % 3 == 0 end,
  function(i, j) return ((i * j) % 2 + (i * j) % 3) % 2 == 0 end,
  function(i, j) return ((i + j) % 2 + (i * j) % 3) % 2 == 0 end,
}

local function newGrid(size, value)
  local g = {}
  for r = 0, size - 1 do
    local row = {}
    for c = 0, size - 1 do row[c] = value end
    g[r] = row
  end
  return g
end

local function penalty(m, size)
  local score = 0
  -- rule 1: runs of five or more in rows and columns
  for pass = 1, 2 do
    for a = 0, size - 1 do
      local run, last = 0, -1
      for b = 0, size - 1 do
        local v = pass == 1 and m[a][b] or m[b][a]
        if v == last then
          run = run + 1
          if run == 5 then score = score + 3 elseif run > 5 then score = score + 1 end
        else
          last, run = v, 1
        end
      end
    end
  end
  -- rule 2: 2x2 blocks
  for r = 0, size - 2 do
    for c = 0, size - 2 do
      local v = m[r][c]
      if v == m[r][c + 1] and v == m[r + 1][c] and v == m[r + 1][c + 1] then score = score + 3 end
    end
  end
  -- rule 3: finder-like 1:1:3:1:1 with four light modules on one side
  local p1, p2 = "10111010000", "00001011101"
  for pass = 1, 2 do
    for a = 0, size - 1 do
      local chars = {}
      for b = 0, size - 1 do chars[#chars + 1] = (pass == 1 and m[a][b] or m[b][a]) == 1 and "1" or "0" end
      local line = table.concat(chars)
      for _, pat in ipairs({ p1, p2 }) do
        local from = 1
        while true do
          local s = line:find(pat, from, true)
          if not s then break end
          score = score + 40
          from = s + 1
        end
      end
    end
  end
  -- rule 4: dark balance
  local dark = 0
  for r = 0, size - 1 do for c = 0, size - 1 do dark = dark + m[r][c] end end
  local total = size * size
  local k = math.ceil(math.abs(dark * 20 - total * 10) / total) - 1
  if k > 0 then score = score + k * 10 end
  return score
end

function QR.encode(text)
  local n = #text
  local version
  for v = 1, #VERSIONS do
    if 4 + (v <= 9 and 8 or 16) + 8 * n <= dataCodewords(v) * 8 then version = v break end
  end
  if not version then return nil, "too long for a QR code" end
  local spec = VERSIONS[version]
  local total = dataCodewords(version)

  local bits = {}
  pushBits(bits, 4, 4)
  pushBits(bits, n, version <= 9 and 8 or 16)
  for i = 1, n do pushBits(bits, text:byte(i), 8) end
  for _ = 1, math.min(4, total * 8 - #bits) do bits[#bits + 1] = 0 end
  while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end
  local cw = {}
  for i = 1, #bits, 8 do
    local v = 0
    for j = 0, 7 do v = v * 2 + bits[i + j] end
    cw[#cw + 1] = v
  end
  local padByte = 0xEC
  while #cw < total do
    cw[#cw + 1] = padByte
    padByte = padByte == 0xEC and 0x11 or 0xEC
  end

  local blocks, ecs, pos = {}, {}, 1
  for _, group in ipairs(spec[2]) do
    for _ = 1, group[1] do
      local blk = {}
      for i = 1, group[2] do
        blk[i] = cw[pos]
        pos = pos + 1
      end
      blocks[#blocks + 1] = blk
      ecs[#ecs + 1] = rsRemainder(blk, spec[1])
    end
  end
  local stream, longest = {}, 0
  for _, b in ipairs(blocks) do if #b > longest then longest = #b end end
  for i = 1, longest do
    for _, b in ipairs(blocks) do if b[i] then stream[#stream + 1] = b[i] end end
  end
  for i = 1, spec[1] do
    for _, e in ipairs(ecs) do stream[#stream + 1] = e[i] end
  end
  local dataBits = {}
  for _, v in ipairs(stream) do pushBits(dataBits, v, 8) end

  local size = 17 + 4 * version
  local m, fn = newGrid(size, 0), newGrid(size, false)
  local function set(r, c, v)
    if r >= 0 and r < size and c >= 0 and c < size then
      m[r][c] = v
      fn[r][c] = true
    end
  end
  -- finders + separators
  for _, at in ipairs({ { 0, 0 }, { 0, size - 7 }, { size - 7, 0 } }) do
    for dr = -1, 7 do
      for dc = -1, 7 do
        local dark = 0
        if dr >= 0 and dr <= 6 and dc >= 0 and dc <= 6 then
          local ring = math.max(math.abs(dr - 3), math.abs(dc - 3))
          if ring ~= 2 then dark = 1 end
        end
        set(at[1] + dr, at[2] + dc, dark)
      end
    end
  end
  -- timing
  for i = 8, size - 9 do
    set(6, i, (i + 1) % 2)
    set(i, 6, (i + 1) % 2)
  end
  -- alignment
  local al = ALIGN[version]
  for a = 1, #al do
    for b = 1, #al do
      local r, c = al[a], al[b]
      local corner = (a == 1 and b == 1) or (a == 1 and b == #al) or (a == #al and b == 1)
      if not corner then
        for dr = -2, 2 do
          for dc = -2, 2 do
            set(r + dr, c + dc, math.max(math.abs(dr), math.abs(dc)) == 1 and 0 or 1)
          end
        end
      end
    end
  end
  -- reserve format areas (written for real after masking) and the dark module
  for i = 0, 8 do
    if not fn[8][i] then set(8, i, 0) end
    if not fn[i][8] then set(i, 8, 0) end
  end
  for i = 0, 7 do set(8, size - 1 - i, 0) end
  for i = 0, 6 do set(size - 1 - i, 8, 0) end
  set(size - 8, 8, 1)
  -- version information (v7+)
  if version >= 7 then
    local vbits = version * 4096 + bchRemainder(version * 4096, 0x1F25)
    for i = 0, 17 do
      local bit = bitAt(vbits, i)
      local a, b = size - 11 + i % 3, math.floor(i / 3)
      set(b, a, bit)
      set(a, b, bit)
    end
  end
  -- data, zig-zag from the bottom right, skipping the vertical timing column
  local idx, up, col = 1, true, size - 1
  while col > 0 do
    if col == 6 then col = col - 1 end
    for k = 0, size - 1 do
      local r = up and (size - 1 - k) or k
      for d = 0, 1 do
        local c = col - d
        if not fn[r][c] then
          m[r][c] = dataBits[idx] or 0
          idx = idx + 1
        end
      end
    end
    up = not up
    col = col - 2
  end

  local function formatBits(mask)
    local data = 0 * 8 + mask   -- EC level M = 00
    return bxor(data * 1024 + bchRemainder(data * 1024, 0x537), 0x5412)
  end
  local function apply(mask)
    local out = newGrid(size, 0)
    local f = MASKS[mask]
    for r = 0, size - 1 do
      for c = 0, size - 1 do
        local v = m[r][c]
        if not fn[r][c] and f(r, c) then v = 1 - v end
        out[r][c] = v
      end
    end
    local fb = formatBits(mask)
    -- first copy around the top-left finder (x = column, y = row)
    for i = 0, 5 do out[i][8] = bitAt(fb, i) end
    out[7][8] = bitAt(fb, 6)
    out[8][8] = bitAt(fb, 7)
    out[8][7] = bitAt(fb, 8)
    for i = 9, 14 do out[8][14 - i] = bitAt(fb, i) end
    -- second copy split between the other two finders
    for i = 0, 7 do out[8][size - 1 - i] = bitAt(fb, i) end
    for i = 8, 14 do out[size - 15 + i][8] = bitAt(fb, i) end
    out[size - 8][8] = 1
    return out
  end

  local best, bestScore = nil, nil
  for mask = 0, 7 do
    local candidate = apply(mask)
    local s = penalty(candidate, size)
    if not bestScore or s < bestScore then best, bestScore = candidate, s end
  end

  local QUIET = 4
  local rows = {}
  local blank = string.rep("0", size + QUIET * 2)
  for _ = 1, QUIET do rows[#rows + 1] = blank end
  for r = 0, size - 1 do
    local line = { string.rep("0", QUIET) }
    for c = 0, size - 1 do line[#line + 1] = best[r][c] == 1 and "1" or "0" end
    line[#line + 1] = string.rep("0", QUIET)
    rows[#rows + 1] = table.concat(line)
  end
  for _ = 1, QUIET do rows[#rows + 1] = blank end
  return rows
end


M._qr = QR   -- exposed for tests only (pure function, no secrets kept)

---------------------------------------------------------------- Wi-Fi state
local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- omarchy-network-qr's escape_wifi_qr: backslash first, then ; , :
local function escapeWifi(value)
  return (tostring(value or ""):gsub("[\\;,:]", function(c) return "\\" .. c end))
end

local function locationOK()
  local ok, status = pcall(function() return hs.location.authorizationStatus() end)
  return ok and (status == "authorized" or status == "authorizedAlways" or status == "authorizedWhenInUse")
end

local function wifiInterface()
  local ok, list = pcall(hs.wifi.interfaces)
  if ok and type(list) == "table" and type(list[1]) == "string" then return list[1] end
  return "en0"
end

-- WPA / WEP / nopass / enterprise from the interface's security description
-- ("WPA2 Personal", "WPA3 Personal", "WPA2 Enterprise", "WEP", "None", "OWE", ...).
-- CWSecurity raw values that some Hammerspoon builds report as "unrecognized (<n>)".
local CW_SECURITY = { [0] = "nopass", "WEP", "WPA", "WPA", "WPA", "WPA", "enterprise", "enterprise", "enterprise",
  "enterprise", "enterprise", "WPA", "enterprise", "WPA", "nopass", "nopass" }

local function classify(security)
  local s = tostring(security or ""):lower()
  local raw = tonumber(s:match("^unrecognized %((%d+)%)$") or "")
  if raw and CW_SECURITY[raw] then return CW_SECURITY[raw] end
  if s:find("enterprise", 1, true) or s:find("802.1x", 1, true) or s:find("dynamic wep", 1, true) then
    return "enterprise"
  end
  if s == "" or s == "none" or s == "open" or s:find("owe", 1, true) or s:find("enhanced open", 1, true) then
    return "nopass"
  end
  if s:find("wep", 1, true) then return "WEP" end
  return "WPA"
end

---------------------------------------------------------------- overlay
local view, ucc, pwTask
local st = nil      -- the open card; holds the password only while the card is up
local gen = 0       -- bumps on every open/close so late task results are dropped
local prevApp = nil

local function stopTask()
  if pwTask then
    local t = pwTask
    pwTask = nil
    pcall(function() if t:isRunning() then t:terminate() end end)
  end
end

local function deleteView()
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
end

local function clearState()
  if st then
    st.password = nil
    st.rows = nil
  end
  st = nil
end

local function dismiss(refocus)
  gen = gen + 1
  stopTask()
  clearState()
  deleteView()
  local app = prevApp
  prevApp = nil
  if refocus and app then pcall(function() app:activate() end) end
end

function M.close() dismiss(true) end

local function qrSvg(rows)
  local size = #rows
  local module = math.max(4, math.floor(240 / size))
  local d = {}
  for r = 1, size do
    local line = rows[r]
    for c = 1, size do
      if line:byte(c) == 49 then d[#d + 1] = "M" .. (c - 1) .. " " .. (r - 1) .. "h1v1h-1z" end
    end
  end
  local px = size * module
  return string.format(
    '<svg class="qr" width="%d" height="%d" viewBox="0 0 %d %d" shape-rendering="crispEdges">'
      .. '<rect width="%d" height="%d" fill="#fff"/><path fill="#111111" d="%s"/></svg>',
    px, px, size, size, size, size, table.concat(d))
end

local function page()
  local s = st or {}
  local parts = {}
  local function add(x) parts[#parts + 1] = x end
  add('<div class="title">' .. esc((s.ssid ~= nil and s.ssid ~= "" and s.ssid or "Wi-Fi"):upper()) .. '</div>')
  local showing = s.rows ~= nil and not s.loading and (s.error or "") == ""
  if showing then add(qrSvg(s.rows)) end
  if s.loading then
    add('<div class="dim">' .. esc(STR.generating) .. '</div>')
    if s.waitingAuth then add('<div class="dim small">' .. esc(STR.authWaiting) .. '</div>') end
  end
  if (s.error or "") ~= "" then add('<div class="err">' .. esc(s.error) .. '</div>') end
  if s.locationHelp then
    add('<div class="link" data-a="location">' .. esc(STR.location) .. '</div>')
  end
  if s.needsAuth and not s.loading and not showing and (s.error or "") == "" then
    add('<div class="link primary" data-a="generate" tabindex="0">' .. esc(STR.showQr) .. ' ⏎</div>')
    add('<div class="dim small">' .. esc(STR.authHint) .. '</div>')
  end
  if showing then
    add('<div class="dim">' .. esc(STR.scanToJoin) .. '</div>')
    if s.secured then
      if (s.passwordError or "") ~= "" then
        add('<div class="pw err" data-a="password">' .. esc(s.passwordError) .. '</div>')
      elseif s.passwordVisible and s.password then
        add('<div class="pw shown" data-a="password">' .. esc(s.password) .. '</div>')
      else
        add('<div class="pw" data-a="password">' .. esc(STR.showPassword) .. '</div>')
      end
    end
  end
  local font = esc(theme.font or "JetBrainsMono Nerd Font")
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%;background:transparent;overflow:hidden;-webkit-user-select:none;cursor:default}
  body{background:rgba(0,0,0,.78);display:flex;align-items:center;justify-content:center;
    font-family:"]] .. font .. [[","JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace}
  #c{display:flex;flex-direction:column;align-items:center;gap:16px;max-width:320px;text-align:center}
  .title{font-size:10px;font-weight:700;letter-spacing:2px;color:rgba(255,255,255,.55);max-width:320px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .qr{display:block;border-radius:0}
  .dim{font-size:11px;color:rgba(255,255,255,.55)}
  .small{max-width:320px}
  .err{font-size:11px;color:#ff6b6b;max-width:320px;overflow-wrap:anywhere}
  .link{font-size:11px;color:#fff;opacity:.8;cursor:pointer}
  .link:hover,.link:focus{opacity:1;outline:none;text-decoration:underline}
  .primary{font-size:13px;opacity:1}
  .pw{font-size:11px;color:#fff;opacity:.6;cursor:pointer;max-width:320px;word-break:break-all}
  .pw.shown,.pw.err{opacity:1}
  .pw.err{color:#ff6b6b}
  </style></head><body><div id="c">]] .. table.concat(parts) .. [[</div><script>
  const send=(a)=>window.webkit.messageHandlers.omarchy_wifiqr.postMessage({a:a});
  const c=document.getElementById('c');
  document.body.addEventListener('click',e=>{if(!c.contains(e.target))send('close')});
  c.addEventListener('click',e=>{const t=e.target.closest('[data-a]');if(t)send(t.dataset.a)});
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();send('close')}
    else if(e.key==='Enter'){e.preventDefault();if(document.querySelector('[data-a="generate"]'))send('generate')}});
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send('blur')},150));
  setTimeout(()=>{const g=document.querySelector('[data-a="generate"]');if(g)g.focus();else window.focus()},30);
  </script></body></html>]]
end

local function redraw()
  if view and st then
    local ok, err = pcall(function() view:html(page()) end)
    if not ok then log.e("wifiqr: redraw failed: %s", tostring(err)) end
  end
end

local function raise()
  if not view then return end
  pcall(function()
    view:level(hs.drawing.windowLevels.modalPanel)
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
end

local function encodeInto(security, ssid, password)
  local payload = "WIFI:T:" .. security .. ";S:" .. escapeWifi(ssid) .. ";P:" .. escapeWifi(password or "") .. ";;"
  local rows = QR.encode(payload)
  payload = nil
  if not rows then
    st.error = STR.generateFailed
    return false
  end
  st.rows = rows
  return true
end

-- The deliberate user step: read the saved password through macOS's own authorisation prompt.
local function generate()
  if not st or not st.needsAuth or st.loading or pwTask or st.rows then return end
  local myGen = gen
  st.loading, st.waitingAuth, st.error = true, true, ""
  redraw()
  -- The macOS authorisation dialog must not end up underneath a modal-panel overlay.
  pcall(function() view:level(hs.drawing.windowLevels.normal) end)
  local ok, err = pcall(function()
    pwTask = hs.task.new(SECURITY, function(code, out)
      pwTask = nil
      if myGen ~= gen or not st then return end   -- closed or re-summoned meanwhile: drop it
      st.loading, st.waitingAuth = false, false
      local secret = type(out) == "string" and out:gsub("\n$", "") or ""
      out = nil
      if code == 0 and secret ~= "" then
        st.password = secret
        encodeInto(st.security, st.ssid, secret)
      else
        st.error = STR.passwordFailed
        log.w("wifiqr: keychain read did not succeed (exit %s)", tostring(code))
      end
      secret = nil
      raise()
      redraw()
    end, { "find-generic-password", "-D", "AirPort network password", "-a", st.ssid, "-w" })
    if not pwTask:start() then error("could not start security") end
  end)
  if not ok then
    pwTask = nil
    log.e("wifiqr: %s", tostring(err))
    st.loading, st.waitingAuth, st.error = false, false, STR.passwordFailed
    raise()
    redraw()
  end
end

local function togglePassword()
  if not st or not st.secured or not st.rows then return end
  if st.passwordVisible then
    st.passwordVisible = false
  elseif st.password then
    st.passwordVisible = true
  else
    st.passwordError = STR.passwordFailed
  end
  redraw()
end

local function onMessage(msg)
  local body = msg and msg.body
  local a = type(body) == "table" and body.a or nil
  if type(a) ~= "string" then return end
  if a == "close" then
    dismiss(true)
  elseif a == "blur" then
    -- The macOS password prompt takes focus on purpose; only a real switch away closes.
    if not pwTask then dismiss(false) end
  elseif a == "generate" then
    generate()
  elseif a == "password" then
    togglePassword()
  elseif a == "location" then
    dismiss(false)
    require("omarchy.actions").run("settings", PRIVACY_PANE)
  end
end

local function detect()
  local s = { ssid = "", security = "nopass", secured = false }
  local iface = wifiInterface()
  local details = hs.wifi.interfaceDetails(iface)
  if not (details and details.power) then
    s.error = STR.wifiOff
    return s
  end
  local ssid = hs.wifi.currentNetwork(iface)
  if type(ssid) ~= "string" or ssid == "" then
    -- macOS hides the name without Location permission: say how to fix it, as netpanel does.
    if not locationOK() then s.locationHelp = true else s.error = STR.noWifi end
    return s
  end
  s.ssid = ssid
  local kind = classify(details.security)
  if kind == "enterprise" then
    s.error = STR.enterprise
    return s
  end
  s.security = kind
  s.secured = kind ~= "nopass"
  s.needsAuth = s.secured
  return s
end

function M.open()
  -- A re-summon regenerates from scratch: nothing of the previous card survives.
  gen = gen + 1
  stopTask()
  clearState()
  deleteView()
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() ~= "org.hammerspoon.Hammerspoon" then prevApp = front end

  local ok, s = pcall(detect)
  if not ok then
    log.e("wifiqr: could not read Wi-Fi state: %s", tostring(s))
    s = { ssid = "", error = STR.generateFailed }
  end
  st = s
  if not st.error and st.ssid ~= "" and not st.secured then encodeInto("nopass", st.ssid, "") end

  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy_wifiqr")
    ucc:setCallback(function(msg)
      local okMsg, err = pcall(onMessage, msg)
      if not okMsg then log.e("wifiqr: message handler failed: %s", tostring(err)) end
    end)
  end
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local frame = screen:fullFrame()
  local okView, err = pcall(function()
    view = hs.webview.new(frame, { developerExtrasEnabled = false }, ucc)
      :windowStyle({ "borderless" })
      :transparent(true)
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.modalPanel)
      :shadow(false)
      :closeOnEscape(false)
      :deleteOnClose(true)
      :html(page())
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
  if not okView then
    log.e("wifiqr: could not open: %s", tostring(err))
    dismiss(false)
    toast.warn("Wi-Fi QR could not open")
    return
  end
  log.i("wifiqr: open (%s)", (st.error or st.locationHelp) and "no code" or (st.secured and "secured" or "open network"))
end

function M.toggle()
  if view then M.close() else M.open() end
end

M.actions = {
  ["wifiqr.open"] = { fn = function() M.open() end, desc = "Share the connected Wi-Fi network as a QR code" },
  ["wifiqr.toggle"] = { fn = function() M.toggle() end, desc = "Toggle the Wi-Fi QR overlay" },
  ["wifiqr.close"] = { fn = function() M.close() end, desc = "Close the Wi-Fi QR overlay (forgets the password)" },
}

function M.start()
  M.stop()
  return M
end

function M.stop()
  dismiss(false)
  if ucc then ucc = nil end
end

return M
