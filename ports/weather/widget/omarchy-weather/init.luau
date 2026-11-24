-- omarchy-weather: Omarchy 4.5's weather pill for the OmniShell bar.
--
-- Bar: the condition glyph only (Omarchy's Nerd Font weather icons, day/night aware), as in
-- Omarchy's BarWidget. Left click opens the detail popout; right click shows Omarchy's
-- weather status line as a toast (Hammerspoon action weather.status, which receives only
-- numbers and a unit letter, never text).
--
-- Data: OmniWM's own weather feed (ctx.data.weather, Open-Meteo, for the [weather] city or
-- coordinates in shell.toml). Popout: hero (big glyph, big temperature + unit, location,
-- FEELS / WIND / HUMID), then a divider and the next three days (glyph, weekday, high/low).
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local W = 480
local MARKER = "\u{F041}"

-- Model.js iconForCode (wttr.in codes -> Nerd Font glyphs).
local function iconForCode(code: number, night: boolean): string
    if code == 113 then return if night then "\u{E32B}" else "\u{E30D}" end
    if code == 116 then return if night then "\u{E32E}" else "\u{E302}" end
    if code == 119 or code == 122 then return "\u{E33D}" end
    if code == 143 or code == 248 or code == 260 then return if night then "\u{E346}" else "\u{E313}" end
    if code == 176 or code == 263 or code == 353 then return if night then "\u{E333}" else "\u{E308}" end
    if code == 179 or code == 227 or code == 230 or code == 323 or code == 326 or code == 368 then
        return if night then "\u{E327}" else "\u{E30A}"
    end
    if code == 182 or code == 185 or code == 281 or code == 284 or code == 311 or code == 314
        or code == 317 or code == 320 or code == 350 or code == 362 or code == 365 or code == 374 or code == 377 then
        return "\u{E3AD}"
    end
    if code == 200 or code == 386 or code == 389 or code == 392 or code == 395 then return "\u{E31D}" end
    if code == 266 or code == 293 or code == 296 or code == 299 or code == 302 or code == 305 or code == 308
        or code == 356 or code == 359 then
        return "\u{E318}"
    end
    if code == 329 or code == 332 or code == 335 or code == 338 or code == 371 then return "\u{E31A}" end
    return "\u{E33D}"
end

-- Model.js iconForOpenMeteoCode (WMO weather_code -> wttr code -> glyph).
local function iconForWmo(code: number?, night: boolean): string
    local c = math.floor(tonumber(code) or 0)
    local wttr = 119
    if c == 0 then wttr = 113
    elseif c == 1 or c == 2 then wttr = 116
    elseif c == 3 then wttr = 119
    elseif c == 45 or c == 48 then wttr = 143
    elseif c == 51 or c == 53 or c == 55 or c == 56 or c == 57 or c == 61 then wttr = 266
    elseif c == 63 or c == 65 or c == 66 or c == 67 or c == 80 or c == 81 or c == 82 then wttr = 308
    elseif c == 71 or c == 73 or c == 75 or c == 77 or c == 85 or c == 86 then wttr = 338
    elseif c == 95 or c == 96 or c == 99 then wttr = 389
    end
    return iconForCode(wttr, night)
end

