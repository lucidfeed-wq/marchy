-- omarchy-media: Omarchy 4.5 now-playing bar item (omarchy.media) for OmniShell.
--
-- Bar: play/pause glyph (bright while playing, dimmed while paused) and "title  ·  artist",
-- hidden when nothing with a title or artist is playing. Left click plays/pauses, middle
-- click skips, right click opens the card, scrolling up/down goes to the previous/next track.
-- Card: 64 px artwork (or the music glyph), title, artist, album, and previous / play-pause /
-- next buttons.
--
-- Data comes from macOS's system now-playing info via OmniWM (ctx.data.media); the buttons
-- use OmniWM's `media ...` commands. No Apple Events permission is involved. Track text is
-- only rendered, never sent anywhere.
local look = require("../lib/look")

local FONT = "JetBrainsMono Nerd Font"
local W = 320
local LABEL_MAX = 180

-- Nerd Font code points from Omarchy's BarWidget.qml.
local G = {
    play = "\u{F040A}", pause = "\u{F03E4}", previous = "\u{F04AE}", next = "\u{F04AD}", music = "\u{F075A}",
}

local function now(ctx: Context)
    local m = ctx.data.media
    if not m then
        return nil
    end
    local title = m.title or ""
    local artist = m.artist or ""
    return { title = title, artist = artist, album = m.album or "", playing = m.playing == true,
        artwork = m.artwork, shown = title ~= "" or artist ~= "" }
end

local function playPause(_c: Context, e: Event)
    if e.button == "middle" then
        omniwm.run("media next")
    else
        omniwm.run("media toggle")
    end
end

-- One track per wheel notch; trackpad deltas accumulate first.
local function scroll(ctx: Context, e: Event)
    local delta = if e.precise then e.dy / 30 else e.dy
    local total = (ctx.state.scroll or 0) :: number
    if total * delta < 0 then total = 0 end
    total += delta
    local steps = if total >= 0 then math.floor(total) else math.ceil(total)
    ctx.state.scroll = total - steps
    if steps > 0 then
        omniwm.run("media previous")
    elseif steps < 0 then
        omniwm.run("media next")
    end
end

function render(ctx: Context)
    local m = now(ctx)
    if not m or not m.shown then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = look.scale(ctx)
    local props = {
        gap = 6 * scale,
        onClick = playPause,
        onRightClick = ui.popout,
        onScroll = scroll,
        help = m.title .. (if m.artist ~= "" then " \u{2014} " .. m.artist else ""),
        ui.text{ text = if m.playing then G.pause else G.play, font = FONT, size = 12 * scale,
            color = if m.playing then "foreground" else "secondaryForeground" },
    }
    local style = ctx.data.bar.style
    local vertical = style ~= nil and style.vertical
    if m.title ~= "" and not vertical then
        props[#props + 1] = look.text{ text = m.title .. (if m.artist ~= "" then "  \u{00B7}  " .. m.artist else ""),
            size = 12 * scale, maxWidth = LABEL_MAX * scale, color = "foreground" }
    end
    return look.bar(ctx, props)
end

local function button(glyph: string, command: string, size: number, label: string)
    return ui.stack{ pad = 6, radius = look.radius(6), hover = look.hover, help = label,
        border = "foreground/0.25", borderWidth = 1, onClick = command,
        ui.text{ text = glyph, font = FONT, size = size, color = "foreground" } }
end

function popout(ctx: Context)
    local m = now(ctx) or { title = "", artist = "", album = "", playing = false, artwork = nil, shown = false }
    local art
    if m.artwork then
        art = ui.stack{ w = 64, h = 64, radius = look.radius(6), fill = "foreground/0.06",
            border = "foreground/0.25", borderWidth = 1,
            ui.image{ image = m.artwork, w = 60, h = 60, radius = look.radius(5) } }
    else
        art = ui.stack{ w = 64, h = 64, radius = look.radius(6), fill = "foreground/0.06",
            border = "foreground/0.25", borderWidth = 1,
            ui.text{ text = G.music, font = FONT, size = 28, color = "foreground" } }
    end
    local info = { gap = 4, center = false, w = W - 74,
        look.text{ text = if m.title ~= "" then m.title else "Nothing playing", size = 13, weight = "bold",
            maxWidth = W - 74 } }
    if m.artist ~= "" then
        info[#info + 1] = look.text{ text = m.artist, size = 11, color = "secondaryForeground", maxWidth = W - 74 }
    end
    if m.album ~= "" then
        info[#info + 1] = look.text{ text = m.album, size = 10, color = "secondaryForeground", maxWidth = W - 74 }
    end
    return look.panel(ctx, { w = W + 28,
        ui.column{ w = W, gap = 10, center = false,
            ui.row{ w = W, gap = 10, art, ui.column(info) },
            ui.row{ w = W, gap = 6,
                ui.box{ grow = 1 },
                button(G.previous, "media previous", 14, "Previous"),
                button(if m.playing then G.pause else G.play, "media toggle", 18, if m.playing then "Pause" else "Play"),
                button(G.next, "media next", 14, "Next"),
                ui.box{ grow = 1 } } } })
end
