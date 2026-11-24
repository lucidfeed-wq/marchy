# omarchy.weather → macOS (`weather`)

**Status: partial** · **Bar placement: trailing** · **Requires: OmniWM's `[weather]` table** in `~/.config/omniwm/shell/shell.toml` (city, or latitude/longitude) and OmniWM's built-in Weather service turned on (Settings → Network & Permissions → Built-in Services; on by default)

## What it does
Omarchy's weather pill. The bar shows only the current condition glyph (Omarchy's Nerd Font
weather icons, day/night aware). Left click opens the detail popout (480 pt wide):

- **Hero:** a 64 pt condition glyph and a 56 pt bold temperature with its °C/°F unit on the left. On the right: the location (map marker U+F041 + the upper-cased place name), and below it three stats, FEELS / WIND / HUMID (label 11 pt dim, value 14 pt).
- "Fetching forecast…" while there is no reading.
- A hairline divider, then the **next three days**, centred. Each day shows its glyph, the upper-cased full weekday name, the high, and the low (dim).

Right click shows Omarchy's status line (`omarchy-weather-status`) as a toast:
`Toronto  ·  Temp 13°C  ·  Wind 11 km/h`.

Glyphs are Omarchy's `Model.js` maps, used unchanged. WMO weather code → wttr code
(`iconForOpenMeteoCode`) → glyph (`iconForCode`): clear U+E30D / night U+E32B, partly cloudy
U+E302 / U+E32E, overcast U+E33D, fog U+E313 / U+E346, rain U+E318, snow U+E31A,
thunder U+E31D, fallback U+E33D.

## Data source: Omarchy vs. this port
| | Omarchy 4.5 (`Panel.qml` / `Model.js`) | This port (OmniWM `ctx.data.weather`) |
|---|---|---|
| Provider | `curl wttr.in/<loc>?format=j1` (current, nearest area, days), plus `curl api.open-meteo.com/v1/forecast` (current temp / apparent / humidity / wind / code / is_day, daily code / max / min, `forecast_days=4`, `timezone=auto`) | OmniWM fetches Open-Meteo only (current incl. humidity, 24 hourly entries, 7 days, rain chance, sunrise/sunset). No wttr.in, so no `nearest_area`. |
| Location | `~/.local/state/omarchy/settings/weather.json` (set by clicking the location → Open-Meteo geocoding search), otherwise IP auto-detect via `geo.omarchy.org` (and wttr.in's own lookup as a last resort) | `[weather] city = "…"` (geocoded by OmniWM through Open-Meteo) or `latitude`/`longitude` in shell.toml. **No IP auto-detect.** With coordinates, OmniWM reports no place name, so the location row is hidden. |
| Units | `unit` setting `imperial` / `metric`, else auto by country (US, Liberia, Myanmar) or locale | OmniWM fetches in `[weather] units` (`celsius` default, or `fahrenheit`; wind follows: km/h or mph). The widget option `unit` = `auto` (OmniWM's) / `metric` / `imperial` converts in the widget (°C↔°F, km/h↔mph). |
| Refresh | `refreshMinutes` (15), three retries 2.5 s apart, middle-click refresh | `[weather] refresh` minutes (15 default, at least 5). OmniWM retries on failure and marks the data `stale`. No manual refresh command exists. |
| Forecast days | the first 3 days after today | `days[2…4]` (OmniWM's `days[1]` is today) |
| Weekday names | `locale.standaloneDayName(…, LongFormat)` | `ctx.format.date(time, "EEEE")`, which follows the macOS language |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `BarWidget.qml` (glyph pill, hidden until there is a reading) | widget `omarchy-weather` `render`: `look.bar` + `ui.text` glyph. It shows a dim cloud while OmniWM has no reading or weather is off/blocked, so the popout can say why. |
| `Panel.qml` hero / stats / forecast | widget `popout` with the same layout, sizes, and dim roles (`secondaryForeground` for Omarchy's `Qt.darker(fg, 1.4/1.5)`) |
| Right click → `omarchy-notification-send "$(omarchy-weather-status)"` | right click → `weather.status`. The widget sends only `x = "<temp>,<wind>,<c\|f>"` (integers + unit letter). Hammerspoon reads the place from `[weather] city` itself and shows a toast. |
| `SUPER + CTRL + ALT + W` → `omarchy-notification-weather` → `omarchy-shell shell toggle omarchy.weather` | `weather.toggle` → `omniwmctl shell toggle omarchy-weather` |
| IPC `open` / `close` / `toggle` | `weather.toggle` (one toggle) |

## Hotkeys to bind (Omarchy chords → actions)
Add to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + ALT + W` | `weather.toggle` |

## Setup
Add OmniWM's weather table to `~/.config/omniwm/shell/shell.toml` (the port never edits it):
```toml
[weather]
city = "Toronto"        # or latitude = 43.65, longitude = -79.38
units = "celsius"       # or "fahrenheit"
refresh = 15            # minutes, at least 5
```
Optional: `[profiles.default.widgets.omarchy-weather] unit = "imperial"` shows °F / mph regardless of OmniWM's unit.

## Safety
- Display-only widget. The forecast comes from OmniWM, and the port makes no network requests of its own.
- `weather.status` accepts only `^-?\d+,\d+,[cf]$` (or `none`), clamps the values to a sane range, and never shows URL text. The place name comes from shell.toml.
- Nothing is persisted. No timers, no tasks except `omniwmctl shell toggle`. No permissions are used (not even Location).

## Gaps (honest list)
- **No IP auto-location.** OmniWM needs `[weather]` in shell.toml. Without it the popout explains what to add, and the pill stays a dim placeholder.
- **Click-to-edit location** (Open-Meteo geocoding search that saves `weather.json`) is not ported. Changing the location would mean rewriting shell.toml, which this port does not do. Edit `[weather]` by hand; OmniWM reloads it live.
- **Middle-click refresh** is not ported: OmniWM has no weather refresh command. Its own `refresh` interval and retries apply.
- **Location label for coordinates:** OmniWM reports a place name only for `city = …`. Omarchy showed wttr.in's nearest area.
- The **auto unit** follows OmniWM's configured unit, not the country/locale heuristics in `Model.js`.
- Numbers use plain digits (Omarchy's `I18n.formatNumber` localisation isn't reproduced). Labels are English.

## Test steps
1. Add the `[weather]` block above, run `omarchy-port install weather --bar`, and reload Hammerspoon. Within a few seconds the bar shows a condition glyph (a moon variant at night).
2. Left click. Expected: the large glyph and temperature, the upper-cased city with the map marker, FEELS / WIND / HUMID, a divider, and three weekdays with high/low.
3. Set `[profiles.default.widgets.omarchy-weather] unit = "imperial"`. Temperatures should switch to °F and wind to mph. Set it back to `auto`.
4. Right-click the pill. Expected: a toast like `Toronto  ·  Temp 13°C  ·  Wind 11 km/h`.
5. `open -g 'hammerspoon://omarchy?a=weather.status&x=hello'`. Expected: the "Weather unavailable" toast and a log line "status refused" with no argument text.
6. Bind `weather.toggle` to SUPER+CTRL+ALT+W and press it twice. The popout should open, then close.
7. Turn Weather off in OmniWM Settings. The pill should dim, and the popout should say it is turned off.
