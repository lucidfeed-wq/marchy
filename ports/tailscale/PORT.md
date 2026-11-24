# omarchy.tailscale → macOS (`tailscale`)

**Status: partial** · **Bar placement: trailing** · **Requires: Tailscale.app** in `/Applications` (the port drives its bundled CLI `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; tested read-only against 1.104.7)

## What it does
Omarchy's Tailscale bar widget. The bar shows the Tailscale mark drawn as a 3×3 dot grid
(the "T" dots at full opacity, the rest at 24 %). It is dimmed and crossed out when Tailscale
is off, and carries a red "!" badge when the device needs login. Left click opens the panel and
right click turns Tailscale on or off.

The panel (380 pt wide, JetBrains Mono Nerd Font) has these parts:

| Section | Content |
|---|---|
| Hero | Mark, this machine's name, and a rotating status phrase ("ENCRYPTING CONNECTIONS", … 10 phrases, new one every 2.8 s with a fade) or "TAILSCALE IS DISCONNECTED". On/off switch on the right (tooltip: Turn Tailscale off / on / Authorize this device). |
| Status line | Last command error (error colour) or progress message ("Starting Tailscale login…"). It clears after 2.2 s. |
| CONNECTIONS | Shown only when there is more than one `tailscale switch` profile. Glyph U+EB01 + account label (nickname → tailnet → account → id); the selected one is bold and highlighted; `…` while a switch is running. |
| EXIT NODES | Tailnet exit nodes (U+F11E2), up to 5 recent/active Mullvad regions (U+F0582), then "+ Choose Mullvad region". That last row opens a searchable region list (city / country). Clicking a node uses it; clicking the active one stops using it. |
| MACHINES · N | Online, non-Mullvad peers sorted by name. Each row has the OS glyph (Linux U+F033D, macOS/iOS U+F0035, Windows U+F0372, Android U+F0032, other U+F07C0), the name, and `IP · DNS name`. Taildrop "Send files" (U+F048A) appears when the tailnet allows it and the peer is a target. Copy (U+F018F) opens the copy menu: name, DNS name, IPv6, IPv4. A search field appears when there are more than 8 machines; "MACHINES · n OF N" shows while it filters. Also "Loading machines…", "No machines found on this tailnet." and "No machines match." |
| Refresh | Re-polls the CLI. This replaces Omarchy's `r` key and middle click. |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `Service.qml` processes (`tailscale status --json [--peers=false]`, `exit-node list`, `switch --list --json`) | `hs.task` with argv lists only (no shell), the absolute CLI path, a 15 s watchdog that terminates hung polls |
| `refreshIntervalSec` (30, 5–3600) + 2 s startup ramp (max 15 ticks) + 600 ms refresh after an action | `hs.timer` with the same values. Interval: `hs.settings.set("omarchy.tailscale.refreshIntervalSec", n)`, clamped to 5–3600 |
| Light poll while closed, full poll when the panel opens | Full poll on every refresh, unless the tailnet has more than 500 peers. Then the poll is light, and full polls run only on `tailscale.refresh` / `tailscale.panel` / after actions. Hammerspoon cannot see when the OmniShell popout opens. |
| `Model.js` (`parseStatus`, `peerFromStatus`, `displayHostName`, `filterIPv4/IPv6`, `hasFileSharing`, `isTaildropTarget`, `parseExitNodeList`, `mullvadRegionOptions`, `parseAccounts`, `loginPlan`) | Reimplemented in Lua with the same rules. `exit-node list` columns are sliced by character, not byte, so city names with accents work. |
| Optimistic `_desired` toggle state | Same (`active` in the published JSON) |
| `tailscale up` / `down`, login URL detection (stream + 10 s timeout) → `omarchy-launch-browser` | Same commands. The URL is taken only from the CLI's own output or `AuthURL`, checked to be http(s), and opened with `/usr/bin/open <url>` |
| `tailscale switch <id>` | `tailscale.switch` (x = account id from the last published list) |
| `tailscale set --exit-node=<target>` / `--exit-node=` | `tailscale.exit-node` (x = `peer:<id>` or `region:<Country>/<City>` from the last published list). The target is that node's DNS name or IP, never URL text |
| `recentMullvadRegions` stored in the bar entry | `hs.settings` key `omarchy.tailscale.recentMullvadRegions` (region keys only, max 5) |
| Copy menu → `wl-copy` | `tailscale.copy` (x = `name\|dns\|ip\|ip6:<peer id>`) → `hs.pasteboard.setContents`, plus a "Copied <machine> IP" toast. The value is never logged. |
| `omarchy-tailscale-send <machine>` (file chooser + `tailscale file cp`) | `tailscale.send` (x = peer id) → `hs.dialog.chooseFileOrFolder` (multiple selection) → `tailscale file cp --update-interval=0 -- <files…> <machine>:`. Toasts "Sent to …" / "Could not send to …". File paths are never logged. |
| Panel / IPC `open`/`close`/`toggle` | `tailscale.panel` → `omniwmctl shell toggle omarchy-tailscale` (forces a full refresh first) |
| IPC `up` / `down` / `toggleTailscale` / `refresh` | `tailscale.up` / `tailscale.down` / `tailscale.toggle` / `tailscale.refresh` |
| IPC `status()` | Lua only: `require("omarchy.ports.tailscale").status()` (URL actions cannot return values) |
| `PanelHero`, `ToggleSwitch`, `PanelSectionHeader`, `PanelSeparator`, `CursorSurface` | OmniShell `ui.row/column/stack/box/text`, palette roles (`foreground`, `secondaryForeground`, `accent`, `error`), `look.panel`, `look.hover` |
| Phrase fade (150 ms out / 200 ms in) | A text keyed by phrase with an `appear` opacity animation (200 ms) |

The repo's `omarchy-tray` already mirrors the Tailscale.app menu-bar item into the bar. This widget
is the Omarchy-style one. Hide the mirrored item if you don't want both, using the omarchy-tray
`hide` setting with the Tailscale bundle id.

## Hotkeys to bind (Omarchy chords → actions)
Omarchy's default bindings have no Tailscale chord. The panel is reached through
`SUPER + CTRL + <1…9>` ("Bar panel N", `omarchy-shell shell togglePanelAt right N`).
If you want a key, add one to `~/.config/omarchy-mac/bindings.toml`, for example:

| Suggested chord | Action |
|---|---|
| (your choice, e.g. `SUPER + CTRL + ALT + N`) | `tailscale.panel` |
| (your choice) | `tailscale.toggle` |

## Safety
- No shell anywhere. Every command is an argv list to the absolute CLI path.
- URL arguments are validated against the state this module last published. Unknown account, exit-node,
  region or machine ids are refused and logged without the value. Exit-node targets and Taildrop targets
  come from the CLI's own data and must match `^[%w%-%.:]+$`.
- Login URLs are opened only when they come from the CLI's output or status (`AuthURL`) and look like http(s) URLs.
- Copied values, file names and paths are never logged. The CLI's argument list isn't logged either
  (the port does not use `util.run`, which logs argv on failure).
- The search fields (machines, Mullvad regions) filter inside the widget. Typed text never leaves OmniShell.
- No new permissions, no sudo, no daemons. Polls are `hs.task`, and timers are ≥ 2 s except the one-shot
  600 ms post-action refresh. `M.stop` stops every timer and terminates running tasks.
- The Taildrop file chooser is a modal `hs.dialog` panel that the user opens on purpose, like the Wi-Fi password prompt in netpanel.lua.

## Gaps (honest list)
- **Keyboard navigation inside the panel** (j/k/arrows, Enter, `c`/`n`/`d`/`s`/`t`/`r`, `/`, Esc) is not
  ported. OmniShell popouts here are mouse-driven. The Refresh row replaces `r`, and the copy menu covers `c`/`n`/`d`.
- **Middle click = refresh** on the bar icon is not mapped. Use the Refresh row or `tailscale.refresh`.
- **Authorize Tailscale operator** (`pkexec tailscale set --operator=$USER`) is Linux-only. Needing it
  would require admin rights, and the macOS app has no operator concept. If `switch --list` is refused,
  the error is shown in the status line instead.
- **Huge tailnets:** at most 300 machines are published to the widget (no virtualised list in OmniShell, and
  the JSON goes through `omniwmctl` argv). The search only covers those 300, and a note says so. Above 500
  peers, polls between refreshes are light (`--peers=false`).
- **Exit-node and Mullvad commands on macOS:** `tailscale set --exit-node=…`, `up`, `down` and `switch` are
  supported by the macOS app's CLI (`--help` lists them), but they were not exercised here (only read-only
  commands were run). Some App Store builds may refuse CLI changes. Errors then appear in the status line.
- **Receiving Taildrop files:** Omarchy's `omarchy-tailscale-receive` service isn't needed. Tailscale.app on macOS receives files itself.
- **No per-profile scroll memory or cursor rings:** OmniShell has its own scrolling, and the copy menu opens inline under the row rather than as a floating popup.
- Phrases, labels and number formatting are English only (Omarchy's I18n isn't reproduced).

## Test steps
1. `omarchy-port install tailscale --bar`, reload Hammerspoon, and check `~/.local/state/omarchy-mac/hs.log` for `ports: tailscale loaded` and no `tailscale:` errors.
2. With Tailscale connected, the bar shows the dot-grid mark in the foreground colour. Hover it: you should see "Tailscale: connected".
3. Left click. The hero should show this Mac's name, the switch on, phrases rotating about every 3 s, and MACHINES · N listing online peers with their OS glyphs and `100.x · name.tailnet.ts.net`.
4. Click the copy glyph on a peer, then "100.x…". Expected: a "Copied <name> IP" toast and that IP in the clipboard. Check the log has no IP.
5. Right-click the bar icon. The mark should dim and cross out immediately, `tailscale status` should report stopped, and the panel should say "TAILSCALE IS DISCONNECTED". Right-click again to reconnect.
6. If you have more than one account: click the other CONNECTIONS row. You should see `…`, then the tailnet switch and new machines.
7. If exit nodes or Mullvad are available: pick one. It should become bold and highlighted and `tailscale status` should show the exit node. Click it again to stop using it. Open "Choose Mullvad region", type a city to filter, then pick one. It should then appear in the recent list.
8. On a peer with the send glyph, click it, choose a file, and send. Expected: a "Sent to <machine>" toast, and the file arrives on the peer.
9. `open -g 'hammerspoon://omarchy?a=tailscale.copy&x=ip:bogus'`. Nothing should be copied, and the log should say "copy refused".
10. Bind `tailscale.panel` and press the chord. The popout should open under the widget.
