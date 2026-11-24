# omarchy.notifications → macOS (`notifications`)

**Status: partial** · **Bar placement: trailing** (Omarchy's Do Not Disturb indicator, `bar/indicators/Dnd.qml`) · **Requires: nothing** (Hammerspoon built-ins; optional `/usr/bin/shortcuts` with two user-made Shortcuts for macOS Focus sync)

## What it does
Omarchy's notification daemon draws notifications as cards in a deck that hangs from the
top-right corner, under the bar.

**Cards**
- Each card is 380 px wide, with a 2 px accent border on the theme background and 12 px side
  padding.
- On the left is a 40 px picture: the app icon, a glyph, or the source's first letter on a faint tile.
- Then a bold summary (up to 3 lines) and a dimmer body (2 lines, 8 when open).
- On the right is a relative time (blank under 5 min, then `12m`, `14:05`, `yesterday`, `Mon`).
  It turns into ✕ while the card is hovered.
- Action buttons sit along the bottom, 3 per row, divided by thin rules.

**Stacks and hover**
- Cards from the same app stack into one deck. The cards behind the front one peek 10 px below
  it, slightly smaller. Up to 3 are drawn, the last at 55 %.
- Hovering a deck opens it to list every card. New cards wait while you read (30 s at most), and
  timers pause.

**Lifetime and clicks**
- Low urgency lasts 5 s, normal 8 s (stretched to at most 30 s if the sender asks), critical
  until dismissed.
- Left click activates a card. Right or middle click, or ✕, dismisses it.

**Do Not Disturb**
- DND silences cards straight into history. Omarchy's own action toasts and bare critical alerts
  still get through. The state survives a reload.
- In the bar, the 󰂛 indicator shows DND and toggles it.

**Keybindings**
- Act on the newest card.
- Dismiss the newest card, or all cards.
- Replay the last 6.
- Hand the keyboard to the deck: arrows or j/k move, Return clicks, Delete dismisses, 1–9 press a
  button, Esc leaves. Keyboard mode also ends after 10 s idle.
- Toggle DND.

## Why "partial": whose notifications
Omarchy replaces the system's notification server, so every app's notifications go through it.
On macOS, reading other apps' notifications (Notification Center's database, or OmniWM's
`ctx.data.notifications`) needs **Full Disk Access**, which this machine must not grant. So:

- **Other apps' notifications** stay with macOS Notification Center. `notifications.center` opens
  it through the built-in `notification-center` action.
- **omarchy-mac's own notifications** get the full Omarchy deck. Any Hammerspoon module can post
  one:

```lua
local n = package.loaded["omarchy.ports.notifications"]   -- or require("omarchy.ports.notifications")
local key = n and n.post{
  app = "Backups",                 -- groups cards into a deck; also the letter tile
  summary = "Backup finished",     -- bold headline
  body = "42 files copied",        -- optional, wraps to 2 lines (8 when the deck is open)
  glyph = "\u{F00C}",              -- optional Nerd Font glyph instead of the letter
  bundle = "com.apple.finder",     -- optional: shows its app icon; click focuses that app
  urgency = "normal",              -- "low" (5 s) | "normal" (8 s) | "critical" (stays)
  duration = 12000,                -- optional ms, at most 30000
  actions = { { label = "Open", fn = function() ... end } },   -- up to 9 buttons
  onClick = function() ... end,    -- optional: what a click on the card does
  onClose = function(reason) end,  -- "dismissed" | "expired" | "activated"
  replaces = previousKey,          -- optional: update a card in place
  transient = false,               -- true: never kept in history
  bypassQuiet = false,             -- true: shows through Do Not Disturb (like omarchy-action)
}
-- n.dismiss(key), n.dismissAll(), n.setDoNotDisturb(true|false), n.isDnd()
```

