# omarchy.elsewhen → macOS (`elsewhen`)

**Status: partial** · **Bar placement: trailing** (Omarchy's `defaultSection` is `right`) ·
**Requires: nothing to install.** `omarchy-port sync` is recommended: the greetings, coastlines
and globe cities are read at runtime from the synced upstream source. Without it, greetings
are English and the globe shows only its graticule.

## What it does
Jason Fried's world clock for the Omarchy bar. A status-slot button (`󰇧`, nf-md-earth,
tooltip "World clock"; right-click refreshes) opens a panel:

- **Hero**: "It's 2:05 PM here in Miami" (in the accent colour while the clocks are shifted,
  with the shift such as "+3h"), then **World [globe] Clock**. The small drawn globe leans on
  the earth's axis and marks home or the focused city.
- **One row per city**: the name; the temperature and weather glyph (clicking the
  temperature flips °C/°F); the date and day offset ("Tue Nov 24 · Tomorrow"), replaced by
  the local greeting while hovered ("Bonjour", "おはよう ohayo"); the time with AM/PM
  (clicking flips 24-hour); the zone abbreviation and the offset from home, or from UTC
  (clicking flips). Under that is the city's 24-hour daylight strip. It lights the real
  daylight (from the city's coordinates) and marks now with the sun by day and tonight's moon
  phase by night. Sunrise ↑ and sunset ↓ arrows appear on hover. The row's tint follows the
  city's time of day, and hovering lifts it. A × removes the city; the last city always stays.
- Click a row to turn the little globe to it. Click the caption to go back to home. With no
  city focused, the caption asks **"Where are you?"**.
- Scroll over a strip to shift every clock (Omarchy drags it). The clocks spring back 2.5 s
  after you stop.
- **+ Add a city** opens the search. The offline zone catalogue and Omarchy's city aliases
  are searched first, then Open-Meteo's geocoder (any town, from 3 letters).
- The **globe mode**: click the little globe. An orthographic globe shows coastlines, a
  30° graticule, the day/night line, and the cities. Dots are gold by day and dark by night;
  tracked cities get an accent ring and home an accent dot. Names are dark over land and
  light over sea. Scroll to spin and tilt it. Click a city to centre it and read its name,
  time, badge (home/tracked), zone and offset underneath. The little globe becomes a × that
  goes back to the list.
- First run seeds the list like Omarchy: home, plus four well-known cities spread round the
  clock from it.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `BarIconButton` `󰇧`, left = toggle, right/middle = refresh | Widget `omarchy-elsewhen`: `look.bar` with the same glyph (JetBrainsMono Nerd Font). Click → `ui.popout`; right-click → `elsewhen.refresh` |
| `KeyboardPanel` (340 px content) | OmniShell popout (`look.panel`, 340 pt content) |
| `date` probe per zone + local ticking | `ctx.format.offset(seconds, zone)` for every zone, and `ctx.format.date(seconds, "zzz", zone)` for the abbreviation. The widget redraws every minute (`ctx.data.clock`) and every 20 s (`interval`). |
| `Model.js` rows: time, meridiem, date, day label, phase, progress, relative / UTC offset | Reimplemented in Luau (`clockText`, `dayLabel` with civil-day arithmetic, `phaseFor`, `relativeLabel` "+9h"/"-3.5h", `utcLabel` "UTC+5:30") |
| `Sun.js` + `GlobeModel.subsolarPoint` (sunrise/sunset, lit spans, polar day/night), `moonPhase`, `moonLitOutline` | Ported 1:1 to Luau; the moon is drawn as a `ui.path` |
| `MiniGlobe.qml` / `Globe.qml` Canvas (orthographic projection, limb clipping, coastline fill, graticule, terminator, dots, label layout) | `project`, `limb`, `strokeRuns` and `clipRing` ported to Luau and drawn as `ui.path` (fill/border) with `ui.box` dots and `ui.text` labels in a `ui.stack`. The same colours are used (ocean fg 5 %, land fg 92 %, graticule fg 10 %, terminator `#E5C736` @ 55 %, gold `#E5C736`), along with the same declutter (19 pt) and label rules (14 labels, flip near the right edge). |
| `world.json`, `cities.json` (plugin dir) | Read by Hammerspoon from `~/.local/share/omarchy-mac/upstream/current/shell/plugins/panels/elsewhen/` and published once as the var `omarchy_elsewhen_globe` |
| `Greetings.js` (zone → country → language → hour bands) | Parsed by Hammerspoon from the same upstream folder (110 languages). Each city's bands are published with it; the widget picks the band for the city's local hour. Fallback: English bands. |
| Settings `cities`, `here`, `hour24`, `offsetMode`, `units` in shell.json | `~/.config/omarchy-mac/elsewhen.json`, written atomically by Hammerspoon. It holds city names, zones, coordinates and regions only. |
| `timedatectl show -p Timezone` | `/etc/localtime` resolved with `hs.fs.pathToAbsolute`, re-checked every 60 s and on wake |
| `seedFirstRun` (`pickSeedZones`, gaps 180/120/60 min) | Same algorithm. Offsets come from `/bin/date +%z` run once per candidate zone, with `TZ` in the task environment (no shell). |
| Geocoding (`curl` Open-Meteo, a city in its own zone beats the top hit; `zone1970.tab` fallback) | `hs.http.asyncGet` to the same Open-Meteo endpoint. The fallback is `/usr/share/zoneinfo/zone.tab`, because macOS ships no `zone1970.tab`. Coordinates are saved with the city so it is looked up only once. |
| Weather (`curl` Open-Meteo forecast, 20 min TTL, every 15 min while open) | `hs.http.asyncGet`, the same URL, 20 min TTL, checked every 15 min. It uses WMO codes and the same glyphs: 󰖨 sunny, 󰖕 partly, 󰖐 cloudy, 󰖗 rain, 󰖘 snow. |
| `CitySearch` (offline matches, then geocoder places; `mergePlaces`; ↑↓ Return Esc) | Hammerspoon `hs.webview` search window ("Add a city" / "Where are you?") at the top right, with its own `omarchy_elsewhen` message handler. It uses the same matching rules and shows the UTC offset of every result (WebKit `Intl`). The query goes to Lua through the message handler. |
| Drag a row to reorder | Drag the cities in the search window's "Your cities" list (`elsewhen.add`) |
| `setHere` / `claimHome` (rename the home row, keep its place) | `elsewhen.here` → pick in the search window. The same rename rule applies when the place is on the Mac's zone. |
| ShellIpc `omarchy.elsewhen` `open/toggle`, `refresh`, `add`, `remove` | `elsewhen.toggle` (`omniwmctl shell toggle omarchy-elsewhen`), `elsewhen.refresh`, `elsewhen.add`, `elsewhen.remove` (x = `<rev>:<index>`) |

## Hotkeys to bind (Omarchy chords → actions)
| Omarchy chord (default/hypr/bindings/utilities.lua) | Action |
|---|---|
| `SUPER + CTRL + ALT + E` (World clock) | `elsewhen.toggle` |

Add it to `~/.config/omarchy-mac/bindings.toml` as `hs = "elsewhen.toggle"`.

## Safety
- **Typed text:** the search query is typed text. It goes from the page to Lua through the
  WKWebView message handler, never through a `hammerspoon://` URL. It is never logged and
  never written to disk; the session cache of geocoder answers lives in memory only. As in
  Omarchy, the query is sent to Open-Meteo's geocoder. That is the feature's purpose, and it
  only happens once 3 or more letters are typed in the search window.
- **What is stored:** `~/.config/omarchy-mac/elsewhen.json` holds city names chosen from the
  catalogue or the geocoder, their IANA zones, their coordinates and regions, and the three
  toggles. Nothing else is stored.
- **Network:** `api.open-meteo.com` (weather for the stored cities' coordinates) and
  `geocoding-api.open-meteo.com` (city names). Both use `hs.http.asyncGet` and never block.
  Weather is refreshed at most every 20 minutes. There is no other traffic, and nothing is
  sent about the user.
- **URL arguments:** only `elsewhen.remove` takes one. Its `<rev>:<index>` must match the
  revision and list length the module last published, and the last city is never removed.
  `elsewhen.toggle-hour24` accepts only `24`/`12`. Picks from the page are re-validated in
  Lua: the zone must be a real file under `/usr/share/zoneinfo` and must not contain `..`;
  labels are stripped of `,|` and control characters and capped at 64 bytes; coordinates
  are clamped; reorders must be an exact permutation.
- No shell. `/bin/date` gets fixed arguments, with the zone only in its environment.
  `omniwmctl` gets fixed arguments. No new permissions. The timers (15 min facts, 60 s zone
  check) and the wake watcher stop in `M.stop`.

## Gaps (honest list)
- **No opening spin or focus reset when the panel opens.** OmniShell gives a widget no
  "popout opened" hook, and `ui.popout` cannot be called from a handler. The three-turn spin
  is gone, and a city focused earlier stays focused until you click the caption.
- **Keyboard control of the panel** is not ported: ↑/↓ focus, ←/→ shift an hour, `t` 24-hour,
  Alt+T units, `w` here, `p` people, `+`/`a` add, `j` jump, `r` refresh, Space globe,
  Delete remove, and Esc unwinding. Use the mouse, the search window (which has its own
  keys), or the actions.
- **Scrubbing** is done by scrolling over a strip, in 15-minute steps. Dragging along the strip
  and the arrow keys' one-hour steps are not available.
- **Who's here (people and GitHub avatars) is not ported.** The names are typed text that
  Omarchy keeps in its settings. Persisting them conflicts with this machine's rule against
  storing typed text, and the avatar fetch would add GitHub traffic.
- **Reordering** happens in the search window's list, not by dragging rows in the panel.
- **Globe simplifications:** there is no zoom transition (the rows knocked aside, the globe
  growing out of the hero icon). There is also no drag-and-throw: scroll spins and tilts
  instead. Other differences:
  - No "jump to a city" box or session-only cities.
  - Clicking a city on the Mac's zone does not claim it as home.
  - Labels over land are coloured by a point-in-polygon test, not clipped per glyph.
  - No reduced-detail drawing while the globe moves.
- **Here on another time zone:** Omarchy moves the system clock (`sudo -n timedatectl`). macOS
  needs an administrator for that, so the port shows a toast and opens Date & Time settings.
- The **moon-phase show** (Shift-click the moon) and the **arched caption** are not ported.
  The caption is straight text.
- **Sunrise/sunset times** appear as the arrows' tooltips, not as the tap-to-show chip.
- **Language:** strings and day/month names are English. Zone abbreviations come from macOS
  (`zzz`), so some zones read `GMT+9` where Linux prints `JST`. Numbers use ASCII digits, and
  there is no right-to-left mirroring.
- **Weather refreshes in the background** (every 15 min, TTL 20 min) rather than only while
  the panel is open, because Hammerspoon cannot see when the popout opens.
- The 24-hour default follows the macOS locale's preferred hour format, read via
  `ctx.format.date(…, "j")`. Omarchy reads the Qt locale.
- The panel has no scroll area. The list is capped at 24 cities.
- If `world.json` / `cities.json` / `Greetings.js` are missing (no `omarchy-port sync`), the globe has no
  coastlines or built-in cities (a hint says so) and greetings are English.

## Test steps
1. `omarchy-port sync`, then install the port with `--bar` and reload Hammerspoon. Check
   `~/.local/state/omarchy-mac/hs.log` for `elsewhen: seeded 5 cities around <zone>` and no errors.
2. Click `󰇧`. The panel shows the caption with your local time, **World (globe) Clock**, and
   five rows: home plus four cities spread round the clock. Within a few seconds each row
   gets a temperature and weather glyph, and its strip shows real daylight with a gold sun
   or a moon.
3. Hover over a row. The date changes to the local greeting (in Tokyo, "こんばんは konbanwa"
   in the evening), ↑ ↓ arrows appear on the strip (hover them for the sunrise and sunset
   times), and a × appears at the top right.
4. Click a time (24-hour flips on every row), an offset ("+9h" ↔ "UTC+9"), and a temperature
   (°C ↔ °F). Reload Hammerspoon. The choices persist.
5. Scroll over a strip. Every clock moves in 15-minute steps, the caption turns accent with
   "+1h", and 2.5 s after you stop everything snaps back.
6. Click a row. The little globe turns to that city. Click the caption to return to home.
7. Click **+ Add a city** and type `lyon`. "Lyon Europe/Paris UTC+1" is listed. Type
   `springfield`: after "Searching places…", geocoder results such as "Springfield Illinois, US"
   appear. Press Return. The search window closes and a new row appears.
8. Open **+ Add a city** again and drag a city in "Your cities" to a new position. The panel
   reorders to match. Click × in that list, or on a hovered row, to remove a city.
9. Click the caption (with no row focused). "Where are you?" opens. Pick a town on your
   own zone: the caption and the home row are renamed. Pick a town on another zone: a toast
   appears and Date & Time settings open.
10. Click the little globe. The globe shows coastlines, the gold day/night line, and city
    dots with names. Scroll sideways to spin it and up/down to tilt it. Click a city to see
    its name, time and zone below. Click × to go back.
11. Bind `elsewhen.toggle` to Super+Ctrl+Alt+E. The chord opens and closes the panel.
12. `grep -i springfield ~/.local/state/omarchy-mac/hs.log` should find nothing.
