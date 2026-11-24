-- omarchy-tray: macOS menu-bar extras mirrored into the OmniShell bar (v2, scratch only; APIs checked against omniwm.d.luau 0.8.0).
--
-- Data:  Hammerspoon (omarchy/tray.lua) runs `omniwmctl shell set omarchy_tray <json>`;
--        the JSON arrives here as the string ctx.data.vars["omarchy_tray"].
-- Click: hammerspoon://omarchy?a=tray&x=<key>       -> AXPress on the real status item
--        hammerspoon://omarchy?a=tray-menu&x=<key>  -> AXShowMenu (right click) when offered
-- Icons: third-party items use the owning app's icon (ui.icon{ app = bundle }), Apple items an
--        SF Symbol chosen by AXIdentifier. The real status-item artwork is not available
--        without Screen Recording.

local look = require("../lib/look")

local BASE = "hammerspoon://omarchy?a="
local cache = { text = nil, items = {} }

local function encode(s: string): string
    return (string.gsub(s, "[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function opener(action: string, key: string)
    return function(_ctx: Context, _event: Event)
        local _, err = omniwm.open(BASE .. action .. "&x=" .. encode(key))
        if err then
            omniwm.log("omarchy-tray: could not open", action, key, err)
        end
    end
end

local function items(ctx: Context)
    local text = ctx.select("vars", "omarchy_tray")
    if text ~= cache.text then
        cache.text = text
        cache.items = {}
        if type(text) == "string" and text ~= "" then
            local value = json.decode(text)
            if type(value) == "table" and type(value.items) == "table" then
                cache.items = value.items
            end
        end
    end
    return cache.items
end

local function hidden(settings, item): boolean
    local raw = settings.hide
    if type(raw) ~= "string" or raw == "" then return false end
    for entry in string.gmatch(raw, "[^,%s]+") do
        if entry == item.b or entry == item.k or (item.id and entry == item.id) then return true end
    end
    return false
end

local function glyph(item, size: number, color)
    if item.s then
        return ui.symbol{ name = item.s, size = size * 0.8, color = color }
    end
    if item.b == "com.apple.systemuiserver" or item.b == "com.apple.MenuBarAgent" then
        return ui.symbol{ name = "circle.grid.2x2", size = size * 0.8, color = color }
    end
    return ui.icon{ app = item.i or item.b, w = size, h = size, placeholder = "app.dashed" }
end

local function cell(ctx: Context, item, size: number, settings)
    local label = item.d or item.t or item.n
    local props = {
        key = item.k,
        gap = 3,
        pad = 3,
        radius = look.radius(5),
        hover = look.hover,
        help = label,
        onClick = opener("tray", item.k),
        onRightClick = opener(if item.menu then "tray-menu" else "tray", item.k),
        glyph(item, size, settings.color or "foreground"),
    }
    if item.v and settings.showValues ~= false then
        props[#props + 1] = look.text{ text = item.v, size = 11, color = "secondaryForeground" }
    end
    return ui.row(props)
end

function render(ctx: Context)
    local style = ctx.data.bar.style
    if style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local settings: { [string]: any } = ctx.data.settings or {}
    local list = items(ctx)
    if #list == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    local size = math.max(12, math.min(18, style.height - 10))
    local limit = tonumber(settings.maxInline) or 12
    local row = { gap = 1 }
    local shown = 0
    for _, item in list do
        if not hidden(settings, item) then
            shown += 1
            if shown <= limit then
                row[#row + 1] = cell(ctx, item, size, settings)
            end
        end
    end
    if shown > limit then
        row[#row + 1] = ui.row{ key = "more", pad = 3, radius = look.radius(5), hover = look.hover,
            help = "More menu-bar items", onClick = ui.popout,
            ui.symbol{ name = "chevron.down", size = 10, color = "secondaryForeground" } }
    end
    return ui.row(row)
end

function popout(ctx: Context)
    local settings: { [string]: any } = ctx.data.settings or {}
    local limit = tonumber(settings.maxInline) or 12
    local rows = { pad = 6, gap = 2 }
    local shown = 0
    for _, item in items(ctx) do
        if not hidden(settings, item) then
            shown += 1
            if shown > limit then
                rows[#rows + 1] = ui.row{ key = item.k, gap = 8, pad = 4, radius = look.radius(6),
                    hover = look.hover, onClick = opener("tray", item.k),
                    onRightClick = opener(if item.menu then "tray-menu" else "tray", item.k),
                    glyph(item, 16, "foreground"),
                    look.text{ text = item.d or item.n, size = 13, maxWidth = 220 } }
            end
        end
    end
    return look.panel(ctx, rows)
end
