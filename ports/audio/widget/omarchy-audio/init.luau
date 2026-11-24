-- omarchy-audio: Omarchy 4.5 audio bar item and panel (omarchy.audio) for OmniShell.
--
-- Bar: the Omarchy volume glyph. Left click opens the panel, right click mutes/unmutes
-- everything (output and microphone), scrolling changes the output volume by 5 %.
-- Panel: hero (glyph, "Audio", volume mood, on/off switch), OUTPUT (percent, slider, devices),
-- INPUT (percent, slider, devices), SOURCES (per-app mixer).
--
-- Data: output volume/mute, outputs, microphone level/mute and the app mixer come from OmniWM
-- (ctx.data) and are changed with OmniWM's `volume ...` / `microphone ...` commands. Input
-- devices come from Hammerspoon (ports/audio.lua publishes the JSON var "omarchy_audio");
-- picking one opens hammerspoon://omarchy?a=audio.input&x=<uid>.
-- The app mixer is shown only when OmniWM already has System Audio Recording access; this
-- widget never asks for it.
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local BASE = "hammerspoon://omarchy?a="
local W = 340
local STEP = 5

-- Nerd Font code points from Omarchy's Panel.qml / Model.js.
local G = {
    muted = "\u{EEE8}", low = "\u{F026}", mid = "\u{F027}", high = "\u{F028}",
    headphones = "\u{F02CB}", speaker = "\u{F04C3}", bluetooth = "\u{F00AF}", display = "\u{F0379}",
    mic = "\u{F036C}", micMuted = "\u{F036D}",
    appOn = "\u{F057E}", appMuted = "\u{F075F}",
}

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
    local text = ctx.select("vars", "omarchy_audio")
    if text ~= cache.text then
        cache.text = text
        cache.value = if type(text) == "string" and text ~= "" then json.decode(text) else nil
    end
    return cache.value
end

---------------------------------------------------------------- Model.js
local function isHeadphones(name: string?): boolean
    local n = string.lower(name or "")
    for _, word in { "headphone", "headset", "earbud", "earphone", "airpod" } do
        if string.find(n, word, 1, true) then
            return true
        end
    end
    return false
end

local function stripCI(s: string, pattern: string): string
    local a, b = string.find(string.lower(s), pattern)
    if not a or not b then
        return s
    end
    return string.sub(s, 1, a - 1) .. string.sub(s, b + 1)
end

local function friendly(label: string?): string
    local s = string.match(label or "", "^%s*(.-)%s*$") or ""
    s = stripCI(s, "^sof%-soundwire%s+")
    s = stripCI(s, "^built%-?in audio%s+")
    s = stripCI(s, "%s+output$")
    s = stripCI(s, "%s+input$")
    s = string.gsub(s, "Microphones", "Microphone")
    if s == "" then
        return "Unknown"
    end
    return s
end

local function sinkGlyph(name: string?, transport: string?): string
    if isHeadphones(name) then
        return G.headphones
    end
    local blob = string.lower((name or "") .. " " .. (transport or ""))
    if string.find(blob, "bluetooth", 1, true) then
        return G.bluetooth
    end
    if string.find(blob, "hdmi", 1, true) or string.find(blob, "display", 1, true) then
        return G.display
    end
    return G.speaker
end

local function mood(volume: number?, muted: boolean): string
    if muted then return "Muted" end
    local p = math.round(volume or 0)
    if p == 0 then return "Silenced" end
    if p >= 100 then return "Concert hall" end
    if p >= 85 then return "Party mode" end
    if p >= 70 then return "Cranked up" end
    if p >= 50 then return "Steady groove" end
    if p >= 30 then return "Easy listening" end
    if p >= 15 then return "Murmur" end
    return "Whisper"
end

---------------------------------------------------------------- state
local function levels(ctx: Context)
    local vol = ctx.data.volume
    local outMuted = ctx.data.muted == true
    local mic = ctx.data.microphone
    local inVol = if mic then mic.volume else nil
    local inMuted = if mic and mic.muted ~= nil then mic.muted == true else nil
    local default: AudioOutput? = nil
    local outputs: { AudioOutput } = ctx.data.outputs or {}
    for _, o in outputs do
        if o.default then
            default = o
        end
    end
    local hasOutput = vol ~= nil
    local hasInput = inMuted ~= nil
    return {
        vol = vol, outMuted = outMuted, inVol = inVol, inMuted = inMuted == true,
        hasOutput = hasOutput, hasInput = hasInput, default = default,
        anyAudible = (hasOutput and not outMuted) or (hasInput and inMuted ~= true),
    }