There is deliberately **no URL action that takes notification text**, because
`hammerspoon/omarchy/url.lua` logs every URL argument. URL actions take only enums and digits.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `NotificationServer` (D-Bus) | `M.post{...}` Lua API for omarchy-mac modules (see above). Other apps: see "Why partial". |
| Deck surface (overlay layer, top-right, `Delivery.deckMargins`) | One `hs.canvas` at `overlay` level with `clickActivating(false)`, so clicking a card never takes focus from the app you are in. It joins all Spaces and shows over full-screen apps, like Omarchy's surface does once a card arrives. It sits 5 px (`Style.gapsOut`) from the right edge and below the menu bar, plus the OmniWM bar height when that bar is `belowMenuBar`. A deck stays on the screen it started on until it empties. |
| `Toast.qml` (BorderSurface, Liberation Sans, `Style.font.*`) | The same geometry and sizes. Liberation Sans is used if installed, else Arial (metric-compatible). JetBrainsMono Nerd Font is used for the glyph, stamp, ✕ and buttons. The dim text and body colours are computed like `Qt.darker(text, 1.4 / 1.15)`. Text is word-wrapped in Lua with measured widths and ends in … when cut. |
| `Layout.js` (PEEK 10, SHRINK 0.035, VISIBLE 3, FADE 0.55, gaps 6/12) | Ported 1:1. The cards behind the front one are drawn as plates only, as in Omarchy. |
| Hover (deck owns hover, 120 ms collapse grace, held cards, 30 s cap) | Canvas mouse enter/exit/move events with the same rules. Expiry timers pause while the pointer is over the deck and resume with the time that was left. They are one-shot `hs.timer.doAfter` timers, not polling. |
| `durationFor()` | Same numbers (5 s / 8 s / 30 s cap / critical stays). |
| Do Not Disturb (`quiet`, persisted) | `dnd` saved to `~/.local/state/omarchy-mac/notifications.json`. Bypass: `bypassQuiet = true`, or critical with no `app` (Omarchy: `omarchy-action` / bare `notify-send` critical). |
| macOS Focus | Optional sync. If Shortcuts named **Omarchy Focus On** and **Omarchy Focus Off** exist (checked once at start with `/usr/bin/shortcuts list`), toggling DND runs the matching one with `/usr/bin/shortcuts run "<name>"`. macOS gives no way to read the Focus state without Full Disk Access, so the indicator shows the port's own state. |
| History (`Store.js`, 100 rows, persisted) | 100 rows **in memory only**, never written to disk, gone on reload. `notifications.history` replays the newest 6 (without buttons: their sender is gone), or shows "No recent notifications" with 󰂚. |
| Keyboard mode | An `hs.hotkey.modal` that is active only after `notifications.keyboard` (or `notifications.act` on a card with several choices), and leaves on Esc, a choice, or 10 s idle. It binds only Esc, ↑/↓, j/k, Tab/Shift-Tab, Return/Enter, Delete/Forward Delete and 1–9. Every other key passes through untouched. |
| `Dnd.qml` indicator (󰂛 U+F009B, tooltips "Allow / Silence Notifications") | Widget `omarchy-notifications`. Click toggles DND. The glyph is drawn in the `error` colour when on (Omarchy `bar.active` = urgent) and dimmed when off. Right click opens a small panel: Do Not Disturb On/Off, Show recent notifications, Dismiss all, Notification Center, Focus Settings… |
| Verification-code detection (`Detect.js`), copy-code buttons, links in bodies, `--exec` argv, sender window routing | Not applicable. Only omarchy-mac's own code posts here, and it passes Lua functions (`actions`, `onClick`, `bundle`) instead. |

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys. Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `SUPER + comma` | `notifications.act` |
| `SUPER + SHIFT + comma` | `notifications.dismiss-all` |
| `SUPER + CTRL + comma` | `notifications.keyboard` |
| `SUPER + ALT + comma` | `notifications.dismiss-one` |
| `SUPER + SHIFT + ALT + comma` | `notifications.history` |
| `SUPER + CTRL + ALT + comma` | `notifications.toggle-dnd` |

Other actions: `notifications.invoke` (x = button 1–9 on the newest card),
`notifications.invoke-last`, `notifications.expand`, `notifications.dnd` (x = `on|off`),
`notifications.clear-history`, `notifications.center`, `notifications.focus-settings`,
`notifications.test` (posts a fixed sample card).

### Optional: sync Do Not Disturb with macOS Focus
1. Open **Shortcuts.app** and create a shortcut named exactly **Omarchy Focus On**, with one action:
   **Set Focus** › Turn **Do Not Disturb** **On** › Until Turned Off.
