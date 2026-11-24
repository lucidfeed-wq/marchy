-- omarchy-bluetooth: Omarchy-style Bluetooth item (Nerd Font glyphs 󰂯 on, 󰂱 connected, 󰂲 off).
-- The popout is interactive: power toggle and paired devices from Hammerspoon
-- (omarchy/netpanel.lua publishes "omarchy_bt" via blueutil); clicking a device connects or
-- disconnects it via hammerspoon://omarchy?a=bt-device&x=<address>.
local look = require("../lib/look")
local bluetooth = require("../lib/bluetooth")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local cache = { text = nil, value = nil }

local function enc(s: string): string
    return (string.gsub(s, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function go(action: string, arg: string?)
    return function(_c: Context, _e: Event)
        omniwm.open(BASE .. action .. (if arg then "&x=" .. enc(arg) else ""))
    end
end

local function data(ctx: Context)
    local text = ctx.select("vars", "omarchy_bt")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

function render(ctx: Context)
    local state = bluetooth.state(ctx)
    local d = data(ctx)
    local power = if d and d.power ~= nil then d.power elseif state then state.power else false
    local connected = 0
    if d and d.devices then
        for _, dev in d.devices do if dev.c then connected += 1 end end
    elseif state then
        connected = state.connected
    end
    local glyph = if not power then "󰂲" elseif connected > 0 then "󰂱" else "󰂯"
    return look.bar(ctx, {
        onClick = ui.popout,
        help = if not power then "Bluetooth: Off" else ("Bluetooth: " .. connected .. " connected"),
        ui.text{ text = glyph, font = FONT, size = 15 * look.scale(ctx),
            color = if power then "foreground" else "secondaryForeground" },
    })
end

function popout(ctx: Context)
    local width = look.width
    local d = data(ctx) or {}
    local rows = { w = width, gap = 10, center = false }
    rows[#rows + 1] = ui.row{ w = width,
        look.text{ text = "Bluetooth", size = 14, weight = "semibold", grow = 1 },
        ui.row{ pad = 4, radius = look.radius(6), hover = look.hover, onClick = go("bt-power"),
            look.text{ text = if d.power then "On" else "Off", size = 13,
                color = if d.power then "accent" else "secondaryForeground" } } }
    if d.missing then
        rows[#rows + 1] = look.text{ text = "Install blueutil: brew install blueutil", size = 12,
            color = "secondaryForeground" }
    elseif d.power then
        local list = { w = width,
            look.text{ text = "Devices", size = 11, weight = "medium", color = "secondaryForeground" } }
        for _, dev in d.devices or {} do
            list[#list + 1] = ui.row{ w = width, gap = 10, pad = 6, radius = look.radius(8), hover = look.hover,
                onClick = go("bt-device", dev.a),
                ui.text{ text = if dev.c then "󰂱" else "󰂯", font = FONT, size = 15,
                    color = if dev.c then "accent" else "secondaryForeground" },
                look.text{ text = dev.n, size = 13, weight = if dev.c then "medium" else nil,
                    maxWidth = width - 120, grow = 1 },
                look.text{ text = if dev.c then "Connected" else "Connect", size = 11,
                    color = "secondaryForeground" } }
        end
        rows[#rows + 1] = look.group(list)
    end
    rows[#rows + 1] = ui.row{ w = width, gap = 10, pad = 6, radius = look.radius(8), hover = look.hover,
        onClick = "bluetooth settings",
        ui.text{ text = "", font = FONT, size = 15, color = "secondaryForeground" },
        look.text{ text = "Bluetooth Settings… (pair new devices)", size = 13 } }
    return look.panel(ctx, { w = width + 28, ui.column(rows) })
end
