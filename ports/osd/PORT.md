# omarchy.osd → macOS (`osd`)

**Status: ported** · **Bar placement: none** (Omarchy kind `panel`, no bar presence) · **Requires: nothing** (Hammerspoon built-ins only)

## What it does
Omarchy's on-screen display: a small card drawn at the bottom centre of the focused screen,
67 px above the bottom edge, that never takes focus. Two layouts:

| Layout | When | Content |
|---|---|---|
| Progress | payload has `value` and no `message` | glyph · 142 px bar (track = foreground 45 %, fill = accent) · right-aligned readout (`42%`, or `progressText`) |
| Status | payload has a `message` (or no value) | glyph · bold message (≤ 190 px, ≤ 325 px for `media*`/`player*` icons, elided with …) |

The card hides itself after `duration` ms (default 1200; `0` = until closed). Updating it while
it is open animates the bar (140 ms, OutCubic); a fresh card starts at its value. The icon
column is pinned to the widest volume glyph in progress mode so the bar does not shift.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `OverlayWindow` (layer-shell, empty input mask) | `hs.canvas` at `overlay` level, all Spaces + full-screen auxiliary, `clickActivating(false)`, no mouse callback, never focused |
| `BorderSurface` (background 97 %, popups border 2 px, `Style.cornerRadius`) | canvas rectangle: `background` @ 0.97, `accent` 2 px stroke, square corners (same as `omarchy.toast`) |
| `Commons.Color.popups.text` / `accent` | `theme.color("foreground")` / `theme.color("accent")` |
| `Style.font.displayLarge` glyph / bold `Style.font.title` text | JetBrainsMono Nerd Font 32 pt / JetBrainsMono NF Bold 16 pt |
| `OsdModel.js` (`iconFor`, `stateForShow`) | reimplemented 1:1 in Lua, same icon names, aliases and Nerd Font code points (U+EEE8, U+F026–F028, U+F036C/D, U+F030C, U+F0379, U+F07F8, U+F0741, U+F0709, U+F0425, U+F0343, U+F075A, U+F040A, U+F03E4, U+F04AD/E) |
| `ShellIpc osd.show(json)` / `close()` | actions `osd.show` (x = same JSON) / `osd.close` |
| `ShellIpc osd.state()` / `ping()` | Lua only: `require("omarchy.osd").state()` / `.ping()` (URL actions cannot return values) |
| Callers (`omarchy-osd` from the volume / brightness / mic key scripts) | `osd.volume-up` / `-down` (x = step 1–25, default 5), `osd.volume-mute`, `osd.mic-mute` via `hs.audiodevice`; `osd.brightness-up` / `-down` via `hs.brightness` |

### Showing an OSD from anywhere (replaces the `omarchy-osd` command)
```sh
open -g 'hammerspoon://omarchy?a=osd.show&x=%7B%22icon%22%3A%22volume%22%2C%22value%22%3A40%7D'   # {"icon":"volume","value":40}
open -g 'hammerspoon://omarchy?a=osd.show&x=%7B%22icon%22%3A%22reboot%22%2C%22message%22%3A%22Restarting%E2%80%A6%22%7D'
open -g 'hammerspoon://omarchy?a=osd.close'
```
From another Hammerspoon module: `require("omarchy.osd").showTable{ icon = "brightness", value = 70 }`.

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys; add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`) with whatever chord you prefer:

| Omarchy chord | Action |
|---|---|
| `XF86AudioRaiseVolume` | `osd.volume-up` |
| `XF86AudioLowerVolume` | `osd.volume-down` |
| `XF86AudioMute` | `osd.volume-mute` |
| `XF86AudioMicMute` | `osd.mic-mute` |
| `XF86MonBrightnessUp` | `osd.brightness-up` |
| `XF86MonBrightnessDown` | `osd.brightness-down` |

On a Mac the F-row media keys are system keys handled by macOS (which shows its own HUD), so these
chords cannot be bound as-is. Bind them to ordinary chords instead (e.g. Hyper+F11/F12).

## Safety
- URL arguments are untrusted: the payload is capped at 2 KB, `message` at 240 bytes, `icon` at
  32 bytes, `progressText` at 32 bytes, control characters are stripped, and numbers are parsed
  and clamped like `OsdModel.js`. A URL cannot pin the card on screen: `duration` `0` or
  more than 10 s becomes 10 s. Only Lua callers (`showTable`) get `0` = "until closed".
- Step arguments are clamped to 1–25. No shell commands; nothing is built from `x`.
- Message text is never logged (only the icon name and whether a bar was shown). No content
  capture of any kind, so Citrix Viewer is unaffected.
- No new permissions, no daemons, no polling timers. The only repeating timer is the 140 ms bar
  animation (60 fps, stops itself), which runs only while an open OSD is updated.

## Gaps (honest list)
- **Glyph ink measurement.** Qt measures each glyph's ink box; Hammerspoon only reports advance
  widths, so the icon column uses max(advance, 1.1 em) and centres the glyph. Spacing can differ
  from Omarchy by a pixel or two.
- **Hardware keys / macOS HUD.** macOS still shows its own volume/brightness HUD for the F-row
  keys. The port does not intercept system keys (an event tap on them would be invasive).
  Use the `osd.*` actions on your own chords.
- **Brightness** works on the built-in display only (`hs.brightness`). External monitors are not
  controlled; the action shows a warning toast.
- **Keyboard backlight / touchpad / touchscreen OSDs.** Their glyphs are supported through `osd.show`, but
  there are no matching actions: macOS gives no readable keyboard-backlight level and no
  touchpad on/off toggle.
- **Media OSDs.** `media-*` / `player-*` icons and the wider 325 px message work through
  `osd.show`, but the port doesn't watch the player. Reading the track title would need Apple
  Events permission for Music/Spotify, which is forbidden here.
- **Mic mute** uses the input device's mute control. If the device has none, the port sets the
  input gain to 0 instead (75 when you unmute).
- **Number formatting** is plain digits (`42%`). Omarchy's `I18n.formatNumber` localisation is not reproduced.
- **Click-through.** The canvas has no mouse handler and never activates Hammerspoon. On some
  Hammerspoon builds a click right on the card can still land on it rather than on the window
  below. The card is small and gone in 1.2 s.

## Test steps
1. Install the port, reload Hammerspoon, check `~/.local/state/omarchy-mac/hs.log` has no `osd:` errors.
2. `open -g 'hammerspoon://omarchy?a=osd.show&x=%7B%22value%22%3A42%7D'`. Expected: a card at the bottom centre with
   the medium-volume glyph, a bar about 42 % filled in accent, and `42%`. It disappears after about 1.2 s.
3. Run it again with `%7B%22value%22%3A90%7D` within a second. Expected: the bar animates from 42 to 90 and the glyph switches to volume-high.
4. Show `{"icon":"mic-muted","message":"Microphone muted"}`. Expected: the glyph plus bold text, with no bar.
5. Show `{"value":5,"duration":0}`. Expected: it closes by itself after 10 s (the URL cap). Then run `osd.close`.
6. Bind `osd.volume-up` / `osd.volume-down` / `osd.volume-mute` / `osd.brightness-up` / `osd.mic-mute` and press
   each one. The setting should change, and the OSD should show the new level or state.
7. Switch the theme (`omarchy-theme set …`) and show an OSD again. Expected: the background, border and fill follow the new theme.
