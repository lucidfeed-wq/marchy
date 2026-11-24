-- omarchy-power: Omarchy 4.5's Power bar widget (battery, power profile) for the OmniShell bar.
--
-- Bar: Omarchy's Nerd Font battery glyph (10 levels, charging set while on AC, the full
-- glyph when charged), plus "NN%" when the percentage is switched on. Hidden on Macs
-- without a battery, like Omarchy. Left click opens the panel, right click toggles the
-- percentage (Hammerspoon action power.toggle-percentage, remembered there).
--
-- Panel: hero (glyph, BATTERY, rotating status phrase, big percentage), charge bar, stats
-- (battery size, charge cycles, time left / to full, charge rate), POWER PROFILE buttons.
-- Battery data: OmniWM (ctx.data.battery / charging / power). Battery size and the power
-- mode: Hammerspoon (ports/power.lua) via the JSON var "omarchy_power". Changing Low Power
-- Mode needs an administrator, so the profile buttons open Battery settings.
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local W = 380
local cache = { text = nil, value = nil }

local CHARGING = { "\u{F089C}", "\u{F0086}", "\u{F0087}", "\u{F0088}", "\u{F089D}",
    "\u{F0089}", "\u{F089E}", "\u{F008A}", "\u{F008B}", "\u{F0085}" }
local DEFAULT = { "\u{F007A}", "\u{F007B}", "\u{F007C}", "\u{F007D}", "\u{F007E}",
    "\u{F007F}", "\u{F0080}", "\u{F0081}", "\u{F0082}", "\u{F0079}" }
local FULL = "\u{F0085}"

local CHARGING_PHRASES = { "Pumping power", "Injecting electrons", "Pouring juice", "Amassing watts",
    "Hoarding joules", "Sucking volts", "Topping reserves", "Soaking amps", "Inhaling kilowatts" }
local BATTERY_PHRASES = { "Slurping power", "Spending joules", "Draining watts", "Burning electrons",
    "Sipping juice", "Spending coulombs", "Bleeding amps", "Guzzling volts", "Munching reserves" }

local PROFILE_ICON = { ["power-saver"] = "\u{F032A}", balanced = "\u{F029A}", performance = "\u{F04C5}" }
local PROFILE_LABEL = { ["power-saver"] = "Power-saver", balanced = "Balanced", performance = "Performance" }

local function data(ctx: Context)
    local text = ctx.select("vars", "omarchy_power")
    if text ~= cache.text then
        cache.text = text
        local value = nil
        if type(text) == "string" and text ~= "" then
            value = json.decode(text)
        end
        cache.value = if type(value) == "table" then value else nil
    end
    return cache.value
end

-- Model.js with macOS inputs: UPower's Discharging / Charging / FullyCharged / PendingCharge
-- become power source "battery" / charging / charged / on AC but not charging.
local function model(ctx: Context)
    local level = ctx.select("battery")
    if type(level) ~= "number" then
        return nil
    end
    local source = ctx.select("power", "source")
    local charging = ctx.select("charging") == true
    local charged = ctx.select("power", "charged") == true
    local onBattery = if source ~= nil then source == "battery" else not charging
    local fraction = math.clamp(level / 100, 0, 1)
    local watts = tonumber(ctx.select("power", "watts"))
    local toFull = tonumber(ctx.select("power", "full"))
    local stateName = if onBattery then "discharging" elseif charged then "full" elseif charging then "charging" else "pending"
    local threshold = false
    if not onBattery then
        if stateName == "pending" then
            threshold = true
        elseif stateName == "full" and fraction < 0.99 then
            threshold = true
        elseif stateName == "charging" and fraction < 0.99 then
            threshold = (watts ~= nil and math.abs(watts) <= 0.2) or (toFull ~= nil and toFull >= 8 * 60)
        end
    end
    local index = math.clamp(math.floor(fraction * 10), 0, 9) + 1
    local glyph = DEFAULT[index]
    if not threshold then
        if stateName == "full" then
            glyph = FULL
        elseif not onBattery then
            glyph = CHARGING[index]
        end
    end
    local mode = if threshold then "Threshold" elseif onBattery then "On battery"
        elseif level >= 100 then "Fully charged" else "Charging"
    local fullyCharged = stateName == "full" and not threshold
    local batteryFull = fullyCharged or (not onBattery and fraction >= 1)
    local idle = batteryFull or threshold
    return { level = level, fraction = fraction, glyph = glyph, mode = mode, threshold = threshold,
        onBattery = onBattery, fullyCharged = fullyCharged, batteryFull = batteryFull, idle = idle,
        flowing = not onBattery and not idle, watts = watts, toFull = toFull,
        remaining = tonumber(ctx.select("power", "remaining")), cycles = tonumber(ctx.select("power", "cycles")),
        lowPower = ctx.select("power", "lowPower") == true }
end

