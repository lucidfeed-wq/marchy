-- omarchy-workspaces: Omarchy-style workspace numbers for the OmniShell bar.
--
-- Plain labels (the workspace displayName, so emoji names such as the user's
-- 6 and 7 show as-is), the focused workspace in the accent colour, empty
-- workspaces at half opacity. Like Omarchy, the first `alwaysShow` workspaces
-- of this display are always listed; later ones appear only while occupied or
-- focused. Click switches, right-click opens OmniWM's workspace menu, windows
-- can be dropped on a label, and scrolling over the widget steps through the
-- listed workspaces, clamped at the ends.
--
-- Written from scratch against omniwm.d.luau (OmniWM 0.8.0); it borrows only
-- the click/target/menu/drop conventions of the bundled `workspaces` widget.

spanIslands = true

local look = require("../lib/look")

-- Nerd Font "nf-md-square_rounded" glyph that Omarchy shows for an active
-- workspace (only used with activeStyle = "glyph").
local ACTIVE_GLYPH = "\u{F14FB}"

type Metrics = {
    font: string,
    size: number,
    across: number,
    minWidth: number,
    padX: number,
    radius: number,
    emptyOpacity: number,
    activeColor: string,
    textColor: string,
    activeWeight: Weight,
    glyph: boolean,
    vertical: boolean,
}

local function text(settings, key: string, fallback: string): string
    local value = settings[key]
    if type(value) ~= "string" or value == "" then
        return fallback
    end
    return value
end

local function number(settings, key: string, fallback: number): number
    local value = tonumber(settings[key])
    if value == nil then
        return fallback
    end
    return value
end

local function metrics(ctx: Context, style: BarStyle, settings): Metrics
    return {
        font = text(settings, "font", "JetBrainsMono Nerd Font"),
        size = number(settings, "size", 12),
        across = math.max(16, style.height - 4),
        minWidth = number(settings, "minWidth", 20),
        padX = 6,
        radius = 4,
        emptyOpacity = math.clamp(number(settings, "emptyOpacity", 0.5), 0, 1),
        activeColor = text(settings, "activeColor", "accent"),
        textColor = text(settings, "textColor", "foreground"),
        activeWeight = if settings.activeBold == false then "regular" else "bold",
        glyph = settings.activeStyle == "glyph",
        vertical = style.vertical,
    }
end

-- Window totals by workspace id from ctx.data.workspaces. The bar's own
-- per-workspace list leaves out floating windows unless showFloatingWindows is
-- on, so a workspace holding only floating windows would otherwise look empty.
local function totals(ctx: Context): { [string]: number }
    local map = {}
    for _, workspace in ipairs(ctx.data.workspaces or {}) do
        map[workspace.id] = workspace.windows
    end
    return map
end

local function occupied(workspace: BarWorkspace, counts: { [string]: number }): boolean
    return #workspace.windows > 0 or (counts[workspace.id] or 0) > 0
end

-- The workspaces this bar instance lists, in OmniWM's order.
local function listed(ctx: Context): { BarWorkspace }
    local bar = ctx.data.bar
    local settings: { [string]: any } = ctx.data.settings or {}
    local always = number(settings, "alwaysShow", 5)
    local showAll = settings.showAll == true
    local counts = totals(ctx)
    local result = {}
    local index = 0
    for _, workspace in ipairs(bar.workspaces) do
        if bar.island == "all" or workspace.focused == (bar.island == "active") then
            index += 1
            if showAll or index <= always or workspace.focused or occupied(workspace, counts) then
                result[#result + 1] = workspace
            end
        end
    end
    return result
end

local function cell(ctx: Context, workspace: BarWorkspace, m: Metrics, isOccupied: boolean)
    local focused = workspace.focused
    local label = if focused and m.glyph then ACTIVE_GLYPH else workspace.name
    local weight: Weight = if focused then m.activeWeight else "regular"
    local width = ctx.format.measure(label, { font = m.font, size = m.size, weight = weight })
    local extent = math.max(m.minWidth, math.ceil(width) + 2 * m.padX)
    return ui.stack{
        key = workspace.id,
        w = if m.vertical then m.across else extent,
        h = if m.vertical then math.max(m.minWidth, m.size + 8) else m.across,
        radius = m.radius,
        hover = look.hover,
        opacity = if focused or isOccupied then 1 else m.emptyOpacity,
        animate = 0.12,
        -- Omarchy cycles the layout when the active workspace is clicked; that
        -- was too easy to trigger by accident here, so clicks only switch.
        -- Super+L still cycles the layout.
        onClick = "switch-workspace " .. workspace.id,
        target = "workspace " .. workspace.id,
        menu = true,
        drop = true,
        help = omniwm.l10n("Focus workspace %@", workspace.name),
        ui.text{ text = label, font = m.font, size = m.size, weight = weight,
            color = if focused then m.activeColor else m.textColor },
    }
end

local function scroll(ctx: Context, event: Event)
    if event.momentum ~= nil and event.momentum ~= "none" then
        return
    end
    local delta = if math.abs(event.dy) >= math.abs(event.dx) then event.dy else -event.dx
    if delta == 0 then
        return
    end
    local settings: { [string]: any } = ctx.data.settings or {}
    if settings.invertScroll == true then
        delta = -delta
    end
    local state = ctx.state
    -- Drop leftover travel from an earlier gesture: on a direction reversal
    -- (as lib/audio.luau and lib/calendar.luau do) or after a 0.3 s pause.
    if os.clock then
        local t = os.clock()
        if state.scrollLast and t - state.scrollLast > 0.3 then
            state.scrollAccum = 0
        end
        state.scrollLast = t
    end
    if (state.scrollAccum or 0) * delta < 0 then
        state.scrollAccum = 0
    end
    state.scrollAccum = (state.scrollAccum or 0) + delta
    local threshold = if event.precise then 24 else 0.5
    if math.abs(state.scrollAccum) < threshold then
        return
    end
    local step = if state.scrollAccum < 0 then 1 else -1
    state.scrollAccum = 0
    if os.clock then
        local now = os.clock()
        if state.scrollAt and now - state.scrollAt < 0.15 then
            return
        end
        state.scrollAt = now
    end
    local list = listed(ctx)
    local current = 0
    for index, workspace in ipairs(list) do
        if workspace.focused then
            current = index
            break
        end
    end
    if current == 0 then
        return
    end
    local target = math.clamp(current + step, 1, #list)
    if target ~= current then
        omniwm.run("switch-workspace " .. list[target].id)
    end
end

function render(ctx: Context)
    local bar = ctx.data.bar
    local style = bar.style
    if style == nil then
        return ui.box{ w = 0, h = 0 }
    end
    local settings: { [string]: any } = ctx.data.settings or {}
    local m = metrics(ctx, style, settings)
    local counts = totals(ctx)
    local props = { gap = 0, onScroll = scroll }
    for _, workspace in ipairs(listed(ctx)) do
        props[#props + 1] = cell(ctx, workspace, m, occupied(workspace, counts))
    end
    if m.vertical then
        return ui.column(props)
    end
    return ui.row(props)
end
