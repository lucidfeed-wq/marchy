-- omarchy-agents: Omarchy's Agents bar panel (omarchy.agents) on OmniShell.
--
-- Bar: the 󱚣 glyph, in the urgent (error) colour when any subscription is at 90 % of a window.
-- Click opens the panel, right click starts an agent (the agent picker).
-- Panel (380 px, as Omarchy): hero ("Agents" + "SUBSCRIPTIONS", refresh and start-agent buttons),
-- then per subscription: mark, name, plan, an 󰋽 note when the numbers are not current, a
-- "Sign-in required" link, and one line per limit window: title, meter (model-scoped allowances
-- as ticks), time until it resets; the exact percentage and the numbers' age are in the tooltip.
-- With nothing signed in, the panel offers Claude Code, Codex and Grok to sign in to.
--
-- Data: Hammerspoon (ports/agents.lua) publishes the JSON var "omarchy_agents" with
-- `omniwmctl shell set`; clicks go to hammerspoon://omarchy?a=agents.<verb>.
-- Provider marks: path data from Omarchy's shell/plugins/agents/assets/*.svg (MIT, Omarchy).
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local GLYPH = "󱚣"
local WIDTH = 380
local TRACK = "foreground/0.16"
local cache = { text = nil :: string?, value = nil :: any }

type Mark = { d: string, viewBox: { number }, evenOdd: boolean, fill: string }
local MARKS: { [string]: Mark } = {
    claude = { d = "m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z", viewBox = { 0, 0, 256, 257 }, evenOdd = false, fill = "#D97757" },
    codex = { d = "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z", viewBox = { 0, 0, 24, 24 }, evenOdd = true, fill = "foreground" },
    grok = { d = "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815", viewBox = { 0, 0, 24, 24 }, evenOdd = false, fill = "foreground" },
}

local INTRO = "Sign in to an AI coding subscription, and this panel keeps track of how much of it you have left."

