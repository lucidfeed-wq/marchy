# Omarchy → macOS port contract (read fully before generating a port)

You are converting ONE Omarchy 4.5 shell plugin (Quickshell/QML, Linux/Hyprland) into a native
macOS equivalent that runs in this Mac's Omarchy layer. Reproduce the plugin's **look and
behaviour** (layout, labels, glyphs, interactions, colours by theme role) using the macOS
building blocks below. Do not transliterate QML line by line; read it to understand what it
shows and does, then rebuild it.

## Runtime pieces on this Mac

| Piece | Role | API reference |
|---|---|---|
| **OmniShell** (OmniWM 0.8 bar) | Renders bar widgets and their popouts. Sandboxed **Luau**; declarative `render(ctx)` / `popout(ctx)` functions returning `ui.*` trees. No filesystem, no processes. | `~/.config/omniwm/shell/omniwm.d.luau` (authoritative types), bundled widgets `~/.config/omniwm/shell/default/widgets/*`, helpers `~/.config/omniwm/shell/default/lib/*.luau` (`look`, `actions`, `wifi`, `bluetooth`, `audio`, `battery`, `media`, `stats`, `weather`, …) |
| **Hammerspoon** (Lua 5.4, full macOS access, Accessibility + Location granted) | The backend: reads system state, runs commands, performs actions, draws overlays/pickers (`hs.canvas`, `hs.webview`, `hs.chooser`). | https://www.hammerspoon.org/docs/ ; local modules in `~/.hammerspoon/omarchy/` |
| **omniwmctl** | Window manager IPC (replaces `hyprctl`). | `/Applications/OmniWM.app/Contents/MacOS/omniwmctl help` |

## The bridge (how widget ⇄ backend talk) — use exactly this

1. **Backend → widget (state):** the Hammerspoon port module publishes JSON with
   `hs.task.new("/Applications/OmniWM.app/Contents/MacOS/omniwmctl", cb, { "shell", "set", "omarchy_<id>", json }):start()`.
   Only publish when the JSON changed. **OmniWM rejects any var larger than 4096 bytes**
   (`omniwmctl shell set` fails with `invalid_arguments`): keep each var well under 4000 bytes,
   trim/round data, cap list lengths, or split into several vars the widget joins. The widget reads it with
   `ctx.select("vars", "omarchy_<id>")` and `json.decode`, caching the decoded value by text.
2. **Widget → backend (actions):** `onClick = function(_c, _e) omniwm.open("hammerspoon://omarchy?a=<id>.<verb>&x=<urlencoded arg>") end`.
   The action name MUST be namespaced `<id>.<verb>` (e.g. `audio.set-volume`). URL-encode `x`.
3. **Overlays/pickers** (Omarchy kinds `overlay`, `panel`, `menu`) are drawn by Hammerspoon
   (`hs.webview` borderless + `hs.webview.usercontent` messages, like
   `~/.hammerspoon/omarchy/picker.lua`), opened by a port action, e.g. `emojis.open`.
4. **Hotkeys** are NOT defined by ports. List the Omarchy chords the plugin uses in PORT.md;
   the user adds them to `~/.config/omarchy-mac/bindings.toml` (`hs = "<id>.<verb>"`).

### Hammerspoon port module (required shape) — file `hammerspoon/<id>.lua`
```lua
local M = { id = "<id>" }
local log = require("omarchy.log")      -- log.i / log.w / log.e (format strings)
local toast = require("omarchy.toast")  -- toast.show(text, seconds) / toast.warn(text)
local theme = require("omarchy.theme")  -- theme.hex("accent"|"background"|"foreground"|"selection"|"dark_foreground"|"bright_foreground"|"red"|"green"|...), theme.isDark(), theme.font
M.actions = {
  ["<id>.<verb>"] = { fn = function(x) ... end, desc = "..." },
}
function M.start() ... end   -- timers/watchers; first publish
function M.stop() ... end    -- stop every timer/watcher/task you created
return M
```
Rules: never block the main thread (use `hs.task`, `hs.timer`, async callbacks; no
`hs.execute` in a timer loop); bound every timer interval ≥ 2 s unless event-driven; validate
every URL argument against your own last published state (any local app can open
`hammerspoon://` URLs); never run a shell string built from `x`.

### OmniShell widget (required shape) — directory `widget/omarchy-<id>/`
`init.luau` with `function render(ctx: Context)` and optionally `function popout(ctx: Context)`;
optional `settings.toml` (`[options.<name>] type/title/default`). Look & feel:
`local look = require("../lib/look")`, `look.bar(ctx, props)` for the bar button,
`look.panel(ctx, { w = ..., child })` for popouts, `look.group`, `look.text`, `look.radius`,
`look.hover`, `look.scale(ctx)`, `look.width`. Text glyphs use
`ui.text{ font = "JetBrainsMono Nerd Font", ... }` with the SAME Nerd Font glyphs Omarchy uses.
Colours by palette role names (`"foreground"`, `"secondaryForeground"`, `"accent"`,
`"accentForeground"`, `"error"`, `"success"`, `"warning"`) so themes apply. Only use APIs that
exist in `omniwm.d.luau`. Reference implementations to imitate:
`~/.config/omniwm/shell/widgets/omarchy-wifi/init.luau`,
`~/.config/omniwm/shell/widgets/omarchy-bluetooth/init.luau`,
`~/.config/omniwm/shell/widgets/omarchy-tray/init.luau`, backend
`~/.hammerspoon/omarchy/netpanel.lua`, overlay `~/.hammerspoon/omarchy/picker.lua`.

## Linux → macOS capability map
See `capabilities.toml` next to this file. If the plugin needs something mapped `none`,
implement everything else and list the gap in PORT.md; never fake a feature.

## Safety rules (clinical machine — these are hard requirements)
- **Privacy:** never write notification text, clipboard contents, window titles, typed text or
  file contents to logs, files or `omniwmctl shell set` unless the plugin's core function is to
  display them (then keep them in memory/vars only, never logged). The user's EMR (Citrix
  Viewer, bundle `com.citrix.receiver.icaviewer.mac`) must be excluded from any content capture.
- **No new permissions** (no Full Disk Access, no Screen Recording, no new daemons, no sudo).
- **Only new files** under your output directory. Never edit files outside it.
- Commands: absolute paths (`/usr/bin/...`, `/opt/homebrew/bin/...`). If a Homebrew CLI is
  required, list it in PORT.md under "Requires" (the installer handles it); prefer built-ins.

## Output (in your output directory)
```
hammerspoon/<id>.lua            backend module (always, unless the plugin is pure display)
widget/omarchy-<id>/init.luau   bar widget (for bar-widget kinds)
widget/omarchy-<id>/settings.toml (optional)
PORT.md                         what it does, Omarchy→mac mapping used, hotkeys to bind,
                                bar placement (leading|center|trailing), requires, gaps, test steps
port.json                       {"id","status":"ported|partial|not-portable","bar":"leading|center|trailing|none",
                                 "requires":[...], "actions":[...], "hotkeys":[{"chord","action"}]}
```
Before finishing: run `luajit -b hammerspoon/<id>.lua /dev/null` and fix any syntax errors;
re-read the widget against `omniwm.d.luau` for every API you used.