local function duration(minutes: number?): string?
    if minutes == nil or minutes <= 0 then return nil end
    local m = math.floor(minutes + 0.5)
    if m < 60 then return m .. "m" end
    if m % 60 == 0 then return (m // 60) .. "h" end
    return (m // 60) .. "h " .. (m % 60) .. "m"
end

local function rate(watts: number?): string
    local v = math.abs(watts or 0)
    local s = string.format("%.1f", v)
    s = string.gsub(s, "%.0$", "")
    return s .. "W"
end

local function txt(text: string, size: number, color: string?, weight: Weight?, maxWidth: number?)
    return ui.text{ text = text, font = FONT, size = size, color = color or "foreground", weight = weight,
        maxWidth = maxWidth, lines = 1 }
end

function render(ctx: Context)
    if ctx.data.bar.style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local m = model(ctx)
    if not m then
        return ui.box{ w = 0, h = 0 }
    end
    local d = data(ctx)
    local scale = look.scale(ctx)
    local props = {
        onClick = ui.popout,
        onRightClick = function(_c: Context, _e: Event)
            omniwm.open(BASE .. "power.toggle-percentage")
        end,
        help = "Battery " .. m.level .. "% · " .. m.mode,
        ui.text{ text = m.glyph, font = FONT, size = 13 * scale, color = "foreground" },
    }
    local style = ctx.data.bar.style
    local vertical = style ~= nil and style.vertical
    if d and d.pct == true and not vertical then
        props[#props + 1] = ui.text{ text = m.level .. "%", font = FONT, size = 11 * scale, color = "foreground" }
    end
    return look.bar(ctx, props)
end

local function pair(label: string, value: string, width: number)
    return ui.row{ w = width, gap = 8,
        ui.text{ text = label, font = FONT, size = 11, color = "foreground", opacity = 0.6, grow = 1, lines = 1 },
        txt(value, 11) }
end

local function profileButton(name: string, active: boolean, width: number)
    return ui.column{ key = "profile-" .. name, w = width, gap = 4, pad = 8, radius = look.radius(4),
        border = if active then "accent" else "foreground/0.25", borderWidth = 1,
        fill = if active then "foreground/0.10" else nil, hover = look.hover,
        help = "Change Low Power Mode in Battery Settings (needs an administrator)",
        onClick = "battery settings",
        txt(PROFILE_ICON[name] or "\u{F0084}", 14, if active then "accent" else "foreground"),
        txt(PROFILE_LABEL[name] or name, 11, "foreground", if active then "bold" else nil, width - 16) }
end

function popout(ctx: Context)
    local m = model(ctx)
    local rows = { w = W, gap = 14, center = false }
    if not m then
        rows[#rows + 1] = txt("No battery", 12, "secondaryForeground")
        return look.panel(ctx, { w = W + 28, ui.column(rows) })
    end
    local d = data(ctx) or {}

    -- Hero: glyph · BATTERY / status · percentage
    local phrases = if m.fullyCharged then nil elseif m.flowing then CHARGING_PHRASES
        elseif m.onBattery then BATTERY_PHRASES else nil
    local status = m.mode
    if m.fullyCharged then
        status = "Fully charged"
    elseif phrases then
        local seconds = tonumber(ctx.select("seconds")) or 0
        status = phrases[(math.floor(seconds / 2.8) % #phrases) + 1]
    end
    status = string.upper(status)
    rows[#rows + 1] = ui.row{ w = W, gap = 14,
        txt(m.glyph, 24),
        ui.column{ gap = 2, center = false, grow = 1,
            txt("Battery", 14, "foreground", "bold"),
            ui.text{ key = "status-" .. status, text = status, font = FONT, size = 10, weight = "bold",
                color = "secondaryForeground", lines = 1, maxWidth = W - 140,
                appear = { opacity = 0, animate = { duration = 0.2, curve = "easeOut" } } } },
        txt(m.level .. "%", 28, "foreground", "bold") }

    -- Charge bar (pulses while charging)
    local pulse = 1
    if m.flowing then
        local seconds = tonumber(ctx.select("seconds")) or 0
        pulse = if math.floor(seconds) % 2 == 0 then 1 else 0.55
    end
    rows[#rows + 1] = ui.stack{ w = W, h = 8, radius = 4, fill = "foreground/0.12",
        ui.box{ align = "leading", w = math.max(8, W * m.fraction), h = 8, radius = 4, fill = "foreground",
            opacity = pulse, animate = { duration = 0.95, curve = "easeInOut" } } }

    -- Stats
    local half = (W - 20) / 2
    local size = if type(d.size) == "number" then (math.floor(d.size) .. "Wh") else ""
    local timeLabel = if m.threshold then "Charge limit" elseif m.onBattery then "Time left" else "Time to full"
    local timeValue = "—"
    if m.threshold then
        timeValue = "-"
    elseif m.idle then
        timeValue = "-"
    else
        timeValue = duration(if m.onBattery then m.remaining else m.toFull) or "—"
    end
    local stateLabel = if m.threshold then "Battery state" elseif m.onBattery then "Discharging" else "Charging"
    local stateValue = if m.threshold then "Holding" elseif m.batteryFull then "-" elseif m.watts ~= nil then rate(m.watts) else "—"
    rows[#rows + 1] = ui.row{ w = W, gap = 20,
        ui.column{ w = half, gap = 4, center = false,
            pair("Battery size", size, half),
            pair("Charge cycles", if m.cycles ~= nil then tostring(math.floor(m.cycles)) else "—", half) },
        ui.column{ w = half, gap = 4, center = false,
            pair(timeLabel, timeValue, half),
            pair(stateLabel, stateValue, half) } }

    -- Power profile
    rows[#rows + 1] = ui.box{ w = W, h = 1, fill = "foreground/0.12" }
    local profiles = { "power-saver", "balanced" }
    if d.high == true then
        profiles[#profiles + 1] = "performance"
    end
    -- OmniWM's lowPower updates immediately; pmset (Hammerspoon) adds High Power Mode.
    local active = if m.lowPower then "power-saver" elseif d.mode == "high" then "performance"
        elseif d.mode == "low" and ctx.select("power", "lowPower") == nil then "power-saver" else "balanced"
    local cell = (W - 6 * (#profiles - 1)) / #profiles
    local buttons = { w = W, gap = 6 }
    for _, name in profiles do
        buttons[#buttons + 1] = profileButton(name, name == active, cell)
    end
    rows[#rows + 1] = ui.column{ w = W, gap = 10, center = false,
        txt("POWER PROFILE", 11, "secondaryForeground", "bold"),
        ui.row(buttons) }
    return look.panel(ctx, { w = W + 28, ui.column(rows) })
end
