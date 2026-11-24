-- omarchy-monitor: Omarchy-style Display item (Nerd Font 󰍹 one display, 󰍺 several).
-- Scroll on it: brightness ±5 % per notch (and the brightness OSD when the osd port is
-- installed). Click: the Display panel (mood name, brightness slider, scale presets, displays).
-- Built-in brightness comes from OmniWM (ctx.data.brightness, `brightness set <pct>`).
-- Displays, scale presets and external brightness come from Hammerspoon
-- (ports/monitor publishes the JSON var "omarchy_monitor"); clicks go to
-- hammerspoon://omarchy?a=monitor.<verb>&x=<index or number>.
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local ONE, MANY, CHECK = "󰍹", "󰍺", "󰄬"
local W = 340
local PRECISE_POINTS_PER_STEP = 12
local cache = { text = nil, value = nil }

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

local function data(ctx: Context)
    local text = ctx.select("vars", "omarchy_monitor")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

-- Model.js brightnessName()
local function moodName(percent: number): string
    local p = math.round(percent)
    if p >= 95 then return "Sun blast" end
    if p >= 80 then return "Solar flare" end
    if p >= 65 then return "Golden hour" end
    if p >= 45 then return "Even day" end
    if p >= 30 then return "Soft glow" end
    if p >= 20 then return "Lamp light" end
    if p >= 10 then return "Candlelit" end
    return "Night owl"
end

-- Which brightness the panel controls: the focused external display through BetterDisplay
-- when that is what Hammerspoon reports, else OmniWM's (the built-in / main display).
local function brightness(ctx: Context, d)
    if d and d.focusedBuiltin == false and type(d.ext) == "number" then
        return { value = d.ext, external = true }
    end
    local b = ctx.data.brightness
    if b and b.available then
        return { value = b.value, external = false }
    end
    return nil
end

local function setBrightness(b, percent: number, osd: boolean)
    local pct = math.clamp(math.round(percent), 1, 100)
    if b.external then
        open("monitor.brightness", tostring(pct))
    else
        omniwm.run(string.format("brightness set %d", pct))
    end
    if osd then
        open("monitor.osd", tostring(pct))
    end
end

