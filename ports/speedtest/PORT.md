# omarchy.speedtest → macOS (`speedtest`)

**Status: ported** · **Bar placement: none** (Omarchy kind `panel`, summoned from the menu) ·
**Requires: nothing** (`/usr/bin/networkQuality` ships with macOS 12+)

## What it does
An internet speed test that you open on demand. Opening it starts a fresh run, and
dismissing it stops the traffic. Omarchy's shared `SpeedTestOverlay` has no card. Over a deep
near-black scrim (black @ 78 %) float the title (the connection under test, uppercase, dim
white) and two dials, **DOWNLOAD** and **UPLOAD**, in **Mbps**. Each dial has:
- an open 270° scale with its gap at the bottom, a faint tick ring (46 ticks, every fifth a major),
- an accent value arc with a soft under-glow,
- a hubless gradient needle,
- the digital readout (one decimal under 10),
- the direction printed in the gap.

On opening, both needles sweep to full scale and back (the "ignition"). The dial that is not
measuring yet sits at 50 % until it has a figure. Both dials share one full-scale latch
(100 → 250 → 500 → 1000 → 2500 → 5000 → 10000 Mbps), which grows when a reading passes
92 % of the current stop. A bordered **Run Again** button (tooltip "Measure again via …")
fades in when the run ends, and any error shows below it in red (#ff6b6b). Esc, a click on the
scrim, or `shell hide` dismisses the overlay. Return runs it again.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `SpeedTestOverlay` (layer-shell overlay, exclusive keyboard) | Full-screen, transparent, borderless `hs.webview` at `modalPanel` level on the screen under the pointer. It has its own `omarchy_speedtest` message handler. SVG dials reproduce the QML geometry: 210 px diameter, 4 px arc, 12 px glow at 18 %, needle 0.32 × diameter, readout 24 px bold, captions 10 px, 48 px between dials, and the same easing and durations (600 ms glide, 550 + 650 ms ignition, 400 ms scale). The accent comes from the Omarchy theme. The text is fixed white on the scrim, as in Omarchy. |
| `omarchy-network-speedtest down` / `up` (streams Mbps lines) | `/usr/bin/networkQuality -c -u -M 15` (download only), then `-c -d -M 15` (upload only), run by `hs.task` with fixed arguments and no shell. The port reads `dl_throughput` / `ul_throughput` (bits/s → Mbps) from the JSON. |
| `phaseTimer` 20 s watchdog | 30 s watchdog per phase (`networkQuality` spends up to 15 s plus setup) |
| `expectedStop` / `pendingRun` / clear-phase-before-kill | Same state machine as `Panel.qml`. Reopening while a dismissed run is still exiting queues a fresh run. |
| `omarchy-network-status` → SSID or "Ethernet" | `hs.network.primaryInterfaces()` gives the primary interface. On Wi-Fi it uses `hs.wifi.currentNetwork()` (the SSID, when Location permission lets Hammerspoon see it) or "Wi-Fi"; on `enN` it shows "Ethernet". |
| Payload `{"connection": "MyWifi"}` | `speedtest.open` with optional `x = connection name` (display only, 64 chars, escaped) |
| `shell summon omarchy.speedtest` (menu *Trigger > Tests > Network Speed Test*) | `speedtest.open` (`speedtest.toggle`) |
| Esc / scrim / `shell hide` | `speedtest.close`, Esc, a scrim click, or the overlay losing focus |
| Run Again | The button, Return, or `speedtest.run` |

The module also publishes a summary to the OmniShell var `omarchy_speedtest`:
`{v, open, running, phase, download, upload, error}` (Mbps). It is there for scripts or a
future widget. The port has no bar widget, because the plugin has none.

## Hotkeys to bind (Omarchy chords → actions)
Omarchy 4.5 defines no chord for the speed test (it lives in the menu). To add one, put it in
`~/.config/omarchy-mac/bindings.toml`, e.g. `hs = "speedtest.toggle"`.

| Omarchy chord | Action |
|---|---|
| (none; menu *Trigger > Tests > Network Speed Test*) | `speedtest.toggle` |

## Safety
- No shell, and an absolute path (`/usr/bin/networkQuality`) with constant arguments. The
  only URL argument is the optional connection name. It is only ever shown, through
  `textContent`; it is never passed to a process or used to build markup.
- The page's messages are checked (`close`, `again`, `ready` booleans only). A run is never
  started unless the overlay is open and idle.
- Dismissing the overlay terminates `networkQuality` right away, so no traffic continues
  behind a closed overlay. `M.stop` does the same on reload.
- No new permissions. Reading the SSID uses the Location permission Hammerspoon already has;
  without it the title just says "Wi-Fi". Note: `networkQuality` uses real data on your
  plan, as Omarchy's test does.

## Gaps (honest list)
- **No per-second live figures.** Omarchy's client streams a reading every second. Apple's
  `networkQuality -c` prints one JSON result when each direction finishes. While a phase runs,
  its dial is live (full opacity, at 0) and settles on the measured capacity when the phase
  ends. Parsing the human-readable progress output instead would be fragile across macOS versions.
- **Different methodology and server.** `networkQuality` measures saturated capacity against
  Apple's CDN (it runs several parallel flows), while Omarchy's client tests against
  `speed.omarchy.org`. Expect somewhat different numbers. The tooltip says "Measure again via
  networkQuality".
- Each phase is capped at 15 s (`-M 15`), so a full run takes about 30 s.
- The overlay closes when it loses focus (for example Cmd-Tab). Omarchy's exclusive layer
  surface cannot lose focus in this way.
- Strings are English only, and numbers use plain digits (no `I18n.formatNumber`). There is no
  right-to-left mirroring.

## Test steps
1. Install the port, reload Hammerspoon, and check `~/.local/state/omarchy-mac/hs.log` has
   no `speedtest:` errors.
2. `open -g 'hammerspoon://omarchy?a=speedtest.open'`. The screen dims, and the Wi-Fi name
   (or WI-FI / ETHERNET) appears above two dials. Both needles sweep to full scale and back.
   The DOWNLOAD dial is at full opacity and UPLOAD is at 50 %.
3. After about 15 s the download needle glides to the measured Mbps (the scale latches up if
   needed) and UPLOAD becomes live. After about 15 s more, it settles too and **Run Again**
   fades in. Hover over it to see "Measure again via networkQuality".
4. Press Return (or click Run Again). Both dials reset and a new run starts.
5. Press Esc during a run. The overlay closes, and `pgrep networkQuality` finds nothing a
   moment later.
6. Turn Wi-Fi off and open it again. A red error line appears instead of figures.
7. `open -g 'hammerspoon://omarchy?a=speedtest.open&x=Office%20LAN'` puts OFFICE LAN in the title.
