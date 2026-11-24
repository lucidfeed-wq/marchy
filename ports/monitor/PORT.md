# omarchy.monitor → macOS (`monitor`)

**Status: partial** · **Bar placement: trailing** · **Requires: nothing** (optional: `betterdisplaycli`, `brew install waydabber/betterdisplay/betterdisplaycli`, with BetterDisplay running, for external brightness and turning displays off)

## What it does
Omarchy's Display item sits in the bar as 󰍹 (U+F0379), or 󰍺 (U+F037A) when more than one display is connected.

| Interaction | Result |
|---|---|
| Scroll on the item | Brightness ±5 % per notch, with the brightness OSD |
| Click | The Display panel |

The panel, top to bottom:

| Section | Content |
|---|---|
| Hero | The display glyph, **Display**, and a mood name for the brightness in caps: Night owl < 10, Candlelit, Lamp light, Soft glow, Even day, Golden hour, Solar flare, Sun blast ≥ 95. With no controllable backlight it says **FIXED BRIGHTNESS**. |
| BRIGHTNESS | A slider from 1 to 100 % with the value on the right. |
| SCALE | Pills for 1x 1.25x 1.6x 2x 3x 4x, limited to those the focused display can take. The active one is highlighted. With more than one display, the focused display's name appears on the right. |
| DISPLAYS | Shown with more than one display. Each row shows 󰍹, the name (`… · focused`) and 󰄬 when it is on. Clicking turns a display off or on, but never the last one that is on. |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `BarIconButton` 󰍹/󰍺 + `onWheelMoved` (±5 per notch, OSD) | `look.bar` item with the same glyphs. `onScroll` accumulates trackpad deltas like OmniShell's `lib/audio.luau`, 12 points = one notch, then ±5 %. The OSD shows through `monitor.osd`, which calls the `osd` port's `showTable{icon="brightness"}` when that port is installed. Widget setting `osd` (default on). |
| `omarchy-brightness-display` (built-in backlight) | OmniWM's own `ctx.data.brightness` and the `brightness set <pct>` command. These use DisplayServices on OmniWM's main display, normally the built-in panel. |
| Focused external display brightness (`ddcutil`) | `betterdisplaycli get -name=<display> -brightness` and `set -name=<display> -brightness=<pct>%`, only if `/opt/homebrew/bin/betterdisplaycli` exists. Sets are queued, so a slider drag never piles up processes, as Omarchy's `brightnessSetQueued` does. Without the CLI, an external focused display falls back to the built-in slider, or to FIXED BRIGHTNESS. |
| `brightnessName()` (Model.js) | Same bands and names. |
| `SCALE` presets / `omarchy-hyprland-monitor-scaling <s>` | macOS calls scale "Looks like". Native width is the display's widest 1x mode. For each preset *s* the port picks the mode whose logical width is native ÷ *s*, within 7 % and with the same aspect ratio. It prefers HiDPI (2x) modes and the current refresh rate. Then it calls `hs.screen:setMode(w, h, scale, freq, depth)`. Pill labels show the real effective scale (for example `1.68x` on a 14" MacBook Pro, where Omarchy would round to a clean Hyprland scale). Presets with no matching mode are hidden, as Omarchy's `availableScales` hides them. |
| `DISPLAYS` toggle (`hl.monitor({ disabled = … })`) | `betterdisplaycli set -name=<display> -connected=off|on`, if installed. Displays turned off this session stay in the list so they can be turned back on. The last display that is on cannot be turned off. Without the CLI the rows are shown dimmed with a note. |
| Focused monitor (`Hyprland.focusedMonitor`) | `hs.screen.mainScreen()` (the screen of the focused window). It is watched with `hs.screen.watcher.newWithActiveScreen`, so there is no polling, where Omarchy polls every 5 s while the panel is open. Opening the panel also refreshes. |
| `ShellIpc omarchy.monitor open/toggle` (Super+Ctrl+D) | `monitor.open` runs `omniwmctl shell toggle omarchy-monitor`, which opens the widget's popout. |
| `ShellIpc omarchy.monitor brightness(pct)` / `state()` | `brightness set <pct>` (OmniWM) / the `omarchy_monitor` shell var. |
| `omarchy-hyprland-monitor-scaling up/down` (Super+/ and Super+Alt+/) | `monitor.scale-up` / `monitor.scale-down` step through the focused display's presets. |
| `omarchy-hyprland-monitor-internal toggle` (Super+Ctrl+Delete) | `monitor.toggle-internal`: laptop display off/on through `betterdisplaycli`. |
| `omarchy-hyprland-monitor-internal-mirror toggle` (Super+Ctrl+Alt+Delete) | `monitor.mirror-internal`: `hs.screen:mirrorOf()` (built-in mirrors the external display) and `hs.screen:mirrorStop()`. |

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys. Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + D` | `monitor.open` |
| `SUPER + SLASH` | `monitor.scale-up` |
| `SUPER + ALT + SLASH` | `monitor.scale-down` |
| `SUPER + CTRL + Delete` | `monitor.toggle-internal` |
| `SUPER + CTRL + ALT + Delete` | `monitor.mirror-internal` |

Brightness keys (`XF86MonBrightnessUp/Down`) belong to the `osd` port (`osd.brightness-up/down`).

## Safety
- URL arguments are an index from the last published list (`monitor.scale`, `monitor.display`) or a
  number checked to be in range (`monitor.brightness` 1–100, `monitor.osd` 0–100). Anything else is
  refused with a toast. `setMode` only ever receives a mode that `availableModes()` returned for
  that same screen id.
- Commands use absolute paths (`/opt/homebrew/bin/betterdisplaycli`,
  `/Applications/OmniWM.app/Contents/MacOS/omniwmctl`) through `hs.task`, with the display name as
  a separate argument. There is no shell.
- Turning displays off needs the optional CLI, and the last display that is on is always refused.
- No polling timers. No new permissions. Nothing private is published (display names, modes and
  numbers only).

## Gaps (honest list)
- **TEXT SIZE slider**: not ported. macOS has no system-wide text size that an app can set
  (Omarchy's slider rewrites the shell font plus GTK text scaling). The panel's
  **Displays Settings…** row opens System Settings › Displays instead.
- **Keyboard navigation** in the panel (j/k/h/l, Enter, Tab to other panels) is not ported.
  OmniShell popouts are driven by the pointer here.
- **Clean scales**: Hyprland needs scales that divide the mode into whole pixels. macOS only
  offers its own "Looks like" sizes, so the pills show the nearest real ones (for example 1.68x),
  and 3x/4x are usually missing on laptops.
- **External brightness and turning displays off** need BetterDisplay's CLI. Its `get` output format
  was not verified on this Mac (`betterdisplaycli` is not installed yet). The port accepts a
  0–1 fraction or a percentage.
- **Built-in brightness** follows OmniWM's main display (`CGMainDisplayID`). If an external display
  is the main display, OmniWM reports no backlight. The slider then shows only when
  BetterDisplay can control the focused display.
- **Mirroring**: macOS mirror sets are not reported by Hammerspoon in a stable way. The port
  remembers that it turned mirroring on in this session. After a reload, run the toggle twice
  or use System Settings › Displays.

## Test steps
1. Install with `--bar`, reload Hammerspoon. Check there are no `monitor:` errors in `~/.local/state/omarchy-mac/hs.log`.
2. The bar shows 󰍹 (󰍺 with an external display). Scroll on it: the built-in brightness changes in 5 %
   steps. With the `osd` port installed, the brightness OSD shows the new level.
3. Click it. Expected: **Display** and a mood name (for example EVEN DAY at 50 %). Drag the slider: the
   brightness follows, and the label and percentage update.
4. SCALE: on a 14" MacBook Pro, expect about `1x 1.25x 1.68x 2x`, with `2x` active by default.
   Click `1.68x`: the display switches to "Looks like 1800×1169" and the pill becomes active.
   Click `2x` to go back.
5. Bind `monitor.scale-up` / `monitor.scale-down` and press them. Each press moves one preset, with a toast.
6. With an external display: DISPLAYS lists both, with the focused one marked. Without betterdisplaycli
   the rows are dimmed and a note says what is needed. With it, click the external display: it turns off.
   Click it again: it comes back. Clicking the last display that is on is refused.
7. `monitor.mirror-internal` (two displays): the built-in mirrors the external. Run it again to stop.
8. Bind `monitor.open` to Super+Ctrl+D: it opens and closes the panel from the keyboard.