2. Create **Omarchy Focus Off** with **Set Focus** › Turn **Do Not Disturb** **Off**.
3. Reload Hammerspoon. The indicator's right-click panel stops showing the "not synced" note.
   From then on, `notifications.toggle-dnd` also switches macOS Do Not Disturb.

## Safety
- Notification text is kept in memory only: the cards on screen plus a 100-row session history.
  It is never logged (log lines name only failures and the DND on/off state), never written to a
  file and never sent to OmniShell. The bar var carries `dnd`, counts, and whether Focus sync is
  available.
- No URL action accepts text. URL arguments are `on|off` or a single digit.
- Callers' strings are length-capped (summary 512, body 4096, labels 64 bytes) and stripped of
  control characters. At most 100 cards are live and 9 buttons per card.
- The canvas never activates Hammerspoon, so a card appearing or being clicked never steals focus
  from Citrix Viewer. Nothing reads from Citrix Viewer. Keyboard mode starts only from an explicit
  chord, binds a short list of keys, and ends after 10 s idle.
- Does not use OmniWM's `ctx.data.notifications` or the `notifications …` commands (Full Disk
  Access), nor its `notifications settings` pane (it opens Privacy › Full Disk Access).
- No polling. The only repeating timer is the 20 s relative-time clock, which runs only while
  cards are on screen. Everything stops in `M.stop`.

## Gaps (honest list)
- **Other apps' notifications are not shown in the Omarchy deck** (Full Disk Access). They stay in
  macOS Notification Center. Do Not Disturb for them is macOS Focus, which syncs only through the
  optional Shortcuts above and cannot be read back.
- **History does not survive a reload**: a deliberate privacy choice. Omarchy persists it.
- **Animations**: no drop-in, slide-up or crossfade. Cards appear and disappear at once.
- **Text**: no markup or links in bodies (Omarchy's `Markup.js`). Wrapping is measured per word, so line
  breaks can differ slightly from Qt's.
- **Unreachable cards**: if an open deck is taller than the screen, the canvas is cut at the bottom
  edge. Omarchy also leaves those cards out of reach, but skips them for the keyboard.
- **omarchy-mac's existing toasts** (`omarchy.toast`, hs.alert) are not routed through this deck. Only
  modules that call `post{}` use it.

## Test steps
1. Install with `--bar`, reload Hammerspoon. Check there are no `notifications:` errors in `~/.local/state/omarchy-mac/hs.log`.
2. `open -g 'hammerspoon://omarchy?a=notifications.test'`. Expected: a card at the top right with 󰂚,
   **Notifications are working**, two body lines, and a **Notification Center** button. The frontmost app
   keeps focus. It disappears after 8 s.
3. Run the test twice quickly. Expected: one deck, with the second card peeking under the first.
   Hover the deck: it opens and lists both cards, and they stop counting down. Leave: it closes, and
   both expire a moment later.
4. Hover a card: the time slot turns into ✕. Click ✕: the card goes. Right click a card: it goes.
   Click the button: Notification Center opens.
5. From the Hammerspoon console, run `require("omarchy.ports.notifications").post{ app = "Test", summary = "Critical", urgency = "critical" }`.
   It stays until dismissed. Bind `notifications.act` (Super+,) and press it: it is dismissed.
6. Post a card with two `actions`, then press `notifications.keyboard` (Super+Ctrl+,). The newest card is
   tinted and its buttons show 1 and 2. Press 2: the second action runs and keyboard mode ends.
   Press it again, then Esc: everything goes back to normal. Typing in another app is unaffected
   after Esc or 10 s.
7. Click the 󰂛 indicator in the bar: it turns red (DND on), and `notifications.test` shows nothing.
   `notifications.history` (Super+Shift+Alt+,) replays the silenced card. Click 󰂛 again: off.
   Reload Hammerspoon with DND on: it is still on.
8. Optional: create the two Shortcuts, reload, and toggle DND. The macOS Focus (Control Center) follows.
9. Check `~/.local/state/omarchy-mac/hs.log` and `notifications.json`: no summary or body text in either.
