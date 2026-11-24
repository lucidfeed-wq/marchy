-- omarchy-tailscale: Omarchy 4.5's Tailscale bar widget for the OmniShell bar.
--
-- Bar: the Tailscale mark drawn natively as a 3x3 dot grid (inactive dots faded), dimmed
-- and crossed out when Tailscale is off, with an "!" badge when this device needs login.
-- Left click opens the panel; right click turns Tailscale on/off (as in Omarchy).
--
-- Data: Hammerspoon (ports/tailscale.lua) polls the Tailscale CLI and publishes the JSON var
-- "omarchy_tailscale". Clicks go to hammerspoon://omarchy?a=tailscale.<verb>&x=<id>; only
-- ids that the backend published are sent (never typed text: the machine and region search
-- filters stay inside this widget).
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local W = 380
local cache = { text = nil, value = nil }

local PHRASES = {
    "Encrypting connections", "Sending secrets", "Guarding wires", "Braiding packets",
    "Polishing tunnels", "Hiding routes", "Sealing ports", "Sorting tailnets",
    "Shuffling keys", "Watching machines",
}

local G = {
    linux = "\u{F033D}", apple = "\u{F0035}", windows = "\u{F0372}", android = "\u{F0032}",
    mullvad = "\u{F0582}", other = "\u{F07C0}", account = "\u{EB01}", send = "\u{F048A}",
    copy = "\u{F018F}", exit = "\u{F11E2}", refresh = "\u{F0450}",
}