local function enc(s: string): string
    return (string.gsub(s, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function go(action: string, arg: string?)
    return function(_c: Context, _e: Event)
        omniwm.open(BASE .. action .. (if arg then "&x=" .. enc(arg) else ""))
    end
end

local function data(ctx: Context): any
    local text = ctx.select("vars", "omarchy_agents")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

-- Omarchy's formatDuration: "now", "2d 3h", "4h 12m", "7m".
local function duration(seconds: number): string
    if not (seconds > 0) then return "now" end
    local minutes = math.floor(seconds / 60)
    local hours = math.floor(minutes / 60)
    local days = math.floor(hours / 24)
    if days > 0 then return string.format("%dd %dh", days, hours % 24) end
    if hours > 0 then return string.format("%dh %dm", hours, minutes % 60) end
    return string.format("%dm", math.max(1, minutes))
end

-- A window whose reset time has passed starts over empty (Omarchy's limitWindow).
local function live(p: any, r: any, now: number): (number, number)
    local percent = if type(p) == "number" then math.clamp(p, 0, 1) else 0
    local reset = if type(r) == "number" then r else 0
    if reset > 0 and reset <= now then return 0, 0 end
    return percent, reset
end

local function alarming(d: any, now: number): boolean
    if type(d) ~= "table" or type(d.providers) ~= "table" then return false end
    for _, p in d.providers do
        for _, w in p.windows or {} do
            local percent = live(w.p, w.r, now)
            if percent >= 0.9 then return true end
        end
    end
    return false
end

local function displayTitle(title: string): string
    local model, window = string.match(title, "^(.+) (%a+)$")
    if model and (window == "Session" or window == "Weekly" or window == "Monthly") then
        return model .. " " .. window
    end
    return title
end

local function planLabel(plan: any): string
    if type(plan) ~= "string" or plan == "" then return "" end
    return string.upper(string.sub(plan, 1, 1)) .. string.sub(plan, 2)
end

local function mark(id: string, size: number)
    local m = MARKS[id]
    if not m then
        return ui.text{ text = GLYPH, font = FONT, size = size, color = "foreground" }
    end
    return ui.path{ w = size, h = size, viewBox = m.viewBox, d = m.d, evenOdd = m.evenOdd, fill = m.fill }
end

local function separator()
    return ui.box{ w = WIDTH, h = 1, fill = "foreground/0.12" }
end

local function heroButton(glyph: string, tip: string, onClick)
    return ui.stack{ w = 34, h = 34, radius = 0, fill = "accent/0.12", hover = "accent/0.3", help = tip,
        onClick = onClick,
        ui.text{ text = glyph, font = FONT, size = 16, color = "accent" } }
end

local function hero(meta: string)
    return ui.row{ w = WIDTH, gap = 14,
        ui.text{ text = GLYPH, font = FONT, size = 24, color = "foreground" },
        ui.column{ grow = 1, gap = 2, center = false,
            ui.text{ text = "Agents", font = FONT, size = 14, weight = "bold", color = "foreground" },
            ui.text{ text = string.upper(meta), font = FONT, size = 10, weight = "bold",
                color = "secondaryForeground", maxWidth = WIDTH - 140 } },
        ui.row{ gap = 6,
            heroButton("󰑐", "Refresh now", go("agents.refresh")),
            heroButton("󰞷", "Start the default agent", go("agents.launch")) } }
end

local function meter(width: number, percent: number, hot: boolean, scoped: { any }, now: number)
    local color = if hot then "error" else "foreground"
    local layers = { w = width, h = 10,
        ui.progress{ value = percent, w = width, h = 4, radius = 2, fill = TRACK, color = color } }
    for _, s in scoped do
        local p = live(s.p, s.r, now)
        local along = math.clamp(width * p - 1, 0, width - 2)
        layers[#layers + 1] = ui.box{ w = 2, h = 10, radius = 1, fill = color, align = "leading", dx = along }
    end
    return ui.stack(layers)
end

local function ageLine(stale: boolean, fetched: number, now: number): string?
    if not stale then return nil end
    if fetched > 0 and now - fetched > 60 then return "Last updated " .. duration(now - fetched) .. " ago" end
    if fetched > 0 then return "Last updated less than a minute ago" end
    return "Last updated time unavailable"
end

local function scopedText(model: string, percent: number, window: string): string
    local pct = tostring(math.round(percent * 100))
    if window == "Session" then return model .. ": " .. pct .. "% of its session allowance" end
    if window == "Weekly" then return model .. ": " .. pct .. "% of its weekly allowance" end
    if window == "Monthly" then return model .. ": " .. pct .. "% of its monthly allowance" end
    return model .. ": " .. pct .. "% of its " .. window .. " allowance"
end

local function limitRow(valueW: number, w: any, stale: boolean, fetched: number, now: number)
    local title = displayTitle(if type(w.t) == "string" then w.t else "Limit")
    local percent, reset = live(w.p, w.r, now)
    local hot = percent >= 0.9
    local titleW = math.floor(WIDTH * 0.3)
    local meterW = WIDTH - titleW - valueW - 20
    local resetText = if reset > 0 then duration(reset - now) else ""
    local used = tostring(math.round(percent * 100))
    local lines = { if reset > 0 then title .. ": " .. used .. "% used · resets in " .. resetText else title .. ": " .. used .. "% used" }
    local age = ageLine(stale, fetched, now)
    if age then lines[#lines + 1] = age end
    local scoped = if type(w.s) == "table" then w.s else {}
    for _, s in scoped do
        local p = live(s.p, s.r, now)
        lines[#lines + 1] = scopedText(if type(s.t) == "string" then s.t else "", p, title)
    end
    return ui.row{ w = WIDTH, gap = 0, help = table.concat(lines, "\n"),
        ui.row{ w = titleW, ui.text{ text = title, font = FONT, size = 11, color = "foreground", maxWidth = titleW } },
        meter(meterW, percent, hot, scoped, now),
        ui.box{ w = 20, h = 1 },
        ui.row{ w = valueW, ui.box{ grow = 1, h = 1 },
            ui.text{ text = resetText, font = FONT, size = 11, color = "secondaryForeground" } } }
end

local function section(ctx: Context, p: any, now: number)
    local id = if type(p.id) == "string" then p.id else ""
    local name = if type(p.name) == "string" then p.name else id
    local head = { w = WIDTH, gap = 10, mark(id, 16),
        ui.text{ text = name, font = FONT, size = 12, weight = "bold", color = "foreground" } }
    if type(p.note) == "string" and p.note ~= "" then
        head[#head + 1] = ui.text{ text = "󰋽", font = FONT, size = 10, color = "secondaryForeground", help = p.note }
    end
    head[#head + 1] = ui.box{ grow = 1, h = 1 }
    head[#head + 1] = ui.text{ text = planLabel(p.plan), font = FONT, size = 10, color = "secondaryForeground" }
    local col = { w = WIDTH, gap = 16, center = false, ui.row(head) }
    if p.signin == true then
        col[#col + 1] = ui.row{ pad = 2, hover = look.hover, onClick = go("agents.signin", id),
            help = if type(p.signinHelp) == "string" and p.signinHelp ~= "" then p.signinHelp else "Sign in to " .. name .. " again",
            ui.text{ text = "Sign-in required", font = FONT, size = 11, color = "error" } }
    end
    local windows = if type(p.windows) == "table" then p.windows else {}
    if #windows > 0 then
        local valueW = math.ceil((ctx.format.measure("00h 00m", { font = FONT, size = 11 })))
        local fetched = if type(p.fetched) == "number" then p.fetched else 0
        local rows = { w = WIDTH, gap = 12, center = false }
        for _, w in windows do
            rows[#rows + 1] = limitRow(valueW, w, p.stale == true, fetched, now)
        end
        col[#col + 1] = ui.column(rows)
    end
    return ui.column(col)
end

local function choices(d: any)
    local list = if type(d) == "table" and type(d.choices) == "table" then d.choices else {}
    local cellW = math.floor((WIDTH - 20) / 3)
    local row = { w = WIDTH, gap = 10 }
    for _, c in list do
        local id = if type(c.id) == "string" then c.id else ""
        local name = if type(c.name) == "string" then c.name else id
        local installed = c.installed == true
        row[#row + 1] = ui.column{ w = cellW, gap = 8, pad = 10, radius = 0, hover = if installed then look.hover else nil,
            opacity = if installed then 1 else 0.4,
            help = if installed then "Sign in to " .. name else name .. " is not installed",
            onClick = if installed then go("agents.signin", id) else nil,
            mark(id, 40),
            ui.text{ text = name, font = FONT, size = 12, color = "foreground" } }
    end
    return ui.row(row)
end

function render(ctx: Context)
    local d = data(ctx)
    local hot = alarming(d, ctx.data.seconds)
    return look.bar(ctx, {
        onClick = ui.popout,
        onRightClick = go("agents.launch"),
        help = "Agents",
        ui.text{ text = GLYPH, font = FONT, size = 15 * look.scale(ctx), color = if hot then "error" else "foreground" },
    })
end

function popout(ctx: Context)
    local d = data(ctx)
    local now = ctx.data.seconds
    local providers = if type(d) == "table" and type(d.providers) == "table" then d.providers else {}
    local blank = #providers == 0
    local col = { w = WIDTH, gap = 16, center = false, hero(if blank then "Add an account" else "Subscriptions") }
    if d == nil then
        col[#col + 1] = separator()
        col[#col + 1] = ui.text{ text = "Waiting for Hammerspoon: the agents port publishes this panel's numbers.",
            font = FONT, size = 10, color = "secondaryForeground", maxWidth = WIDTH, lines = 3 }
    elseif blank then
        col[#col + 1] = separator()
        col[#col + 1] = ui.text{ text = INTRO, font = FONT, size = 10, color = "secondaryForeground", maxWidth = WIDTH, lines = 3 }
        col[#col + 1] = choices(d)
    else
        for _, p in providers do
            col[#col + 1] = separator()
            col[#col + 1] = section(ctx, p, now)
        end
    end
    return look.panel(ctx, { w = WIDTH + 28, ui.column(col) })
end
