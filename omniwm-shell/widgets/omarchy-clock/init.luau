-- omarchy-clock: Omarchy 4.5's centred clock for the OmniShell bar.
--
-- Default format matches Omarchy's "dddd HH:mm" (e.g. "Monday 14:30").
-- Right-click toggles Omarchy's alternate "d MMMM 'W'ww yyyy" form
-- (e.g. "23 November W48 2026"); left-click opens the bundled calendar popout.
--
-- The time comes from os.date (always 24-hour internally); ctx.data.clock is
-- read only to subscribe to the host's once-a-minute redraw. Weekday and
-- month names come from ctx.format.date, so they follow the macOS language.

local look = require("../lib/look")
local calendar = require("../lib/calendar")

local FORMATS = {
    ["weekday-24h"] = true, -- Monday 14:30   (Omarchy default)
    ["weekday-12h"] = true, -- Monday 2:30 PM
    ["24h"] = true,         -- 14:30
    ["12h"] = true,         -- 2:30 PM
    ["date-24h"] = true,    -- Mon 23 Nov 14:30
    ["iso"] = true,         -- 2026-11-23 14:30
}

local function setting(settings, key: string, fallback: any): any
    local value = settings[key]
    if value == nil or value == "" then
        return fallback
    end
    return value
end

-- Current Unix time. os.time is part of Luau's os library; fall back to the
-- host's seconds feed if a sandbox ever removes it.
local function now(ctx: Context): number
    if os.time then
        return os.time()
    end
    return ctx.data.seconds
end

-- Hour (0-23) and minute straight from os.date. The host clock string is not
-- parsed (its 12/24-hour form, separators and any seconds follow the macOS
-- locale); render() still reads ctx.data.clock so the widget redraws each
-- minute.
local function hourMinute(_ctx: Context, seconds: number): (number, string)
    local t = os.date("*t", seconds)
    return t.hour, string.format("%02d", t.min)
end

local function twelve(hour: number, minute: string): string
    local h = hour % 12
    if h == 0 then
        h = 12
    end
    return string.format("%d:%s %s", h, minute, if hour < 12 then "AM" else "PM")
end

local function name(ctx: Context, seconds: number, template: string, strftime: string): string
    return ctx.format.date(seconds, template) or os.date(strftime, seconds)
end

-- ISO-8601 week number.
local function isoWeek(seconds: number): number
    local t = os.date("*t", seconds)
    local weekday = (t.wday + 5) % 7 + 1 -- Monday = 1 ... Sunday = 7
    local week = (t.yday - weekday + 10) // 7
    local function weeksIn(year: number): number
        local function p(y: number): number
            return (y + y // 4 - y // 100 + y // 400) % 7
        end
        return if p(year) == 4 or p(year - 1) == 3 then 53 else 52
    end
    if week < 1 then
        return weeksIn(t.year - 1)
    elseif week > weeksIn(t.year) then
        return 1
    end
    return week
end

local function primary(ctx: Context, format: string, seconds: number): (string, string)
    local hour, minute = hourMinute(ctx, seconds)
    local h24 = string.format("%02d:%s", hour, minute)
    if format == "weekday-12h" then
        return name(ctx, seconds, "EEEE", "%A") .. " " .. twelve(hour, minute), "Wednesday 12:00 PM"
    elseif format == "24h" then
        return h24, "00:00"
    elseif format == "12h" then
        return twelve(hour, minute), "12:00 PM"
    elseif format == "date-24h" then
        local t = os.date("*t", seconds)
        return string.format("%s %d %s %s", name(ctx, seconds, "EEE", "%a"), t.day,
            name(ctx, seconds, "MMM", "%b"), h24), "Wed 30 Sep 00:00"
    elseif format == "iso" then
        return os.date("%Y-%m-%d", seconds) .. " " .. h24, "0000-00-00 00:00"
    end
    return name(ctx, seconds, "EEEE", "%A") .. " " .. h24, "Wednesday 00:00"
end

local function alternate(ctx: Context, seconds: number): string
    local t = os.date("*t", seconds)
    return string.format("%d %s W%02d %d", t.day, name(ctx, seconds, "MMMM", "%B"), isoWeek(seconds), t.year)
end

function render(ctx: Context)
    local style = ctx.data.bar.style
    if style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    -- Reading the clock feed subscribes this widget to its once-a-minute
    -- updates, in both the primary and the alternate format.
    local _tick = ctx.data.clock
    local settings: { [string]: any } = ctx.data.settings or {}
    local format = setting(settings, "format", "weekday-24h")
    if not FORMATS[format] then
        format = "weekday-24h"
    end
    local seconds = now(ctx)
    local label, reserve = primary(ctx, format, seconds)
    if ctx.state.alternate then
        label, reserve = alternate(ctx, seconds), "30 September W00 0000"
    end
    local scale = look.scale(ctx)
    local props = {
        gap = 0,
        pad = 6 * scale,
        onClick = ui.popout,
        onRightClick = function(c: Context, _event: Event)
            c.state.alternate = not c.state.alternate
        end,
        help = "Calendar (right-click: switch format)",
        ui.text{ key = "time", text = label, font = setting(settings, "font", "JetBrainsMono Nerd Font"),
            size = tonumber(settings.size) or 12, weight = setting(settings, "weight", "regular"),
            color = setting(settings, "color", "foreground"), reserve = reserve },
    }
    return look.bar(ctx, props)
end

function popout(ctx: Context)
    return calendar.popout(ctx)
end
