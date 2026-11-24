# omarchy.emojis → macOS (`emojis`)

**Status: ported** · **Bar placement: none** (Omarchy kind `overlay`, no bar presence) · **Requires: nothing** (Hammerspoon built-ins; Omarchy's `emojis.json` from `omarchy-port sync`)

## What it does
An emoji picker. A 400 × 500 card sits in the centre of a dimmed screen and uses the menu surface
colours: theme background, 2 px foreground border, square corners, 18 px padding, and a scrim of the
background at 50 %.

- **Header:** what you have typed, or *Search emojis…* at 58 % opacity (16 px).
- **Grid:** 44 px cells with 24 px emoji. The cursor cell gets the menu's selected background
  (foreground at 8 %).
- **Keys:** type to filter by keyword (first 1000 matches, substring match on Omarchy's keyword
  text). ← → move by one and wrap. ↑ ↓ move by a row. PageUp and PageDown move by a page. Ctrl+U
  clears the filter. Return inserts the emoji and closes. Esc clears the filter first, then closes.
  Hovering moves the cursor, and a click inserts. A click on the scrim closes.
- **No matches:** 󰈉 in the accent colour (28 px, 80 %) over "No matches for “…”".

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `OverlayWindow` + scrim + `BorderSurface` card | full-screen `hs.webview` (borderless, transparent, `modalPanel`, `allowTextEntry`, `closeOnEscape(false)`). Scrim and card are drawn in the page, usercontent channel `omarchy_emojis` |
| `FileView $OMARCHY_PATH/shell/plugins/emojis/emojis.json` | read from the synced upstream checkout `~/.local/share/omarchy-mac/upstream/current/shell/plugins/emojis/emojis.json`, validated (each `e` is a string of at most 64 bytes with no control characters, `k` is at most 512 bytes, at most 5000 entries) and cached by mtime. If it is missing or unparseable, a toast says so and a 48-emoji built-in set is used |
| `EmojiSearch.filterEmojis` (lower-case keyword `indexOf`, limit 1000) | same algorithm in the page's JS |
| `Util.editsFilter` (Backspace, Ctrl+Backspace, Ctrl+U) | a real text field (Backspace, ⌥⌫ word delete, ⌘V paste), plus Ctrl+U to clear |
| `omarchy-menu-emoji-insert` (`wl-copy --sensitive` + Shift+Insert, then the copy is dropped) | the emoji is **typed** into the app that was frontmost before the picker opened, as one synthetic key event with the whole grapheme as its Unicode string (`hs.eventtap.event` + `setUnicodeString`), so ZWJ sequences and flags arrive whole and the clipboard is untouched. Falls back to `hs.eventtap.keyStrokes` |
| Citrix Viewer frontmost | **never typed into.** The emoji is only copied to the clipboard and a toast says "Not typed into Citrix Viewer: copied …" |
| — (macOS extra) | Shift+Return or Shift+click copies instead of typing |
| `omarchy-shell shell toggle omarchy.emojis` | actions `emojis.toggle`, `emojis.open`, `emojis.close` |

## Hotkeys to bind (Omarchy chords → actions)
| Omarchy chord | Action |
|---|---|
| `SUPER + CTRL + E` | `emojis.toggle` |

Add it to `~/.config/omarchy-mac/bindings.toml` (`hs = "emojis.toggle"`).

## Safety
- **Never logs picked emojis or search text.** The only log lines are "data file missing/unparseable",
  "could not open" and a handler error, and none of them carries content. The search text never
  leaves the page, which sends Lua only `{pick: <index>, copy: <bool>}`, `{close}` or `{blur}`. The
  index is checked to be an integer within the list Lua itself embedded.
- **Citrix Viewer (`com.citrix.receiver.icaviewer.mac`)** is checked twice: as the target app, and as
  the frontmost app again just before typing (after re-activating the target, 0.18 s later). If
  either check finds Citrix, or focus moved to anything else, nothing is typed and the emoji is
  copied instead.
- The upstream data file is treated as untrusted data: validated, re-encoded and embedded with `<`
  escaped. Cells are built with `textContent`, never `innerHTML`.
- No clipboard *reads* at all. The clipboard is written only by an explicit copy (Shift, or the
  Citrix/no-target fallback).
- No network, no new permissions (synthetic key events use Hammerspoon's existing Accessibility).
  No timers or watchers run while the picker is closed.

## Gaps (honest list)
- **Emoji data needs `omarchy-port sync`.** Without the upstream checkout you get only the small
  built-in set, and a toast says so.
- **Secure input fields** (password boxes, apps with Secure Keyboard Entry on) ignore synthetic
  key events. Nothing is typed there, so use Shift+Return to copy.
- **Very long sequences** (more than 20 UTF-16 units, which is the macOS key-event limit) are copied
  instead of typed. No emoji in Omarchy's list reaches that limit.
- **Localisation.** The strings are the English ones from Omarchy's `shell.json`
  ("Search emojis…", "No matches for “%1”"). Right-to-left arrow mirroring is not reproduced.
- Like Omarchy, there is no skin-tone picker and no recently-used list.

## Test steps
1. Run `omarchy-port sync`, install the port, reload Hammerspoon, and check that
   `~/.local/state/omarchy-mac/hs.log` has no `emojis:` errors.
2. Focus TextEdit and run `open -g 'hammerspoon://omarchy?a=emojis.toggle'`. Expected: the dimmed
   screen, a centred card in theme colours with a foreground border, "Search emojis…" and a grid of
   emoji.
3. Type `heart`. The grid filters. Use the arrows and PageDown. Press Return, and the picker closes
   and the emoji appears in TextEdit. The clipboard is unchanged.
4. Pick 👨‍👩‍👧 (type `family`). It is inserted as one character, not as separate people.
5. Type `zzzzqq`. You see 󰈉 and "No matches for “zzzzqq”". Esc clears the filter, and Esc again
   closes and returns focus to TextEdit.
6. Focus Citrix Viewer, open the picker and press Return on an emoji. Nothing is typed, the toast
   says it was copied, and ⌘V pastes it.
7. Shift+Return on an emoji copies it without typing.
8. Move `emojis.json` away and open the picker. A toast mentions `omarchy-port sync` and the
   built-in set is shown.
9. `grep -i emojis ~/.local/state/omarchy-mac/hs.log`: no emoji and no search text appear.
