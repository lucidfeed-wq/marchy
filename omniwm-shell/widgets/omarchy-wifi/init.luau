-- omarchy-wifi: Omarchy-style Wi-Fi item. Icon/status from OmniWM (ctx.data.wifi); the popout
-- is interactive: networks from Hammerspoon (omarchy/netpanel.lua publishes the JSON var
-- "omarchy_wifi"), clicks go to hammerspoon://omarchy?a=wifi-join|wifi-power|wifi-scan.
local look = require("../lib/look")
local wifi = require("../lib/wifi")

local FONT = "JetBrainsMono Nerd Font"
local LEVELS = { [0] = "󰤯", "󰤟", "󰤢", "󰤥", "󰤨" }
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
    local text = ctx.select("vars", "omarchy_wifi")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

local function glyphFor(state): string
    if not state.power then return "󰤮" end
    if not state.connected then return "󰤯" end
    return LEVELS[math.clamp(state.level or 0, 0, 4)] or "󰤨"
end

local function bars(rssi: number?): number
    if not rssi then return 0 end
    if rssi >= -55 then return 4 elseif rssi >= -65 then return 3 elseif rssi >= -75 then return 2 end
    return 1
end

function render(ctx: Context)
    local state = wifi.state(ctx)
    if not state then return ui.box{ w = 0, h = 0 } end
    return look.bar(ctx, {
        onClick = ui.popout,
        help = state.help,
        ui.text{ text = glyphFor(state), font = FONT, size = 15 * look.scale(ctx),
            color = if state.power then "foreground" else "secondaryForeground" },
    })
end

local function row(width: number, glyph: string, label: string, detail: string?, onClick, accent: boolean?)
    local r = { w = width, gap = 10, pad = 6, radius = look.radius(8), hover = look.hover, onClick = onClick,
        ui.text{ text = glyph, font = FONT, size = 15, color = if accent then "accent" else "secondaryForeground" },
        look.text{ text = label, size = 13, weight = if accent then "medium" else nil, maxWidth = width - 110, grow = 1 } }
    if detail then
        r[#r + 1] = look.text{ text = detail, size = 11, color = "secondaryForeground" }
    end
    return ui.row(r)
end

function popout(ctx: Context)
    local width = look.width
    local state = wifi.state(ctx) or {}
    local d = data(ctx) or {}
    local power = if d.power ~= nil then d.power else state.power
    local rows = { w = width, gap = 10, center = false }
    rows[#rows + 1] = ui.row{ w = width,
        look.text{ text = "Wi-Fi", size = 14, weight = "semibold", grow = 1 },
        ui.row{ pad = 4, radius = look.radius(6), hover = look.hover, onClick = go("wifi-power"),
            look.text{ text = if power then "On" else "Off", size = 13,
                color = if power then "accent" else "secondaryForeground" } } }
    if power then
        local current = d.current or state.ssid
        if current then
            rows[#rows + 1] = look.group{ w = width, row(width, LEVELS[bars(state.rssi)] or "󰤨", current, "Connected", nil, true) }
        elseif d.location == false then
            rows[#rows + 1] = look.group{ w = width,
                row(width, "󰍔", "Allow Location for Hammerspoon to see network names", nil,
                    go("settings", "com.apple.settings.PrivacySecurity.extension")) }
        end
        local nets = { w = width,
            look.text{ text = "Networks", size = 11, weight = "medium", color = "secondaryForeground" } }
        for _, n in d.networks or {} do
            nets[#nets + 1] = row(width, LEVELS[bars(n.r)] or "󰤟", n.s,
                (if n.k then "Saved" elseif n.sec then "󰌾" else nil), go("wifi-join", n.s))
        end
        if #nets == 1 then
            nets[#nets + 1] = look.text{ text = "Scanning…", size = 12, color = "secondaryForeground" }
        end
        rows[#rows + 1] = look.group(nets)
    end
    rows[#rows + 1] = row(width, "󰑐", "Scan again", nil, go("wifi-scan"))
    rows[#rows + 1] = row(width, "", "Wi-Fi Settings…", nil, go("settings", "com.apple.wifi-settings-extension"))
    return look.panel(ctx, { w = width + 28, ui.column(rows) })
end