local function enc(s: string): string
    return (string.gsub(s, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function go(action: string, arg: string?)
    return function(_c: Context, _e: Event)
        omniwm.open(BASE .. action .. (if arg then "&x=" .. enc(arg) else ""))
    end
end

local function data(ctx: Context)
    local text = ctx.select("vars", "omarchy_tailscale")
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

local function osIcon(os: string?): string
    local v = string.lower(os or "")
    if v == "linux" then return G.linux end
    if v == "macos" or v == "ios" then return G.apple end
    if v == "windows" then return G.windows end
    if v == "android" then return G.android end
    if v == "mullvad" then return G.mullvad end
    return G.other
end

-- The Tailscale mark (TailscaleIcon.qml): 3x3 dots, the T silhouette at full opacity.
local OPACITY = { { 0.24, 0.24, 0.24 }, { 1, 1, 1 }, { 0.24, 1, 0.24 } }

local function mark(size: number, color: string, crossed: boolean, warning: boolean)
    local dot = math.max(2, size * 0.24)
    local gap = (size - dot * 3) / 2
    local grid = { w = size, h = size, gap = gap }
    for _, line in OPACITY do
        local row = { gap = gap }
        for _, o in line do
            row[#row + 1] = ui.box{ w = dot, h = dot, radius = dot / 2, fill = color, opacity = o }
        end
        grid[#grid + 1] = ui.row(row)
    end
    local layers = { w = size, h = size, ui.column(grid) }
    if crossed then
        local thick = math.max(2, size * 0.14)
        layers[#layers + 1] = ui.box{ w = size * 1.15, h = thick, radius = thick / 2, fill = color, rotate = -45 }
    end
    if warning then
        local b = math.max(7, size * 0.42)
        layers[#layers + 1] = ui.stack{ align = "bottomTrailing", w = b, h = b, radius = b / 2, fill = "error",
            border = "background", borderWidth = 1,
            ui.text{ text = "!", font = FONT, size = math.max(6, b * 0.72), weight = "bold", color = "background" } }
    end
    return ui.stack(layers)
end

local function txt(text: string, size: number, color: string?, weight: Weight?, maxWidth: number?)
    return ui.text{ text = text, font = FONT, size = size, color = color or "foreground", weight = weight,
        maxWidth = maxWidth, lines = 1 }
end

local function header(text: string)
    return ui.row{ w = W, txt(text, 11, "secondaryForeground", "bold") }
end

local function separator()
    return ui.box{ w = W, h = 1, fill = "foreground/0.12" }
end

local function toggleSwitch(on: boolean, busy: boolean, hint: string)
    local h = 16
    local knob = h - 4
    return ui.stack{ w = 30, h = h, radius = h / 2, fill = if on then "accent" else "foreground/0.18",
        opacity = if busy then 0.6 else 1, help = hint, hover = look.hover, onClick = go("tailscale.toggle"),
        ui.box{ align = if on then "trailing" else "leading", dx = if on then -2 else 2, w = knob, h = knob,
            radius = knob / 2, fill = if on then "accentForeground" else "foreground", animate = "spring" } }
end

local function iconButton(glyph: string, hint: string, onClick)
    return ui.stack{ w = 26, h = 26, radius = look.radius(6), hover = look.hover, help = hint, onClick = onClick,
        txt(glyph, 14) }
end

function render(ctx: Context)
    if ctx.data.bar.style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local d = data(ctx)
    local active = d ~= nil and d.active == true
    local login = d ~= nil and d.login == true
    local size = 13 * look.scale(ctx)
    local help = "Tailscale"
    if not d then
        help = "Tailscale: waiting for Hammerspoon"
    elseif d.installed == false then
        help = "Tailscale: not installed"
    elseif login then
        help = "Tailscale: needs login"
    elseif active then
        help = "Tailscale: connected"
    else
        help = "Tailscale: disconnected"
    end
    return look.bar(ctx, {
        onClick = ui.popout,
        onRightClick = go("tailscale.toggle"),
        help = help,
        mark(size, if active then "foreground" else "secondaryForeground", not active and not login, login),
    })
end

local function accountRows(d, rows)
    if type(d.accounts) ~= "table" or #d.accounts <= 1 then return end
    rows[#rows + 1] = separator()
    local list = { w = W, gap = 4, center = false, header("CONNECTIONS") }
    for _, a in d.accounts do
        local sel = a.sel == true
        list[#list + 1] = ui.row{ key = "acc-" .. tostring(a.id), w = W, gap = 8, pad = 6, radius = look.radius(4),
            fill = if sel then "foreground/0.08" else nil, hover = look.hover,
            onClick = if sel then nil else go("tailscale.switch", tostring(a.id)),
            ui.box{ w = 22, h = 18, txt(G.account, 12, if sel or a.busy then "foreground" else "secondaryForeground") },
            txt(tostring(a.label or "Account"), 12, "foreground", if sel then "bold" else nil, W - 60),
            if a.busy then txt("…", 12, "secondaryForeground") else nil }
    end
    rows[#rows + 1] = ui.column(list)
end

local function exitRow(e, key: string)
    local act = e.act == true
    local glyph = if e.mv then G.mullvad else G.exit
    return ui.row{ key = key, w = W, gap = 8, pad = 6, radius = look.radius(4),
        fill = if act or e.busy then "foreground/0.08" else nil, hover = look.hover,
        help = if act then "Disconnect" else "Connect",
        onClick = go("tailscale.exit-node", tostring(e.id)),
        ui.box{ w = 22, h = 18, txt(glyph, 12, if act or e.busy then "foreground" else "secondaryForeground") },
        txt(tostring(e.n or "Unknown"), 12, "foreground", if act then "bold" else nil, W - 60),
        if e.busy then txt("…", 12, "secondaryForeground") else nil }
end

local function exitRows(ctx: Context, d, rows)
    if not d.active then return end
    local exits = if type(d.exits) == "table" then d.exits else {}
    local regions = if type(d.regions) == "table" then d.regions else {}
    if #exits == 0 and #regions == 0 then return end
    rows[#rows + 1] = separator()
    local list = { w = W, gap = 4, center = false, header("EXIT NODES") }
    for i, e in exits do
        list[#list + 1] = exitRow(e, "exit-" .. i)
    end
    if #regions > 0 then
        local open = ctx.state.mvOpen == true
        list[#list + 1] = ui.row{ key = "mv-add", w = W, gap = 8, pad = 6, radius = look.radius(4),
            fill = if open then "foreground/0.08" else nil, hover = look.hover,
            onClick = function(c: Context, _e: Event) c.state.mvOpen = not (c.state.mvOpen == true) end,
            ui.box{ w = 22, h = 18, txt("+", 12) },
            txt("Choose Mullvad region", 12) }
        if open then
            local query = string.lower(tostring(ctx.state.mvQuery or ""))
            list[#list + 1] = ui.input{ key = "ts-mullvad-search", w = W, h = 26, placeholder = "Search regions",
                font = FONT, size = 12, text = ctx.state.mvQuery,
                onChange = function(c: Context, e: Event) c.state.mvQuery = e.text or "" end,
                onCancel = function(c: Context, _e: Event) c.state.mvOpen = false end }
            local shown = { w = W, gap = 2, center = false }
            for _, r in regions do
                local label = string.lower(tostring(r.city or "") .. " " .. tostring(r.country or ""))
                if query == "" or string.find(label, query, 1, true) then
                    local act = r.act == true
                    shown[#shown + 1] = ui.row{ key = "rg-" .. tostring(r.id), w = W, gap = 8, pad = 5,
                        radius = look.radius(4), fill = if act or r.busy then "foreground/0.08" else nil,
                        hover = look.hover, help = if act then "Disconnect" else "Connect",
                        onClick = function(c: Context, _e: Event)
                            c.state.mvOpen = false
                            omniwm.open(BASE .. "tailscale.exit-node&x=" .. enc(tostring(r.id)))
                        end,
                        ui.box{ w = 22, h = 18, txt(G.mullvad, 12, if act then "foreground" else "secondaryForeground") },
                        ui.column{ gap = 1, center = false, grow = 1,
                            txt(tostring(r.city or ""), 12, "foreground", if act then "bold" else nil, W - 60),
                            txt(tostring(r.country or ""), 10, "secondaryForeground", nil, W - 60) } }
                end
            end
            if #shown == 0 then
                list[#list + 1] = txt("No Mullvad regions found.", 11, "secondaryForeground")
            elseif #shown > 8 then
                shown.h = 240
                shown.scroll = true
                list[#list + 1] = ui.column(shown)
            else
                list[#list + 1] = ui.column(shown)
            end
        end
    end
    rows[#rows + 1] = ui.column(list)
end

local function peerRow(ctx: Context, p)
    local id = tostring(p.id)
    local parts = {}
    if p.ip and p.ip ~= "" then parts[#parts + 1] = p.ip end
    if p.dns and p.dns ~= "" then parts[#parts + 1] = p.dns end
    local row = { key = "peer-" .. id, w = W, gap = 8, pad = 6, radius = look.radius(4),
        ui.text{ text = osIcon(p.os), font = FONT, size = 14, color = "foreground" },
        ui.column{ gap = 1, center = false, grow = 1,
            txt(tostring(p.n or "Unknown"), 12, "foreground", nil, W - 110),
            txt(table.concat(parts, " · "), 10, "secondaryForeground", nil, W - 110) } }
    if p.send then
        row[#row + 1] = iconButton(G.send, "Send files", go("tailscale.send", id))
    end
    row[#row + 1] = iconButton(G.copy, "Copy", function(c: Context, _e: Event)
        c.state.copyFor = if c.state.copyFor == id then nil else id
    end)
    local out = { ui.row(row) }
    if ctx.state.copyFor == id then
        local menu = { key = "copy-" .. id, w = W - 40, gap = 0, center = false, radius = look.radius(4),
            border = "secondaryForeground", borderWidth = 1, fill = "background" }
        local options = {
            { kind = "name", label = p.n }, { kind = "dns", label = p.dns },
            { kind = "ip6", label = p.ip6 }, { kind = "ip", label = p.ip },
        }
        for _, o in options do
            if type(o.label) == "string" and o.label ~= "" then
                menu[#menu + 1] = ui.row{ key = "copy-" .. o.kind, w = W - 40, gap = 10, pad = 10, hover = look.hover,
                    onClick = function(c: Context, _e: Event)
                        c.state.copyFor = nil
                        omniwm.open(BASE .. "tailscale.copy&x=" .. enc(o.kind .. ":" .. id))
                    end,
                    ui.text{ text = o.label, font = FONT, size = 12, color = "foreground", grow = 1,
                        maxWidth = W - 90, lines = 1 },
                    ui.text{ text = G.copy, font = FONT, size = 14, color = "foreground" } }
            end
        end
        out[#out + 1] = ui.row{ w = W, ui.box{ w = 40, h = 1 }, ui.column(menu) }
    end
    return out
end

local function machineRows(ctx: Context, d, rows)
    if not (d.installed and d.active) then return end
    rows[#rows + 1] = separator()
    local peers = if type(d.peers) == "table" then d.peers else {}
    local total = tonumber(d.total) or #peers
    local query = string.lower(tostring(ctx.state.peerQuery or ""))
    local filtered = {}
    for _, p in peers do
        local hay = string.lower(tostring(p.n or "") .. " " .. tostring(p.dns or "") .. " " .. tostring(p.ip or ""))
        if query == "" or string.find(hay, query, 1, true) then
            filtered[#filtered + 1] = p
        end
    end
    local title = "MACHINES"
    if total > 0 then
        title = if query == "" then ("MACHINES · " .. total) else ("MACHINES · " .. #filtered .. " OF " .. total)
    end
    local list = { w = W, gap = 6, center = false, header(title) }
    if total > 8 then
        list[#list + 1] = ui.input{ key = "ts-peer-search", w = W, h = 26, placeholder = "Search machines",
            font = FONT, size = 12, text = ctx.state.peerQuery,
            onChange = function(c: Context, e: Event) c.state.peerQuery = e.text or "" end,
            onCancel = function(c: Context, _e: Event) c.state.peerQuery = "" end }
    end
    if #peers == 0 then
        list[#list + 1] = ui.row{ w = W, txt(if d.loaded then "No machines found on this tailnet." else "Loading machines…",
            12, "secondaryForeground") }
    elseif #filtered == 0 then
        list[#list + 1] = ui.row{ w = W, txt("No machines match.", 11, "secondaryForeground") }
    else
        local body = { w = W, gap = 6, center = false }
        for _, p in filtered do
            for _, el in peerRow(ctx, p) do
                body[#body + 1] = el
            end
        end
        if #filtered > 7 then
            body.h = 300
            body.scroll = true
        end
        list[#list + 1] = ui.column(body)
        if total > #peers then
            list[#list + 1] = txt("Showing the first " .. #peers .. " machines", 10, "secondaryForeground")
        end
    end
    rows[#rows + 1] = ui.column(list)
end

function popout(ctx: Context)
    local d = data(ctx)
    local rows = { w = W, gap = 12, center = false }
    if not d then
        rows[#rows + 1] = txt("Tailscale", 14, "foreground", "bold")
        rows[#rows + 1] = txt("Waiting for Hammerspoon (ports/tailscale)…", 12, "secondaryForeground", nil, W)
        return look.panel(ctx, { w = W + 28, ui.column(rows) })
    end
    local active = d.active == true
    local login = d.login == true
    local meta = "TAILSCALE IS DISCONNECTED"
    if active then
        local seconds = tonumber(ctx.select("seconds")) or 0
        meta = string.upper(PHRASES[(math.floor(seconds / 2.8) % #PHRASES) + 1])
    end
    local hint = if active then "Turn Tailscale off" elseif login then "Authorize this device" else "Turn Tailscale on"
    local hero = { w = W, gap = 14,
        ui.box{ opacity = if active then 1 else 0.5, mark(24, if active then "foreground" else "secondaryForeground",
            not active and not login, login) },
        ui.column{ gap = 2, center = false, grow = 1,
            txt(if d.installed then tostring(d.name ~= "" and d.name or "Tailscale") else "Tailscale", 14,
                "foreground", "bold", W - 100),
            ui.text{ key = "meta-" .. meta, text = meta, font = FONT, size = 10, weight = "bold",
                color = "secondaryForeground", maxWidth = W - 100, lines = 1,
                appear = { opacity = 0, animate = { duration = 0.2, curve = "easeOut" } } } } }
    if d.installed then
        hero[#hero + 1] = toggleSwitch(active, d.busy == true, hint)
    end
    rows[#rows + 1] = ui.row(hero)
    if type(d.msg) == "string" and d.msg ~= "" then
        rows[#rows + 1] = ui.text{ text = d.msg, font = FONT, size = 11, maxWidth = W, lines = 3,
            color = if d.err then "error" else "secondaryForeground" }
    end
    if d.installed == false then
        rows[#rows + 1] = ui.row{ w = W, pad = 12, radius = look.radius(4), fill = "foreground/0.06",
            txt("Tailscale is not installed (/Applications/Tailscale.app).", 12, "secondaryForeground", nil, W - 24) }
    end
    accountRows(d, rows)
    exitRows(ctx, d, rows)
    machineRows(ctx, d, rows)
    if d.installed then
        rows[#rows + 1] = ui.row{ w = W, gap = 8, pad = 4, radius = look.radius(4), hover = look.hover,
            onClick = go("tailscale.refresh"),
            ui.box{ w = 22, h = 18, txt(G.refresh, 12, "secondaryForeground") },
            txt("Refresh", 12, "secondaryForeground") }
    end
    return look.panel(ctx, { w = W + 28, ui.column(rows) })
end
