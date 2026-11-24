# omarchy.power → macOS (`power`)

**Status: partial** · **Bar placement: trailing** · **Requires: nothing** (OmniWM's battery/power feeds plus Hammerspoon built-ins; `/usr/bin/pmset` and `/usr/sbin/ioreg` are only read)

## What it does
Omarchy's Power bar widget. The bar shows Omarchy's battery glyph: ten levels, the charging set
while on AC, U+F0085 when fully charged, and the plain set while the charger is holding. Right
click toggles a `NN%` label next to it. The widget is hidden on Macs without a battery. Left click
opens the panel (380 pt):

| Part | Content |
|---|---|
| Hero | Battery glyph (24 pt) · **Battery** + an upper-cased status line · the big bold percentage (28 pt). While charging or on battery the status rotates Omarchy's phrases every 2.8 s ("PUMPING POWER", "SLURPING POWER", …). Otherwise it reads FULLY CHARGED / THRESHOLD / CHARGING / ON BATTERY. |
| Charge bar | 8 pt track (foreground 12 %) with the fill at the charge level. It pulses (1 → 0.55) while charging. |
| Stats | Battery size `NNWh` · Charge cycles. Time left / Time to full (or Charge limit while holding) · Discharging/Charging rate `13.1W` (or Battery state "Holding"). Idle/full values show `-`, as in Omarchy. |
| POWER PROFILE | Bordered buttons: Power-saver (U+F032A) · Balanced (U+F029A) · Performance (U+F04C5, only on Macs with High Power Mode). The active one is highlighted. |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| UPower `displayDevice` (percentage, state, onBattery, changeRate, timeToFull) | `ctx.data.battery`, `ctx.data.charging`, `ctx.data.power.source/charged/watts/full/remaining` (OmniWM, IOKit) |
| UPower states Discharging / Charging / FullyCharged / PendingCharge | source `battery` / `charging` / `charged` / on AC but not charging (macOS "Not charging", e.g. Optimized Charging or a charge limit) |
| `Model.js` `batteryIcon`, `chargeThresholdActive`, `modeLabel`, `batteryFraction` | Reimplemented in the widget with the same rules and glyph code points |
| `omarchy-battery-status --shell` `percentage` / `rate` / `time` / `cycles` | OmniWM: level, `|watts|` (one decimal, `.0` dropped), `remaining` / `full` minutes formatted `45m`, `2h`, `2h 5m`, and `cycles` |
| `omarchy-battery-status` `size` (UPower energy-full Wh) | Hammerspoon: `ioreg -rn AppleSmartBattery` → (AppleRawMaxCapacity / NominalChargeCapacity / FullChargeCapacity mAh) × Voltage → Wh, published in `omarchy_power` |
| `threshold` (charge_control_*_threshold) | No readable charge-limit value on macOS. "Charge limit" shows `-` (Omarchy's fallback) while holding. |
| `omarchy-powerprofiles-list` (`powerprofilesctl`) | Hammerspoon: `pmset -g` → `powermode` 0/1/2 (Automatic / Low Power / High Power) when the Mac has High Power Mode, else `lowpowermode` 0/1. Falls back to `ctx.data.power.lowPower`. Mapped to Balanced / Power-saver / Performance. |
| `omarchy-powerprofiles-set <battery\|ac> <profile>` | **Not possible without sudo.** The profile buttons open Battery settings (`battery settings`), where Low Power Mode is changed. |
| Right click → `togglePercentage` (saved in the bar entry) | right click → `power.toggle-percentage` (saved in `hs.settings` `omarchy.power.showPercentage`) |
| `SUPER + CTRL + P` → panel `omarchy.power` | `power.toggle` → `omniwmctl shell toggle omarchy-power` |
| 5 s refresh while open | OmniWM's own battery sampling. Hammerspoon re-reads `pmset` every 60 s and 3 s after a power event (`hs.battery.watcher`, debounced), and battery size every 5 min. |
| `omarchy-system-stats` (`systemInfo`) | Omarchy 4.5's panel fetches it but never shows it, so it is not ported. OmniWM's bundled `system-stats` widget covers CPU/memory. |

### The bundled `battery` widget
`omniwm-shell/shell.toml` currently ends `trailing` with `"volume", "battery"`. `omarchy-power`
**replaces** OmniWM's bundled `battery` widget (same data, Omarchy look). `omarchy-port install power --bar`
puts `omarchy-power` just before `battery`. Remove `"battery"` from `trailing` yourself if you
don't want two battery icons. The installer does not remove it.

## Hotkeys to bind (Omarchy chords → actions)
| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + P` | `power.toggle` |

Optional: `power.toggle-percentage`, `power.refresh`.

## Safety
- Read-only system access: `pmset -g` and `ioreg -rn AppleSmartBattery` via `hs.task`, argv only, absolute paths. Only the `powermode`/`lowpowermode` lines and the capacity/voltage numbers are parsed. The ioreg output (which includes serial numbers) is never logged or stored.
- No sudo. Low Power Mode is never changed by the port.
- Actions take no URL arguments. The only persisted value is the show-percentage boolean.
- Timers are 60 s / 300 s plus a 3 s debounce. `M.stop` stops every timer, the battery watcher, and any running task.

## Gaps (honest list)
- **Setting the power profile** needs `sudo pmset -a lowpowermode/powermode …`, so it is not ported. The buttons only show the current mode and open Battery settings. Per-source profiles (Omarchy's `battery`/`ac` argument) correspond to macOS's "Only on Battery / Only on Power Adapter" choices in that pane.
- **Charge limit value** (Omarchy's `threshold`, e.g. `75-80%`) is not exposed by macOS, so it shows `-`. "Holding" is inferred from "on AC, not charging, not charged".
- **Battery size** is computed from the current voltage, so it can differ by a few Wh from the design figure. It is blank if ioreg has no capacity keys.
- **High Power Mode detection** relies on `pmset -g` printing `powermode`/`highpowermode`. Only `lowpowermode` was seen on the Mac this was written on, so the three-button layout is unverified.
- **Keyboard navigation** of the profile buttons (arrows + Enter) is not ported (the popout is mouse-driven).
- Percentage animation easing and colour transitions are approximations. Labels and numbers are English with plain digits.

## Test steps
1. `omarchy-port install power --bar`, reload Hammerspoon, check the log for `ports: power loaded`. Optionally remove `"battery"` from `trailing`.
2. The bar shows the Omarchy battery glyph matching the level. Plug in the charger: the glyph should switch to the charging set.
3. Right-click the glyph. `NN%` should appear next to it. Reload Hammerspoon: it should stay. Right-click again to hide it.
4. Left click. Check the hero (glyph, BATTERY, phrases rotating while on battery, big percentage), the bar fill at the level, then Battery size (~`NNWh`), Charge cycles (compare `system_profiler SPPowerDataType`), Time left, and Discharging `x.xW`.
5. Turn on Low Power Mode in System Settings → Battery. Within about 60 s (or right away after `open -g 'hammerspoon://omarchy?a=power.refresh'`), Power-saver should be highlighted.
6. Click Balanced. Battery settings should open, and the mode should not change by itself.
7. Bind `power.toggle` to SUPER+CTRL+P. The popout should open and close.
8. On a desktop Mac (no battery) the widget should not appear.
