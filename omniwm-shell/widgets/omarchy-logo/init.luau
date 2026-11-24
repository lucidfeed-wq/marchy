-- omarchy-logo: the Omarchy menu button for the OmniShell top bar.
--
-- Left click opens the Omarchy menu, right click opens a terminal (as in
-- Omarchy 4.5's omarchy.menu bar widget). Both go through Hammerspoon's URL
-- handler: hammerspoon://omarchy?a=<action>. omniwm.open() hands a non-file
-- URL to macOS (Launch Services); it does not run a shell and needs no
-- [[shellPermissions]] entry.
--
-- While macOS Secure Input is on, a red lock glyph is drawn beside the logo.
-- OmniWM's own keyboard modes (paused / prefix / window) still get their chip.

local look = require("../lib/look")
local keyboardMode = require("../lib/keyboard-mode")

-- Glyph U+E900 of Omarchy's omarchy.ttf (the icon its bar menu button uses),
-- extracted with fontTools and flipped into SVG coordinates (1024 x 1024).
local LOGO = "M70 954H549V1024H0V0H1024V1024H626V954H954V70H70Z"
    .. "M884 884H140V140H551V210H210V814H814V210H736V140H884Z"
    .. "M471 884H549V954H471Z"
    .. "M473 70H551V140H473Z"
    .. "M0 473H210V551H0Z"

local BASE = "hammerspoon://omarchy?a="

local function setting(settings, key: string, fallback: any): any
    local value = settings[key]
    if value == nil or value == "" then
        return fallback
    end
    return value
end

local function opener(action: string)
    return function(_ctx: Context, _event: Event)
        local _, err = omniwm.open(BASE .. action)
        if err then
            omniwm.log("omarchy-logo: could not open", action, err)
        end
    end
end

function render(ctx: Context)
    local style = ctx.data.bar.style
    if style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local settings: { [string]: any } = ctx.data.settings or {}
    local scale = look.scale(ctx)
    local size = tonumber(settings.size) or 12
    local color = setting(settings, "color", "accent")
    local locked = style.secureInput and settings.secureInputLock ~= false
    local item = math.max(16, style.height - 4)

    local props = {
        gap = 5 * scale,
        pad = 6 * scale,
        onClick = opener(setting(settings, "clickAction", "menu")),
        onRightClick = opener(setting(settings, "rightClickAction", "terminal")),
        help = if locked
            then "Omarchy menu (Secure Input is on; right-click: terminal)"
            else "Omarchy menu (right-click: terminal)",
        ui.path{ key = "logo", w = size, h = size, viewBox = { 0, 0, 1024, 1024 }, d = LOGO, fill = color },
    }
    if locked then
        props[#props + 1] = look.glyph{ key = "secure-input", name = "lock.fill", size = 11 * scale,
            weight = "semibold", color = setting(settings, "lockColor", "red"),
            help = "Secure Input is on (an app such as a password field or Citrix holds the keyboard)" }
    end
    local button = look.bar(ctx, props)
    return keyboardMode.wrap(style, button, item)
end
