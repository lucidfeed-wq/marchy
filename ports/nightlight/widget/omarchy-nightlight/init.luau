-- omarchy-nightlight: Omarchy 4.5's NightLight bar indicator (from omarchy.indicators) for
-- the OmniShell bar, backed by macOS Night Shift.
--
-- Like Omarchy's BarIndicator: the nf-md-theme-light-dark glyph (U+F050E) at full strength
-- while Night Shift is on; while it is off the slot keeps its space but stays hidden until
-- the pointer is over it, then shows at 45 % (alwaysShow = true keeps it at 45 %).
-- Tooltip "Day Light" while on (a click goes back to daylight), "Night Light" while off.
-- Click toggles via hammerspoon://omarchy?a=nightlight.toggle; state comes from the
-- Hammerspoon port (var "omarchy_nightlight").
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local GLYPH = "\u{F050E}"
local BASE = "hammerspoon://omarchy?a="
local cache = { text = nil :: string?, value = nil :: any }

local function data(ctx: Context): any
    local text = ctx.select("vars", "omarchy_nightlight")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

local function go(action: string)
    return function(_c: Context, _e: Event)
        omniwm.open(BASE .. action)
    end
end

local function hover(c: Context, event: Event)
    if event.phase == "began" then
        c.state.hovered = true
    elseif event.phase == "ended" or event.phase == "cancelled" or event.phase == "cancel" then
        c.state.hovered = false
    end
end

function render(ctx: Context)
    if ctx.data.bar.style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local d = data(ctx) or {}
    local settings: { [string]: any } = ctx.data.settings or {}
    local active = d.enabled == true
    local revealed = settings.alwaysShow == true or ctx.state.hovered == true
    local opacity = if active then 1 elseif revealed then 0.45 else 0
    local help = if active then "Day Light" else "Night Light"
    if d.available == false then
        help = "Night Light (install nightlight, or click for Displays settings)"
    end
    return look.bar(ctx, {
        onClick = go("nightlight.toggle"),
        onRightClick = go("nightlight.settings"),
        onHover = hover,
        help = help,
        ui.text{ text = GLYPH, font = FONT, size = 15 * look.scale(ctx), color = "foreground",
            opacity = opacity, animate = "ease" },
    })
end
