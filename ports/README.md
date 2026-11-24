# Generated ports

Native macOS ports of Omarchy shell plugins, produced by `omarchy-port generate` (or by a cloud
agent following `omarchy-mac/port/BRIDGE.md`). Each directory holds:

- `hammerspoon/<id>.lua`: backend module (installed to `~/.hammerspoon/omarchy/ports/`)
- `widget/omarchy-<id>/`: OmniShell bar widget (installed to `~/.config/omniwm/shell/widgets/`)
- `PORT.md`, `port.json`: mapping notes, gaps, suggested hotkeys, status

Ports here are **not validated on a Mac until** `omarchy-port validate <id>` passes. To use one:
copy it to `~/.config/omarchy-mac/port/out/<id>/`, then `omarchy-port validate <id>` and
`omarchy-port install <id> [--bar]`.
