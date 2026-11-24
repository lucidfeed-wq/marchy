# omarchy-mac

**[Omarchy](https://omarchy.org)'s desktop, rebuilt natively for macOS.** Hold Caps Lock as
Super, tile windows the Hyprland way, use Omarchy's keybindings, its bar, menu, themes and
pickers, and convert Omarchy shell plugins (including the 6,900+ in the
[Omarchy plugin marketplace](https://github.com/omacom/omarchy-plugin-marketplace)) into
native Mac ports automatically.

> Targets Omarchy **4.5 "Quattro RS"** · Apple Silicon · macOS 26+

## What you get

| Omarchy (Linux) | omarchy-mac |
|---|---|
| Super key | **Caps Lock** held = Super (Karabiner-Elements), tap = Escape. Real held modifiers, so Super+drag works and shortcuts **keep working during macOS Secure Input** (password fields, e-signing). |
| Hyprland dwindle tiling, workspaces 1–9, scrolling layout | [OmniWM](https://omniwm.app) (dwindle + niri-style scrolling), instant workspaces, gaps 5/10, accent border |
| Omarchy keybindings (`Super+Return`, `Super+W`, `Super+1..9`, `Super+Shift+arrows`, `Super+Ctrl+T`, …) | 150+ bindings from **one file**, `bindings.toml`, generated into Karabiner, OmniWM and Hammerspoon (`omarchy-keys`) |
| Omarchy bar | OmniShell bar: logo, workspaces, clock, **menu-bar tray mirrored into the bar**, interactive Wi-Fi and Bluetooth panels |
| `Super+Space` menu, `Super+K` keybindings | Omarchy menu with type-to-search (Hammerspoon chooser), searchable keybinding list |
| Theme picker / background picker | Image-grid pickers; one switch restyles Ghostty, Neovim, btop, the bar, borders, wallpaper and light/dark mode (all 23+ official Omarchy themes) |
| Super+drag move/resize, Super+scroll | Same |
| Omarchy shell plugins | **`omarchy-port`**: converts plugins to native ports (see below) |

## Install

```sh
git clone https://github.com/<you>/omarchy-mac ~/omarchy-mac
~/omarchy-mac/bootstrap.sh            # --dry-run to preview
```

`bootstrap.sh` installs the stack with Homebrew, fetches Omarchy's themes, backs up your
current config, installs everything, then lists the macOS permissions to approve.
Afterwards: `omarchy-doctor --static` (health check) and `omarchy-doctor --interactive`
(guided test of your real keys, including a forced Secure Input pass).

Undo: `~/omarchy-mac/rollback.sh` restores the most recent backup.

## How it fits together

```
Caps Lock ──► Karabiner-Elements ──► held Ctrl+Opt+Cmd ("Super")
                     │                    │
                     │                    ├─► OmniWM native hotkeys (window/workspace actions, Carbon)
                     │                    └─► Hammerspoon hs.hotkey (apps, menu, pickers, screenshots)
                     └─► Super+Ctrl / Super+Alt layers, Citrix-safe rules ─► shell_command
                                                     (omarchy-wm / hammerspoon://omarchy?a=…)
OmniShell bar widgets ◄── omniwmctl shell set <json> ── Hammerspoon backends (tray, Wi-Fi, BT, ports)
OmniShell widget clicks ──► hammerspoon://omarchy?a=<action> ──► Hammerspoon
```

Nothing reads the keyboard through event taps (they go blind under Secure Input and can leave a
modifier stuck). Bindings are Carbon hotkeys or Karabiner rules.

| Path | What |
|---|---|
| `omarchy-mac/bindings.toml` | every shortcut (edit, then `omarchy-keys install`) |
| `omarchy-mac/bin/` | `omarchy-keys` (generator), `omarchy-theme`, `omarchy-wm`, `omarchy-omniwm-set`, `omarchy-doctor`, `omarchy-port` |
| `hammerspoon/` | menu, launchers, pickers, tray, Wi-Fi/Bluetooth backend, layout guard, ports loader |
| `omniwm-shell/` | bar layout + Omarchy widgets |
| `omarchy-mac/port/` | the converter's contract and Linux → macOS capability map |
| `deploy.sh` / `rollback.sh` | install with backups / restore |

## Converting Omarchy plugins: `omarchy-port`

Omarchy 4.5's shell is a set of Quickshell (QML) plugins, which only run on Linux. `omarchy-port`
reads a plugin's source, maps each Linux service it uses to a macOS equivalent
(`capabilities.toml`), and has a headless Claude agent write a native port (an OmniShell bar
widget plus a Hammerspoon backend) in an isolated sandbox. It then validates the port
(compiles in Hammerspoon, loads in OmniWM, actions exist and are namespaced, privacy lint)
before you install it.

```sh
omarchy-port sync                    # fetch Omarchy's source (v4.5.0)
omarchy-port analyze                 # 32 plugins: native / portable / partial / skip / not portable
omarchy-port generate osd audio      # or --all
omarchy-port validate --all
omarchy-port install osd --bar

omarchy-port market weather          # search the Omarchy plugin marketplace (security flags shown)
omarchy-port add carl.weather        # fetch a listed plugin at its validated commit
omarchy-port add owner/repo          # or any GitHub repo with an Omarchy manifest.json
```

Third-party plugin code is only *read* by the converter and treated as untrusted data, never run.
Every port is validated, and nothing is installed without `omarchy-port install`. Generation needs
the [Claude Code](https://claude.com/claude-code) CLI.

## Safety design

- **Secure Input:** Super chords include Ctrl/Cmd and are Carbon hotkeys or Karabiner rules, so
  they survive password fields. `omarchy-doctor --secure-input` proves it.
- **No Full Disk Access, no Screen Recording, no SIP changes.** The menu-bar tray uses
  Accessibility only.
- **Remote desktops (Citrix Viewer):** Caps Lock sends no stray modifiers into the session, and
  every binding is served by Karabiner there.
- **Privacy:** notification, clipboard and window-title content is never logged; the tray
  mirror skips OmniWM's own item because it shows window titles.

## Limits (macOS, not this project)

Hyprland animations and blur, per-window opacity (except Ghostty), replacing the lock screen or
the password prompt, and moving native menus under the tray icon you clicked.

## Credits

[Omarchy](https://github.com/basecamp/omarchy) (MIT): design, keybindings and themes; themes are
fetched from its release at install time. [OmniWM](https://github.com/OmniNull/OmniWM) (GPL-2.0):
tiling and the bar runtime; installed via Homebrew and not vendored here.
[Karabiner-Elements](https://karabiner-elements.pqrs.org), [Hammerspoon](https://www.hammerspoon.org),
[Ghostty](https://ghostty.org), [blueutil](https://github.com/toy/blueutil).
