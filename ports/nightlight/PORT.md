# omarchy.nightlight → macOS (`nightlight`)

**Status: partial** · **Bar placement: trailing** (Omarchy shows it as the `NightLight` item of
the `omarchy.indicators` bar widget) · **Requires: `nightlight`** (`brew install smudge/smudge/nightlight`,
installs `/opt/homebrew/bin/nightlight`). Without it the port still loads: the indicator stays
hidden and every action opens System Settings > Displays.

## What it does
Omarchy's `omarchy.nightlight` is a service that owns the hyprsunset screen temperature: night
light is 4000 K, daylight is 6500 K plus an identity reset, and anything below 6000 K counts
as "on". It feeds the bar's NightLight indicator and the `nightlight` IPC target
(`status`, `refresh`, `enable`, `disable`, `toggle`) that `omarchy-toggle-nightlight` and the
Omarchy menu's *Toggle > Nightlight On/Off* use.

The indicator (`shell/plugins/bar/indicators/NightLight.qml`) shows the glyph `󰔎`
(nf-md-theme-light-dark, U+F050E). While night light is on, the glyph is at full strength
and the tooltip says "Day Light". While it is off, the slot keeps its space but stays hidden.
Hovering over the indicators shows it at 45 % with the tooltip "Night Light". Clicking it
toggles night light.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| hyprsunset temperature 4000 K / 6500 K + `identity` | macOS **Night Shift** on/off through `/opt/homebrew/bin/nightlight on|off` (hs.task, fixed arguments, no shell) |
| `hyprctl hyprsunset temperature` probe → `enabled` | `nightlight status`, read leniently (the on/off line), plus `nightlight temp` for Night Shift's 0–100 warmth |
| Service state for the bar | Published to the OmniShell var `omarchy_nightlight`: `{v, available, loaded, enabled, strength}`. It is re-read every 30 s and on wake/unlock, because Night Shift also changes on its own schedule and from Control Center. |
| Optimistic apply + queued pending temperature | Same: the indicator flips at once, a second toggle during an apply is queued, and a probe confirms the result |
| `NightLight` BarIndicator (`󰔎`, dimmed 45 %, concealed until hover) | Widget `omarchy-nightlight`: `look.bar` slot with the same glyph (JetBrainsMono Nerd Font). Opacity is 1 when on, 0 when off, and 0.45 while the pointer is over it. The `alwaysShow` setting matches the Indicators widget's option. |
| Tooltips `bar.dayLight` / `bar.nightLight` | "Day Light" / "Night Light" (English) |
| IPC `nightlight toggle/enable/disable/refresh/status` | Actions `nightlight.toggle`, `.enable`, `.disable`, `.refresh`, `.status` (a toast with the state). From Lua: `require("omarchy.ports.nightlight").state()` |
| (no CLI) | `nightlight.settings` opens System Settings > Displays (right-click on the indicator) |

### Using it from a script
```sh
open -g 'hammerspoon://omarchy?a=nightlight.toggle'
open -g 'hammerspoon://omarchy?a=nightlight.enable'
open -g 'hammerspoon://omarchy?a=nightlight.disable'
```

## Hotkeys to bind (Omarchy chords → actions)
Omarchy 4.5 ships no default chord for night light. It is toggled from the bar indicator and
the menu (*Toggle > Nightlight*). If you want a chord, add one to `~/.config/omarchy-mac/bindings.toml`:

| Omarchy chord | Action |
|---|---|
| (none by default) | `nightlight.toggle` |

## Safety
- No action takes a URL argument. Only the fixed words `on`, `off`, `status` and `temp` are
  ever passed to `/opt/homebrew/bin/nightlight`, by absolute path and without a shell.
- No new permissions. The Homebrew `nightlight` tool uses the same per-user Night Shift
  client as System Settings, with no sudo and no daemon.
- Nothing personal is read or logged. The only polling is a 30 s timer, which runs the tool
  only when it is installed, plus a sleep/wake watcher. Both stop in `M.stop`.

## Gaps (honest list)
- **No Kelvin temperature.** Night Shift has a 0–100 warmth slider, not a colour
  temperature. The port leaves your slider alone and turns Night Shift on or off; it never
  forces 4000 K. `strength` is published, but nothing in the bar shows it.
- **Requires a Homebrew tool.** macOS has no built-in CLI for Night Shift. Without
  `nightlight`, the indicator has no state to show (it stays hidden), and a click opens
  Displays settings with a toast saying what to install.
- **`nightlight status` output format.** The parser looks for a bare `on`/`off` line and
  skips schedule lines. If a future version of the tool changes its wording, the port logs
  `could not read the on/off state` and treats Night Shift as off until a toggle.
- **Indicator group hover.** Omarchy reveals every inactive indicator when you hover over the
  indicator area. This port can only see the pointer over its own slot, so an inactive
  indicator appears only when you hover directly over it.
- **External displays.** Night Shift applies to the displays macOS supports it on. Some
  external monitors are not tinted (a macOS limitation, not the port's).
- Tooltips are English only.

## Test steps
1. `brew install smudge/smudge/nightlight`. Install the port with `--bar` and reload Hammerspoon.
   Check that `~/.local/state/omarchy-mac/hs.log` has no `nightlight:` errors.
2. Turn Night Shift off in Control Center. Within 30 s the indicator slot should be empty.
   Hover over it and `󰔎` should show at about 45 % with the tooltip "Night Light".
3. Click it. Night Shift turns on, the glyph goes to full strength, and the tooltip reads
   "Day Light". Control Center > Display shows Night Shift on.
4. Click again. Night Shift turns off and the indicator hides.
5. Turn Night Shift on from Control Center. Within 30 s the indicator should show it as on.
6. `open -g 'hammerspoon://omarchy?a=nightlight.status'` should show a toast with the current state.
7. Right-click the indicator. System Settings opens at Displays.
8. Uninstall the formula (or rename the binary) and reload. Clicking the indicator area now
   shows the install hint and opens Displays settings.
