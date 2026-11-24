-- omarchy-reminders: Omarchy 4.5's Reminder bar indicator (from omarchy.indicators) for the
-- OmniShell bar, fed by the Hammerspoon reminders port (var "omarchy_reminders": count and
-- next due time only, never the reminder text).
--
-- Like Omarchy's BarIndicator: the 󰢌 glyph (U+F088C, the one omarchy-reminder uses) at full
-- strength while reminders are queued; with none queued the slot keeps its space but stays
-- hidden until the pointer is over it, then shows at 45 % (alwaysShow keeps it at 45 %).
-- Tooltip "N reminders" / "Set Reminder". Click: show the queued reminders if there are any,
-- otherwise open the setup flow (hammerspoon://omarchy?a=reminders.indicator).
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local GLYPH = "\u{F088C}"
local BASE = "hammerspoon://omarchy?a="
local cache = { text = nil :: string?, value = nil :: any }

local function data(ctx: Context): any
    local text = ctx.select("vars", "omarchy_reminders")
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
    local count = tonumber(d.count) or 0
    local active = count > 0
    local revealed = settings.alwaysShow == true or ctx.state.hovered == true
    local opacity = if active then 1 elseif revealed then 0.45 else 0
    local help = if count == 1 then "1 reminder" elseif count > 1 then string.format("%d reminders", count)
        else "Set Reminder"
    return look.bar(ctx, {
        onClick = go("reminders.indicator"),
        onRightClick = go("reminders.open"),
        onHover = hover,
        help = help,
        ui.text{ text = GLYPH, font = FONT, size = 15 * look.scale(ctx), color = "foreground",
            opacity = opacity, animate = "ease" },
    })
end
