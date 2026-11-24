# omarchy.media → macOS (`media`)

**Status: partial** · **Bar placement: trailing** (Omarchy's default bar does not include it; put it wherever you like) · **Requires: nothing** (OmniWM 0.8 now-playing data + Hammerspoon built-ins)

## What it does
Omarchy's media service and its now-playing bar item:

| Part | Content |
|---|---|
| Bar | Play/pause glyph (`U+F03E4` while playing, `U+F040A` while paused; bright while playing, dimmed when paused), then `title  ·  artist`, at most 180 px wide. Hidden when nothing has a title or artist. Left click plays/pauses, middle click skips, right click opens the card, scroll up/down goes to the previous/next track. The tooltip is `title — artist`. |
| Card | 64 px artwork, or the music glyph `U+F075A` when there is none. Then the title (bold, or "Nothing playing"), artist and album, and centred previous `U+F04AE` / play-pause / next `U+F04AD` buttons. |
| Service | The keyboard entry points (`media.playPause`, `next`, `previous` in Omarchy's IPC) as Hammerspoon actions for the media keys. |

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `Mpris.players` + `selectActivePlayer()` | macOS system now-playing (one app at a time), via OmniWM `ctx.data.media` (title, artist, album, artwork, playing). No Apple Events. |
| `runAction("playPause" / "next" / "previous")` from the widget | OmniWM commands `media toggle`, `media next`, `media previous` |
| ShellIpc `media.playPause` / `next` / `previous` (media keys) | `media.play-pause` / `media.next` / `media.previous`: Hammerspoon posts the system media key (`hs.eventtap.event.newSystemKeyEvent` PLAY / NEXT / PREVIOUS), which macOS sends to the now-playing app |
| Track OSD after a key action (`omarchy.osd`, "title - artist") | If the `osd` port is installed, it shows the media OSD with Omarchy's fallback label (Play/pause, Next, Previous). See Gaps. |
| `PopupCard`, `BorderSurface`, `Button` | `look.panel`, bordered `ui.stack` art tile, bordered glyph buttons |
| `Qt.darker(fg, 1.5)` (paused glyph, details) | `secondaryForeground` |

## Hotkeys to bind (Omarchy chords → actions)
Ports don't bind keys. Add these to `~/.config/omarchy-mac/bindings.toml` (`hs = "<action>"`):

| Omarchy chord | Action |
|---|---|
| `XF86AudioPlay`, `XF86AudioPause` | `media.play-pause` |
| `XF86AudioNext`, `ALT + XF86AudioPlay` | `media.next` |
| `XF86AudioPrev`, `ALT + SHIFT + XF86AudioPlay` | `media.previous` |
| `SHIFT + XF86AudioPlay` / `SHIFT + XF86AudioPause` (switch media source) | none (see Gaps) |

The Mac's own F7–F9 media keys already do play/pause/next/previous system-wide, so these actions
matter only for other chords (e.g. Hyper + F8) or for keyboards that lack media keys.

## Safety
- No permissions requested. The widget gets now-playing data from OmniWM, which reads the
  system now-playing info. It does not use Apple Events or Automation for Music or Spotify, and
  makes no `hs.spotify` / `hs.itunes` calls.
- Track titles, artists and albums exist only inside the widget's render (OmniWM data). The
  Hammerspoon module never sees them: nothing is logged, published or written.
- The actions take no URL arguments. The only thing they do is post one media key press
  (down + up). No shell, no timers, no watchers.
- Media keys go to macOS's now-playing routing, not to the frontmost app. Citrix Viewer
  only gets them if it is the now-playing app.

## Gaps (honest list)
- **One player only.** macOS exposes a single system now-playing app. Omarchy's source list
  (shown when more than one MPRIS player exists), `selectPlayer`, and the source switch IPC
  (`sourceNext`, `sourcePrevious`, `sourceSwitch`, with playback transfer) have no equivalent.
- **Explicit play / pause** (`media.play`, `media.pause`) are not offered as hotkey actions. The
  media key only toggles, and Hammerspoon cannot read the playing state without Apple Events.
  The widget's buttons use OmniWM, which knows the state.
- **Button enablement.** Omarchy greys out buttons the player cannot handle (`canGoNext`, …).
  macOS now-playing data doesn't say, so all three buttons are always enabled.
- **Scrolling title.** Omarchy scrolls an overlong title while playing. Here it is truncated at
  180 px.
- **Key OSD text.** The OSD (with the `osd` port) shows "Play/pause" / "Next" / "Previous"
  instead of the new track's "title - artist".
- **Volume keys** handled inside Omarchy's media service (`handleVolumeKey`) belong to the `osd`
  port here (`osd.volume-up` / `-down` / `-mute`).
- **Middle click** depends on OmniShell passing middle-button clicks to `onClick` (the handler
  checks `event.button == "middle"`). If it doesn't, middle click does nothing.

## Test steps
1. Install the port with `--bar` and reload. `omniwmctl query shell-widgets` should show `omarchy-media` loaded.
2. Play something in Music, Spotify, or a browser tab. The bar shows `U+F03E4` and `title  ·  artist`.
   Pause it: the glyph becomes `U+F040A` and dims.
3. Left click the item: playback toggles. Scroll down: next track. Scroll up: previous track.
4. Right click the item. The card shows artwork (or `U+F075A`), title, artist, album and the three buttons, and each button works.
5. Stop all playback and quit the player. The item disappears.
6. Bind `media.play-pause`, `media.next`, `media.previous` (e.g. Hyper+F8/F9/F7) and press them. Playback
   follows. With the `osd` port installed, the media OSD shows the action name.
7. `grep -i media ~/.local/state/omarchy-mac/hs.log` shows only `url: media.*` action lines, with no
   track text.
