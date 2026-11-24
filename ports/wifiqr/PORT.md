# omarchy.wifiqr → macOS (`wifiqr`)

**Status: ported** · **Bar placement: none** (Omarchy kind `panel`, no bar presence) · **Requires: nothing** (Hammerspoon built-ins and `/usr/bin/security`)

## What it does
Shares the connected Wi-Fi network as a QR code that a phone can scan to join. Like Omarchy's
share card, it has no card of its own. The code floats on a heavy near-black scrim (78 %) over the
whole screen:

| Element | Look |
|---|---|
| Network name | spaced small capitals (10 px bold, letter-spacing 2), white at 55 % |
| QR code | dark modules `#111111` on a white square, square corners, module size `max(4, floor(240 / modules))` px, 4-module quiet zone |
| "Generating QR code…" | 11 px, white at 55 %, while it works |
| Errors | 11 px, `#ff6b6b` |
| "Scan to join this network" | 11 px, white at 55 % |
| "Show password" (secured networks) | 11 px white at 60 %. Click it to show the passphrase in place, and click again to hide it |

Esc or a click on the scrim closes it. Summoning it again starts from scratch, so nothing from the
previous card carries over. The payload is the standard
`WIFI:T:<WPA|WEP|nopass>;S:<ssid>;P:<password>;;`, with `\ ; , :` escaped exactly as in
`omarchy-network-qr`.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `OverlayWindow` + scrim + `Keys.onEscapePressed` | full-screen `hs.webview` (borderless, transparent, `modalPanel` level, `allowTextEntry`), scrim and content drawn in the page, usercontent channel `omarchy_wifiqr` |
| `omarchy-network-qr --meta` (nmcli: device, SSID, key-mgmt) | `hs.wifi.interfaces()[1]`, `hs.wifi.currentNetwork(iface)`, `hs.wifi.interfaceDetails(iface).security` (Personal → WPA, WEP → WEP, None/OWE → nopass, Enterprise/802.1X → refused as in Omarchy; raw CoreWLAN codes that Hammerspoon reports as `unrecognized (<n>)`, such as 11 = WPA3 Personal on this Mac, are mapped too) |
| nmcli `--show-secrets` PSK | `/usr/bin/security find-generic-password -D "AirPort network password" -a <ssid> -w`. The SSID is passed as its own argv element, with no shell. macOS asks you to allow it |
| `qrencode --margin 4` | a small QR encoder in Lua inside the module: byte mode, error correction M, versions 1–15 (up to 412 bytes), all 8 masks scored. Built locally, with no network and no third-party code. Tested by decoding 49 payloads covering every version boundary (v1–v15) with CoreImage's QR detector on Lua 5.4 and LuaJIT |
| Grid of native rectangles | one inline SVG `<path>` with crisp edges |
| `omarchy-network-password` reveal (`Show password`) | toggles the passphrase that was already read for the code. No second read |
| Entry point `omarchy-shell shell summon omarchy.wifiqr` (menu Setup › Network › QR Code) | actions `wifiqr.open` (re-summon), `wifiqr.toggle`, `wifiqr.close` |

### Deliberate difference (clinical machine)
Omarchy builds a secured network's code the moment the card opens. On macOS, reading the saved
password needs the user's authorisation. So for a secured network the card first shows the network
name and **"Show QR code ⏎"**, with a hint that macOS will ask. The password is read only after that
click (or Return). Open networks need no secret, so their code appears immediately. While macOS's
prompt is up, the overlay drops to normal window level so the prompt is never hidden behind it, and
losing focus to the prompt does not close the card.

## Hotkeys to bind (Omarchy chords → actions)
Omarchy has no default chord for it (it opens from the menu: Setup › Network › QR Code, and from the
network panel). Suggested:

| Omarchy entry | Action |
|---|---|
| menu `setup.network.qr` (alias `wifi-qr`) | `wifiqr.open` |

Add it to `~/.config/omarchy-mac/bindings.toml` (`hs = "wifiqr.open"`) under a chord of your choice.

## Safety
- **The Wi-Fi password is a secret.** It is read only on an explicit click or Return, through macOS's
  own authorisation prompt. It is kept only in this module's memory and in the open page, and only
  for as long as the card is open. It never goes to the log (the only log lines are "open
  (secured|open network|no code)" and a security exit code), a file, `omniwmctl` (this port publishes
  nothing), or a URL.
- Closing, re-summoning, Esc, the scrim or switching away all do the same thing: they kill a pending
  `security` read, drop the password and the code, and delete the webview. A result that arrives
  after the card closed is discarded (generation counter).
- When macOS asks, choose **Allow**, not **Always Allow**. Always Allow would let `/usr/bin/security`
  read that item without asking from then on.
- The page sends only fixed verbs (`close`, `blur`, `generate`, `password`, `location`). Lua
  validates them against a whitelist, and all text is HTML-escaped. URL actions take no argument.
- No network access, no CDN, no new permissions. Location (already granted to Hammerspoon) is only
  read, to explain a hidden SSID. No timers or watchers run while the card is closed.

## Gaps (honest list)
- **Hidden networks.** macOS does not say whether the current network is hidden, so the code never
  carries `H:true`. Phones still join after one scan in most cases, but a hidden SSID may need the
  phone to be told it is hidden.
- **Passwords only in the iCloud Keychain** (not in the System/login keychain) cannot be read by
  `security`. The card then says "Could not read the Wi-Fi password".
- **Enterprise (802.1X) networks** are refused, as in Omarchy.
- **Interface choice.** Omarchy takes the default-route device. The port uses the first Wi-Fi
  interface (`en0` on every current Mac) and does not accept an interface payload.
- **Lua strings cannot be wiped.** The password is released (references dropped, webview deleted) on
  close and freed by the garbage collector later. It is not zeroed in memory.
- The card does not scale itself down on very small screens (Omarchy scales the content to fit). At
  a 240 px code that matters only below about 320 × 420 points.

## Test steps
1. Install the port, reload Hammerspoon, and check that `~/.local/state/omarchy-mac/hs.log` has no
   `wifiqr:` errors.
2. On a WPA2/WPA3 network: `open -g 'hammerspoon://omarchy?a=wifiqr.open'`. Expected: dark scrim, the
   network name in spaced capitals, **Show QR code ⏎** and the macOS hint. There is no keychain
   prompt yet.
3. Press Return. Expected: macOS asks to allow `security` to read the item (enter an admin password
   and choose Allow). The QR appears with "Scan to join this network" and "Show password". Scan it
   with a phone camera: it offers to join the network.
4. Click "Show password", and the passphrase appears. Click again, and it is hidden.
5. Press Esc. The overlay closes and focus returns to the previous app. Open it again: the
   **Show QR code** step is back (nothing was kept).
6. Open it, press Return, and press Esc while the macOS prompt is still up. The prompt's result is
   ignored (nothing reappears).
7. On an open network: the code appears immediately, with no prompt and no password line.
8. Remove Hammerspoon's Location permission. The card shows "Allow Location for Hammerspoon to see
   network names", and clicking it opens Privacy & Security.
9. `grep -i wifiqr ~/.local/state/omarchy-mac/hs.log`: no SSID password or QR payload appears.
