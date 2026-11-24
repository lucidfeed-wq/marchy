# omarchy.idle → macOS (`idle`)

**Status: ported** · **Bar placement: none** (Omarchy kind `service`, no bar presence) · **Requires: nothing** (Hammerspoon built-ins only)

## What it does
Omarchy's idle service. After a period without keyboard or mouse input, it runs an **idle cycle**:

1. **Screensaver** at `idle.screensaver` seconds of idle (default **150 s**).
2. **Lock** at `idle.lock` seconds of idle (default **300 s**). The lock fires even while the
   screensaver is up.

Input before the lock cancels the cycle. There are two exceptions. Right after the screensaver
is launched (3 s grace) and while it runs, stray input is ignored; dismissing the screensaver
then cancels the cycle. A timeout of `0` turns that step off. With both at `0`, the service is idle.

**Stay awake** (Omarchy's idle-inhibitor toggle, `SUPER+CTRL+I`) stops the cycle, and so does any app
that keeps the display awake (video, calls), as Omarchy's `respectInhibitors` does.

Timeouts come from the same keys Omarchy uses, in `~/.config/omarchy-mac/shell.json` (optional):
```json
{ "idle": { "screensaver": 150, "lock": 300 } }
```
The file is re-read between idle cycles, so changes apply without a reload. Values from 1 to 4 s are raised to 5 s.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `IdleMonitor { timeout: firstIdleTimeout; respectInhibitors }` | `hs.host.idleTime()` (HID idle), capped at the time since the module started, as `IdleMonitor` starts counting at shell load. An adaptive one-shot `hs.timer` sleeps until the first deadline could be reached (2–30 s) and polls every 2 s only during a cycle. |
| `secondsFromConfig`, `firstIdleTimeout`, `delayAfterFirstIdle` | same rules. Deadlines are set once per cycle from the idle time actually observed, so a late check can only bring a step forward. |
| `omarchy-launch-screensaver` (ttfx in a terminal, skipped when locked or `screensaver-off`) | `hs.caffeinate.startScreensaver()` (the macOS screensaver), skipped when the session is locked, when displays are already asleep, or when turned off with `idle.screensaver-toggle` |
| Hyprland open/close events for the `org.omarchy.screensaver` window | `hs.caffeinate.watcher` `screensaverDidStart` / `screensaverDidStop` |
| `omarchy-system-lock` | `hs.caffeinate.lockScreen()` (the same call as the built-in `lock` action) |
| `omarchy-system-wake` (DPMS on, keyboard backlight restore) | nothing: macOS wakes the displays on input itself |
| Stay-awake state file `~/.local/state/omarchy/indicators/stay-awake`, `omarchy-toggle-idle` | **shared, not duplicated:** the built-in Hammerspoon action `stay-awake` (`hs.caffeinate.toggle("displayIdle")`), read with `hs.caffeinate.get("displayIdle")`. `idle.toggle` / `enable` / `disable` call that action, so one switch drives both. |
| Other idle inhibitors | display-sleep power assertions from `hs.caffeinate.currentAssertions()` (`PreventUserIdleDisplaySleep`, `NoDisplaySleepAssertion`), with OmniWM's own `session awake …` recognised by its pid. The macOS screensaver's own process is ignored. |
| ShellIpc `idle.status` / `debug` (JSON) | Lua `require("omarchy.ports.idle").status()` (table), and action `idle.status` (summary toast) |
| ShellIpc `idle.enable` / `disable` / `toggle` | `idle.enable` / `idle.disable` / `idle.toggle` |
| `omarchy-toggle-screensaver` (`screensaver-off` flag), "Screensaver enabled/disabled" | `idle.screensaver-toggle` (`hs.settings` flag `omarchy.idle.screensaverOff`), same wording and glyph `U+F1104` |
| Menu "Screensaver" (`omarchy-launch-screensaver force`) | `idle.screensaver` |
| Locked / sleeping state | `screensDidLock` / `Unlock`, `sessionDidResignActive` / `BecomeActive` (suspend while locked), `systemWillSleep` (cancel), `screensDidSleep` / `Wake` |

### Coordination with the other "stay awake" switches
- The built-in Hammerspoon `stay-awake` action and this port's `idle.toggle` are **the same switch**.
- OmniWM's `session awake on|off|<minutes>` (bar control) holds its own display assertion. The port
  treats it as an inhibitor. `idle.toggle` / `idle.enable` cannot turn it off from Hammerspoon,
  so they say so in a toast instead of fighting it.
- An app holding a display assertion (a playing video, a call) pauses the cycle. That matches macOS,
  which will not sleep the display either.

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys. Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + I` (Toggle locking on idle) | `idle.toggle` |
| `SUPER + CTRL + L` (Lock system) | built-in `lock` (not part of this port) |

## Safety (clinical machine)
- **Only ever earlier, never later.** The port adds a screensaver and lock on top of macOS's own
  screen-lock settings and never weakens them. It does not write power settings (no `pmset`, no
  `sudo`), does not create power assertions, does not call `hs.caffeinate.declareUserActivity`
  (which would push back macOS's own idle lock), and does not change "Require password".
  If the port stops or fails, macOS's own policy still applies.
- A reload never locks on the spot: idle time counts from module start, as in Omarchy.
  An idle machine still locks `lock` seconds after a reload.
- After locking, no new cycle starts until input is seen or the session is unlocked, so it cannot lock again and again.
- No processes, no shell, no URL arguments. Timers: one adaptive check timer (≥ 2 s), one-shot
  screensaver/lock deadlines, and a 3 s grace timer. All are stopped in `M.stop`, along with the caffeinate watcher.
- The log records only events (cycle start/cancel with the reason, screensaver start, lock),
  never what was on screen. Typing in Citrix Viewer counts as activity like any other input. Nothing is read from it.

## Gaps (honest list)
- **Screensaver look.** Omarchy's screensaver is its terminal animation (`omarchy-screensaver` in
  Ghostty/Alacritty, one window per monitor). The port starts the macOS screensaver selected in
  System Settings → Screen Saver instead.
- **1Password lock, keyboard layout reset** done by `omarchy-system-lock` are not reproduced.
- **Keyboard backlight restore** on wake (`omarchy-system-wake`) is left to macOS.
- **Separate idle state file.** Omarchy's `stay-awake` file is not used. The Hammerspoon
  `displayIdle` assertion is the state, and it does not survive a Hammerspoon reload. Neither did
  the built-in `stay-awake` action before this port.
- **Idle inhibitors** are read from power assertions every check (≤ 30 s, 2 s during a cycle), not
  pushed as events. An inhibitor that appears in the last seconds before a deadline is caught by the
  re-check when the lock deadline fires.

## Test steps
1. Install the port and reload. `~/.local/state/omarchy-mac/hs.log` should have `idle: service-ready: screensaver=150 lock=300`.
2. For quick testing, write `{"idle":{"screensaver":20,"lock":40}}` to `~/.config/omarchy-mac/shell.json`.
3. Leave the Mac alone. At about 20 s the log has `idle-cycle-start`, then `screensaver-start`, and the macOS
   screensaver appears. At about 40 s the session locks (`lock-system: lock-timeout`).
4. Unlock, wait about 25 s for the screensaver, then move the mouse. The screensaver goes away, the log
   has `idle-cycle-cancel: screensaver-dismissed`, and no lock follows.
5. Run `idle.toggle` (or the built-in `stay-awake`). The toast says "Staying awake…". Leave the Mac alone for 60 s:
   no screensaver, no lock. Run `idle.toggle` again to switch back.
6. Play a video in a browser (it holds a display assertion). `idle.status` says "Idle lock paused".
7. Turn on OmniWM's Stay Awake from the bar, then run `idle.toggle`. The toast says OmniWM Stay Awake is on.
8. `idle.screensaver-toggle` → "Screensaver disabled". The next cycle locks at the lock deadline without a screensaver.
9. Delete the test `shell.json` (or set the values back to 150/300) when done.
