-- omarchy-elsewhen: Omarchy 4.5's Elsewhen world clock (Jason Fried) for the OmniShell bar.
--
-- Bar: the nf-md-earth glyph (U+F01E7) in a status slot, tooltip "World clock". Click opens
-- the panel; right-click refreshes (Omarchy's right/middle click).
-- Popout, like Omarchy's panel:
--   * the hero: "It's 2:05 PM here in Miami" (accent while the clocks are shifted), then
--     "World [globe] Clock" with a small drawn globe leaning on the earth's axis
--   * one row per city: name, temperature and weather glyph, the date and how far ahead or
--     behind ("Tomorrow"), or the local greeting while hovered; the time with AM/PM; the zone
--     abbreviation and the offset from home (or UTC); and the city's 24-hour daylight strip
--     (real sunrise/sunset from its coordinates, the sun by day and tonight's moon by night,
--     sunrise/sunset arrows with their times on hover)
--   * click a row to turn the little globe to it; scroll over a strip to shift
--     every clock, which springs back 2.5 s later; click a time, offset or temperature to flip
--     24-hour, home/UTC or C/F for the whole list; the × removes a city
--   * "+ Add a city" opens the search overlay (Hammerspoon); the caption asks "Where are you?"
--   * the little globe opens globe mode: a bigger orthographic globe with coastlines, the
--     day/night line and the cities (gold by day, dark by night), scroll to spin it, click a
--     city to select it and read its time underneath
-- All zone arithmetic is ctx.format.offset / ctx.format.date. The city list, weather, greetings
-- and coastlines come from the Hammerspoon port (vars omarchy_elsewhen, omarchy_elsewhen_globe).
interval = 20

local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local GLYPH = "\u{F01E7}"
local BASE = "hammerspoon://omarchy?a="
local GOLD = "#E5C736"
local W = 340
local PADX = 12
local DIM = "foreground/0.62"
local FAINT = "foreground/0.42"
local DEG = math.pi / 180
local TILT = 23.44
local DAY = 1440
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local WEATHER = { sunny = "\u{F05A8}", partly = "\u{F0595}", cloudy = "\u{F0590}", rain = "\u{F0597}",
    snow = "\u{F0598}" }

---------------------------------------------------------------- bridge
local caches: { [string]: { text: string?, value: any } } = {
    main = { text = nil, value = nil }, globe = { text = nil, value = nil } }

local function decoded(ctx: Context, var: string, slot: string): any
    local cache = caches[slot]
    local text = ctx.select("vars", var)
    if text ~= cache.text then
        cache.text = text
        local ok, value = pcall(function() return if type(text) == "string" and text ~= "" then json.decode(text) else nil end)
        cache.value = if ok then value else nil
    end
    return cache.value
end

local function enc(s: string): string
    return (string.gsub(s, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function open(action: string, arg: string?)
    omniwm.open(BASE .. action .. (if arg then "&x=" .. enc(arg) else ""))
end

local function go(action: string, arg: string?)
    return function(_c: Context, _e: Event)
        open(action, arg)
    end
end

---------------------------------------------------------------- time
type Moment = { off: number, y: number, m: number, d: number, wday: number, hour: number, min: number }

local function moment(ctx: Context, sec: number, zone: string?): Moment?
    local off = ctx.format.offset(sec, zone)
    if off == nil then
        return nil
    end
    local t: any = os.date("!*t", math.floor(sec + off))
    return { off = off // 60, y = t.year, m = t.month, d = t.day, wday = t.wday, hour = t.hour, min = t.min }
end

-- Days since 1970-01-01 for a civil date (calendar fields only, so DST cannot skew it).
local function civil(y: number, m: number, d: number): number
    local yy = if m <= 2 then y - 1 else y
    local era = (if yy >= 0 then yy else yy - 399) // 400
    local yoe = yy - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function pad2(n: number): string
    return string.format("%02d", n)
end

local function clockText(hour: number, min: number, h24: boolean): (string, string)
    if h24 then
        return pad2(hour) .. ":" .. pad2(min), ""
    end
    local h = hour % 12
    if h == 0 then
        h = 12
    end
    return string.format("%d:%s", h, pad2(min)), if hour < 12 then "AM" else "PM"
end

local function oneDecimal(x: number): string
    local r = math.round(x * 10) / 10
    if r == math.floor(r) then
        return string.format("%d", r)
    end
    return string.format("%.1f", r)
end

local function relativeLabel(off: number, localOff: number): string
    local diff = off - localOff
    if diff == 0 then
        return ""
    end
    return (if diff > 0 then "+" else "") .. oneDecimal(diff / 60) .. "h"
end

local function utcLabel(off: number): string
    if off == 0 then
        return "UTC"
    end
    local a = math.abs(off)
    local h, m = a // 60, a % 60
    return "UTC" .. (if off < 0 then "-" else "+") .. tostring(h) .. (if m == 0 then "" else ":" .. pad2(m))
end

local function dayLabel(delta: number): string
    if delta == 0 then
        return ""
    elseif delta == 1 then
        return "Tomorrow"
    elseif delta == -1 then
        return "Yesterday"
    elseif delta > 0 then
        return string.format("+%d days", delta)
    end
    return string.format("-%d days", -delta)
end

local function phaseFor(hour: number): string
    if hour < 6 or hour >= 20 then
        return "night"
    elseif hour < 8 then
        return "dawn"
    elseif hour < 17 then
        return "day"
    end
    return "dusk"
end

local function scrubLabel(minutes: number): string
    local m = math.round(minutes)
    if m == 0 then
        return ""
    end
    local a = math.abs(m)
    local parts = {}
    local d, h, r = a // DAY, (a % DAY) // 60, a % 60
    if d > 0 then parts[#parts + 1] = tostring(d) .. "d" end
    if h > 0 then parts[#parts + 1] = tostring(h) .. "h" end
    if r > 0 then parts[#parts + 1] = tostring(r) .. "m" end
    return (if m > 0 then "+" else "-") .. table.concat(parts, " ")
end

local function weatherKind(code: number?): string
    if code == nil then
        return ""
    end
    local c = code
    if c <= 1 then return "sunny" end
    if c == 2 then return "partly" end
    if c == 3 or c == 45 or c == 48 then return "cloudy" end
    if (c >= 71 and c <= 77) or c == 85 or c == 86 then return "snow" end
    if (c >= 51 and c <= 67) or (c >= 80 and c <= 82) or (c >= 95 and c <= 99) then return "rain" end
    return ""
end

local function tempLabel(celsius: number?, units: string): string
    if celsius == nil then
        return ""
    end
    if units == "F" then
        return tostring(math.round(celsius * 9 / 5 + 32)) .. "°F"
    end
    return tostring(math.round(celsius)) .. "°C"
end

local function greetingFor(bands: any, hour: number): (string, string)
    if type(bands) ~= "table" or #bands == 0 then
        return "", ""
    end
    local band = bands[1]
    for i = 2, #bands do
        local b = bands[i]
        if type(b) == "table" and (tonumber(b[1]) or 99) <= hour then
            band = b
        end
    end
    return tostring(band[2] or ""), tostring(band[3] or "")
end

---------------------------------------------------------------- the sun and the moon
local function subsolar(sec: number): (number, number)
    local jd = sec / 86400 + 2440587.5
    local n = jd - 2451545.0
    local L = (280.460 + 0.9856474 * n) % 360
    local g = ((357.528 + 0.9856003 * n) % 360) * DEG
    local lambda = (L + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) * DEG
    local eps = (TILT - 0.0000004 * n) * DEG
    local decl = math.asin(math.sin(eps) * math.sin(lambda)) / DEG
    local alpha = math.atan2(math.cos(eps) * math.sin(lambda), math.cos(lambda)) / DEG
    local eot = (L - alpha + 540) % 360 - 180
    local utcHours = (sec % 86400) / 3600
    local lon = -15 * (utcHours - 12) - eot
    lon = ((lon + 540) % 360) - 180
    return decl, lon
end

local function wrap180(d: number): number
    return ((d + 540) % 360) - 180
end

local function localMidnight(sec: number, offMin: number): number
    local l = sec + offMin * 60
    return math.floor(l / 86400) * 86400 - offMin * 60
end

type Sun = { kind: string, rise: number, set: number }

-- Sunrise and sunset as minutes from the zone's own midnight (Sun.js).
local function sunTimes(lat: number, lon: number, sec: number, offMin: number): Sun
    local midnight = localMidnight(sec, offMin)
    local t = midnight + 43200
    for _ = 1, 3 do
        local _, slon = subsolar(t)
        t += wrap180(slon - lon) / 15 * 3600
    end
    local dec = subsolar(t)
    local cosH = (math.sin(-0.833 * DEG) - math.sin(lat * DEG) * math.sin(dec * DEG))
        / (math.cos(lat * DEG) * math.cos(dec * DEG))
    if cosH <= -1 then
        return { kind = "midnightSun", rise = 0, set = DAY }
    elseif cosH >= 1 then
        return { kind = "polarNight", rise = 0, set = 0 }
    end
    local half = math.acos(cosH) / DEG / 15 * 3600
    return { kind = "normal", rise = (t - half - midnight) / 60, set = (t + half - midnight) / 60 }
end

local function litSpans(sun: Sun): { { number } }
    if sun.kind == "polarNight" then
        return {}
    elseif sun.kind == "midnightSun" then
        return { { 0, 1 } }
    end
    local out = {}
    for shift = -DAY, DAY, DAY do
        local a = math.clamp(sun.rise + shift, 0, DAY)
        local b = math.clamp(sun.set + shift, 0, DAY)
        if b > a then
            out[#out + 1] = { a / DAY, b / DAY }
        end
    end
    return out
end

local function litAt(sun: Sun, minutes: number): boolean
    if sun.kind == "midnightSun" then
        return true
    elseif sun.kind == "polarNight" then
        return false
    end
    for shift = -DAY, DAY, DAY do
        if minutes >= sun.rise + shift and minutes < sun.set + shift then
            return true
        end
    end
    return false
end

local function moonPhase(sec: number): number
    local jd = sec / 86400 + 2440587.5
    return ((jd - 2451550.1) / 29.530588853) % 1
end

-- The lit part of the moon on a disc of radius r about the origin (GlobeModel.moonLitOutline).
local function moonPath(phase: number, r: number): string
    local squash = math.cos(2 * math.pi * phase)
    local side = if phase > 0.5 then -1 else 1
    local parts = {}
    for i = 0, 14 do
        local t = math.pi * i / 14
        parts[#parts + 1] = string.format("%s%.2f %.2f", if i == 0 then "M" else "L", side * r * math.sin(t), -r * math.cos(t))
    end
    for i = 14, 0, -1 do
        local t = math.pi * i / 14
        parts[#parts + 1] = string.format("L%.2f %.2f", side * r * squash * math.sin(t), -r * math.cos(t))
    end
    return table.concat(parts, " ") .. " Z"
end

local function solarElevation(lat: number, lon: number, slat: number, slon: number): number
    local cz = math.sin(lat * DEG) * math.sin(slat * DEG)
        + math.cos(lat * DEG) * math.cos(slat * DEG) * math.cos((lon - slon) * DEG)
    return math.asin(math.clamp(cz, -1, 1)) / DEG
end

---------------------------------------------------------------- the globe (GlobeModel.js)
local function project(lat: number, lon: number, spin: number, viewLat: number, r: number): (number, number, number)
    local phi = lat * DEG
    local lam = (lon - spin) * DEG
    local p0 = viewLat * DEG
    local cosc = math.sin(p0) * math.sin(phi) + math.cos(p0) * math.cos(phi) * math.cos(lam)
    local x = r * math.cos(phi) * math.sin(lam)
    local y = -r * (math.cos(p0) * math.sin(phi) - math.sin(p0) * math.cos(phi) * math.cos(lam))
    return x, y, cosc
end

local function limb(alat: number, alon: number, blat: number, blon: number, spin: number, viewLat: number,
    r: number): (number?, number?)
    if math.abs(blon - alon) > 180 then
        return nil, nil
    end
    local lo, hi = 0, 1
    for _ = 1, 8 do
        local m = (lo + hi) / 2
        local _, _, c = project(alat + (blat - alat) * m, alon + (blon - alon) * m, spin, viewLat, r)
        if c > 0 then lo = m else hi = m end
    end
    local x, y = project(alat + (blat - alat) * lo, alon + (blon - alon) * lo, spin, viewLat, r)
    return x, y
end

local function pt(buf: { string }, cmd: string, x: number, y: number)
    buf[#buf + 1] = string.format("%s%.1f %.1f", cmd, x, y)
end

-- Near-side runs of a [lat, lon] polyline, appended to buf as M/L commands.
local function strokeRuns(buf: { string }, pts: { { number } }, spin: number, viewLat: number, r: number)
    local run = 0
    local prev: { number }? = nil
    local prevVis = false
    for _, p in pts do
        local x, y, c = project(p[1], p[2], spin, viewLat, r)
        local vis = c > 0
        if vis then
            if run == 0 and prev and not prevVis then
                local ex, ey = limb(p[1], p[2], prev[1], prev[2], spin, viewLat, r)
                if ex and ey then
                    pt(buf, "M", ex, ey)
                    run = 1
                end
            end
            pt(buf, if run == 0 then "M" else "L", x, y)
            run += 1
        else
            if run > 0 and prev then
                local ex, ey = limb(prev[1], prev[2], p[1], p[2], spin, viewLat, r)
                if ex and ey then pt(buf, "L", ex, ey) end
            end
            run = 0
        end
        prev = p
        prevVis = vis
    end
end

type XY = { x: number, y: number }

-- A flat [lon, lat, ...] ring clipped to the visible hemisphere, following the limb.
local function clipRing(ring: { number }, spin: number, viewLat: number, r: number): { XY }
    local n = #ring // 2
    local out: { { x: number, y: number, limb: boolean } } = {}
    for i = 0, n - 1 do
        local j = (i + 1) % n
        local alat, alon = ring[i * 2 + 2], ring[i * 2 + 1]
        local blat, blon = ring[j * 2 + 2], ring[j * 2 + 1]
        local ax, ay, ac = project(alat, alon, spin, viewLat, r)
        local bx, by, bc = project(blat, blon, spin, viewLat, r)
        local _ = ax + ay
        if ac > 0 and bc > 0 then
            out[#out + 1] = { x = bx, y = by, limb = false }
        elseif ac > 0 then
            local ex, ey = limb(alat, alon, blat, blon, spin, viewLat, r)
            if ex and ey then out[#out + 1] = { x = ex, y = ey, limb = true } end
        elseif bc > 0 then
            local ex, ey = limb(blat, blon, alat, alon, spin, viewLat, r)
            if ex and ey then out[#out + 1] = { x = ex, y = ey, limb = true } end
            out[#out + 1] = { x = bx, y = by, limb = false }
        end
    end
    if #out < 3 then
        return {}
    end
    local res: { XY } = {}
    for k = 1, #out do
        local a = out[k]
        res[#res + 1] = { x = a.x, y = a.y }
        local b = out[k % #out + 1]
        if a.limb and b.limb then
            local a0 = math.atan2(a.y, a.x)
            local a1 = math.atan2(b.y, b.x)
            local d = a1 - a0
            while d > math.pi do d -= 2 * math.pi end
            while d < -math.pi do d += 2 * math.pi end
            local steps = math.max(1, math.round(math.abs(d) / 0.15))
            for t = 1, steps - 1 do
                local ang = a0 + d * t / steps
                res[#res + 1] = { x = r * math.cos(ang), y = r * math.sin(ang) }
            end
        end
    end
    return res
end

local function polyPath(buf: { string }, poly: { XY })
    for k, p in poly do
        pt(buf, if k == 1 then "M" else "L", p.x, p.y)
    end
    buf[#buf + 1] = "Z"
end

local function inPoly(poly: { XY }, x: number, y: number): boolean
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local a, b = poly[i], poly[j]
        if (a.y > y) ~= (b.y > y) and x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function graticule(buf: { string }, lons: { number }, lats: { number }, spin: number, viewLat: number, r: number)
    for _, lon in lons do
        local pts = {}
        for lat = -90, 90, 3 do pts[#pts + 1] = { lat, lon } end
        strokeRuns(buf, pts, spin, viewLat, r)
    end
    for _, lat in lats do
        local pts = {}
        for lon = -180, 180, 3 do pts[#pts + 1] = { lat, lon } end
        strokeRuns(buf, pts, spin, viewLat, r)
    end
end

-- The great circle 90 degrees from the subsolar point, as [lat, lon] points.
local function terminator(slat: number, slon: number): { { number } }
    local la, lo = slat * DEG, slon * DEG
    local s = { math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la) }
    local up = if math.abs(s[3]) < 0.9 then { 0, 0, 1 } else { 1, 0, 0 }
    local function cross(a: { number }, b: { number }): { number }
        return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
    end
    local function norm(v: { number }): { number }
        local m = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
        if m == 0 then m = 1 end
        return { v[1] / m, v[2] / m, v[3] / m }
    end
    local a = norm(cross(up, s))
    local b = norm(cross(s, a))
    local out = {}
    for i = 0, 120 do
        local t = i / 120 * 2 * math.pi
        local v1 = a[1] * math.cos(t) + b[1] * math.sin(t)
        local v2 = a[2] * math.cos(t) + b[2] * math.sin(t)
        local v3 = a[3] * math.cos(t) + b[3] * math.sin(t)
        out[#out + 1] = { math.asin(math.clamp(v3, -1, 1)) / DEG, math.atan2(v2, v1) / DEG }
    end
    return out
end

local function shortestTurn(from: number, to: number): number
    local d = ((to - from) % 360 + 360) % 360
    return if d > 180 then d - 360 else d
end

-- Tween spin (and optionally viewLat) at ~30 fps; a newer tween cancels an older one.
local function animate(state: { [string]: any }, toSpin: number, toLat: number?, frames: number, fromSpin: number?)
    state.animId = (state.animId or 0) + 1
    local id = state.animId
    local s0 = fromSpin or state.spin or toSpin
    local l0 = state.viewLat or 0
    local i = 0
    local function step()
        if state.animId ~= id then
            return
        end
        i += 1
        local t = math.min(1, i / frames)
        local e = 1 - (1 - t) ^ 4
        state.spin = s0 + (toSpin - s0) * e
        if toLat ~= nil then
            state.viewLat = l0 + (toLat - l0) * e
        end
        if i < frames then
            omniwm.after(1 / 30, step)
        end
    end
    local _h, err = omniwm.after(1 / 30, step)
    if err then
        state.spin = toSpin
        if toLat ~= nil then state.viewLat = toLat end
    end
end

---------------------------------------------------------------- the model
type Row = { index: number, key: string, name: string, zone: string, lat: number?, lon: number?,
    m: Moment?, c: number?, w: number?, g: any }

local function settings(ctx: Context, d: any)
    local localM = moment(ctx, os.time(), nil)
    local h24 = d and d.h24
    if h24 ~= true and h24 ~= false then
        -- Unset follows the system: the locale's preferred hour ("j") carries the AM/PM marker
        -- only when the Mac uses 12-hour time.
        local probe = ctx.format.date(46800, "j") or ""
        local marker = ctx.format.date(46800, "a") or ""
        h24 = marker == "" or string.find(probe, marker, 1, true) == nil
    end
    return {
        h24 = h24 == true,
        utc = d and d.off == "utc",
        units = if d and d.units == "F" then "F" else "C",
        localOff = if localM then localM.off else 0,
    }
end

local function rows(ctx: Context, d: any, sec: number): { Row }
    local out: { Row } = {}
    for i, c in (if d and type(d.cities) == "table" then d.cities else {}) do
        if type(c) == "table" and type(c.z) == "string" then
            out[#out + 1] = { index = i, key = tostring(c.n) .. "|" .. c.z, name = tostring(c.n or c.z), zone = c.z,
                lat = tonumber(c.lat), lon = tonumber(c.lon), m = moment(ctx, sec, c.z),
                c = tonumber(c.c), w = tonumber(c.w), g = c.g }
        end
    end
    return out
end

local function focusedRow(ctx: Context, list: { Row }): Row?
    local key = ctx.state.focus
    if key == nil then
        return nil
    end
    for _, r in list do
        if r.key == key then
            return r
        end
    end
    return nil
end

---------------------------------------------------------------- the little globe
local mini = { key = "", grat = "", land = "", marker = nil :: { number }? }

local function miniGlobe(ctx: Context, globe: any, spin: number, marker: { number }?, crossed: boolean)
    local size = 31
    local r = size / 2 - 1
    local stack = { w = size, h = size, rotate = TILT }
    if crossed then
        return ui.stack{ w = size, h = size,
            ui.text{ text = "\u{00D7}", font = FONT, size = 24, color = "foreground" } }
    end
    local land = if globe and type(globe.land) == "table" then globe.land else {}
    local key = string.format("%d|%.1f|%s", #land, spin, if marker then string.format("%.2f,%.2f", marker[1], marker[2]) else "")
    if key ~= mini.key then
        mini.key = key
        local g = {}
        graticule(g, { -90, 0 }, { 0 }, spin, 0, r)
        mini.grat = table.concat(g, " ")
        local l = {}
        for _, ring in land do
            if type(ring) == "table" and #ring >= 40 then
                local poly = clipRing(ring, spin, 0, r)
                if #poly >= 3 then polyPath(l, poly) end
            end
        end
        mini.land = table.concat(l, " ")
    end
    local vb = { -size / 2, -size / 2, size, size }
    stack[#stack + 1] = ui.box{ w = r * 2, h = r * 2, radius = r, fill = "foreground/0.16" }
    if mini.grat ~= "" then
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = vb, d = mini.grat,
            border = if #land > 0 then "foreground/0.42" else "foreground/0.85", borderWidth = 1 }
    end
    if mini.land ~= "" then
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = vb, d = mini.land, fill = "foreground" }
    end
    if marker then
        local x, y, c = project(marker[1], marker[2], spin, 0, r)
        if c > 0 then
            local mr = math.max(1.6, r * 0.13)
            stack[#stack + 1] = ui.box{ align = "topLeading", dx = size / 2 + x - mr * 1.9, dy = size / 2 + y - mr * 1.9,
                w = mr * 3.8, h = mr * 3.8, radius = mr * 1.9, border = "accent/0.65", borderWidth = 1 }
            stack[#stack + 1] = ui.box{ align = "topLeading", dx = size / 2 + x - mr, dy = size / 2 + y - mr,
                w = mr * 2, h = mr * 2, radius = mr, fill = "accent" }
        end
    end
    stack[#stack + 1] = ui.box{ w = r * 2, h = r * 2, radius = r, border = "foreground", borderWidth = 1.4 }
    return ui.stack(stack)
end

---------------------------------------------------------------- the daylight strip
local function strip(ctx: Context, row: Row, sec: number, width: number, hovered: boolean, h24: boolean)
    local m = row.m
    local s = { w = width, h = 18 }
    if not m then
        return ui.stack(s)
    end
    local progress = (m.hour * 60 + m.min) / DAY
    local sun: Sun? = nil
    if row.lat and row.lon then
        sun = sunTimes(row.lat, row.lon, localMidnight(sec, m.off) + 43200, m.off)
    end
    local spans = if sun then litSpans(sun) else { { 6 / 24, 18 / 24 } }
    local lit = if sun then litAt(sun, progress * DAY) else (m.hour >= 6 and m.hour < 18)
    s[#s + 1] = ui.box{ w = width, h = 3, radius = 1.5, fill = "foreground/0.10" }
    for _, span in spans do
        s[#s + 1] = ui.box{ align = "leading", dx = width * span[1], w = math.max(1, width * (span[2] - span[1])),
            h = 3, radius = 1.5, fill = "foreground/0.28" }
    end
    local mx = math.clamp(width * progress - 5, 0, width - 10)
    if lit then
        s[#s + 1] = ui.box{ key = "now", align = "leading", dx = mx, w = 10, h = 10, radius = 5, fill = GOLD,
            animate = "ease" }
    else
        s[#s + 1] = ui.stack{ key = "now", align = "leading", dx = mx, w = 10, h = 10, animate = "ease",
            ui.box{ w = 10, h = 10, radius = 5, fill = "foreground/0.22" },
            ui.path{ w = 10, h = 10, viewBox = { -5, -5, 10, 10 }, d = moonPath(moonPhase(sec), 5), fill = "foreground" } }
    end
    if hovered and sun and sun.kind == "normal" then
        local marks = { { sun.rise, true }, { sun.set, false } }
        for _, mk in marks do
            local minutes, rising = mk[1], mk[2]
            if minutes >= 0 and minutes <= DAY then
                local at = width * minutes / DAY
                local box = 14
                local x = math.clamp(if rising then at - box + 3 else at - 3, 0, width - box)
                local covered = math.abs((mx + 5) - (x + box / 2)) < 5 + 4
                if not covered then
                    local total = math.round(minutes)
                    local t, mer = clockText((total // 60) % 24, total % 60, h24)
                    local when = if mer ~= "" then t .. " " .. mer else t
                    s[#s + 1] = ui.text{ align = "leading", dx = x + 3, dy = if rising then -2 else 2, w = box,
                        text = if rising then "\u{2191}" else "\u{2193}", font = FONT, size = 10, color = FAINT,
                        help = (if rising then "Sunrise " else "Sunset ") .. when }
                end
            end
        end
    end
    -- Scroll along the strip to shift every clock; it springs back 2.5 s later.
    s.onScroll = function(c: Context, e: Event)
        local delta = if e.dx ~= 0 then -e.dx else e.dy
        local acc = (c.state.scrubAcc or 0) + (if e.precise then delta / 8 else delta)
        local steps = if acc >= 0 then math.floor(acc) else math.ceil(acc)
        c.state.scrubAcc = acc - steps
        if steps ~= 0 then
            c.state.scrub = (c.state.scrub or 0) + steps * 15
            local token = (c.state.scrubToken or 0) + 1
            c.state.scrubToken = token
            local st = c.state
            omniwm.after(2.5, function()
                if st.scrubToken == token then st.scrub = 0 end
            end)
        end
    end
    return ui.stack(s)
end

---------------------------------------------------------------- a city row
local function cityRow(ctx: Context, d: any, row: Row, total: number, sec: number, opts: any, picked: boolean)
    local m = row.m
    local hovered = ctx.state.hover == row.key
    local inner = W - PADX * 2
    local phase = if m then phaseFor(m.hour) else "day"
    local base = if phase == "day" then 0.10 elseif phase == "night" then 0.035 else 0.07
    local fill = if picked then 0.15 elseif hovered then base + 0.05 else base
    local time, mer = "--:--", ""
    local date, dayL = "\u{2026}", ""
    local abbr, offText = "", ""
    if m then
        time, mer = clockText(m.hour, m.min, opts.h24)
        date = string.format("%s %s %d", WEEKDAYS[m.wday] or "", MONTHS[m.m] or "", m.d)
        local hereM = moment(ctx, sec, nil)
        if hereM then
            dayL = dayLabel(civil(m.y, m.m, m.d) - civil(hereM.y, hereM.m, hereM.d))
        end
        abbr = ctx.format.date(sec, "zzz", row.zone) or ""
        offText = if opts.utc then utcLabel(m.off) else relativeLabel(m.off, opts.localOff)
    end
    local temp = tempLabel(row.c, opts.units)
    local glyph = WEATHER[weatherKind(row.w)] or ""

    local nameLine = { w = inner - 96, gap = 7,
        look.text{ text = row.name, font = FONT, size = 13, weight = "semibold", maxWidth = inner - 96 - 60, lines = 1 },
        ui.box{ grow = 1, h = 1 } }
    if temp ~= "" then
        nameLine[#nameLine + 1] = ui.text{ text = temp, font = FONT, size = 10, color = DIM,
            onClick = go("elsewhen.toggle-units"), help = "Celsius / Fahrenheit" }
    end
    if glyph ~= "" then
        nameLine[#nameLine + 1] = ui.text{ text = glyph, font = FONT, size = 11, color = DIM }
    end

    local second
    local greet, roman = "", ""
    if m and hovered then
        greet, roman = greetingFor(row.g, m.hour)
    end
    if greet ~= "" then
        second = ui.row{ gap = 5,
            ui.text{ text = greet, size = 10, color = "foreground", maxWidth = inner - 120, lines = 1 },
            if roman ~= "" then ui.text{ text = roman, font = FONT, size = 10, color = FAINT, maxWidth = 110, lines = 1 }
                else ui.box{ w = 0, h = 0 } }
    else
        second = ui.row{ gap = 5,
            ui.text{ text = date, font = FONT, size = 10, color = if dayL ~= "" then DIM else FAINT },
            if dayL ~= "" then ui.text{ text = "\u{00B7}", font = FONT, size = 10, color = FAINT } else ui.box{ w = 0, h = 0 },
            if dayL ~= "" then ui.text{ text = dayL, font = FONT, size = 10, color = DIM } else ui.box{ w = 0, h = 0 } }
    end

    local timeLine = ui.row{ gap = 4, align = "trailing",
        onClick = go("elsewhen.toggle-hour24", if opts.h24 then "12" else "24"), help = "24-hour / AM-PM",
        ui.text{ text = time, font = FONT, size = 16, weight = "semibold", color = "foreground" },
        if mer ~= "" then ui.text{ text = mer, font = FONT, size = 10, color = DIM } else ui.box{ w = 0, h = 0 } }
    local offLine = ui.row{ gap = 5, align = "trailing", onClick = go("elsewhen.toggle-offset"),
        help = "Offsets from home / UTC",
        ui.text{ text = abbr, font = FONT, size = 10, color = FAINT },
        if offText ~= "" then ui.text{ text = offText, font = FONT, size = 10, color = FAINT } else ui.box{ w = 0, h = 0 } }

    local top = ui.row{ w = inner, gap = 12,
        ui.column{ w = inner - 96, gap = 2, center = false, ui.row(nameLine), second },
        ui.column{ w = 84, gap = 1, center = false, timeLine, offLine } }

    local body = ui.column{ key = "row:" .. row.key, w = W, pad = PADX, gap = 9, center = false,
        fill = string.format("foreground/%.3f", fill), radius = look.radius(6),
        onClick = function(c: Context, _e: Event)
            local st = c.state
            st.focus = row.key
            if row.lon then
                local from = st.spin or opts.spin
                animate(st, from + shortestTurn(from, row.lon), nil, 21, from)
            end
        end,
        onHover = function(c: Context, e: Event)
            if e.phase == "began" then
                c.state.hover = row.key
            elseif (e.phase == "ended" or e.phase == "cancelled" or e.phase == "cancel") and c.state.hover == row.key then
                c.state.hover = nil
            end
        end,
        top,
        strip(ctx, row, sec, inner, hovered, opts.h24) }

    if hovered and total > 1 then
        return ui.stack{ w = W, body,
            ui.stack{ align = "topTrailing", dx = -4, dy = 4, w = 18, h = 18, radius = 9,
                fill = "foreground/0.14", border = "foreground/0.35", borderWidth = 1, hover = "foreground/0.10",
                onClick = go("elsewhen.remove", string.format("%d:%d", tonumber(d.rev) or 0, row.index)), help = "Remove",
                ui.text{ text = "\u{00D7}", font = FONT, size = 11, color = DIM } } }
    end
    return body
end

---------------------------------------------------------------- globe mode
local function globeMode(ctx: Context, d: any, globe: any, list: { Row }, sec: number, opts: any, spinNow: number)
    local st = ctx.state
    local size = W
    local r = 150
    local spin = spinNow
    local viewLat = st.viewLat or 0
    local slat, slon = subsolar(sec)
    local land = if globe and type(globe.land) == "table" then globe.land else {}
    local home = d and d.home

    -- [name, zone, lat, lon, rank, home, tracked]: home first, then the built-ins, then tracked.
    local cities = {}
    local seen = {}
    local function add(name: string, zone: string, lat: number?, lon: number?, rank: number, isHome: boolean, tracked: boolean)
        if lat == nil or lon == nil then return end
        local k = string.lower(name)
        if seen[k] then
            local c = cities[seen[k]]
            c.tracked = c.tracked or tracked
            return
        end
        cities[#cities + 1] = { name = name, zone = zone, lat = lat, lon = lon, rank = rank, home = isHome, tracked = tracked }
        seen[k] = #cities
    end
    if home and home.lat then add(tostring(home.n), tostring(d.zone), tonumber(home.lat), tonumber(home.lon), 0, true, false) end
    local trackedNames = {}
    for _, row in list do trackedNames[string.lower(row.name)] = true end
    for _, c in (if globe and type(globe.cities) == "table" then globe.cities else {}) do
        if type(c) == "table" then
            add(tostring(c[1]), tostring(c[2]), tonumber(c[3]), tonumber(c[4]), tonumber(c[5]) or 3, false,
                trackedNames[string.lower(tostring(c[1]))] == true)
        end
    end
    for _, row in list do add(row.name, row.zone, row.lat, row.lon, 0, false, true) end

    local buf = {}
    graticule(buf, { -150, -120, -90, -60, -30, 0, 30, 60, 90, 120, 150, 180 }, { -60, -30, 0, 30, 60 }, spin, viewLat, r)
    local gratPath = table.concat(buf, " ")
    local polys = {}
    local lb = {}
    for _, ring in land do
        if type(ring) == "table" and #ring >= 8 then
            local poly = clipRing(ring, spin, viewLat, r)
            if #poly >= 3 then
                polys[#polys + 1] = poly
                polyPath(lb, poly)
            end
        end
    end
    local tb = {}
    strokeRuns(tb, terminator(slat, slon), spin, viewLat, r)

    local vb = { -size / 2, -size / 2, size, size }
    local stack = { w = size, h = size, key = "globe" }
    stack[#stack + 1] = ui.box{ w = r * 2, h = r * 2, radius = r, fill = "foreground/0.05", border = "foreground/0.22", borderWidth = 1 }
    if gratPath ~= "" then
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = vb, d = gratPath, border = "foreground/0.10", borderWidth = 1 }
    end
    if #lb > 0 then
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = vb, d = table.concat(lb, " "), fill = "foreground/0.92" }
    end
    if #tb > 0 then
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = vb, d = table.concat(tb, " "), border = GOLD .. "8C", borderWidth = 1 }
    end

    -- Near-side cities in priority order, thinned (keep = home, tracked, selected).
    local selected = st.gsel or (if home then string.lower(tostring(home.n)) else nil)
    local cand = {}
    for _, c in cities do
        local x, y, cosc = project(c.lat, c.lon, spin, viewLat, r)
        if cosc > 0 then
            cand[#cand + 1] = { c = c, x = x, y = y, cosc = cosc,
                keep = c.home or c.tracked or string.lower(c.name) == selected }
        end
    end
    table.sort(cand, function(a, b)
        if a.keep ~= b.keep then return a.keep end
        if a.c.rank ~= b.c.rank then return a.c.rank < b.c.rank end
        return a.cosc > b.cosc
    end)
    local plotted = {}
    for _, p in cand do
        local clash = false
        if not p.keep then
            for _, q in plotted do
                if math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) < 19 then clash = true; break end
            end
        end
        if not clash then plotted[#plotted + 1] = p end
    end
    local function selectCity(c: any)
        return function(cc: Context, _e: Event)
            cc.state.gsel = string.lower(c.name)
            local from = cc.state.spin or spinNow
            animate(cc.state, from + shortestTurn(from, c.lon), math.clamp(c.lat, -60, 60), 21, from)
        end
    end
    for _, p in plotted do
        local c = p.c
        local day = solarElevation(c.lat, c.lon, slat, slon) > -0.833
        local isSel = string.lower(c.name) == selected
        local cx, cy = size / 2 + p.x, size / 2 + p.y
        local dot = if isSel then 7.2 else 4.4
        if c.home then
            stack[#stack + 1] = ui.box{ align = "topLeading", dx = cx - 6.4, dy = cy - 6.4, w = 12.8, h = 12.8, radius = 6.4,
                border = "accent/0.65", borderWidth = 1.4 }
            dot = 6.8
        elseif c.tracked then
            stack[#stack + 1] = ui.box{ align = "topLeading", dx = cx - 4.6, dy = cy - 4.6, w = 9.2, h = 9.2, radius = 4.6,
                border = "accent", borderWidth = 1.3 }
        end
        if isSel then
            stack[#stack + 1] = ui.box{ align = "topLeading", dx = cx - 7.5, dy = cy - 7.5, w = 15, h = 15, radius = 7.5,
                border = if day then GOLD else "foreground", borderWidth = 1.4 }
        end
        stack[#stack + 1] = ui.box{ align = "topLeading", dx = cx - dot / 2, dy = cy - dot / 2, w = dot, h = dot, radius = dot / 2,
            fill = if c.home then "accent" elseif day then GOLD else "background/0.92",
            border = if day then "background/0.7" else "foreground/0.85", borderWidth = 1,
            onClick = selectCity(c), help = c.name }
    end

    -- Labels: greedy by rank then nearness to the centre, flipped left near the right edge.
    local placed = {}
    local labelCand = {}
    for _, p in plotted do
        if p.cosc >= 0.12 then labelCand[#labelCand + 1] = p end
    end
    table.sort(labelCand, function(a, b)
        local ra = if a.keep then 0 else a.c.rank
        local rb = if b.keep then 0 else b.c.rank
        if ra ~= rb then return ra < rb end
        return a.cosc > b.cosc
    end)
    for _, p in labelCand do
        if #placed >= 14 then break end
        local name = p.c.name
        local lw = #name * 10 * 0.62
        local lx = p.x + 6
        if lx + lw > size / 2 - 4 then lx = p.x - 6 - lw end
        local box = { x = lx, y = p.y - 6.5, w = lw, h = 13 }
        local clash = false
        for _, o in placed do
            if box.x < o.x + o.w and box.x + box.w > o.x and box.y < o.y + o.h and box.y + box.h > o.y then clash = true; break end
        end
        if not clash then
            placed[#placed + 1] = box
            local onLand = false
            for _, poly in polys do
                if inPoly(poly, box.x + box.w / 2, p.y) then onLand = true; break end
            end
            local strong = p.c.home or p.c.tracked
            stack[#stack + 1] = ui.text{ align = "topLeading", dx = size / 2 + box.x, dy = size / 2 + box.y,
                text = name, font = FONT, size = 10, weight = if strong then "bold" else "regular",
                color = if onLand then "background" else "foreground", onClick = selectCity(p.c) }
        end
    end

    stack.onScroll = function(c: Context, e: Event)
        local s2 = c.state
        s2.animId = (s2.animId or 0) + 1
        local k = if e.precise then 0.45 else 6
        s2.spin = (s2.spin or spinNow) - e.dx * k
        s2.viewLat = math.clamp((s2.viewLat or 0) + e.dy * k * 0.5, -60, 60)
    end

    -- Footer: the selected city, its time and badge, then its zone and offset (click flips).
    local footer = { w = W, gap = 1, center = true }
    local sel = nil
    for _, c in cities do
        if string.lower(c.name) == selected then sel = c; break end
    end
    if sel then
        local m = moment(ctx, sec, sel.zone)
        local day = solarElevation(sel.lat, sel.lon, slat, slon) > -0.833
        local t, mer = "", ""
        if m then t, mer = clockText(m.hour, m.min, opts.h24) end
        local badge = if sel.home then "home" elseif sel.tracked then "tracked" else ""
        footer[#footer + 1] = ui.row{ gap = 7,
            if day then ui.box{ w = 7, h = 7, radius = 3.5, fill = GOLD }
                else ui.stack{ w = 7, h = 7, ui.box{ w = 7, h = 7, radius = 3.5, fill = "foreground/0.22" },
                    ui.path{ w = 7, h = 7, viewBox = { -3.5, -3.5, 7, 7 }, d = moonPath(moonPhase(sec), 3.5), fill = "foreground" } },
            ui.text{ text = sel.name, font = FONT, size = 10, weight = "semibold", color = "foreground" },
            ui.text{ text = if mer ~= "" then t .. " " .. mer else t, font = FONT, size = 10, color = DIM },
            if badge ~= "" then ui.text{ text = badge, font = FONT, size = 10, color = "accent" } else ui.box{ w = 0, h = 0 } }
        local offText = ""
        if m then offText = if opts.utc then utcLabel(m.off) else relativeLabel(m.off, opts.localOff) end
        footer[#footer + 1] = ui.row{ gap = 6, onClick = go("elsewhen.toggle-offset"), help = "Offsets from home / UTC",
            ui.text{ text = sel.zone, font = FONT, size = 10, color = FAINT },
            if offText ~= "" then ui.text{ text = offText, font = FONT, size = 10, color = DIM } else ui.box{ w = 0, h = 0 } }
    else
        footer[#footer + 1] = ui.box{ w = 1, h = 26 }
    end
    local out = { w = W, gap = 6, center = true, ui.stack(stack), ui.column(footer) }
    if globe and globe.missing then
        out[#out + 1] = ui.text{ text = "Coastlines need `omarchy-port sync`", font = FONT, size = 10, color = FAINT }
    end
    return ui.column(out)
end

---------------------------------------------------------------- bar + popout
function render(ctx: Context)
    if ctx.data.bar.style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    return look.bar(ctx, {
        onClick = ui.popout,
        onRightClick = go("elsewhen.refresh"),
        help = "World clock",
        ui.text{ text = GLYPH, font = FONT, size = 15 * look.scale(ctx), color = "foreground" },
    })
end

function popout(ctx: Context)
    local _tick = ctx.data.clock
    local st = ctx.state
    local d = decoded(ctx, "omarchy_elsewhen", "main")
    local globe = decoded(ctx, "omarchy_elsewhen_globe", "globe")
    local opts = settings(ctx, d)
    local scrub = tonumber(st.scrub) or 0
    local sec = os.time() + scrub * 60
    local list = rows(ctx, d, sec)
    local focus = focusedRow(ctx, list)
    local home = d and d.home
    local homeLon = if home and tonumber(home.lon) then tonumber(home.lon) else nil
    local homeLat = if home and tonumber(home.lat) then tonumber(home.lat) else nil

    -- The globe rests on the focused city, or home, until a tween (row click, globe) writes st.spin.
    local restLon = if focus and focus.lon then focus.lon else homeLon
    local spinNow = tonumber(st.spin) or restLon or 0
    opts.spin = spinNow
    local marker: { number }? = nil
    if focus and focus.lat and focus.lon then
        marker = { focus.lat, focus.lon }
    elseif homeLat and homeLon then
        marker = { homeLat, homeLon }
    end

    -- Hero caption: "It's 2:05 PM here in Miami", plus the shift while scrubbed.
    local here = moment(ctx, sec, nil)
    local caption = ""
    if here then
        local t, mer = clockText(here.hour, here.min, opts.h24)
        local when = if mer ~= "" then t .. " " .. mer else t
        caption = if home and home.n then string.format("It's %s here in %s", when, tostring(home.n))
            else string.format("It's %s here", when)
        local s = scrubLabel(scrub)
        if s ~= "" then caption ..= "  " .. s end
    end
    local captionClick = function(c: Context, _e: Event)
        if c.state.focus ~= nil then
            c.state.focus = nil
            if homeLon then
                local from = c.state.spin or spinNow
                animate(c.state, from + shortestTurn(from, homeLon), nil, 21, from)
            end
        elseif not c.state.globe then
            open("elsewhen.here")
        end
    end
    local globeClick = function(c: Context, _e: Event)
        c.state.globe = not c.state.globe
        c.state.gsel = nil
        if c.state.globe then
            local target = focus or nil
            local lon = if target and target.lon then target.lon else homeLon
            local lat = if target and target.lat then target.lat else homeLat
            if lon then
                local from = c.state.spin or spinNow
                animate(c.state, from + shortestTurn(from, lon), math.clamp(lat or 0, -60, 60), 24, from)
            end
            if target then c.state.gsel = string.lower(target.name) end
        else
            c.state.viewLat = 0
        end
    end

    local hero = ui.column{ w = W, gap = 2, center = true,
        ui.row{ onClick = captionClick, help = if focus then "Back to here" else "Where are you?",
            ui.text{ text = caption, font = FONT, size = 10, color = if scrub ~= 0 then "accent" else DIM } },
        ui.row{ gap = 9, center = true,
            ui.text{ text = "World", font = FONT, size = 14, weight = "semibold", color = "foreground" },
            ui.stack{ w = 31, h = 31, onClick = globeClick, help = if st.globe then "Back to the list" else "Globe",
                miniGlobe(ctx, globe, spinNow, marker, st.globe == true) },
            ui.text{ text = "Clock", font = FONT, size = 14, weight = "semibold", color = "foreground" } } }

    local content = { w = W, gap = 14, center = false, hero }
    if st.globe then
        content[#content + 1] = globeMode(ctx, d, globe, list, sec, opts, spinNow)
    elseif not d then
        content[#content + 1] = look.text{ text = "Waiting for Hammerspoon (omarchy elsewhen port)…", size = 11,
            color = "secondaryForeground", maxWidth = W }
    else
        local rowsCol = { w = W, gap = 8, center = false }
        for _, row in list do
            rowsCol[#rowsCol + 1] = cityRow(ctx, d, row, #list, sec, opts, focus ~= nil and focus.key == row.key)
        end
        if #list == 0 then
            rowsCol[#rowsCol + 1] = look.text{ text = "Loading cities…", size = 11, color = "secondaryForeground" }
        end
        content[#content + 1] = ui.column(rowsCol)
        content[#content + 1] = ui.row{ w = W, h = 26, center = true, border = "foreground/0.35", borderWidth = 1,
            radius = look.radius(6), hover = look.hover, onClick = go("elsewhen.add"),
            help = "Search cities (drag to reorder in the search window)",
            ui.text{ text = "+  Add a city", font = FONT, size = 11, color = "foreground" } }
    end
    return look.panel(ctx, { w = W + 28, ui.column(content) })
end