end

local function outputIcon(st): string
    if not st.hasOutput then return G.muted end
    if st.default and isHeadphones(st.default.name) then return G.headphones end
    if st.outMuted then return G.muted end
    local v = (st.vol or 0) / 100
    if v >= 0.67 then return G.high end
    if v >= 0.34 then return G.mid end
    if v > 0 then return G.low end
    return G.muted
end

-- The hero switch mutes (or unmutes) both channels at once; it reads as on while anything
-- is still audible. OmniWM's commands toggle, so only the channels that differ are flipped.
local function toggleAll(ctx: Context, _e: Event)
    local st = levels(ctx)
    local mute = st.anyAudible
    if st.hasOutput and st.outMuted ~= mute then
        omniwm.run("volume mute")
    end
    if st.hasInput and st.inMuted ~= mute then
        omniwm.run("microphone mute")
    end
end

local function percent(value: number?): string
    if value == nil then return "\u{2013}" end
    return tostring(math.round(value)) .. "%"
end

local function setOutput(_c: Context, e: Event)
    if e.value then
        omniwm.run(string.format("volume set %d", math.round(math.clamp(e.value, 0, 1) * 100)))
    end
end

local function setInput(_c: Context, e: Event)
    if e.value then
        omniwm.run(string.format("microphone set %d", math.round(math.clamp(e.value, 0, 1) * 100)))
    end
end

local function scroll(ctx: Context, e: Event)
    if ctx.data.volume == nil then return end
    local delta = if e.precise then e.dy / 15 else e.dy
    local total = (ctx.state.scroll or 0) :: number
    if total * delta < 0 then total = 0 end
    total += delta
    local steps = if total >= 0 then math.floor(total) else math.ceil(total)
    ctx.state.scroll = total - steps
    if steps ~= 0 then
        omniwm.run(string.format("volume %s %d", if steps > 0 then "up" else "down", math.abs(steps) * STEP))
    end
end

---------------------------------------------------------------- bar
function render(ctx: Context)
    local st = levels(ctx)
    local help = if not st.hasOutput then "Audio" elseif st.outMuted then "Audio: muted"
        else "Audio: " .. percent(st.vol)
    return look.bar(ctx, {
        onClick = ui.popout,
        onRightClick = toggleAll,
        onScroll = scroll,
        help = help,
        ui.text{ text = outputIcon(st), font = FONT, size = 15 * look.scale(ctx), color = "foreground" },
    })
end

---------------------------------------------------------------- panel pieces
local function separator()
    return ui.box{ w = W, h = 1, fill = "foreground/0.12" }
end

local function header(label: string, value: string, dim: boolean)
    return ui.row{ w = W,
        look.text{ text = label, size = 10, weight = "bold", color = "secondaryForeground", grow = 1 },
        look.text{ text = value, size = 10, weight = "bold", color = "secondaryForeground",
            opacity = if dim then 0.5 else 1 },
        ui.box{ w = 6, h = 1 } }
end

local function switch(on: boolean)
    return ui.stack{ w = 34, h = 18, radius = 9, help = if on then "Mute" else "Unmute",
        fill = if on then "accent" else "foreground/0.2", onClick = toggleAll,
        ui.box{ w = 14, h = 14, radius = 7, fill = "background",
            align = if on then "trailing" else "leading", dx = if on then -2 else 2 } }
end

local function deviceRow(glyph: string, label: string, active: boolean, onClick)
    return ui.row{ w = W, gap = 8, pad = 6, radius = look.radius(6), hover = look.hover, onClick = onClick,
        fill = if active then "accent/0.14" else nil,
        ui.text{ text = glyph, font = FONT, size = 14, color = "foreground", w = 22 },
        look.text{ text = label, size = 12, weight = if active then "bold" else nil, maxWidth = W - 48, grow = 1 } }
end

