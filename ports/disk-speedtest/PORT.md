# disk-speedtest (Omarchy `omarchy.disk-speedtest`, kind: panel)

## What it does
A summoned overlay with live disk speed dials. You open it and it measures straight away.
Over a dimmed scrim, a themed card shows the model of the disk under test as its title and
two dials, **Read** (left) and **Write** (right), in **MB/s**. The read phase runs first,
then the write phase. While a phase runs, its dial is live: the label turns accent and the
arc pulses. The dial updates once a second and settles on the phase's steady-state average.
Each dial's range snaps to the next scale stop (500 / 1k / 2.5k / 5k / 10k / 15k MB/s). When
the run ends, a run-again button (nf-md-refresh `󰑐`, tooltip "Measure again") appears. If the
run fails, the error text shows in the theme's red. Pressing Esc or clicking the scrim
dismisses the overlay and stops the run.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `SpeedTestOverlay` layer-shell panel | Full-screen, borderless, transparent `hs.webview` at `modalPanel` level on the screen under the mouse. Theme colours (`background`, `foreground`, `bright_foreground`, `dark_foreground`, `accent`, `selection`, `red`) come from `omarchy.theme`. Uses JetBrainsMono Nerd Font. |
| `omarchy-disk-speedtest` (Linux script, streams `disk`/`read`/`write` lines) | A fixed Perl program run with `/usr/bin/perl` (ships with macOS) via `hs.task` streaming. It prints the same `read <MB/s>` / `write <MB/s>` line protocol. It writes a 1 GiB scratch file in the user's temp folder (`hs.fs.temporaryDirectory()`) with `F_NOCACHE`, so reads bypass the page cache and really hit the SSD. Then it reads for 6 s. Then it writes for 6 s, capped at 8 GiB, and ends with `F_FULLFSYNC`. It deletes the file on exit or SIGTERM, and the Lua side deletes it too as a fallback. |
| `disk <model>` line | `diskutil info /` → APFS physical store → `diskutil info diskN` → "Device / Media Name" (e.g. `APPLE SSD AP0512Z`) |
| `shell summon omarchy.disk-speedtest` | `disk-speedtest.open` (or `.toggle`) |
| `shell hide` / Esc / scrim | `disk-speedtest.close`, Esc, a click on the scrim, or the overlay losing focus |
| Run-again button | Button in the overlay, or Return / `r` when the run has ended, or `disk-speedtest.run` |
| pendingRun / expectedStop handling | Same: re-summoning while a dismissed run is still exiting queues a fresh run |

The module also publishes a coarse summary to the OmniShell var `omarchy_disk-speedtest`:
`{v, open, running, phase, disk, read, write, error}`. `read` and `write` are only filled
once that phase has settled. This is for any future bar widget or script. There is no bar
widget, because the plugin has no bar presence.

## Actions
- `disk-speedtest.open`: open the overlay and start a measurement
- `disk-speedtest.toggle`: open, or dismiss if already open
- `disk-speedtest.close`: dismiss (stops the run and deletes the scratch file)
- `disk-speedtest.run`: measure again (opens the overlay if it is closed)

None of the actions take a URL argument, so nothing from `x` reaches a process.

## Hotkeys
Omarchy defines no chord for this plugin; it is summoned with
`omarchy-shell shell summon omarchy.disk-speedtest` (from its menu). To bind one, add an
entry for a free chord to `~/.config/omarchy-mac/bindings.toml` with
`hs = "disk-speedtest.toggle"` (or `disk-speedtest.open`).

## Bar placement
none (panel only).

## Requires
Nothing to install. Uses `/usr/bin/perl` and `/usr/sbin/diskutil`, both built in. No sudo,
no new permissions, and no raw device access.

## Gaps / differences
- The upstream `omarchy-disk-speedtest` script was not in the plugin source. So the test's
  exact sizes, durations and order of operations are this port's own choices: a 1 GiB file,
  6 s per phase, and an 8 GiB write cap. The numbers will not be identical to the Linux script.
- Before the read phase, a 1 GiB file has to be written and is not measured. The Read dial
  shows live at 0 during this step, as Omarchy does before the first figure arrives.
- macOS has no `O_DIRECT`. `F_NOCACHE` gives the same effect for this purpose, but the SSD
  controller's own DRAM cache can still lift short bursts.
- The shared `SpeedTestOverlay` QML component was also not in the plugin source. The dial
  layout is a faithful reconstruction from the properties the panel passes in: title, labels,
  unit, scale stops, live flags, error text and the run-again tooltip. It is not a
  pixel-for-pixel copy.
- I18n: the English strings are hard-coded ("Read", "Write", "Disk speed test failed",
  "Measure again").
- If `/usr/bin/perl` were ever removed from macOS, the overlay shows an error instead of
  measuring.
- The overlay closes when it loses focus (for example Cmd-Tab). Omarchy's exclusive layer
  surface cannot lose focus in this way.

## Test steps
1. Copy `hammerspoon/disk-speedtest.lua` into `~/.hammerspoon/omarchy/` (the installer does
   this) and reload Hammerspoon.
2. `open "hammerspoon://omarchy?a=disk-speedtest.open"`. The overlay appears, the title shows
   the SSD model, and the Read dial is live (accent label, pulsing arc), updating each second.
3. After about 6 s, Read settles on its average and Write goes live. After about 6 s more,
   Write settles and the run-again button appears. Hover it to see "Measure again".
4. Click the run-again button, or press Return. Both dials reset to 0 and the run restarts.
5. Press Esc during a run. The overlay closes, and no `omarchy-disk-speedtest-*.bin` is left
   in `$TMPDIR`.
6. Click the scrim outside the card. The overlay closes.
7. `/Applications/OmniWM.app/Contents/MacOS/omniwmctl shell get omarchy_disk-speedtest`
   (if available) shows the settled summary.
8. Check `~/.local/state/omarchy-mac/hs.log`: no errors from `disk-speedtest`.
