# omarchy.audio → macOS (`audio`)

**Status: partial** · **Bar placement: trailing** (between `omarchy-wifi` and `battery`; it **replaces OmniWM's bundled `volume` widget**) · **Requires: nothing** (OmniWM 0.8 shell data + Hammerspoon built-ins)

## What it does
Omarchy's audio bar item and its panel:

| Part | Content |
|---|---|
| Bar | Omarchy volume glyph: headphones `U+F02CB` when the default output looks like headphones, muted `U+EEE8`, else `U+F026` / `U+F027` / `U+F028` by volume (≥ 34 %, ≥ 67 %). Left click opens the panel, right click mutes or unmutes everything, scrolling changes the volume by 5 % per notch. |
| Hero | Big glyph, **Audio**, the volume "mood" in caps (Muted, Silenced, Whisper, Murmur, Easy listening, Steady groove, Cranked up, Party mode, Concert hall: same bands as `Model.outputVolumeName`), and an on/off switch. The switch is on while anything is audible and mutes or unmutes output and microphone together. |
| OUTPUT | Percent, a slider (right click mutes), then one row per output device with Omarchy's glyphs (`U+F02CB` headphones, `U+F00AF` Bluetooth, `U+F0379` HDMI/DisplayPort, `U+F04C3` speaker). The active device is bold and highlighted. Click a row to switch to it. |
| INPUT | Microphone percent and slider (right click mutes), then the input devices (`U+F036C` mic, `U+F02CB` headset, `U+F00AF` Bluetooth, `U+F0100` camera). Click a row to make it the default input. |
| SOURCES | Per-app mixer (`U+F057E` / `U+F075F` mute glyph, name, percent, slider). The app that is currently the now-playing app is bold. Shown **only** when OmniWM already has System Audio Recording access (see Gaps). |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `Pipewire.defaultAudioSink` volume / mute | `ctx.data.volume` / `ctx.data.muted`; `volume set <pct>`, `volume up|down 5`, `volume mute` |
| Sink list, `omarchy-audio-output-set-default` | `ctx.data.outputs` (CoreAudio devices with transport); `volume output <id>` |
| Default source volume / mute | `ctx.data.microphone`; `microphone set <pct>`, `microphone mute` |
| Source list, `omarchy-audio-input-set-default` | Hammerspoon `hs.audiodevice.allInputDevices()` published as `omarchy_audio`; action `audio.input` → `setDefaultInputDevice()` |
| Playback streams (per-app mixer) | `ctx.data.audioApps` (OmniWM process taps); `volume app <id> set <pct>`, `volume app <id> mute` |
| `toggleAllMuted()` (right click, hero switch) | the same rule: mute when anything is audible, else unmute, by toggling only the channels that differ |
| Volume OSD on scroll | not shown (see Gaps); OmniWM changes the volume directly |
| `KeyboardPanel` toggle via IPC (`SUPER+CTRL+A`) | `audio.toggle` → `omniwmctl shell toggle omarchy-audio` |
| Colours | `foreground`, `secondaryForeground` (Omarchy's `Qt.darker(fg)`), `accent` (slider, switch, active row), panel via `look.panel` |

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys. Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + A` (Audio panel) | `audio.toggle` |

The volume and mic keys (`XF86Audio*`) and `omarchy-audio-output-switch` are not part of this plugin.
The `osd` port covers the volume keys (`osd.volume-up` / `-down` / `-mute`, `osd.mic-mute`).

## Bar setup
`omarchy-port install audio --bar` inserts `omarchy-audio` before `battery` in `trailing`. Then
**remove `"volume"`** from `trailing` in `~/.config/omniwm/shell/shell.toml`, or the bar shows two
volume items:
```toml
trailing = ["omarchy-tray", "omarchy-bluetooth", "omarchy-wifi", "omarchy-audio", "battery"]
```

## Safety
- The only URL action that takes an argument is `audio.input`. Its `x` must be a device uid from
  the list this module last published (≤ 512 bytes). Anything else is refused and logged without the value.
- No shell commands. `omniwmctl` runs through `hs.task` with an argv array. The device list comes
  from an event-driven `hs.audiodevice.watcher` (debounced 0.3 s) plus a 30 s refresh.
- Never asks for permissions. The widget does **not** offer OmniWM's `volume permission` prompt
  (System Audio Recording is a Screen Recording-class permission, forbidden on this machine).
  Nothing reads or records audio.
- Device names are not private, but they are only published to the bar var and never logged.
  OmniWM's private per-app tap devices (`com.barut.OmniWM.*`) are filtered out.

## Gaps (honest list)
- **Per-app mixer needs OmniWM System Audio Recording access.** Without it the SOURCES section is
  hidden. Omarchy always shows its streams. Do not grant the permission on this machine.
- **App list differs.** macOS has no per-stream objects. OmniWM lists apps. The port shows apps
  that are playing, muted, or not at 100 %. App volume is capped at 100 % (Omarchy allows 150 %).
- **Keyboard navigation** in the panel (j/k/h/l, m, Enter, Tab between panels) is not ported.
  The panel works with the mouse only.
- **Input level meter** (live peak bar under the input slider) is not shown. Reading live input
  levels would mean capturing the microphone.
- **Input volume** works only when the default input has a writable volume control. Otherwise the
  percent shows `–` and only mute is offered, if the device has a mute control.
- **Volume OSD on scroll** is not shown (OmniShell widgets cannot reach the `osd` port without a
  URL per notch). Use the `osd.*` actions on keys instead.
- **DSP / virtual sink resolution** (`omarchy-audio-output-sink`, EasyEffects, speaker tunings) has
  no macOS equivalent. OmniWM controls the default device directly.
- **Sink availability filtering** (`omarchy-audio-sink-availability`) is not needed: CoreAudio
  only lists present devices.
- **Headphones** are detected by device name (headphone, headset, earbud, earphone, AirPods), as
  Omarchy does with PipeWire properties. Wired headphones on the built-in jack show the headphone
  glyph only when macOS names the device "Headphones".
- **Panel height** is not capped or scrolled. Omarchy caps it at 560 px.

## Test steps
1. Install the port with `--bar`, remove `volume` from `trailing`, and reload. `~/.local/state/omarchy-mac/hs.log`
   should have no `audio:` errors, and `omniwmctl query shell-widgets` should show `omarchy-audio` loaded.
2. The bar shows the speaker glyph. Scroll over it: the volume changes in 5 % steps and the glyph changes at 34 % and 67 %.
3. Right click the glyph. Output and mic mute together and the glyph becomes `U+EEE8`. Right click
   again and both unmute.
4. Left click to open the panel. Check that the mood label matches the volume (e.g. 55 % → STEADY GROOVE), and that dragging
   the OUTPUT slider changes the volume.
5. Click another output row (e.g. AirPods, if connected). Sound moves there and that row turns bold.
6. Check that the INPUT rows list your microphones. Click another one. System Settings → Sound → Input shows it
   as selected, and its row turns bold within about a second.
7. `open -g 'hammerspoon://omarchy?a=audio.input&x=bogus'`. Expected: nothing changes, and the log
   says `audio: input refused`.
8. Bind `audio.toggle` and press it. The panel opens and closes.
9. With System Audio Recording not granted, check that the panel has no SOURCES section and no permission prompt.