local function displayCount(ctx: Context, d): number
    if d and type(d.displays) == "table" then
        local n = 0
        for _, x in d.displays do
            if x.e then n += 1 end
        end
        if n > 0 then return n end
    end
    local system = ctx.data.system
    if system and system.displays then return math.max(1, #system.displays) end
    return 1
end

local function onScroll(ctx: Context, event: Event)
    local b = brightness(ctx, data(ctx))
    if not b then return end
    local delta = if event.precise then event.dy / PRECISE_POINTS_PER_STEP else event.dy
    local total = ctx.state.scroll or 0
    if total * delta < 0 then total = 0 end
    total += delta
    local steps = if total >= 0 then math.floor(total) else math.ceil(total)
    ctx.state.scroll = total - steps
    if steps ~= 0 then
        local settings: { [string]: any } = ctx.data.settings or {}
        setBrightness(b, b.value + steps * 5, settings.osd ~= false)
    end
end

function render(ctx: Context)
    local d = data(ctx)
    local glyph = if displayCount(ctx, d) > 1 then MANY else ONE
    local b = brightness(ctx, d)
    return look.bar(ctx, {
        onClick = function(c: Context, _e: Event)
            ui.popout(c)
            open("monitor.refresh")
        end,
        onScroll = onScroll,
        help = if b then ("Display: " .. tostring(math.round(b.value)) .. "%") else "Display",
        ui.text{ text = glyph, font = FONT, size = 15 * look.scale(ctx), color = "foreground" },
    })
end

local function separator()
    return ui.box{ w = W, h = 1, fill = "foreground/0.12" }
end

local function header(label: string, detail: string?)
    local r = { w = W,
        look.text{ text = label, size = 10, weight = "bold", color = "secondaryForeground", grow = 1 } }
    if detail then
        r[#r + 1] = look.text{ text = detail, size = 10, weight = "bold", color = "secondaryForeground" }
    end
    return ui.row(r)
end

function popout(ctx: Context)
    local d = data(ctx) or {}
    local b = brightness(ctx, d)
    local count = displayCount(ctx, d)
    local rows = { w = W, gap = 14, center = false }

    -- Hero: display glyph · "Display" · mood name
    rows[#rows + 1] = ui.row{ w = W, gap = 14,
        ui.text{ text = if count > 1 then MANY else ONE, font = FONT, size = 30, color = "foreground" },
        ui.column{ gap = 2, center = false, grow = 1,
            look.text{ text = "Display", size = 14, weight = "bold" },
            look.text{ text = if b then string.upper(moodName(b.value)) else "FIXED BRIGHTNESS",
                size = 10, weight = "bold", color = "secondaryForeground" } } }

    -- Brightness
    if b then
        rows[#rows + 1] = separator()
        local current = b
        rows[#rows + 1] = ui.column{ w = W, gap = 6, center = false,
            header("BRIGHTNESS", tostring(math.round(b.value)) .. "%"),
            ui.slider{ value = math.clamp(b.value / 100, 0, 1), w = W, h = 16, color = "accent",
                onChange = function(_c: Context, e: Event)
                    if e.value then setBrightness(current, e.value * 100, false) end
                end } }
    end

    -- Scale (the focused display's presets)
    local scales = if type(d.scales) == "table" then d.scales else {}
    if #scales > 0 then
        rows[#rows + 1] = separator()
        local n = #scales
        local gap = 3
        local cell = math.floor((W - gap * (n - 1)) / n)
        local pills = { w = W, gap = gap }
        for i, s in scales do
            pills[#pills + 1] = ui.stack{ w = cell, h = 26, radius = look.radius(4),
                border = if s.a then "accent" else "foreground/0.3", borderWidth = 1,
                fill = if s.a then "accent/0.18" else nil, hover = look.hover,
                onClick = go("monitor.scale", tostring(i)),
                look.text{ text = s.l, size = 10, weight = "bold", color = if s.a then "accent" else "foreground" } }
        end
        local named = if count > 1 and type(d.focusedName) == "string" and d.focusedName ~= "" then d.focusedName else nil
        rows[#rows + 1] = ui.column{ w = W, gap = 10, center = false, header("SCALE", named), ui.row(pills) }
    end

    -- Displays (with more than one)
    local list = if type(d.displays) == "table" then d.displays else {}
    if #list > 1 then
        rows[#rows + 1] = separator()
        local col = { w = W, gap = 4, center = false, header("DISPLAYS") }
        for i, x in list do
            local label = if x.f then (x.n .. " · focused") else x.n
            col[#col + 1] = ui.row{ w = W, gap = 8, pad = 6, radius = look.radius(6),
                hover = if x.t then look.hover else nil,
                fill = if x.f then "accent/0.12" else nil,
                opacity = if x.t then 1 else 0.45,
                onClick = if x.t then go("monitor.display", tostring(i)) else nil,
                ui.text{ text = ONE, font = FONT, size = 14, color = "foreground" },
                look.text{ text = label, size = 12, maxWidth = W - 70, grow = 1 },
                ui.text{ text = if x.e then CHECK else " ", font = FONT, size = 13, color = "foreground" } }
        end
        if d.bd == false then
            col[#col + 1] = look.text{ text = "Turning displays off needs betterdisplaycli", size = 11,
                color = "secondaryForeground" }
        end
        rows[#rows + 1] = ui.column(col)
    end

    rows[#rows + 1] = ui.row{ w = W, gap = 10, pad = 6, radius = look.radius(6), hover = look.hover,
        onClick = "brightness settings",
        ui.text{ text = "\u{F013}", font = FONT, size = 14, color = "secondaryForeground" },
        look.text{ text = "Displays Settings…", size = 12 } }
    return look.panel(ctx, { w = W + 28, ui.column(rows) })
end
