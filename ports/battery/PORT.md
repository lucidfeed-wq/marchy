# omarchy.battery → macOS (`battery`)

**Status: partial** · **Bar placement: none** (Omarchy kind `service`, no bar presence; the bar's battery item stays OmniWM's `battery`) · **Requires: nothing** (Hammerspoon built-ins only)

## What it does
Omarchy's low battery warning service. Every 30 s, and whenever the power source changes, it
checks the battery. When the Mac is **on battery, not charging, at 10 % or less**, it shows one
warning for 30 s:

```
󱐋  Time to recharge!
Battery is down to 9%
```

Then it stays quiet while the battery remains low. Once the battery is no longer low (plugged in,
charging, or back above 10 %), the next drop to 10 % warns again. The "already warned" flag
survives a Hammerspoon reload, as Omarchy's `PersistentProperties` survives a shell reload. A Mac
without a battery never warns.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `UPower.displayDevice.percentage` (`batteryPercentage`, −1 without a battery) | `hs.battery.percentage()` rounded, −1 when nil |
| `UPower.onBattery && state == Discharging` (`isDischarging`) | `hs.battery.powerSource() == "Battery Power"` and not `hs.battery.isCharging()` |
| `shouldWarnLowBattery(…, threshold 10, alreadyNotified)` | `M.evaluate(level, discharging, 10, notified)`: same logic, pure function |
| `Timer { interval: 30000; triggeredOnStart }` | `hs.timer.doEvery(30)` plus a check 2 s after start |
| `onOnBatteryChanged` | `hs.battery.watcher`, acting only when the power source changes |
| `PersistentProperties.notifiedLowBattery` | `hs.settings` key `omarchy.battery.notifiedLow` (one boolean) |
| `omarchy-battery-low <level>` → notification `-g 󱐋 -u normal "Time to recharge!" "Battery is down to N%" -t 30000` | Omarchy-styled `hs.alert` (`omarchy.toast` style: theme background, accent border, JetBrainsMono Nerd Font), same glyph and wording, 30 s. Kept separate from toasts so a later toast does not replace it. Cleared on plug-in. |

## Hotkeys to bind (Omarchy chords → actions)
The plugin itself has no chords. Related Omarchy binding, already built in:

| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + ALT + B` (Show battery remaining, `omarchy-notification-battery`) | built-in `show-battery` (not part of this port) |

`battery.check` runs a check now, for testing.

## Safety
- No permissions requested. `hs.notify` is deliberately not used, because it could make macOS ask for
  notification permission for Hammerspoon.
- No processes, no shell, no URL arguments. One 30 s timer and one battery watcher, both stopped in `M.stop`.
- The log gets one line per warning (`battery: low battery warning at N%`), nothing else.

## Gaps (honest list)
- **Power profiles.** Omarchy also switches power-profiles-daemon profiles on AC/battery changes
  (`omarchy-powerprofiles-set`, `busctl` reads, IPC `battery.refreshPowerProfile`). The macOS
  equivalent, Low Power Mode, can only be set with `sudo pmset`, which is forbidden. Not ported.
  Use System Settings → Battery.
- **`omarchy-hook battery-low`.** User hooks (`~/.config/omarchy/hooks/battery-low`) are not run.
  omarchy-mac has no hooks directory, and running user scripts unasked is out of scope here.
- **Notification center.** The warning is an on-screen alert, not a Notification Center entry.
  It can't be clicked away, but it disappears after 30 s or when you plug in.
- **Urgency.** `-u normal` has no equivalent. The alert always uses the toast style.

## Test steps
1. Install the port and reload. `~/.local/state/omarchy-mac/hs.log` should have `ports: battery loaded` and no `battery:` errors.
2. In the Hammerspoon console, `require("omarchy.ports.battery").evaluate(9, true, 10, false)`
   returns `notify = true, notifiedLowBattery = true`. With `alreadyNotified = true` it returns `notify = false`.
   `evaluate(9, false, 10, false)` (charging) returns `notify = false, notifiedLowBattery = false`.
3. Preview the alert with `require("omarchy.ports.battery").warn(9)`. Check that the glyph, both lines,
   theme colours and accent border look right. It closes after 30 s.
4. On battery, run `battery.check` (`open -g 'hammerspoon://omarchy?a=battery.check'`). Above 10 % nothing
   happens. To test the real path, let the battery run down to 10 % on battery power: one warning appears,
   and no second one 30 s later.
5. Plug in. The warning (if still up) closes. Unplug while at 10 % or less: it warns again.
