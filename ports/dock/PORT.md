# omarchy.dock → macOS (`dock`)

**Status: partial** · **Bar placement: none** (Omarchy kind `service`, no bar presence) · **Requires: nothing** (Hammerspoon built-ins; `/usr/bin/open`)

## What it does
Omarchy's dock is a transparent strip of app icons along one screen edge, shown on floating
workspaces, plus an "all apps" grid.

| Part | Behaviour (as in Omarchy) |
|---|---|
| Strip | First slot: an "all apps" button drawn as a 3×3 grid of squares in the bar text colour. Then pinned apps in pin order, then running apps that are not pinned, in the order they were first seen. 36 px icons in 48 px square slots, 3 px from the edge. |
| States | Pinned but not running: 70 % opacity. Launching: pulses between 100 % and 70 % (500 ms) until the app opens a window, 10 s at most. Hovered icon pops out 1.15× away from the edge. |
| Click | Brings the app's next window forward: windows on screen first, then minimized ones (restored), then the rest; clicking again while one is focused moves on. An app with no window is launched. |
| Middle click | Launches the app again. |
| Right click (app) | **New Window** (running) · **Keep in Dock** / **Remove from Dock** · **Quit** (running). |
| Right click (apps button) | **Top / Bottom / Left / Right** (✓ on the current one) · **Auto-hide** ✓. |
| Drag | Drag an icon along the dock to reorder it; dropping pins it in that slot (`DockModel.js` `orderWithKeyAt` / `pinsInOrder`). |
| Auto-hide | The dock waits off screen until the pointer touches the edge strip below it, and tucks away 150 ms after the pointer leaves. |
| App grid | Full-screen scrim (background @ 50 %) with a card of every app: 56 px icons, two-line names, up to 7 columns × 4 rows, scrolls. Type to filter ("Search apps…", "No apps match “…”"), arrows move, Return launches, Backspace edits, Esc clears the filter, then closes. Clicking the scrim closes it. Right click an app: **Open** · **Keep in Dock** / **Remove from Dock**. |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `DockWindow` (layer-shell `PanelWindow`, keyboard focus none, empty input mask while hidden) | `hs.canvas` at the `dock` window level with `clickActivating(false)`: clicking an icon never takes focus from the app you are in (the EMR included). Joins all Spaces; not drawn over full-screen apps. Its frame is only the strip (plus the menu while one is open), so the rest of the screen stays clickable. |
| "Shown on floating workspaces" (`omarchy-hyprland-workspace-layout-current`) | **No equivalent.** OmniWM 0.8 workspaces only have the niri and dwindle layouts (`IPCWorkspaceLayout`: default/niri/dwindle). Floating is per window, so no workspace is ever "floating". The dock is shown and hidden explicitly with `dock.toggle` / `dock.show` / `dock.hide`, and stays that way across reloads. |
| `DesktopEntries`, `Hyprland.toplevels` | Running apps from `hs.application.runningApplications()` (regular apps only: `kind() == 1`), kept up to date by `hs.application.watcher` (launched/terminated). Windows come from `app:allWindows()` (standard windows only). Window titles are never read. |
| `appLibrary.launch(entry)` | `/usr/bin/open -b <bundle id>` through `hs.task`. The id must come from this module's own lists: the scanned app folders, the saved pins, or running apps. |
| `bringForward()` (`hyprctl dispatch focus / alter_zorder`, restore from `special:minimized`) | `hs.window:unminimize()` when minimized, then `hs.window:focus()`. |
| `quit()` (close every toplevel) | `hs.application:kill()` (a normal Quit; the app may ask to save). |
| "New Window" (launch the entry again) | The app's own **File › New Window** menu item (`selectMenuItem`), else `open -b` (macOS reopens the app). |
| `omarchy-dock pinned/pin/unpin/position/autohide` (`shell.json`) | `~/.local/state/omarchy-mac/dock.json` (bundle ids, position, auto-hide, shown). Default pins are Omarchy's mapped to Mac apps: Finder, Chrome, Ghostty, Calculator, TextEdit (only those installed are shown). |
| `AppGrid` (`OverlayWindow`, scrim, `BorderSurface` menu colours) | Borderless, transparent `hs.webview` at `modalPanel` level, like `omarchy/picker.lua`, with its own message handler `omarchy_dock`. Apps come from `/Applications` (and one level of subfolders), `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, `~/Applications`. Agent/background apps (`LSUIElement`, `LSBackgroundOnly`) are left out, as Omarchy leaves out `NoDisplay` entries. Icons are `hs.image.imageFromAppBundle()` encoded as PNG data URLs and sent in batches of 12 after the grid is on screen, so opening it never stalls. Names are inserted with `textContent` (never as HTML). Every message from the page is checked against the scanned list. |
| `ShellIpc omarchy.dock apps()` (Super+Alt+Space) | `dock.apps` |
| `ShellIpc omarchy.dock refresh()` | Not needed: the dock follows app launches and quits by itself. |

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys. Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `SUPER + ALT + SPACE` | `dock.apps` |
| (none in Omarchy: the dock follows the workspace layout) | `dock.toggle` (suggested: any free chord) |

Other actions: `dock.show`, `dock.hide`, `dock.position` (x = `top|bottom|left|right`),
`dock.autohide` (x = `on|off|toggle`). For example:
`open -g 'hammerspoon://omarchy?a=dock.position&x=left'`.

## Safety
- No window titles or window contents are read, logged or stored. Only bundle ids, the
  position, auto-hide and shown/hidden are saved.
- The canvas never activates Hammerspoon (`clickActivating(false)`), so using the dock never pulls
  keyboard focus away from Citrix Viewer or anything else. Clicking a Citrix Viewer icon only
  focuses its window, the same as the macOS Dock does.
- URL arguments are enums only (`dock.position`, `dock.autohide`). Launching takes a bundle id from
  the module's own lists, never from a URL or the page, and runs `/usr/bin/open -b <id>`
  without a shell.
- No polling. The 0.5 s pulse timer runs only while a launched app is starting (10 s at most).
  The app grid's icon feed is a short one-shot chain. Everything stops in `M.stop`.
- No new permissions. `selectMenuItem` and window focus use the Accessibility permission
  Hammerspoon already has.

## Gaps (honest list)
- **Automatic show on floating workspaces**: not possible (see mapping). The dock is an explicit
  toggle and appears on the focused screen only, not one per screen.
- **Maximized windows** do not switch the dock to auto-hide, as Omarchy's `fullscreenMode === 1`
  does. Hammerspoon cannot tell "maximized" from a large window.
- **Drag from the app grid onto the dock** (Omarchy's external drag) is not ported. Use
  right click › Keep in Dock in the grid. Dragging inside the dock works, but the live
  "step aside" preview appears only if Hammerspoon delivers mouse-move events while the button is
  held (see "unsure" below). The drop itself is worked out from the press and release positions.
- **Uninstall** (grid right click › Uninstall, Delete key) is deliberately not ported. Moving
  apps to the Trash from an overlay is too risky on this machine.
- **No slide animation** for auto-hide (it shows and hides at once), and no drop-in animation.
- **Closing the menu**: Omarchy closes the menu on any click outside it (focus grab). Here it
  closes 0.6 s after the pointer leaves the dock, or when you pick a row.
- **Fuzzy search**: the grid ranks prefix, word-prefix, then substring matches. It is not
  Omarchy's `appLibrary.sortedEntries` scorer.
- **Right-to-left mirroring** of the menu is not reproduced.

## Test steps
1. Install, reload Hammerspoon, then check `~/.local/state/omarchy-mac/hs.log` has no `dock:` errors.
2. `open -g 'hammerspoon://omarchy?a=dock.toggle'`. Expected: a strip at the bottom centre, above the
   macOS Dock: the 3×3 apps button, then Finder, Chrome, Ghostty, Calculator, TextEdit
   (pinned ones that are not running look faded), then other running apps.
3. Hover an icon. It should grow 1.15× upward. Click a running app: its window comes forward, and the
   frontmost app before the click must not flash or lose focus first. Click it again: the
   next window of that app comes forward.
4. Click a faded (not running) pin. It should pulse until the app opens a window, then show at full opacity.
5. Right click an app, then choose Remove from Dock: it disappears once it is no longer running. Right click a running
   unpinned app, then choose Keep in Dock: it is pinned at the end. Check `~/.local/state/omarchy-mac/dock.json`.
6. Drag an icon two slots to the right and release. It should move there and become pinned.
7. Right click the apps button, then choose Left: the dock moves to the left edge, centred vertically. Choose Auto-hide:
   the dock disappears. Touch the left edge: it comes back, and leaving makes it tuck away again.
8. Bind `dock.apps` to Super+Alt+Space and press it. Expected: the app grid. Type "saf": only matching apps.
   Use arrows and Return to launch one. Esc clears the filter, and a second Esc closes the grid with focus back where it was.
   Right click an app, then choose Keep in Dock: it appears in the dock.
9. With Citrix Viewer focused, click dock icons for other apps. Citrix must not receive any
   keystrokes and nothing must be typed. Focus simply moves to the clicked app.
10. `open -g 'hammerspoon://omarchy?a=dock.hide'`. The strip disappears, and stays hidden after reload.
