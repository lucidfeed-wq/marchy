-- omarchy elsewhen: backend for the port of the Omarchy 4.5 bar widget `omarchy.elsewhen`
-- (Jason Fried's world clock: one row per city, a daylight strip, local greetings, a globe).
--
-- The clock itself is drawn by the OmniShell widget omarchy-elsewhen, which does every bit of
-- time-zone arithmetic with ctx.format.offset / ctx.format.date. This module does what a
-- sandboxed widget cannot:
--   * keeps the city list and the row toggles (24-hour, home/UTC offsets, C/F) in
--     ~/.config/omarchy-mac/elsewhen.json (city names and zones only; no typed text)
--   * knows the Mac's IANA zone (/etc/localtime) and "here", seeds the first list like
--     Omarchy (home plus four cities spread round the clock, via /bin/date probes)
--   * geocodes cities (Open-Meteo, as Omarchy does; zone.tab as the offline fallback) and
--     reads their current weather (Open-Meteo forecast, 20-minute TTL)
--   * turns Omarchy's Greetings.js into per-city greeting bands
--   * reads the globe's coastlines and cities (world.json, cities.json)
--   * draws the "Add a city" / "Where are you?" search overlay (hs.webview) with drag reorder
-- Greetings.js, world.json and cities.json are read at runtime from the synced upstream source
-- (~/.local/share/omarchy-mac/upstream/current/...; `omarchy-port sync`). Without them the
-- greetings fall back to English and the globe shows its graticule only.
--
-- Published OmniShell vars:
--   omarchy_elsewhen       {v, rev, zone, home, h24, off, units, cities:[{n,z,lat,lon,c,w,g}]}
--   omarchy_elsewhen_globe {v, land:[[lon,lat,...]], cities:[[name,zone,lat,lon,rank]]} (static)
--
-- URL arguments: only elsewhen.remove takes one ("<rev>:<index>"), checked against the
-- published revision and list length. Search queries travel from the overlay page to Lua by
-- the WKWebView message handler, never by URL, and are never logged.
local M = { id = "elsewhen" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")
local u = require("omarchy.util")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local DATE = "/bin/date"
local VAR = "omarchy_elsewhen"
local GLOBE_VAR = "omarchy_elsewhen_globe"
local HOME = os.getenv("HOME") or ""
local CONFIG = HOME .. "/.config/omarchy-mac/elsewhen.json"
local UPSTREAM = HOME .. "/.local/share/omarchy-mac/upstream/current/shell/plugins/panels/elsewhen"
local ZONEINFO = "/usr/share/zoneinfo/"
local ZONE_TAB = "/usr/share/zoneinfo/zone.tab"
local GEOCODE = "https://geocoding-api.open-meteo.com/v1/search?count=10&language=en&format=json&name="
local FORECAST = "https://api.open-meteo.com/v1/forecast?current=temperature_2m,weather_code&temperature_unit=celsius"
local WEATHER_TTL = 20 * 60
local FACTS_EVERY = 15 * 60       -- Omarchy refreshes facts every 15 minutes
local ZONE_CHECK_EVERY = 60       -- notices a time-zone change (travel)
local MAX_CITIES = 24
local MAX_LABEL = 64

---------------------------------------------------------------- helpers
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Labels may not carry "," or "|", and are capped (on a UTF-8 boundary).
local function cleanLabel(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("[%c,|]", " "):gsub("%s+", " ")
  s = trim(s)
  if #s > MAX_LABEL then
    local cut = MAX_LABEL
    while cut > 0 do
      local b = s:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end
      cut = cut - 1
    end
    s = trim(s:sub(1, cut))
  end
  return s
end

local function validZone(z)
  if type(z) ~= "string" or #z > 64 or not z:match("^[%w_%+%-/]+$") then return false end
  if z:find("..", 1, true) or z:sub(1, 1) == "/" or not z:find("/", 1, true) then return false end
  return hs.fs.attributes(ZONEINFO .. z, "mode") == "file"
end

local function labelForZoneId(id)
  return (tostring(id or ""):match("([^/]+)$") or ""):gsub("_", " ")
end

local function coord(v, limit)
  local n = tonumber(v)
  if n and n == n and math.abs(n) <= limit then return math.floor(n * 10000 + 0.5) / 10000 end
  return nil
end

local function factsKey(c) return tostring(c.name) .. "|" .. tostring(c.zone) end

local function nearPlace(a, b)
  return a.lat and b.lat and math.abs(a.lat - b.lat) < 0.01 and math.abs(a.lon - b.lon) < 0.01
end

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local data = fh:read("*a")
  fh:close()
  return data
end

-- UTF-8 for a code point (no utf8 library in LuaJIT).
local function utf8char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
    0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- A JavaScript string literal's body: \uXXXX (with surrogate pairs), \n, \\, \", \'.
local function jsUnescape(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" and i < n then
      local nx = s:sub(i + 1, i + 1)
      if nx == "u" and s:sub(i + 2, i + 5):match("^%x%x%x%x$") then
        local cp = tonumber(s:sub(i + 2, i + 5), 16)
        i = i + 6
        if cp >= 0xD800 and cp < 0xDC00 and s:sub(i, i + 1) == "\\u" and s:sub(i + 2, i + 5):match("^%x%x%x%x$") then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo >= 0xDC00 and lo < 0xE000 then
            cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8char(cp)
      else
        out[#out + 1] = (nx == "n" and "\n") or (nx == "t" and "\t") or nx
        i = i + 2
      end
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

---------------------------------------------------------------- state
local cfg = { cities = {}, here = nil, hour24 = nil, offsetMode = "home", units = nil }
local loadedFromDisk = false
local localZone = nil
local rev = 0
local geo, fallbackGeo, weather = {}, {}, {}
local greet = nil          -- parsed Greetings.js, or false when unavailable
local lastPush, lastGlobePush = nil, nil
local timers = {}
local tasks = {}
local httpBusy, factsQueued = false, false
local view, ucc
local overlayMode = nil    -- "add" | "here"
local placeCache, placeWanted, placeBusy = {}, nil, false
local zoneCatalog = nil

local function pushVar(name, text)
  if not hs.fs.attributes(CTL) then return end
  local t = hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("elsewhen: shell set %s failed: %s", name, tostring(err):sub(1, 160)) end
  end, { "shell", "set", name, text })
  t:start()
end

---------------------------------------------------------------- config
local function sanitizeCity(c)
  if type(c) ~= "table" then return nil end
  local zone = type(c.zone) == "string" and trim(c.zone) or ""
  if not validZone(zone) then return nil end
  local name = cleanLabel(c.name)
  if name == "" then name = labelForZoneId(zone) end
  local out = { name = name, zone = zone }
  local lat, lon = coord(c.lat, 90), coord(c.lon, 180)
  if lat and lon then out.lat, out.lon = lat, lon end
  local region = cleanLabel(c.region)
  if region ~= "" then out.region = region end
  return out
end

local function loadConfig()
  local raw = readFile(CONFIG)
  if not raw then return false end
  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then
    log.w("elsewhen: could not parse %s; starting fresh", CONFIG)
    return false
  end
  local cities = {}
  for _, c in ipairs(type(data.cities) == "table" and data.cities or {}) do
    local s = sanitizeCity(c)
    if s and #cities < MAX_CITIES then cities[#cities + 1] = s end
  end
  cfg.cities = cities
  cfg.here = sanitizeCity(data.here)
  cfg.hour24 = (data.hour24 == true or data.hour24 == false) and data.hour24 or nil
  cfg.offsetMode = data.offsetMode == "utc" and "utc" or "home"
  cfg.units = (data.units == "C" or data.units == "F") and data.units or nil
  return #cities > 0
end

local function saveConfig()
  u.mkdirp(HOME .. "/.config/omarchy-mac")
  local text = hs.json.encode({
    cities = cfg.cities, here = cfg.here, hour24 = cfg.hour24,
    offsetMode = cfg.offsetMode, units = cfg.units,
  }, true)
  local ok, err = u.writeFile(CONFIG, text or "{}")
  if not ok then log.w("elsewhen: could not save %s: %s", CONFIG, tostring(err)) end
end

---------------------------------------------------------------- greetings (Greetings.js)
local function block(text, name)
  local s = text:find("var " .. name .. " = {", 1, true)
  if not s then return "" end
  local e = text:find("\n}", s, true)
  return text:sub(s, e or #text)
end

local function loadGreetings()
  local text = readFile(UPSTREAM .. "/Greetings.js")
  if not text then
    log.w("elsewhen: Greetings.js not found (run omarchy-port sync); greetings fall back to English")
    return false
  end
  local g = { languages = {}, countries = {}, overrides = {}, alias = {}, zones = {} }
  for key, body in block(text, "LANGUAGES"):gmatch("\n%s+([%w]+): { name: \"[^\"]*\", bands: %[(.-)%] }") do
    local bands = {}
    for from, txt, roman in body:gmatch("{ from: (%d+), text: \"(.-)\", roman: \"(.-)\" }") do
      bands[#bands + 1] = { tonumber(from), jsUnescape(txt), jsUnescape(roman) }
    end
    if #bands > 0 then g.languages[key] = bands end
  end
  for cc, key in block(text, "COUNTRIES"):gmatch("\"(%u%u)\": \"([%w]+)\"") do g.countries[cc] = key end
  for z, key in block(text, "OVERRIDES"):gmatch("\"([%w_%+%-/]+)\": \"([%w]+)\"") do g.overrides[z] = key end
  for z, cc in block(text, "ALIAS_COUNTRY"):gmatch("\"([%w_%+%-/]+)\": \"(%u%u)\"") do g.alias[z] = cc end
  for z, cc in block(text, "ZONE_COUNTRY"):gmatch("\"([%w_%+%-/]+)\": \"(%u%u)\"") do g.zones[z] = cc end
  if not g.languages.en then
    log.w("elsewhen: Greetings.js did not parse; greetings fall back to English")
    return false
  end
  return g
end

local ENGLISH = { { 0, "Good night", "" }, { 5, "Good morning", "" }, { 12, "Good afternoon", "" }, { 18, "Good evening", "" } }

local function bandsFor(zone)
  if not greet then return ENGLISH end
  local key = greet.overrides[zone]
  if not (key and greet.languages[key]) then
    key = greet.countries[greet.alias[zone] or greet.zones[zone] or ""]
  end
  return (key and greet.languages[key]) or greet.languages.en or ENGLISH
end

---------------------------------------------------------------- the Mac's zone and "here"
local function readLocalZone()
  local p = hs.fs.pathToAbsolute("/etc/localtime")
  local z = p and p:match("zoneinfo/(.+)$")
  if z and validZone(z) then return z end
  return nil
end

-- Omarchy's resolveHere: the chosen place while the Mac is still on its zone, else the zone's city.
local function hereZone()
  if not localZone then return nil end
  if cfg.here and cfg.here.zone == localZone then
    return { name = cfg.here.name, zone = localZone, lat = cfg.here.lat, lon = cfg.here.lon, chosen = true }
  end
  return { name = labelForZoneId(localZone), zone = localZone, chosen = false }
end

local function unitsResolved()
  if cfg.units then return cfg.units end
  local ok, d = pcall(hs.host.locale.details)
  if ok and type(d) == "table" then
    if d.measurementSystem == "U.S." then return "F" end
    if d.measurementSystem == nil and d.usesMetricSystem == false then return "F" end
  end
  return "C"
end

local function coordsFor(c)
  if c.lat and c.lon then return { lat = c.lat, lon = c.lon } end
  local key = factsKey(c)
  return geo[key] or fallbackGeo[key]
end

---------------------------------------------------------------- publishing
local function publish()
  local list = {}
  for _, c in ipairs(cfg.cities) do
    local p = coordsFor(c)
    local w = weather[factsKey(c)]
    list[#list + 1] = {
      n = c.name, z = c.zone, lat = p and p.lat or nil, lon = p and p.lon or nil,
      c = w and w.c or nil, w = w and w.w or nil, g = bandsFor(c.zone),
    }
  end
  local here = hereZone()
  local home = nil
  if here then
    local p = coordsFor(here)
    home = { n = here.name, lat = p and p.lat or nil, lon = p and p.lon or nil }
  end
  local text = hs.json.encode({
    v = 1, rev = rev, zone = localZone, home = home, h24 = cfg.hour24, off = cfg.offsetMode,
    units = unitsResolved(), cities = list, adding = overlayMode,
  })
  if not text or text == lastPush then return end
  lastPush = text
  pushVar(VAR, text)
end

local function publishGlobe()
  local out = { v = 1, land = {}, cities = {} }
  local okW, land = pcall(hs.json.decode, readFile(UPSTREAM .. "/world.json") or "")
  if okW and type(land) == "table" then
    for _, ring in ipairs(land) do
      if type(ring) == "table" and #ring >= 8 then
        -- OmniWM rejects shell vars over 4096 bytes: keep every 3rd point, whole degrees.
        local r = {}
        for i = 1, #ring - 1, 6 do
          r[#r + 1] = math.floor((tonumber(ring[i]) or 0) + 0.5)
          r[#r + 1] = math.floor((tonumber(ring[i + 1]) or 0) + 0.5)
        end
        if #r >= 6 then out.land[#out.land + 1] = r end
      end
    end
  end
  local okC, cities = pcall(hs.json.decode, readFile(UPSTREAM .. "/cities.json") or "")
  if okC and type(cities) == "table" then
    for _, c in ipairs(cities) do
      if type(c) == "table" and type(c[1]) == "string" and validZone(c[2]) and coord(c[3], 90) and coord(c[4], 180) then
        out.cities[#out.cities + 1] = { cleanLabel(c[1]), c[2], coord(c[3], 90), coord(c[4], 180), tonumber(c[5]) or 3 }
      end
    end
  end
  if #out.land == 0 then
    out.missing = true
    log.w("elsewhen: world.json not found (run omarchy-port sync); the globe draws its graticule only")
  end
  -- Fit OmniWM's 4096-byte var limit: drop the least prominent cities until it fits.
  table.sort(out.cities, function(a, b) return (a[5] or 3) < (b[5] or 3) end)
  local text = hs.json.encode(out)
  while text and #text > 4000 and #out.cities > 0 do
    table.remove(out.cities)
    text = hs.json.encode(out)
  end
  if text and #text > 4000 then out.land = {} out.missing = true text = hs.json.encode(out) end
  if not text or text == lastGlobePush then return end
  lastGlobePush = text
  pushVar(GLOBE_VAR, text)
end

local function changed()
  rev = rev + 1
  saveConfig()
  publish()
end

---------------------------------------------------------------- offsets probe (first run)
-- One `/bin/date +%z` per zone with TZ in its environment: zones are arguments, never script.
local function probeOffsets(zones, done)
  local out, pending, finished = {}, 0, false
  local function maybeDone()
    if pending == 0 and not finished then finished = true done(out) end
  end
  for _, z in ipairs(zones) do
    if validZone(z) then
      pending = pending + 1
      local t = hs.task.new(DATE, function(code, stdout)
        local sign, hh, mm = tostring(stdout or ""):match("([+-])(%d%d)(%d%d)")
        if code == 0 and sign then
          local mins = tonumber(hh) * 60 + tonumber(mm)
          out[z] = sign == "-" and -mins or mins
        end
        pending = pending - 1
        maybeDone()
      end, { "+%z" })
      t:setEnvironment({ TZ = z })
      if t:start() then tasks[#tasks + 1] = t else pending = pending - 1 end
    end
  end
  hs.timer.doAfter(0, maybeDone)
end

local SEED = {
  { "Honolulu", "Pacific/Honolulu", 3 }, { "Anchorage", "America/Anchorage", 3 },
  { "Los Angeles", "America/Los_Angeles", 2 }, { "Vancouver", "America/Vancouver", 3 },
  { "Mexico City", "America/Mexico_City", 3 }, { "Chicago", "America/Chicago", 3 },
  { "New York", "America/New_York", 1 }, { "Sao Paulo", "America/Sao_Paulo", 2 },
  { "Buenos Aires", "America/Argentina/Buenos_Aires", 3 }, { "Reykjavik", "Atlantic/Reykjavik", 3 },
  { "London", "Europe/London", 1 }, { "Lisbon", "Europe/Lisbon", 3 }, { "Paris", "Europe/Paris", 1 },
  { "Berlin", "Europe/Berlin", 3 }, { "Madrid", "Europe/Madrid", 3 }, { "Rome", "Europe/Rome", 3 },
  { "Cairo", "Africa/Cairo", 3 }, { "Johannesburg", "Africa/Johannesburg", 3 },
  { "Istanbul", "Europe/Istanbul", 3 }, { "Moscow", "Europe/Moscow", 3 }, { "Nairobi", "Africa/Nairobi", 3 },
  { "Dubai", "Asia/Dubai", 2 }, { "Karachi", "Asia/Karachi", 3 }, { "Delhi", "Asia/Kolkata", 2 },
  { "Bangkok", "Asia/Bangkok", 3 }, { "Jakarta", "Asia/Jakarta", 3 }, { "Singapore", "Asia/Singapore", 2 },
  { "Hong Kong", "Asia/Hong_Kong", 2 }, { "Shanghai", "Asia/Shanghai", 2 }, { "Perth", "Australia/Perth", 3 },
  { "Seoul", "Asia/Seoul", 3 }, { "Tokyo", "Asia/Tokyo", 1 }, { "Sydney", "Australia/Sydney", 2 },
  { "Auckland", "Pacific/Auckland", 3 },
}
local DAY = 1440

local function eastOf(off, home)
  local d = (off - home) % DAY
  if d < 0 then d = d + DAY end
  return d
end

local function dialDistance(a, b)
  local d = math.abs(a - b) % DAY
  return math.min(d, DAY - d)
end

-- Omarchy's pickSeedZones: best-ranked first, each >= gap minutes from home and every pick.
local function pickSeed(home, offsets, count)
  local homeOff = offsets[home.zone]
  if homeOff == nil then return {} end
  local picked
  for _, gap in ipairs({ 180, 120, 60 }) do
    picked = {}
    for r = 1, 3 do
      for _, c in ipairs(SEED) do
        if #picked >= count then break end
        local off = offsets[c[2]]
        if c[3] == r and off ~= nil and c[2] ~= home.zone and c[1]:lower() ~= home.name:lower() then
          local east = eastOf(off, homeOff)
          if math.min(east, DAY - east) >= gap then
            local clash = false
            for _, p in ipairs(picked) do
              if dialDistance(p.east, east) < gap then clash = true break end
            end
            if not clash then picked[#picked + 1] = { name = c[1], zone = c[2], east = east } end
          end
        end
      end
    end
    if #picked >= count then break end
  end
  table.sort(picked, function(a, b) return a.east < b.east end)
  local out = {}
  for _, p in ipairs(picked) do out[#out + 1] = { name = p.name, zone = p.zone } end
  return out
end

local refreshFacts

local function seedFirstRun()
  local here = hereZone()
  if not here then
    cfg.cities = {}
    for _, d in ipairs({ { "Los Angeles", "America/Los_Angeles" }, { "Paris", "Europe/Paris" }, { "Tokyo", "Asia/Tokyo" } }) do
      if validZone(d[2]) then cfg.cities[#cfg.cities + 1] = { name = d[1], zone = d[2] } end
    end
    changed()
    refreshFacts()
    return
  end
  local zones = { here.zone }
  for _, c in ipairs(SEED) do zones[#zones + 1] = c[2] end
  probeOffsets(zones, function(offsets)
    if #cfg.cities > 0 then return end   -- something was added meanwhile
    local list = { { name = here.name, zone = here.zone, lat = here.lat, lon = here.lon } }
    for _, c in ipairs(pickSeed(here, offsets, 4)) do list[#list + 1] = c end
    cfg.cities = list
    log.i("elsewhen: seeded %d cities around %s", #list, here.zone)
    changed()
    refreshFacts()
  end)
end

---------------------------------------------------------------- geocoding + weather
local zoneTabText = nil

local function zoneTabCoords(zone)
  zoneTabText = zoneTabText or readFile(ZONE_TAB) or ""
  for line in zoneTabText:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
      local _, iso, z = line:match("^(%S+)\t(%S+)\t(%S+)")
      if z == zone and iso then
        local s1, d1, m1, ss1, s2, d2, m2, ss2 = iso:match("^([+-])(%d%d)(%d%d)(%d*)([+-])(%d%d%d)(%d%d)(%d*)$")
        if s1 then
          local function dec(sign, d, m, s)
            return (sign == "-" and -1 or 1) * (tonumber(d) + tonumber(m) / 60 + (tonumber(s ~= "" and s or "0") or 0) / 3600)
          end
          return { lat = math.floor(dec(s1, d1, m1, ss1) * 1e4 + 0.5) / 1e4, lon = math.floor(dec(s2, d2, m2, ss2) * 1e4 + 0.5) / 1e4 }
        end
        return nil
      end
    end
  end
  return nil
end

local function geocodeResults(body)
  local ok, payload = pcall(hs.json.decode, body or "")
  if not ok or type(payload) ~= "table" then return nil end
  local results = payload.results
  if type(results) ~= "table" then return {} end
  local out = {}
  for i = 1, math.min(#results, 10) do out[i] = results[i] end
  return out
end

local function factsRequest()
  local out = {}
  for _, c in ipairs(cfg.cities) do out[#out + 1] = c end
  local here = hereZone()
  if here then out[#out + 1] = here end
  return out
end

local function fetchWeather(done)
  local now = os.time()
  local keys, points = {}, {}
  local seen = {}
  for _, c in ipairs(factsRequest()) do
    local key = factsKey(c)
    local p = coordsFor(c)
    if p and not seen[key] then
      seen[key] = true
      local w = weather[key]
      if not w or now - w.at >= WEATHER_TTL or not nearPlace(w, p) then
        keys[#keys + 1] = key
        points[#points + 1] = p
      end
    end
  end
  if #keys == 0 then return done() end
  local lats, lons = {}, {}
  for i, p in ipairs(points) do lats[i] = tostring(p.lat) lons[i] = tostring(p.lon) end
  local url = FORECAST .. "&latitude=" .. table.concat(lats, ",") .. "&longitude=" .. table.concat(lons, ",")
  hs.http.asyncGet(url, nil, function(status, body)
    if status == 200 then
      local ok, payload = pcall(hs.json.decode, body or "")
      if ok and type(payload) == "table" then
        if payload[1] == nil then payload = { payload } end
        for i = 1, math.min(#keys, #payload) do
          local cur = type(payload[i]) == "table" and payload[i].current or nil
          local t = cur and tonumber(cur.temperature_2m)
          if t then
            weather[keys[i]] = { c = math.floor(t * 10 + 0.5) / 10, w = tonumber(cur.weather_code),
              at = now, lat = points[i].lat, lon = points[i].lon }
          end
        end
      end
    else
      log.w("elsewhen: forecast request failed (HTTP %s)", tostring(status))
    end
    done()
  end)
end

-- Geocode, one name at a time, every city without coordinates; then the weather.
refreshFacts = function()
  if httpBusy then factsQueued = true return end
  httpBusy = true
  local queue, queued = {}, {}
  for _, c in ipairs(factsRequest()) do
    local key = factsKey(c)
    if not (c.lat and c.lon) and not geo[key] and not queued[key] then
      queued[key] = true
      queue[#queue + 1] = c
    end
  end
  local function finish()
    fetchWeather(function()
      httpBusy = false
      publish()
      if factsQueued then
        factsQueued = false
        hs.timer.doAfter(0, refreshFacts)
      end
    end)
  end
  local function nextOne(i)
    local c = queue[i]
    if not c then return finish() end
    hs.http.asyncGet(GEOCODE .. hs.http.encodeForQuery(c.name), nil, function(status, body)
      local key = factsKey(c)
      local results = status == 200 and geocodeResults(body) or nil
      local best = nil
      for _, r in ipairs(results or {}) do
        if type(r) == "table" and r.timezone == c.zone then best = r break end
      end
      if not best and results and type(results[1]) == "table" then best = results[1] end
      local lat, lon = best and coord(best.latitude, 90), best and coord(best.longitude, 180)
      if results and lat and lon then
        geo[key] = { lat = lat, lon = lon }
        -- Keep it with the city, so it is not looked up again next session.
        for _, cc in ipairs(cfg.cities) do
          if factsKey(cc) == key and not cc.lat then cc.lat, cc.lon = lat, lon end
        end
        saveConfig()
      else
        fallbackGeo[key] = zoneTabCoords(c.zone)
      end
      hs.timer.doAfter(0.2, function() nextOne(i + 1) end)
    end)
  end
  nextOne(1)
end

---------------------------------------------------------------- list edits
local function hasEntry(zone, name)
  for _, c in ipairs(cfg.cities) do if c.zone == zone and c.name == name then return true end end
  return false
end

local function addCity(pick)
  if #cfg.cities >= MAX_CITIES then return toast.warn("Elsewhen: that's a lot of clocks already") end
  local row = sanitizeCity(pick)
  if not row then return end
  for _, c in ipairs(cfg.cities) do
    if c.zone == row.zone and c.name == row.name then
      -- Omarchy's addZone: the same name and zone is the same city unless the coordinates differ.
      if not row.lat or not c.lat or nearPlace(c, row) then return end
      local first = cleanLabel((row.region or ""):match("^([^,]*)") or "")
      if first == "" then return end
      row.name = cleanLabel(row.name .. " (" .. first .. ")")
      if hasEntry(row.zone, row.name) then return end
      break
    end
  end
  cfg.cities[#cfg.cities + 1] = row
  changed()
  refreshFacts()
end

local function removeAt(index)
  if #cfg.cities <= 1 or index < 1 or index > #cfg.cities then return end
  table.remove(cfg.cities, index)
  changed()
end

local function reorder(order)
  local n = #cfg.cities
  if type(order) ~= "table" or #order ~= n then return end
  local seen, out = {}, {}
  for i = 1, n do
    local k = tonumber(order[i])
    if not k or k ~= math.floor(k) or k < 1 or k > n or seen[k] then return end
    seen[k] = true
    out[i] = cfg.cities[k]
  end
  cfg.cities = out
  changed()
end

-- Omarchy's hereAfterPick, minus moving the system clock (that needs an admin on macOS).
local function setHere(pick)
  local row = sanitizeCity(pick)
  if not row or not localZone then return end
  if row.zone ~= localZone then
    toast.warn("Elsewhen: " .. row.name .. " is on another time zone; change it in Date & Time settings")
    pcall(function() require("omarchy.actions").run("settings", "com.apple.Date-Time-Settings.extension") end)
    return
  end
  local current = hereZone()
  local bare = row.name == labelForZoneId(localZone) and not row.lat
  -- The row that stood for the old here follows it, keeping its place in the list.
  if current then
    for i, c in ipairs(cfg.cities) do
      if c.zone == localZone and c.name == current.name then
        if row.name == current.name or not hasEntry(localZone, row.name) then
          cfg.cities[i] = { name = row.name, zone = localZone, lat = row.lat, lon = row.lon, region = row.region }
        end
        break
      end
    end
  end
  cfg.here = (not bare) and row or nil
  changed()
  refreshFacts()
end

---------------------------------------------------------------- search overlay
-- Places people think of that the tz database files under another city's zone (Model.js).
local ALIASES = {
  { "Miami", "America/New_York" }, { "Boca Raton", "America/New_York" }, { "Boston", "America/New_York" },
  { "Philadelphia", "America/New_York" }, { "Washington DC", "America/New_York" }, { "Atlanta", "America/New_York" },
  { "Orlando", "America/New_York" }, { "Tampa", "America/New_York" }, { "Charlotte", "America/New_York" },
  { "Pittsburgh", "America/New_York" }, { "Cleveland", "America/New_York" }, { "Chicago", "America/Chicago" },
  { "Austin", "America/Chicago" }, { "Dallas", "America/Chicago" }, { "Houston", "America/Chicago" },
  { "San Antonio", "America/Chicago" }, { "Nashville", "America/Chicago" }, { "New Orleans", "America/Chicago" },
  { "Minneapolis", "America/Chicago" }, { "Kansas City", "America/Chicago" }, { "St. Louis", "America/Chicago" },
  { "Memphis", "America/Chicago" }, { "Salt Lake City", "America/Denver" }, { "Albuquerque", "America/Denver" },
  { "Colorado Springs", "America/Denver" }, { "Boulder", "America/Denver" }, { "Tucson", "America/Phoenix" },
  { "Scottsdale", "America/Phoenix" }, { "San Francisco", "America/Los_Angeles" }, { "San Diego", "America/Los_Angeles" },
  { "San Jose", "America/Los_Angeles" }, { "Oakland", "America/Los_Angeles" }, { "Sacramento", "America/Los_Angeles" },
  { "Seattle", "America/Los_Angeles" }, { "Portland", "America/Los_Angeles" }, { "Las Vegas", "America/Los_Angeles" },
  { "Montreal", "America/Toronto" }, { "Ottawa", "America/Toronto" }, { "Calgary", "America/Edmonton" },
  { "Victoria", "America/Vancouver" }, { "Rio de Janeiro", "America/Sao_Paulo" }, { "Brasilia", "America/Sao_Paulo" },
  { "Guadalajara", "America/Mexico_City" }, { "Manchester", "Europe/London" }, { "Edinburgh", "Europe/London" },
  { "Glasgow", "Europe/London" }, { "Birmingham", "Europe/London" }, { "Cambridge", "Europe/London" },
  { "Oxford", "Europe/London" }, { "Munich", "Europe/Berlin" }, { "Frankfurt", "Europe/Berlin" },
  { "Hamburg", "Europe/Berlin" }, { "Cologne", "Europe/Berlin" }, { "Lyon", "Europe/Paris" },
  { "Marseille", "Europe/Paris" }, { "Nice", "Europe/Paris" }, { "Barcelona", "Europe/Madrid" },
  { "Valencia", "Europe/Madrid" }, { "Seville", "Europe/Madrid" }, { "Milan", "Europe/Rome" },
  { "Naples", "Europe/Rome" }, { "Florence", "Europe/Rome" }, { "Venice", "Europe/Rome" }, { "Turin", "Europe/Rome" },
  { "Rotterdam", "Europe/Amsterdam" }, { "Geneva", "Europe/Zurich" }, { "Basel", "Europe/Zurich" },
  { "Gothenburg", "Europe/Stockholm" }, { "Porto", "Europe/Lisbon" }, { "Krakow", "Europe/Warsaw" },
  { "St Petersburg", "Europe/Moscow" }, { "Beijing", "Asia/Shanghai" }, { "Shenzhen", "Asia/Shanghai" },
  { "Guangzhou", "Asia/Shanghai" }, { "Osaka", "Asia/Tokyo" }, { "Kyoto", "Asia/Tokyo" }, { "Yokohama", "Asia/Tokyo" },
  { "Nagoya", "Asia/Tokyo" }, { "Busan", "Asia/Seoul" }, { "Mumbai", "Asia/Kolkata" }, { "Delhi", "Asia/Kolkata" },
  { "New Delhi", "Asia/Kolkata" }, { "Bangalore", "Asia/Kolkata" }, { "Bengaluru", "Asia/Kolkata" },
  { "Chennai", "Asia/Kolkata" }, { "Hyderabad", "Asia/Kolkata" }, { "Pune", "Asia/Kolkata" },
  { "Abu Dhabi", "Asia/Dubai" }, { "Tel Aviv", "Asia/Jerusalem" }, { "Canberra", "Australia/Sydney" },
  { "Cape Town", "Africa/Johannesburg" }, { "Durban", "Africa/Johannesburg" }, { "Alexandria", "Africa/Cairo" },
}

-- zone.tab's zones plus the aliases, as {label, zone}: the offline half of the search.
local function catalog()
  if zoneCatalog then return zoneCatalog end
  local out, seen = {}, {}
  local function offer(label, zone)
    local key = label .. "\0" .. zone
    if not seen[key] then seen[key] = true out[#out + 1] = { label, zone } end
  end
  zoneTabText = zoneTabText or readFile(ZONE_TAB) or ""
  for line in zoneTabText:gmatch("[^\n]+") do
    local z = line:sub(1, 1) ~= "#" and line:match("^%S+\t%S+\t(%S+)") or nil
    if z and z:find("/", 1, true) then offer(labelForZoneId(z), z) end
  end
  for _, a in ipairs(ALIASES) do offer(a[1], a[2]) end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  zoneCatalog = out
  return out
end

local function placeOptions(body)
  local results = geocodeResults(body)
  if not results then return {} end
  local out, seen = {}, {}
  for _, r in ipairs(results) do
    if type(r) == "table" then
      local zone = type(r.timezone) == "string" and r.timezone or ""
      local name = cleanLabel(r.name)
      local lat, lon = coord(r.latitude, 90), coord(r.longitude, 180)
      if name ~= "" and validZone(zone) and lat and lon then
        local parts = {}
        local admin = cleanLabel(r.admin1)
        if admin ~= "" and admin ~= name then parts[#parts + 1] = admin end
        local country = cleanLabel(r.country_code or r.country)
        if country ~= "" then parts[#parts + 1] = (#country == 2) and country:upper() or country end
        local region = table.concat(parts, ", ")
        local key = name .. "\0" .. region .. "\0" .. zone
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = { label = name, value = zone, lat = lat, lon = lon, region = region }
        end
      end
    end
  end
  return out
end

local function sendPage(fnName, value)
  if not view then return end
  local js = "window." .. fnName .. " && window." .. fnName .. "(" .. (hs.json.encode({ value }) or "[null]") .. "[0])"
  pcall(function() view:evaluateJavaScript(js) end)
end

local function citiesForPage()
  local out = {}
  for i, c in ipairs(cfg.cities) do out[i] = { i = i, n = c.name, z = c.zone, lat = c.lat, lon = c.lon } end
  return out
end

-- One geocoder request at a time, latest query wins; answers are kept for the session.
local function lookupPlaces()
  local q = placeWanted
  if not q or placeCache[q] or placeBusy then return end
  placeBusy = true
  hs.http.asyncGet(GEOCODE .. hs.http.encodeForQuery(q), nil, function(status, body)
    placeBusy = false
    placeCache[q] = status == 200 and placeOptions(body) or {}
    sendPage("omarchyPlaces", { q = q, places = placeCache[q] })
    if placeWanted ~= q then hs.timer.doAfter(0, lookupPlaces) end
  end)
end

local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function overlayPage(mode)
  local c = function(n) return theme.hex(n) end
  local init = hs.json.encode({
    mode = mode, catalog = catalog(), cities = citiesForPage(), localZone = localZone,
  }) or "{}"
  -- Never let a "</" (e.g. "</script>") reach the page's script block.
  init = init:gsub("</", "<\\/")
  local heading = mode == "here" and "Where are you?" or "Add a city"
  local placeholder = mode == "here" and "Where are you?" or "Search cities…"
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{background:]] .. c("background") .. [[;color:]] .. c("foreground") .. [[;height:100%;overflow:hidden;
    font-family:"JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace;font-size:12px}
  body{border:2px solid ]] .. c("accent") .. [[;display:flex;flex-direction:column;padding:16px 18px;gap:10px}
  h1{font-size:11px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:]] .. c("dark_foreground") .. [[}
  #q{width:100%;background:transparent;border:1px solid ]] .. c("selection") .. [[;outline:0;padding:7px 9px;
    color:]] .. c("bright_foreground") .. [[;font:inherit;font-size:13px}
  #q:focus{border-color:]] .. c("accent") .. [[}
  #q::placeholder{color:]] .. c("dark_foreground") .. [[}
  #res{display:flex;flex-direction:column;gap:1px;min-height:20px}
  .m{display:flex;align-items:baseline;gap:8px;padding:6px 8px;cursor:pointer}
  .m .l{color:]] .. c("foreground") .. [[;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .m .d{color:]] .. c("dark_foreground") .. [[;font-size:11px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .m .o{color:]] .. c("dark_foreground") .. [[;font-size:11px}
  .m.sel{background:]] .. c("selection") .. [[}.m.sel .l{color:]] .. c("accent") .. [[}
  .note{color:]] .. c("dark_foreground") .. [[;font-size:11px;padding:4px 8px}
  h2{font-size:11px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:]] .. c("dark_foreground") .. [[;margin-top:6px}
  #list{display:flex;flex-direction:column;gap:2px;overflow-y:auto;flex:1}
  .c{display:flex;align-items:center;gap:8px;padding:5px 8px;border:1px solid transparent;cursor:grab}
  .c:hover{background:]] .. c("selection") .. [[}
  .c.drag{opacity:.4}.c.over{border-color:]] .. c("accent") .. [[}
  .c .h{color:]] .. c("dark_foreground") .. [[}.c .n{flex:1}.c .z{color:]] .. c("dark_foreground") .. [[;font-size:11px}
  .c .x{color:]] .. c("dark_foreground") .. [[;cursor:pointer;padding:0 4px}.c .x:hover{color:]] .. c("red") .. [[}
  footer{font-size:10px;color:]] .. c("dark_foreground") .. [[}
  </style></head><body>
  <h1>]] .. esc(heading) .. [[</h1>
  <input id="q" placeholder="]] .. esc(placeholder) .. [[" autocomplete="off" spellcheck="false">
  <div id="res"></div>
  <h2 id="lh">Your cities</h2><div id="list"></div>
  <footer>↑ ↓ choose · Return pick · Esc back · drag cities to reorder</footer>
  <script>
  const send=(m)=>window.webkit.messageHandlers.omarchy_elsewhen.postMessage(m);
  const INIT=]] .. init .. [[;
  const q=document.getElementById('q'),res=document.getElementById('res'),list=document.getElementById('list');
  let cities=Array.isArray(INIT.cities)?INIT.cities:[],sel=0,matches=[],places={},timer=null;
  const offCache={};
  function utcLabel(z){
    if(z in offCache)return offCache[z];
    let out='';
    try{
      const p=new Intl.DateTimeFormat('en-US',{timeZone:z,timeZoneName:'shortOffset'}).formatToParts(new Date());
      const t=(p.find(x=>x.type==='timeZoneName')||{}).value||'';
      out=t==='GMT'?'UTC':t.replace(/^GMT/,'UTC');
    }catch(e){out=''}
    return offCache[z]=out;
  }
  function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
  function tracked(label,zone){return cities.some(c=>c.z===zone&&c.n===label)}
  function near(a,b){return a.lat!=null&&b.lat!=null&&Math.abs(a.lat-b.lat)<0.01&&Math.abs(a.lon-b.lon)<0.01}
  function search(){
    const text=q.value.replace(/\s+/g,' ').trim().toLowerCase();
    const starts=[],contains=[];
    for(const [label,zone] of (Array.isArray(INIT.catalog)?INIT.catalog:[])){
      if(INIT.mode==='add'&&tracked(label,zone))continue;
      const l=label.toLowerCase(),z=zone.toLowerCase();
      if(text===''){if(starts.length<6)starts.push({label,value:zone})}
      else if(l.indexOf(text)===0)starts.push({label,value:zone});
      else if(l.indexOf(text)!==-1||z.indexOf(text)!==-1)contains.push({label,value:zone});
    }
    const out=starts.concat(contains).slice(0,6),offline=out.length;
    const ps=text.length>=3?(places[text]||[]):[];
    for(const p of ps){
      if(INIT.mode==='add'&&cities.some(c=>c.z===p.value&&(near(c,p)||(c.lat==null&&c.n.toLowerCase()===p.label.toLowerCase()))))continue;
      let twin=-1;
      for(let j=0;j<offline;j++)if(out[j].value===p.value&&out[j].label.toLowerCase()===p.label.toLowerCase()){twin=j;break}
      if(twin>=0&&out[twin].lat==null)out[twin]=Object.assign({},out[twin],p);
      else if(twin<0||!near(out[twin],p))out.push(p);
    }
    matches=out.slice(0,10);
    if(sel>=matches.length)sel=0;
    let html='';
    matches.forEach((m,i)=>{
      html+='<div class="m'+(i===sel?' sel':'')+'" data-i="'+i+'"><span class="l">'+esc(m.label)+'</span><span class="d">'+
        esc(m.region||m.value)+'</span><span class="o">'+esc(utcLabel(m.value))+'</span></div>';
    });
    if(text.length>=3&&places[text]===undefined)html+='<div class="note">Searching places…</div>';
    res.innerHTML=html;
    res.querySelectorAll('.m').forEach(el=>el.addEventListener('mousedown',e=>{e.preventDefault();pick(+el.dataset.i)}));
  }
  function pick(i){
    const m=matches[i];if(!m)return;
    send({pick:{name:m.label,zone:m.value,lat:m.lat,lon:m.lon,region:m.region||''}});
  }
  function drawList(){
    const show=INIT.mode==='add';
    document.getElementById('lh').style.display=show?'':'none';list.style.display=show?'':'none';
    if(!show)return;
    list.innerHTML=cities.map((c,k)=>'<div class="c" draggable="true" data-k="'+k+'"><span class="h">≡</span><span class="n">'+
      esc(c.n)+'</span><span class="z">'+esc(utcLabel(c.z))+'</span>'+(cities.length>1?'<span class="x" title="Remove">×</span>':'')+'</div>').join('');
    let from=-1;
    list.querySelectorAll('.c').forEach(el=>{
      el.addEventListener('dragstart',e=>{from=+el.dataset.k;el.classList.add('drag');e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain','x')});
      el.addEventListener('dragend',()=>{el.classList.remove('drag');list.querySelectorAll('.over').forEach(o=>o.classList.remove('over'))});
      el.addEventListener('dragover',e=>{e.preventDefault();el.classList.add('over')});
      el.addEventListener('dragleave',()=>el.classList.remove('over'));
      el.addEventListener('drop',e=>{e.preventDefault();const to=+el.dataset.k;if(from<0||from===to)return;
        const order=cities.map(c=>c.i);const [m]=order.splice(from,1);order.splice(to,0,m);send({order})});
      const x=el.querySelector('.x');
      if(x)x.addEventListener('click',e=>{e.stopPropagation();send({remove:cities[+el.dataset.k].i})});
    });
  }
  window.omarchyPlaces=function(p){if(p&&typeof p.q==='string'&&Array.isArray(p.places)){places[p.q]=p.places;search()}};
  window.omarchyCities=function(c){if(Array.isArray(c)){cities=c;drawList();search()}};
  q.addEventListener('input',()=>{
    sel=0;search();
    const text=q.value.replace(/\s+/g,' ').trim().toLowerCase();
    clearTimeout(timer);
    if(text.length>=3&&places[text]===undefined)timer=setTimeout(()=>send({query:text.slice(0,80)}),300);
  });
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();if(q.value){q.value='';search()}else send({close:true})}
    else if(e.key==='Enter'){e.preventDefault();pick(sel)}
    else if(e.key==='ArrowDown'){e.preventDefault();if(matches.length){sel=(sel+1)%matches.length;search()}}
    else if(e.key==='ArrowUp'){e.preventDefault();if(matches.length){sel=(sel-1+matches.length)%matches.length;search()}}
  });
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({close:true})},150));
  drawList();search();setTimeout(()=>q.focus(),30);
  </script></body></html>]]
end

function M.closeOverlay()
  local wasOpen = overlayMode ~= nil
  overlayMode = nil
  placeWanted = nil
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
  if wasOpen then publish() end
end

local function onMessage(body)
  if type(body) ~= "table" then return end
  if body.close == true then return M.closeOverlay() end
  if type(body.query) == "string" then
    local q = body.query:gsub("%s+", " "):lower()
    q = trim(q)
    if #q >= 3 and #q <= 80 then
      placeWanted = q
      if placeCache[q] then sendPage("omarchyPlaces", { q = q, places = placeCache[q] }) else lookupPlaces() end
    end
    return
  end
  if type(body.pick) == "table" then
    local mode = overlayMode
    local pick = body.pick
    M.closeOverlay()
    if mode == "here" then setHere(pick) else addCity(pick) end
    return
  end
  if type(body.order) == "table" and overlayMode == "add" then
    reorder(body.order)
    sendPage("omarchyCities", citiesForPage())
    return
  end
  local idx = tonumber(body.remove)
  if idx and overlayMode == "add" then
    removeAt(math.floor(idx))
    sendPage("omarchyCities", citiesForPage())
  end
end

function M.openOverlay(mode)
  if mode == "here" and not localZone then return toast.warn("Elsewhen: the Mac's time zone is not known yet") end
  M.closeOverlay()
  overlayMode = mode
  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy_elsewhen")
    ucc:setCallback(function(msg)
      local body = type(msg) == "table" and msg.body or nil
      hs.timer.doAfter(0, function()
        local ok, err = pcall(onMessage, body)
        if not ok then log.e("elsewhen: overlay message failed: %s", tostring(err)) end
      end)
    end)
  end
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local w, h = 440, mode == "add" and 560 or 360
  local frame = { x = sf.x + sf.w - w - 16, y = sf.y + 12, w = w, h = math.min(h, sf.h - 24) }
  local ok, err = pcall(function()
    view = hs.webview.new(frame, { developerExtrasEnabled = false }, ucc)
      :windowStyle({ "borderless" })
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.modalPanel)
      :shadow(true)
      :closeOnEscape(false)
      :deleteOnClose(true)
    view:html(overlayPage(mode))
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
  if not ok then
    log.e("elsewhen: could not open the search overlay: %s", tostring(err))
    M.closeOverlay()
    return
  end
  publish()
end

---------------------------------------------------------------- actions
-- x = "24" or "12": the mode the widget asks for (it knows what the system default resolved
-- to); anything else flips the stored setting.
local function toggleHour24(x)
  if x == "24" then
    cfg.hour24 = true
  elseif x == "12" then
    cfg.hour24 = false
  else
    cfg.hour24 = not (cfg.hour24 == true)
  end
  changed()
end

M.actions = {
  -- Omarchy's Super+Ctrl+Alt+E opens the panel: OmniWM can toggle a widget's popout by name.
  ["elsewhen.toggle"] = { fn = function()
    if not hs.fs.attributes(CTL) then return toast.warn("Elsewhen: OmniWM is not installed") end
    local t = hs.task.new(CTL, function(code, _, err)
      if code ~= 0 then log.w("elsewhen: shell toggle failed: %s", tostring(err):sub(1, 160)) end
    end, { "shell", "toggle", "omarchy-elsewhen" })
    t:start()
  end, desc = "World clock: open or close the panel (the bar widget's popout)" },
  ["elsewhen.add"] = { fn = function() M.openOverlay("add") end, desc = "World clock: add a city (search) or reorder" },
  ["elsewhen.here"] = { fn = function() M.openOverlay("here") end, desc = "World clock: where are you? (pick here)" },
  ["elsewhen.close"] = { fn = function() M.closeOverlay() end, desc = "World clock: close the city search" },
  ["elsewhen.remove"] = { fn = function(x)
    local r, i = tostring(x or ""):match("^(%d+):(%d+)$")
    if not r or tonumber(r) ~= rev then return log.w("elsewhen: remove refused (stale or malformed index)") end
    removeAt(tonumber(i))
  end, desc = "World clock: remove a city (x = <rev>:<index> from the published list)" },
  ["elsewhen.toggle-hour24"] = { fn = toggleHour24, desc = "World clock: 24-hour / AM-PM (x = 24 | 12)" },
  ["elsewhen.toggle-offset"] = { fn = function()
    cfg.offsetMode = cfg.offsetMode == "utc" and "home" or "utc"
    changed()
  end, desc = "World clock: offsets from home / UTC" },
  ["elsewhen.toggle-units"] = { fn = function()
    cfg.units = unitsResolved() == "C" and "F" or "C"
    changed()
  end, desc = "World clock: Celsius / Fahrenheit" },
  ["elsewhen.refresh"] = { fn = function()
    weather = {}
    localZone = readLocalZone() or localZone
    publish()
    refreshFacts()
  end, desc = "World clock: re-read the zone and the weather" },
}

---------------------------------------------------------------- lifecycle
local function checkZone()
  local z = readLocalZone()
  if z and z ~= localZone then
    localZone = z
    log.i("elsewhen: the Mac is now on %s", z)
    publish()
    refreshFacts()
  end
end

function M.start()
  M.stop()
  localZone = readLocalZone()
  greet = loadGreetings()
  loadedFromDisk = loadConfig()
  publishGlobe()
  if loadedFromDisk then
    publish()
    refreshFacts()
  else
    publish()
    seedFirstRun()
  end
  timers[#timers + 1] = hs.timer.doEvery(FACTS_EVERY, function() refreshFacts() end)
  timers[#timers + 1] = hs.timer.doEvery(ZONE_CHECK_EVERY, checkZone)
  M.wake = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then hs.timer.doAfter(3, checkZone) end
  end)
  M.wake:start()
end

function M.stop()
  for _, t in ipairs(timers) do pcall(function() t:stop() end) end
  timers = {}
  for _, t in ipairs(tasks) do pcall(function() t:terminate() end) end
  tasks = {}
  if M.wake then M.wake:stop() M.wake = nil end
  M.closeOverlay()
  lastPush, lastGlobePush = nil, nil
end

return M