local function enc(s: string): string
    return (string.gsub(s, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Unit handling: OmniWM fetches in its [weather] units; the widget's `unit` option can
-- show the other system (converted here, like Model.js celsiusToFahrenheit).
local function units(ctx: Context): (boolean, boolean)
    local source = ctx.select("weather", "unit")
    local sourceImperial = source == "°F"
    local settings: { [string]: any } = ctx.data.settings or {}
    local wanted = settings.unit
    if wanted == "imperial" then return sourceImperial, true end
    if wanted == "metric" then return sourceImperial, false end
    return sourceImperial, sourceImperial
end

local function temp(value: number?, fromF: boolean, toF: boolean): number?
    if value == nil then return nil end
    if fromF == toF then return value end
    if toF then return value * 9 / 5 + 32 end
    return (value - 32) * 5 / 9
end

local function speed(value: number?, fromMph: boolean, toMph: boolean): number?
    if value == nil then return nil end
    if fromMph == toMph then return value end
    if toMph then return value * 0.621371 end
    return value * 1.609344
end

local function round(value: number?): string
    if value == nil then return "" end
    return tostring(math.round(value))
end

local function txt(text: string, size: number, color: string?, weight: Weight?)
    return ui.text{ text = text, font = FONT, size = size, color = color or "foreground", weight = weight, lines = 1 }
end

local function access(ctx: Context): string?
    local a = ctx.select("weather", "access")
    if a == "off" then return "Weather is turned off in OmniWM Settings > Network & Permissions" end
    if a == "blocked" then return "Weather is blocked by your organization" end
    return nil
end

local function statusArg(ctx: Context): string
    local t = ctx.select("weather", "temp")
    if type(t) ~= "number" then return "none" end
    local fromF, toF = units(ctx)
    local w = speed(ctx.select("weather", "wind"), fromF, toF) or 0
    return string.format("%d,%d,%s", math.round(temp(t, fromF, toF) or 0), math.max(0, math.round(w)),
        if toF then "f" else "c")
end

function render(ctx: Context)
    if ctx.data.bar.style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local code = ctx.select("weather", "code")
    local size = 13 * look.scale(ctx)
    local ready = type(code) == "number" and ctx.select("weather", "access") == "ok"
    local glyph = if ready then iconForWmo(code, ctx.select("weather", "day") == false) else "\u{E33D}"
    return look.bar(ctx, {
        onClick = ui.popout,
        onRightClick = function(c: Context, _e: Event)
            omniwm.open(BASE .. "weather.status&x=" .. enc(statusArg(c)))
        end,
        ui.text{ text = glyph, font = FONT, size = size, color = if ready then "foreground" else "secondaryForeground" },
    })
end

local function stat(label: string, value: string)
    return ui.column{ gap = 5, center = false,
        txt(label, 11, "secondaryForeground"),
        txt(value, 14) }
end

function popout(ctx: Context)
    local rows = { w = W, gap = 14, center = false }
    local message = access(ctx)
    local data = ctx.data.weather
    if message then
        rows[#rows + 1] = txt(message, 12, "secondaryForeground")
        return look.panel(ctx, { w = W + 28, ui.column(rows) })
    end
    if not data or data.access ~= "ok" then
        rows[#rows + 1] = ui.text{ text = "Fetching forecast…", font = FONT, size = 11, color = "secondaryForeground" }
        rows[#rows + 1] = ui.text{ text = "No forecast yet. OmniWM reports weather for the [weather] city (or latitude/longitude) in ~/.config/omniwm/shell/shell.toml.",
            font = FONT, size = 11, color = "secondaryForeground", maxWidth = W, lines = 3 }
        return look.panel(ctx, { w = W + 28, ui.column(rows) })
    end
    local fromF, toF = units(ctx)
    local unit = if toF then "°F" else "°C"
    local night = data.day == false
    local feels = temp(data.feels, fromF, toF)
    local wind = speed(data.wind, fromF, toF)

    local right = { gap = 12, center = false }
    if type(data.place) == "string" and data.place ~= "" then
        right[#right + 1] = ui.row{ gap = 6, help = "Location: [weather] in shell.toml",
            txt(MARKER, 12, "secondaryForeground"),
            txt(string.upper(data.place), 12, "secondaryForeground") }
    end
    right[#right + 1] = ui.row{ gap = 36,
        stat("FEELS", if feels ~= nil then round(feels) .. unit else ""),
        stat("WIND", if wind ~= nil then round(wind) .. (if toF then " mph" else " km/h") else ""),
        stat("HUMID", if data.humidity ~= nil then round(data.humidity) .. "%" else "") }

    rows[#rows + 1] = ui.row{ w = W, gap = 16,
        ui.box{ w = 0, h = 1 },
        ui.text{ text = iconForWmo(data.code, night), font = FONT, size = 64, color = "foreground", dy = 5 },
        ui.row{ gap = 2,
            ui.text{ text = round(temp(data.temp, fromF, toF)), font = FONT, size = 56, weight = "bold", color = "foreground" },
            ui.text{ text = unit, font = FONT, size = 24, color = "foreground", dy = -10 } },
        ui.box{ grow = 1, h = 1 },
        ui.column(right),
        ui.box{ w = 4, h = 1 } }

    local days = {}
    for index, day in data.days do
        -- days[1] is today; Omarchy shows the next three days.
        if index > 1 and #days < 3 then
            days[#days + 1] = day
        end
    end
    if #days > 0 then
        rows[#rows + 1] = ui.box{ w = W, h = 1, fill = "foreground/0.12" }
        local strip = { gap = 44 }
        for _, day in days do
            local name = ctx.format.date(day.time, "EEEE") or day.label
            strip[#strip + 1] = ui.row{ gap = 10,
                ui.text{ text = iconForWmo(day.code, false), font = FONT, size = 24, color = "foreground" },
                ui.column{ gap = 2, center = false,
                    txt(string.upper(name), 10, "secondaryForeground"),
                    ui.row{ gap = 6,
                        txt(round(temp(day.high, fromF, toF)) .. "°", 12),
                        txt(round(temp(day.low, fromF, toF)) .. "°", 12, "secondaryForeground") } } }
        end
        rows[#rows + 1] = ui.row{ w = W, ui.box{ grow = 1, h = 1 }, ui.row(strip), ui.box{ grow = 1, h = 1 } }
    end
    return look.panel(ctx, { w = W + 28, ui.column(rows) })
end