local function appRow(app, active: boolean)
    local id = app.id
    local muted = app.muted == true
    local volume = math.clamp(app.volume or 0, 0, 100)
    return ui.column{ w = W, gap = 2, pad = 6, radius = look.radius(6), hover = look.hover, center = false,
        fill = if active then "accent/0.14" else nil,
        ui.row{ w = W - 12, gap = 8,
            ui.text{ text = if muted then G.appMuted else G.appOn, font = FONT, size = 14, color = "foreground", w = 22,
                opacity = if muted then 0.5 else 1, onClick = "volume app " .. id .. " mute",
                help = if muted then "Unmute" else "Mute" },
            look.text{ text = app.name or "Stream", size = 12, weight = if active then "bold" else nil,
                maxWidth = W - 110, grow = 1 },
            look.text{ text = percent(volume), size = 10, weight = "bold", color = "secondaryForeground", w = 36,
                opacity = if muted then 0.5 else 1 } },
        ui.slider{ value = volume / 100, w = W - 12, h = 14, color = "accent", opacity = if muted then 0.5 else 1,
            onChange = function(_c: Context, e: Event)
                if e.value then
                    omniwm.run(string.format("volume app %s set %d", id, math.round(math.clamp(e.value, 0, 1) * 100)))
                end
            end,
            onRightClick = "volume app " .. id .. " mute" } }
end

---------------------------------------------------------------- panel
function popout(ctx: Context)
    local st = levels(ctx)
    local d = data(ctx) or {}
    local rows = { w = W, gap = 14, center = false }

    -- Hero: speaker glyph, title and volume mood, on/off switch.
    rows[#rows + 1] = ui.row{ w = W, gap = 14,
        ui.text{ text = outputIcon(st), font = FONT, size = 24, color = "foreground",
            opacity = if st.outMuted then 0.5 else 1 },
        ui.column{ gap = 2, center = false, grow = 1,
            look.text{ text = "Audio", size = 14, weight = "bold" },
            look.text{ text = string.upper(mood(st.vol, st.outMuted)), size = 10, weight = "bold",
                color = "secondaryForeground" } },
        switch(st.anyAudible) }

    -- Output: percent, slider, devices.
    rows[#rows + 1] = separator()
    local out = { w = W, gap = 6, center = false, header("OUTPUT", percent(st.vol), st.outMuted) }
    if st.hasOutput then
        out[#out + 1] = ui.row{ w = W, pad = 6,
            ui.slider{ value = (st.vol or 0) / 100, w = W - 12, h = 16, color = "accent",
                opacity = if st.outMuted then 0.5 else 1, onChange = setOutput, onRightClick = "volume mute" } }
    end
    local outputs: { AudioOutput } = ctx.data.outputs or {}
    for _, o in outputs do
        out[#out + 1] = deviceRow(sinkGlyph(o.name, o.transport), friendly(o.name), o.default == true,
            "volume output " .. o.id)
    end
    rows[#rows + 1] = ui.column(out)

    -- Input: percent, slider, devices (device list from Hammerspoon).
    local inputs = d.inputs or {}
    if #inputs > 0 or st.inVol ~= nil or st.hasInput then
        rows[#rows + 1] = separator()
        local inp = { w = W, gap = 6, center = false,
            header("INPUT", percent(st.inVol), st.inMuted) }
        if st.inVol ~= nil then
            inp[#inp + 1] = ui.row{ w = W, pad = 6,
                ui.slider{ value = (st.inVol or 0) / 100, w = W - 12, h = 16, color = "accent",
                    opacity = if st.inMuted then 0.5 else 1, onChange = setInput,
                    onRightClick = if st.hasInput then "microphone mute" else nil } }
        elseif st.hasInput then
            inp[#inp + 1] = deviceRow(if st.inMuted then G.micMuted else G.mic,
                if st.inMuted then "Microphone muted" else "Microphone on", false, "microphone mute")
        end
        for _, dev in inputs do
            if type(dev.u) == "string" then
                inp[#inp + 1] = deviceRow(dev.g or G.mic, dev.n or "Unknown", dev.d == true, go("audio.input", dev.u))
            end
        end
        rows[#rows + 1] = ui.column(inp)
    end

    -- Sources: per-app mixer, only with access OmniWM already has.
    local apps = ctx.data.audioApps
    if apps and apps.access == "granted" then
        local media = ctx.data.media
        local playing = if media then media.bundle else nil
        local mixer = { w = W, gap = 10, center = false,
            look.text{ text = "SOURCES", size = 10, weight = "bold", color = "secondaryForeground" } }
        for _, app in apps.apps do
            if app.playing or app.muted or (app.volume or 100) < 100 then
                mixer[#mixer + 1] = appRow(app, playing ~= nil and app.id == playing)
            end
        end
        if #mixer > 1 then
            rows[#rows + 1] = separator()
            rows[#rows + 1] = ui.column(mixer)
        end
    end

    return look.panel(ctx, { w = W + 28, ui.column(rows) })
end
