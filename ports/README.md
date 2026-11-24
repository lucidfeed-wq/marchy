# Generated ports

Native macOS ports of Omarchy shell plugins, produced by `omarchy-port generate` (or by a cloud
agent following `omarchy-mac/port/BRIDGE.md`). Each directory holds:

- `hammerspoon/<id>.lua`: backend module (installed to `~/.hammerspoon/omarchy/ports/`)
- `widget/omarchy-<id>/`: OmniShell bar widget (installed to `~/.config/omniwm/shell/widgets/`)
- `PORT.md`, `port.json`: mapping notes, gaps, suggested hotkeys, status

Ports here are **not validated on a Mac until** `omarchy-port validate <id>` passes. To use one:
copy it to `~/.config/omarchy-mac/port/out/<id>/`, then `omarchy-port validate <id>` and
`omarchy-port install <id> [--bar]`.

## Ports in this directory

None of these have been validated on a Mac yet (`omarchy-port validate` not run). They have been
statically checked: luajit and luac 5.4 compile them, luau-analyze checks the widgets against
OmniWM 0.8.0's `omniwm.d.luau`, plus action namespacing and the privacy lint. Each `PORT.md`
lists the gaps.

| Port | Omarchy plugin | Status | Bar | Requires |
|---|---|---|---|---|
| agents | omarchy.agents | partial | trailing | nothing (Claude, Codex, Grok only) |
| audio | omarchy.audio | partial | trailing (replaces `volume`) | nothing |
| battery | omarchy.battery | partial | none | nothing |
| clipboard | omarchy.clipboard | partial | none | nothing |
| disk-speedtest | omarchy.disk-speedtest | ported | none | nothing |
| dock | omarchy.dock | partial | none | nothing |
| elsewhen | omarchy.elsewhen | partial | trailing | `omarchy-port sync` (optional data) |
| emojis | omarchy.emojis | ported | none | `omarchy-port sync` (emoji data; small built-in fallback) |
| idle | omarchy.idle | ported | none | nothing |
| media | omarchy.media | partial | trailing | nothing |
| monitor | omarchy.monitor | partial | trailing | optional `betterdisplaycli` |
| nightlight | omarchy.nightlight | partial | trailing | optional `nightlight` (brew smudge/smudge/nightlight) |
| notifications | omarchy.notifications | partial | trailing | nothing (optional Shortcuts for Focus) |
| osd | omarchy.osd | ported | none | nothing |
| power | omarchy.power | partial | trailing (replaces `battery`) | nothing |
| reminders | omarchy.reminders | ported | trailing | nothing |
| speedtest | omarchy.speedtest | ported | none | nothing (`/usr/bin/networkQuality`) |
| tailscale | omarchy.tailscale | partial | trailing | Tailscale.app |
| weather | omarchy.weather | partial | trailing | `[weather]` location in OmniWM `shell.toml` |
| wifiqr | omarchy.wifiqr | ported | none | nothing |
