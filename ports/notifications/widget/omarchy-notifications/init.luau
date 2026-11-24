-- omarchy-notifications: Omarchy's Do Not Disturb indicator (bar/indicators/Dnd.qml), glyph 󰂛.
-- Click toggles Do Not Disturb for omarchy-mac's own notifications (and the macOS Focus, when
-- the two "Omarchy Focus On/Off" Shortcuts exist). Right click: a small panel with recent
-- notifications, dismiss all, Notification Center and Focus settings.
-- State comes from Hammerspoon (ports/notifications publishes "omarchy_notifications":
-- only the Do Not Disturb flag and counts, never notification text).
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local BELL_OFF = "\u{F009B}"
local BELL = "\u{F009A}"
local cache = { text = nil, value = nil }

local function go(action: string)
    return function(_c: Context, _e: Event)
        omniwm.open(BASE .. action)
    end
end

local function data(ctx: Context)
    local text = ctx.select("vars", "omarchy_notifications")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

function render(ctx: Context)
    local d = data(ctx)
    if not d then return ui.box{ w = 0, h = 0 } end
    local settings: { [string]: any } = ctx.data.settings or {}
    local on = d.dnd == true
    if not on and settings.alwaysShow == false then
        return ui.box{ w = 0, h = 0 }
    end
    return look.bar(ctx, {
        onClick = go("notifications.toggle-dnd"),
        onRightClick = ui.popout,
        help = if on then "Allow Notifications" else "Silence Notifications",
        ui.text{ text = BELL_OFF, font = FONT, size = 15 * look.scale(ctx),
            color = if on then "error" else "secondaryForeground" },
    })
end

local function row(width: number, glyph: string, label: string, onClick: Click, detail: string?)
    local r = { w = width, gap = 10, pad = 6, radius = look.radius(8), hover = look.hover, onClick = onClick,
        ui.text{ text = glyph, font = FONT, size = 15, color = "secondaryForeground" },
        look.text{ text = label, size = 13, maxWidth = width - 110, grow = 1 } }
    if detail then
        r[#r + 1] = look.text{ text = detail, size = 11, color = "secondaryForeground" }
    end
    return ui.row(r)
end

function popout(ctx: Context)
    local width = look.width
    local d = data(ctx) or {}
    local on = d.dnd == true
    local rows = { w = width, gap = 10, center = false }
    rows[#rows + 1] = ui.row{ w = width,
        look.text{ text = "Do Not Disturb", size = 14, weight = "semibold", grow = 1 },
        ui.row{ pad = 4, radius = look.radius(6), hover = look.hover, onClick = go("notifications.toggle-dnd"),
            look.text{ text = if on then "On" else "Off", size = 13,
                color = if on then "accent" else "secondaryForeground" } } }
    local shown = tonumber(d.shown) or 0
    local list = { w = width,
        row(width, BELL, "Show recent notifications", go("notifications.history"),
            if (tonumber(d.history) or 0) > 0 then tostring(d.history) else nil) }
    if shown > 0 then
        list[#list + 1] = row(width, "\u{F00D}", "Dismiss all", go("notifications.dismiss-all"), tostring(shown))
    end
    rows[#rows + 1] = look.group(list)
    rows[#rows + 1] = row(width, "\u{F0F3}", "Notification Center", go("notifications.center"))
    rows[#rows + 1] = row(width, "\u{F013}", "Focus Settings…", "focus settings")
    if d.focus ~= true then
        rows[#rows + 1] = look.text{ text = "macOS Focus is not synced: add the Shortcuts “Omarchy Focus On” and “Omarchy Focus Off”.",
            size = 11, color = "secondaryForeground", maxWidth = width, lines = 3 }
    end
    return look.panel(ctx, { w = width + 28, ui.column(rows) })
end
