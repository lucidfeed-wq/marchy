# omarchy.agents → macOS (`agents`)

**Status: partial** · **Bar placement: trailing** (Omarchy kind `bar-widget`) · **Requires: nothing new** (Hammerspoon built-ins, `/usr/bin/security`; the sign-in links use the existing Ghostty launcher, and *start agent* uses the built-in `agents` picker)

## What it does
One bar icon and one panel that show how much of each AI coding subscription is left.

- **Bar:** 󱚣 (U+F16A3) in the bar's foreground colour. It turns to the urgent (error) colour when
  any subscription window is at 90 % or more. Click opens the panel. Right click starts an agent
  (Omarchy's right click = `omarchy-agent --pick`).
- **Panel (380 px, like Omarchy):**
  - **Hero:** 󱚣 at 24 px, **Agents** in bold, and the meta line **SUBSCRIPTIONS**. Two square
    accent-tinted buttons: 󰑐 *Refresh now* and 󰞷 *Start the default agent*.
  - **One section per subscription:** a separator, then the provider mark (Omarchy's own SVG marks,
    drawn as `ui.path`), the bold name, an 󰋽 note when the numbers are not current (its tooltip says
    why and what to do), and the plan on the right (for example *Max 20x*, *Pro 100*, *SuperGrok*).
  - **One compact line per limit window:** title (30 % width), meter (red at 90 % or more), and the
    time until it resets (`2d 3h`, `4h 12m`, `7m`). The tooltip shows *Weekly: 42% used · resets in
    2d 3h*, the numbers' age when they are stale, and any model-scoped allowance. A model-scoped
    allowance on the same clock (Claude's *Fable Weekly*, a Codex model bucket) is a tick on that
    window's meter, as in Omarchy. A window whose reset time has passed reads as empty.
  - **Sign-in required:** a red link for a lapsed or missing Claude, Codex or Grok sign-in. It opens
    the CLI's own login in a terminal (`claude auth login`, `codex login`, `grok login`), and the
    numbers refresh a minute later.
  - **Blank slate:** with nothing signed in, the panel shows Omarchy's intro sentence and Claude
    Code, Codex and Grok as large marks. A provider whose CLI is not installed is dimmed and says so
    on hover.

## Omarchy → macOS mapping
| Omarchy | macOS port |
|---|---|
| `Panel.qml` bar button + `KeyboardPanel` | OmniShell widget `omarchy-agents` (`look.bar`, `look.panel` popout) |
| `Main.qml` + `Agent.qml` watching `~/.local/state/omarchy/agents/usage/*.json` | Hammerspoon module publishes one JSON var `omarchy_agents` with `omniwmctl shell set`, only when it changed. It republishes when OmniWM relaunches |
| `omarchy-agent-usage-update` + Python collectors (`collectors.py`) | **not run.** Three providers are re-implemented in Lua (below) |
| `claude` collector: `.credentials.json` → `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | same endpoint and headers through `hs.http.asyncGet`. The token comes from `~/.claude/.credentials.json`, else from Claude Code's login-keychain item `Claude Code-credentials` (`/usr/bin/security find-generic-password -s … -w`, which is where Claude Code keeps it on macOS). Session (5-hour), Weekly (7-day) and model-scoped `limits[]` are mapped exactly as in the collector. The plan comes from `~/.claude.json`'s rate-limit tier, else the credentials (`plan_label`) |
| `codex` collector: `codex app-server` `account/rateLimits/read` | **local only:** the `rate_limits` block Codex writes into its own `~/.codex/sessions/**/rollout-*.jsonl` (`token_count` events). It reads the tail (512 KB) of the 8 newest logs from the last 14 session days and keeps the latest snapshot per limit bucket. Plan names are Codex's `/status` table (`prolite` → *Pro 100*, …). Older than 15 min → marked stale |
| `grok` collector: `~/.grok/auth.json` → `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (+ `/v1/billing` for unified billing) | same endpoints and parsing (weekly or monthly credits, monthly included quota), plan from `settings_cache.json`'s `subscription_tier_display` |
| Status texts *Waiting for auth*, *Limits paused*, *Sign-in expired*, *… limits unavailable*, `usageNote()` | same rules and English texts, computed in Lua (`note`, `signin` fields) |
| `limitWindow` / `displayWindows` / `scopedPart` / `bindingWindow` / `formatDuration` | same logic: titles and attaching scoped windows in Lua; reset expiry, durations and the urgent check in the widget, against `ctx.data.seconds` |
| 15 s reuse of a recent answer; forced refresh skips it; 30 s retry when an endpoint could not be reached | same |
| `refreshIntervalSec` (default 900, 30–3600) and `providers.<id>.enabled` settings | `~/.config/omarchy-mac/agents.json`: `{ "refreshIntervalSec": 900, "remote": true, "providers": { "grok": { "enabled": false } } }`. `remote: false` turns every network check off |
| IPC `omarchy-shell omarchy.agents open/close/toggle/refresh` | `agents.toggle` (`omniwmctl shell toggle omarchy-agents`, plus a limits refresh), `agents.refresh` |
| Right click / 󰞷 `omarchy-agent --pick` | `agents.launch` → the built-in Hammerspoon action `agents` (the agent picker; not redefined) |
| *Sign-in required* → `omarchy-agent-account-add --reauth` | `agents.signin` (x = `claude`, `codex` or `grok`, whitelisted) → the CLI's own login in a floating Ghostty (`omarchy.launch.tui`), with a fixed command from the module's table |
| Middle click = refresh, `r` | the 󰑐 hero button (OmniShell has no middle-click handler) |
| Assets `assets/claude.svg`, `codex.svg`, `grok.svg` | the same path data, embedded in the widget as `ui.path` (OmniShell images do not load SVG). Marks © Omarchy contributors, MIT licence (shipped with Omarchy's `omarchy.agents` plugin). Claude keeps its brand orange `#D97757`. The white Codex and Grok marks use the theme foreground, which also covers Omarchy's `-light` variants |

## Hotkeys to bind (Omarchy chords → actions)
| Omarchy chord | Action |
|---|---|
| `SUPER + SHIFT + CTRL + A` (`omarchy-agent --pick`) | `agents.launch` |
| — (IPC `omarchy.agents toggle`, no default chord) | `agents.toggle` |

Add them to `~/.config/omarchy-mac/bindings.toml` (`hs = "agents.launch"`, …). The built-in `agents`
action is unchanged.

## Safety
- **Credentials are read, never written or shown.** The only secrets read are Claude Code's and
  Grok's own sign-in tokens, from their own credential stores. They are used only in the
  `Authorization` header of a request to that provider's own usage endpoint over HTTPS
  (`api.anthropic.com`, `cli-chat-proxy.grok.com`). Nothing is ever refreshed, written back, logged,
  persisted or published.
  - Files are re-read on each check and the reference is dropped after the request.
  - A Claude login that came from the **keychain** is kept in Hammerspoon's memory until its access
    token lapses (about 8 h). Then macOS is asked at most once per token rather than every 15
    minutes. That copy is dropped on a 401/403 response, on a forced refresh and on `M.stop`.
  - The Claude refresh token is checked only for presence, to tell *Limits paused* from *Sign-in
    expired*, and is not kept.
- **What leaves the module:** provider id and name, plan label, fixed status and help sentences,
  percentages, reset times and fetch times. No emails, account ids or tokens. Log lines carry only
  HTTP status or exit codes.
- **Codex session logs contain conversation text.** Only the last 512 KB of the newest logs is read.
  Only lines that contain both `"token_count"` and `"rate_limits"` are JSON-decoded, and the rest is
  discarded without being parsed or stored.
- **Keychain.** If macOS asks whether `security` may read *Claude Code-credentials*, **Allow** gives
  the limits for that token's lifetime. **Always Allow** stops the question for good, but it also
  lets any process that runs `/usr/bin/security` read that item, so prefer Allow. **Deny** is
  remembered: the panel says so and does not ask again until you press refresh. No Full Disk
  Access, no browser cookies or storage, no new permissions.
- **Network** is limited to those two endpoints, every 15 minutes by default (more often only when
  you press refresh or open the panel with the hotkey, and never within 15 s of the last answer).
  `"remote": false` in `agents.json` turns it off completely. Codex needs no network.
- **URL arguments.** Only `agents.signin` takes one, and it must be `claude`, `codex` or `grok`.
  The command run is fixed (`'<binary from a fixed list>' auth login` / `login`). Nothing from `x`
  reaches a shell.
- Everything is async (`hs.task`, `hs.http.asyncGet`, `hs.timer`). A run that never answers gives
  way after 2 minutes. `M.stop` stops every timer, watcher and task.

## Gaps (honest list)
- **20 of Omarchy's 23 providers are not ported:** Kimi, Cursor, Grok Bot, Copilot, Muse,
  Antigravity, Kimchi, Hermes, Devin, Mistral Vibe, Qwen, OpenCode, Z.ai, Ollama Cloud, MiniMax,
  OpenRouter, DeepSeek, Fireworks, Synthetic and Local models.
  - Some need API keys taken from environment variables (which Hammerspoon does not see) or from
    other tools' config files (pi, omp, opencode, …).
  - Some need sources that are not acceptable here: Cursor's editor database `state.vscdb`, the
    Antigravity keyring entry and omp's `agent.db`.
  - The rest have no limits at all and only local transcript statistics.
  - Prepaid **balances** (the fuel-gauge meter) therefore never appear.
- **No local token statistics.** Omarchy's hero line rotates through tokens this week and today, the
  most used model, the busiest day, and prompts and sessions today, all built from every agent's
  transcripts. Scanning those transcripts is not done here, so the hero always shows Omarchy's own
  fallback, *SUBSCRIPTIONS*. An agent with history but no subscription gets no section, which
  matches Omarchy.
- **Codex limits are not live.** Without the Codex app-server they are the snapshot Codex wrote
  during its last session. Usage on another machine or in the web app does not show until Codex
  next runs here. The numbers are marked stale after 15 minutes. The spend cap (*Spend limit*) and
  free reset credits are not read.
- **Accounts.** There are no multiple accounts, *ACTIVE*/*Use* lines, Autoswitch, renaming, 1–9
  jumps or near-limit 3-minute polling. Omarchy's `omarchy agent account` machinery does not exist
  on this Mac.
- **Adding a subscription** is the CLI's own login in a terminal, offered on the blank slate and from
  *Sign-in required*. There is no in-panel name field, device code or paste-back, and no **+** in the
  hero (its place holds refresh).
- **"Make something cool"** starter tiles are not ported. Their prompts are Omarchy-specific
  (Omarchy themes, plugins and apps through `omarchy agent prompt`).
- **Cross-device sync** (`syncMode`, `syncDir`, …) and the drag or Ctrl+↑↓ reordering (`order.json`)
  are not ported. The order is fixed: Claude Code, Codex, Grok.
- **Keyboard navigation** inside the panel (arrows, Enter, `r`, Tab) is not available in an
  OmniShell popout. Use the mouse, or the refresh button.
- **Claude:** `CLAUDE_CONFIG_DIR` is not honoured (Hammerspoon has no shell environment), so only
  `~/.claude` is used. The last good limits are kept in memory only, so after a Hammerspoon reload
  the section fills on the first successful check.
- English strings only (Omarchy's i18n catalogue is not loaded).

## Test steps
1. Install with `omarchy-port install agents --bar` and reload Hammerspoon. The 󱚣 icon appears on the
   right of the bar. Check that `~/.local/state/omarchy-mac/hs.log` has no `agents:` errors (a
   `claude usage check failed (status …)` warning is fine offline).
2. Click the icon. Expected: the hero *Agents / SUBSCRIPTIONS* with 󰑐 and 󰞷, then a *Claude Code*
   section with its orange mark, the plan on the right, *Session* and *Weekly* meters with reset
   times. If macOS asked for keychain access first, choose Allow.
3. Hover a meter. Expected: *Weekly: 42% used · resets in 2d 3h* (plus *Fable: …* when a model
   allowance exists). Compare with `/usage` in Claude Code.
4. If Codex has run here: a *Codex* section with the plan (for example *Pro 100*) and its windows. An
   older snapshot shows 󰋽 with *Codex limits as of its last session…*.
5. Press 󰑐. In the log you see no new errors, and the numbers update within a few seconds.
6. Right-click the bar icon, or press 󰞷. The agent picker opens.
7. Sign out of Grok (or rename `~/.grok/auth.json`) and refresh. You see *Sign-in required* in red,
   and clicking it opens `grok login` in a floating terminal.
8. Put `{ "remote": false }` in `~/.config/omarchy-mac/agents.json` and refresh. Claude and Grok read
   *Limits paused* (with the reason on 󰋽) and no network request is made. Codex still works.
9. Verify privacy: `grep -iE 'bearer|sk-ant|accessToken' ~/.local/state/omarchy-mac/hs.log` finds
   nothing. The published var carries only ids, names, plans, fixed status texts, percentages and
   times (see `snapshot()` in the module).
