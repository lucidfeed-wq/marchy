# omarchy.reminders → macOS (`reminders`)

**Status: ported** · **Bar placement: trailing** (the `Reminder` item of Omarchy's
`omarchy.indicators` widget) · **Requires: nothing** (Hammerspoon built-ins only)

## What it does
Omarchy's `omarchy.reminders` is the interactive reminder setup flow, summoned by
`omarchy-reminder -i` (Super+Ctrl+R, menu *Reminder > Set one*). Over a scrim, a 300 px menu
card shows one line of text at heading size:

1. **"Remind in minutes..."** (the prompt is shown at 58 % opacity until you type). Return
   with nothing typed dismisses the card. Return with anything that is not a whole number
   above 0 sends the notification *Invalid reminder – Enter the number of minutes* and the
   card stays open.
2. **"Reminder message..."**. Return sets the reminder; the message is optional.

Escape clears what you typed, or dismisses the card if nothing is typed. Clicking the scrim
dismisses it. The flow hands off to `omarchy-reminder <minutes> [message]`. That command
starts a transient timer and confirms with *Reminder set for N minutes* (or *<message> in N
minutes*) and *You'll be reminded at H:MM*. When the timer fires it sends the notification
*󰢌 Reminder – <message>*, or *Your N minutes are up* if there was no message.
`omarchy-reminder show` lists *Upcoming reminders* (`<label> in 4m 30s (14:05)`), and
`clear` cancels all of them. The bar indicator `󰢌` is lit while reminders are queued.
Clicking it shows them if any are queued, and otherwise opens the flow.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `OverlayWindow` + scrim (`menu.scrim` = background @ 50 %) + `BorderSurface` card (300 px, menu background, 2 px menu border = foreground, `Style.cornerRadius` 0, padding 18, heading 16 px menu font) | Full-screen, transparent, borderless `hs.webview` at `modalPanel` level (`allowTextEntry`, its own `omarchy_reminders` message handler). It draws the same card in theme colours with JetBrainsMono Nerd Font 16 px, and the prompt as the placeholder at 58 %. |
| Key catcher (Esc clears or dismisses, Return submits) and scrim click | Same keys in the page; a scrim click or the overlay losing focus dismisses |
| `ReminderFlowModel.validMinutes` (`^[0-9]+$`, > 0) | Same rule in Lua, capped at one year |
| `omarchy-reminder <min> [msg]` → `systemd-run --user --on-active` + message file in `$XDG_RUNTIME_DIR` | An in-memory `hs.timer.doAfter`. The message stays in Lua memory only (see Safety). |
| `omarchy-notification-send -g 󰢌 …` (confirmations, fired reminder, show, clear, invalid) | An Omarchy-style card (`hs.canvas`): background @ 97 %, 2 px accent border, `󰢌` in accent, bold heading and body, stacked at the top right of the main screen. Fired reminders stay until clicked and play the system "Glass" sound. Other cards close after 8 s or on click. |
| `omarchy-reminder show` / `clear` | `reminders.show` / `reminders.clear` |
| `omarchy-reminder -i` / `shell summon omarchy.reminders` | `reminders.open` (`reminders.toggle`, `reminders.close`) |
| `omarchy-reminder <minutes>` (no message) | `reminders.set` with `x = minutes` (digits only) |
| `Reminder` indicator (`󰢌`, active while count > 0, tooltip "N reminders" / "Set Reminder", concealed until hover, dimmed 45 %) | Widget `omarchy-reminders`. It reads `omarchy_reminders` = `{v, count, next}` and shows the same glyph: opacity 1 while reminders are queued, 0 when none are, 0.45 while the pointer is over it. `alwaysShow` is a setting. Click → `reminders.indicator`, right-click → `reminders.open`. |

From another Hammerspoon module: `require("omarchy.ports.reminders").add(5, "Check the oven")`,
`.show()`, `.clear()`, `.state()` → `{count, next}`.

## Hotkeys to bind (Omarchy chords → actions)
Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord (default/hypr/bindings/utilities.lua) | Action |
|---|---|
| `SUPER + CTRL + R` (Set reminder) | `reminders.open` |
| `SUPER + CTRL + ALT + R` (Show reminders) | `reminders.show` |
| `SUPER + SHIFT + CTRL + R` (Clear reminders) | `reminders.clear` |

## Safety
- **The reminder text is typed text and never leaves memory.** It goes from the overlay page
  to Lua through the WKWebView message handler, never through a `hammerspoon://` URL, so
  `url.lua` never logs it. It is kept only in this module's table and shown only on the
  reminder's own cards (the confirmation, the fired card and `show`). It is never logged,
  never published to OmniShell, and never written to disk. Log lines record only the
  minutes and whether a message was given.
- `reminders.set` accepts only digits through `x`; there is deliberately no URL action that
  takes a message.
- Messages are trimmed of control characters and capped at 500 bytes, and at most 50
  reminders can be queued. Page messages are validated: the step must match the flow's
  current step, and the value must be a string.
- No new permissions: no `hs.notify` (that would need Notifications permission for
  Hammerspoon), no Apple Reminders/EventKit, no shell, no daemon. The only watcher is a
  sleep/wake watcher, which fires reminders that fell due while the Mac slept.

## Gaps (honest list)
- **Reminders are lost when Hammerspoon reloads or quits** (including `omarchy-mac` reloads
  and logout). Omarchy's systemd timers survive a shell restart but not a reboot. Here,
  persisting the timers would mean writing the typed message to disk, which this machine's
  privacy rules forbid. Set a reminder in Apple Reminders for anything that must survive.
- **Not in Notification Center.** The fired reminder is an on-screen card, not a macOS
  notification. It does not appear in Notification Center or on the lock screen, and Focus
  modes do not suppress it. It stays on screen until clicked.
- **Apple Reminders hand-off was not used.** OmniWM's `reminders add <text>` command
  would need the OmniShell widget to hold the typed text, and it creates persistent
  EventKit items, which is not how Omarchy's short-lived timers behave.
- **`omarchy-reminder show --json`** has no URL equivalent, because URL actions cannot
  return values. Lua callers can use `.state()`, which returns the count and next due time
  but never the text.
- **Indicator group hover.** Omarchy reveals all inactive indicators when you hover over the
  indicator area. This port reveals its slot only when you hover directly over it.
- Strings are English only. Times use `H:MM` in 24-hour form, as `date +%-H:%M` does.

## Test steps
1. Install with `--bar`, reload Hammerspoon, and check `~/.local/state/omarchy-mac/hs.log`
   for errors from `reminders`.
2. `open -g 'hammerspoon://omarchy?a=reminders.open'`. A dim scrim appears with a 300 px
   card that reads "Remind in minutes...".
3. Type `abc` and press Return. An *Invalid reminder* card appears and the flow stays open.
   Press Escape once to clear the text, and again to close the flow.
4. Open the flow again, type `1` and press Return. The prompt changes to "Reminder message...".
   Type `Stretch` and press Return. A card shows *Stretch in 1 minute – You'll be reminded at …*,
   and the bar indicator `󰢌` lights up with the tooltip "1 reminder".
5. Click the indicator. *Upcoming reminders – Stretch in 59s (…)* appears.
6. After a minute, the sticky *󰢌 Reminder – Stretch* card appears with a sound. Click it to
   dismiss it. The indicator hides again.
7. `open -g 'hammerspoon://omarchy?a=reminders.set&x=2'` sets *Reminder set for 2 minutes*.
   Then run `reminders.clear`. *All reminders have been cleared* appears and the indicator hides.
8. `grep -i stretch ~/.local/state/omarchy-mac/hs.log` should find nothing.
