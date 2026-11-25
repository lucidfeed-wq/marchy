# Marchy

**[Omarchy](https://omarchy.org)'s keyboard-driven desktop, rebuilt natively for macOS, as a Mac app.**
Hold Caps Lock as Super, tile windows the Hyprland way, use Omarchy's keybindings, bar, menu,
themes and pickers, and convert Omarchy plugins (including the 6,900+ in the
[Omarchy plugin marketplace](https://github.com/omacom/omarchy-plugin-marketplace)) into native
Mac versions with the AI account you already have.

> Unofficial. Not affiliated with Omarchy, 37signals or Basecamp.
> Targets Omarchy **4.5 "Quattro RS"** · Apple Silicon · macOS 26+

## Install

```sh
brew tap lucidfeed-wq/marchy
brew trust lucidfeed-wq/marchy      # Homebrew asks you to trust third-party taps
brew install --cask marchy
```

or download `Marchy-<version>.dmg` from [Releases](../../releases) and drag Marchy to Applications.
Open Marchy and press **Set Up** on the Home screen: it installs the stack with Homebrew, fetches
Omarchy's themes, backs up your current config and installs the Omarchy layer. Then approve the
macOS permissions it lists (each has an **Open** button).

> Marchy is not notarized yet. The first time, macOS may say it can't be opened: go to
> System Settings > Privacy & Security and click **Open Anyway**.

## The app

| Screen | What it does |
|---|---|
| **Home** | Set up / Update / Undo, component status, permission shortcuts, health check |
| **Plugins** | Ready-made ports (install with one click), the Omarchy marketplace, any GitHub repo, and the plugins you converted |
| **AI** | Connect the AI that converts plugins (below) |
| **Themes** | All official Omarchy themes; one click restyles everything |
| **Shortcuts** | Every keybinding, searchable; edit `bindings.toml` and apply |

A menu-bar icon gives quick access to themes and reloading.

### Bring your own AI

Converting a plugin means rewriting Linux (Quickshell/QML) code as a Mac bar widget and backend,
so Marchy uses an AI for it. Marchy has no account or server of its own; conversions run on
**yours**, one of three ways:

| How | Providers |
|---|---|
| **Local CLI** (your subscription) | Claude Code (Claude account), Codex (ChatGPT account), Grok CLI (xAI/X account). Marchy's **Sign In** opens the CLI's own login. |
| **Linked account** | OpenRouter: **Sign in with OpenRouter** (OAuth), and Marchy receives a key for your account. |
| **API key** | Anthropic, OpenAI, xAI, OpenRouter, Google Gemini, or any OpenAI-compatible server. Keys live in the macOS Keychain. |
| **On this Mac** | Ollama (no account; needs a large model for good results). |

Agent CLIs run in a sandbox folder with no MCP servers and may only read/write that folder and
run `luajit`. API models get no tools at all: they return files as text, which Marchy checks
(Lua compile, contract, privacy lint, widget load) and sends back for fixes, up to two rounds.

The ready-made ports under **Plugins > Included** need no AI.

## What you get

| Omarchy (Linux) | Marchy |
|---|---|
| Super key | **Caps Lock** held = Super (Karabiner-Elements), tap = Escape. Real held modifiers, so Super+drag works and shortcuts **keep working during macOS Secure Input** (password fields, e-signing). |
| Hyprland tiling, workspaces 1–9, scrolling layout | [OmniWM](https://omniwm.app) (dwindle + niri-style scrolling), instant workspaces, gaps, accent border |
| Omarchy keybindings | 150+ bindings from **one file**, `bindings.toml`, generated into Karabiner, OmniWM and Hammerspoon |
| Omarchy bar | OmniShell bar: logo, workspaces, clock, weather, media, menu-bar tray mirrored into the bar, interactive Wi-Fi/Bluetooth/audio panels |
| `Super+Space` menu, `Super+K` keybindings | Omarchy menu with type-to-search; searchable keybinding list |
| (macOS menu bar) | Hidden behind the Omarchy bar; **`Super+/`** searches every menu command of the app in front (type "csv" → File › Export To › CSV…) |
| Theme and background pickers | Image-grid pickers; one switch restyles Ghostty, Neovim, btop, the bar, borders, wallpaper and light/dark mode |
| Omarchy shell plugins | 20 ready-made ports + the converter for any other |

## Command line

Everything the app does is also a command (installed in `~/.local/bin`):

```sh
omarchy-doctor --static              # health check (--interactive: guided key test)
omarchy-theme set tokyo-night
omarchy-keys install                 # regenerate shortcuts after editing bindings.toml

omarchy-port providers               # AI providers and their sign-in status
omarchy-port provider set claude-code      # or: codex, grok, anthropic, openai, xai, openrouter, gemini, ollama
omarchy-port provider key anthropic        # store an API key in the Keychain (reads stdin)
omarchy-port market weather          # search the marketplace (security flags shown)
omarchy-port add carl.weather        # fetch a listed plugin at its validated commit (or owner/repo, URL)
omarchy-port analyze && omarchy-port generate <port id> && omarchy-port validate <port id>
omarchy-port install <port id> --bar
```

Developers: clone this repo and run `./bootstrap.sh` (`--dry-run` to preview); Marchy.app notices
a git checkout linked at `~/.config/omarchy-mac/build` and runs setup from it.
`scripts/build-app.sh` builds the app and DMG (Command Line Tools are enough); pushing a `v*` tag
builds a release on GitHub Actions.

## How it fits together

```
Caps Lock ──► Karabiner-Elements ──► held Ctrl+Opt+Cmd ("Super")
                     │                    ├─► OmniWM native hotkeys (window/workspace actions)
                     │                    └─► Hammerspoon hs.hotkey (apps, menu, pickers)
                     └─► Super+Ctrl / Super+Alt layers, remote-desktop-safe rules ─► shell_command
OmniShell bar widgets ◄── omniwmctl shell set <json> ── Hammerspoon backends (tray, Wi-Fi, BT, ports)
OmniShell widget clicks ──► hammerspoon://omarchy?a=<action> ──► Hammerspoon
Marchy.app ──► bootstrap.sh / deploy.sh / omarchy-port / omarchy-theme / omarchy-doctor
```

Nothing reads the keyboard through event taps (they go blind under Secure Input and can leave a
modifier stuck). Bindings are Carbon hotkeys or Karabiner rules.

## Safety design

- **Secure Input:** Super chords are Carbon hotkeys or Karabiner rules, so they survive password
  fields. `omarchy-doctor --secure-input` proves it.
- **No Full Disk Access, no Screen Recording, no SIP changes.** The menu-bar tray uses Accessibility only.
- **Remote desktops (Citrix Viewer):** Caps Lock sends no stray modifiers into the session.
- **Privacy:** notification, clipboard and window-title content is never logged.
- **Third-party plugins** are only *read* by the converter, as untrusted data, never run. Only the
  port your AI writes runs, after it passes the checks and you install it.
- **Updates keep your edits:** an edited `bindings.toml` is kept (the new default is saved as
  `bindings.toml.new`), and every update backs up your config first (Home > Undo Last Update).

## Limits (macOS, not this project)

Hyprland animations and blur, per-window opacity (except Ghostty), replacing the lock screen or
the password prompt, and moving native menus under the tray icon you clicked.

## Credits

[Omarchy](https://github.com/basecamp/omarchy) (MIT): design, keybindings and themes; themes are
fetched from its release at install time. [OmniWM](https://github.com/OmniNull/OmniWM) (GPL-2.0):
tiling and the bar runtime; installed via Homebrew, not bundled.
[Karabiner-Elements](https://karabiner-elements.pqrs.org), [Hammerspoon](https://www.hammerspoon.org),
[Ghostty](https://ghostty.org), [blueutil](https://github.com/toy/blueutil).

MIT licensed.
