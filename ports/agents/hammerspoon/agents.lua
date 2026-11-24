-- omarchy.agents: port of the Omarchy 4.5 shell plugin `omarchy.agents` (Agents bar panel).
--
-- Omarchy: one bar icon (󱚣, urgent when an account is at 90 % of a window) and one panel:
-- a hero ("Agents" + a rotating summary line, buttons to add a subscription and start the
-- default agent), then one section per subscription: its mark, name and plan, and a compact
-- line per rate-limit window (meter + time until it resets; exact percentage on hover), with
-- model-scoped allowances as ticks on the window they share a clock with, "Sign-in required"
-- links for lapsed Claude / Codex / Grok sign-ins and an info mark explaining stale numbers.
-- The numbers come from omarchy-agent-usage-update, a set of Python collectors.
--
-- Here, Omarchy's collectors are NOT run. This module re-implements only what is safe:
--   claude  Anthropic's OAuth usage endpoint (5-hour session, 7-day weekly, model-scoped
--           windows), asked over HTTPS with hs.http.asyncGet using the access token Claude
--           Code itself keeps: ~/.claude/.credentials.json, else its login-keychain item
--           "Claude Code-credentials" read with /usr/bin/security. Read-only: the token is
--           never refreshed, written, logged or published; only percentages, reset times
--           and the plan label leave this module. A lapsed token reads "Limits paused".
--   codex   no network and no token: the rate_limits block Codex writes into its own session
--           logs (~/.codex/sessions/**/rollout-*.jsonl). Only the tail of the newest logs is
--           read and only the token_count lines are parsed (never message content).
--   grok    the credits endpoint behind Grok's /usage view, asked with the token the Grok
--           CLI keeps in ~/.grok/auth.json (same rules as Claude: read-only, never logged).
-- Every other Omarchy provider is a gap (see PORT.md). Remote checks can be switched off in
-- ~/.config/omarchy-mac/agents.json: { "remote": false }.
--
-- State goes to the omarchy-agents widget with `omniwmctl shell set omarchy_agents <json>`
-- (only when it changed). Actions: agents.refresh, agents.toggle, agents.launch,
-- agents.signin (x = claude | codex | grok).
local M = { id = "agents" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local HOME = os.getenv("HOME")
local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local SECURITY = "/usr/bin/security"
local VAR = "omarchy_agents"
local WIDGET = "omarchy-agents"
local OMNIWM = "com.barut.OmniWM"
local CONFIG = HOME .. "/.config/omarchy-mac/agents.json"

local CLAUDE_USAGE = "https://api.anthropic.com/api/oauth/usage"
local GROK_CREDITS = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
local GROK_MONTHLY = "https://cli-chat-proxy.grok.com/v1/billing"
local REUSE_SECONDS = 15            -- a recent answer is reused unless refresh is pressed
local CURRENT_ENOUGH = 900          -- a 429 on numbers this young keeps them current
local CODEX_STALE = 900             -- session-log limits older than this are marked stale
local RETRY_SECONDS = 30            -- endpoint unreachable (network not up yet)
local GROK_REFRESH_LIFETIME = 30 * 24 * 3600
local DEFAULT_INTERVAL = 900

local ORDER = { "claude", "codex", "grok" }
local NAMES = { claude = "Claude Code", codex = "Codex", grok = "Grok" }
local BINARIES = {
  claude = { HOME .. "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", HOME .. "/.claude/local/claude" },
  codex = { HOME .. "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex" },
  grok = { HOME .. "/.grok/bin/grok", HOME .. "/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok" },
}
local LOGIN_ARGS = { claude = "auth login", codex = "login", grok = "login" }

local HELP = {
  claudeAuth = "Run `claude auth login` to restore authoritative usage.",
  codexAuth = "Run `codex login` to authenticate.",
  grokAuth = "Start Grok, or run `grok login`, to sign in.",
  remoteOff = "Remote limit checks are off in ~/.config/omarchy-mac/agents.json.",
  keychain = "macOS did not allow reading Claude Code's sign-in from the keychain. Press refresh to ask again.",
}

-- Codex's own /status plan names (Omarchy's PLAN_NAMES).
local CODEX_PLANS = {
  free = "Free", go = "Go", plus = "Plus", pro = "Pro 200", prolite = "Pro 100", promax = "Pro 500",
  team = "Business", self_serve_business_usage_based = "Business",
  self_serve_business_prolite = "Business Premium", business = "Enterprise",
  enterprise_cbp_automation = "Enterprise (Automation)", enterprise_cbp_usage_based = "Enterprise",
  ent26 = "Enterprise", enterprise = "Enterprise", edu = "Edu", edu_plus = "Edu Plus", edu_pro = "Edu Pro",
}

---------------------------------------------------------------- helpers
local function now() return os.time() end

local function exists(p) return p ~= nil and hs.fs.attributes(p) ~= nil end
local function isDir(p) return p ~= nil and hs.fs.attributes(p, "mode") == "directory" end

local function readFile(path, limit)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local data = fh:read(limit or "a")
  fh:close()
  return data
end

local function readJSON(path)
  local raw = readFile(path)
  if not raw then return nil end
  local ok, v = pcall(hs.json.decode, raw)
  raw = nil
  if ok and type(v) == "table" then return v end
  return nil
end

local function num(v)
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
  if type(v) == "string" then
    local n = tonumber((v:gsub("%%", ""):match("^%s*(.-)%s*$")))
    if n and n == n then return n end
  end
  return nil
end

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

-- A JSON string field (hs.json may hand back a null sentinel for JSON null).
local function str(v)
  if type(v) == "string" then return v end
  return nil
end

-- Run an async callback body; any error still finishes the provider's refresh step.
local function guarded(done, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      log.e("agents: collector callback failed: %s", tostring(err))
      done()
    end
  end
end

local function findBinary(id)
  for _, p in ipairs(BINARIES[id] or {}) do
    local perms = hs.fs.attributes(p, "permissions")
    if perms and perms:sub(3, 3) == "x" then return p end
  end
  return nil
end

-- days since 1970-01-01 for a civil date (Howard Hinnant's algorithm), integer arithmetic only
local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- ISO 8601 -> epoch seconds (UTC); also accepts epoch seconds / milliseconds.
local function epoch(v)
  if type(v) == "number" then
    if v > 1e12 then return math.floor(v / 1000) end
    return math.floor(v)
  end
  if type(v) ~= "string" or v == "" then return nil end
  if v:match("^%d+$") then return epoch(tonumber(v)) end
  local y, mo, d, h, mi, s, rest = v:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d*)(.*)$")
  if not y then return nil end
  local t = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(s) or 0)
  rest = rest:gsub("^%.%d+", "")
  local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)")
  if sign then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    if sign == "+" then t = t - off else t = t + off end
  end
  return t
end

local function loadConfig()
  local cfg = readJSON(CONFIG) or {}
  local interval = num(cfg.refreshIntervalSec) or DEFAULT_INTERVAL
  if interval < 30 then interval = 30 elseif interval > 3600 then interval = 3600 end
  local enabled = {}
  for _, id in ipairs(ORDER) do
    local p = type(cfg.providers) == "table" and cfg.providers[id]
    enabled[id] = not (type(p) == "table" and p.enabled == false)
  end
  return { interval = math.floor(interval), remote = cfg.remote ~= false, enabled = enabled }
end

---------------------------------------------------------------- records
local rec = {}
for _, id in ipairs(ORDER) do rec[id] = { limits = {}, plan = "", status = "", help = "", stale = false, fetchedAt = 0 } end
local config = { interval = DEFAULT_INTERVAL, remote = true, enabled = { claude = true, codex = true, grok = true } }
local timer, retryTimer, appWatcher, signinTimer, kickTimer
local timerInterval = nil
local running = false
local runningSince = 0
local queued = nil
local lastJSON = nil
local keychainBlocked = false
local keychainTask = nil
local keychainLogin = nil
local publishTask = nil

local function keep(r)
  -- Kept limits after a failed or impossible check: shown with their age, marked stale.
  r.stale = #r.limits > 0
end

---------------------------------------------------------------- Claude Code
local function planLabel(tier, subscription)
  local plan = ""
  if subscription and subscription ~= "" then plan = subscription:sub(1, 1):upper() .. subscription:sub(2) end
  local mult = tier and tier:lower():match("max_(%d+x)")
  if not mult then return plan end
  return (plan ~= "" and plan or "Max") .. " " .. mult
end

-- The CLI's profile (~/.claude.json) restates the tier after an upgrade; the credentials keep
-- the one their token was minted with. Only the two tier strings are pattern-matched out.
local function profileTier()
  local raw = readFile(HOME .. "/.claude.json")
  if not raw then return "" end
  local tier = raw:match('"userRateLimitTier"%s*:%s*"([^"]+)"') or raw:match('"organizationRateLimitTier"%s*:%s*"([^"]+)"') or ""
  raw = nil
  return tier
end

-- Only the fields the probe needs survive; the refresh token and everything else is dropped.
local function parseClaudeLogin(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, v = pcall(hs.json.decode, raw)
  if not ok or type(v) ~= "table" or type(v.claudeAiOauth) ~= "table" then return nil end
  local o = v.claudeAiOauth
  local login = {
    token = type(o.accessToken) == "string" and o.accessToken or "",
    expires = epoch(num(o.expiresAt)) or 0,
    refreshExpires = epoch(num(o.refreshTokenExpiresAt)) or 0,
    hasRefresh = type(o.refreshToken) == "string" and o.refreshToken ~= "",
    subscription = type(o.subscriptionType) == "string" and o.subscriptionType or "",
    tier = type(o.rateLimitTier) == "string" and o.rateLimitTier or "",
  }
  v, o = nil, nil
  return login
end

local function claudeLogin(force, cb)
  local file = readFile(HOME .. "/.claude/.credentials.json")
  if file then
    local login = parseClaudeLogin(file)
    file = nil
    return cb(login, nil)
  end
  -- A login read from the keychain is reused (in memory only) until its token lapses, so macOS
  -- asks at most once per token lifetime instead of on every refresh.
  if not force and keychainLogin and keychainLogin.expires > now() + 60 then return cb(keychainLogin, nil) end
  keychainLogin = nil
  if keychainBlocked and not force then return cb(nil, "keychain") end
  if keychainTask then return cb(nil, "busy") end
  local ok, err = pcall(function()
    keychainTask = hs.task.new(SECURITY, function(code, out)
      keychainTask = nil
      if code == 0 then
        keychainBlocked = false
        local login = parseClaudeLogin(out)
        out = nil
        if login and login.token ~= "" and login.expires > 0 then keychainLogin = login end
        cb(login, nil)
      elseif code == 44 then
        cb(nil, "missing")
      else
        keychainBlocked = true
        log.w("agents: keychain item for Claude Code not readable (exit %s)", tostring(code))
        cb(nil, "keychain")
      end
    end, { "find-generic-password", "-s", "Claude Code-credentials", "-w" })
    if not keychainTask:start() then error("could not start security") end
  end)
  if not ok then
    keychainTask = nil
    log.e("agents: %s", tostring(err))
    cb(nil, "missing")
  end
end

local function claudeLimits(payload)
  local limits = {}
  local function bucket(key, label)
    local b = payload[key]
    if type(b) ~= "table" then return end
    local u = num(b.utilization)
    if u and u >= 0 then
      limits[#limits + 1] = { label = label, percent = clamp01(u / 100), resetsAt = epoch(b.resets_at) or 0 }
    end
  end
  bucket("five_hour", "Session (5-hour)")
  bucket("seven_day", "Weekly (7-day)")
  if type(payload.limits) == "table" then
    local seen = {}
    for _, entry in ipairs(payload.limits) do
      local scope = type(entry) == "table" and entry.scope
      local model = type(scope) == "table" and scope.model
      if type(model) == "table" then
        local name = tostring(model.display_name or model.id or ""):match("^%s*(.-)%s*$")
        local kind = tostring(entry.kind or ""):lower()
        local pct = num(entry.percent)
        if name ~= "" and pct and pct >= 0 and not seen[name .. "\0" .. kind] then
          seen[name .. "\0" .. kind] = true
          local window = kind:find("month", 1, true) and "Monthly"
            or ((kind:find("week", 1, true) or kind:find("day", 1, true)) and "Weekly")
            or ((kind:find("hour", 1, true) or kind:find("session", 1, true)) and "Session") or ""
          local title = window ~= "" and (name .. " " .. window) or name
          limits[#limits + 1] = { label = title, title = title, percent = clamp01(pct / 100), resetsAt = epoch(entry.resets_at) or 0 }
        end
      end
    end
  end
  return limits
end

local function collectClaude(force, done)
  local r = rec.claude
  r.inUse = isDir(HOME .. "/.claude") or exists(HOME .. "/.claude.json")
  if not r.inUse then
    r.limits, r.plan, r.status, r.help, r.stale = {}, "", "", "", false
    return done()
  end
  local tier = profileTier()
  claudeLogin(force, function(login, why)
    local credTier = login and login.tier or ""
    local useTier = tier:lower():match("max_%d+x") and tier or credTier
    if useTier == "" then useTier = tier end
    r.plan = planLabel(useTier, login and login.subscription or "")
    if not login or login.token == "" then
      if why == "busy" then return done() end
      keep(r)
      r.status = "Waiting for auth"
      r.help = why == "keychain" and HELP.keychain or HELP.claudeAuth
      return done()
    end
    local t = now()
    if login.expires > 0 and login.expires <= t then
      keep(r)
      -- A lapsed access token is routine: Claude Code renews it the next time it runs.
      if login.hasRefresh and (login.refreshExpires == 0 or login.refreshExpires > t) then
        r.status = "Limits paused"
        r.help = "Claude Code's access token has lapsed" .. (#r.limits > 0 and " — showing the last known limits." or ".")
          .. " Start Claude Code to refresh it; signing in again is not needed."
      else
        r.status = "Sign-in expired"
        r.help = "Claude Code's saved sign-in expired" .. (#r.limits > 0 and " — showing the last known limits." or ".")
          .. " Start Claude Code, or run `claude auth login`, to refresh it."
      end
      login = nil
      return done()
    end
    if not config.remote then
      keep(r)
      r.status, r.help = "Limits paused", HELP.remoteOff
      login = nil
      return done()
    end
    if not force and r.probedAt and t - r.probedAt < REUSE_SECONDS then
      login = nil
      return done()
    end
    local headers = { Authorization = "Bearer " .. login.token, Accept = "application/json" }
    headers["anthropic-beta"] = "oauth-2025-04-20"
    login = nil
    r.probedAt = t
    hs.http.asyncGet(CLAUDE_USAGE, headers, guarded(done, function(status, body)
      local ok, payload = pcall(hs.json.decode, body or "")
      body = nil
      if status == 200 and ok and type(payload) == "table" then
        local limits = claudeLimits(payload)
        if #limits > 0 then
          r.limits, r.fetchedAt, r.stale, r.status, r.help, r.retry = limits, now(), false, "", "", false
          return done()
        end
        keep(r)
        r.status = #r.limits > 0 and "" or "Claude limits unavailable"
        r.help = "Anthropic's usage endpoint returned no limits."
        return done()
      end
      if type(status) ~= "number" or status <= 0 then
        r.retry = true
        r.help = "Couldn't reach Anthropic's usage endpoint. Retrying shortly."
      elseif status == 429 then
        r.help = "Anthropic's usage endpoint is rate limiting checks right now."
      elseif status == 401 or status == 403 then
        keychainLogin = nil
        r.help = "Anthropic refused Claude Code's sign-in. Start Claude Code, or run `claude auth login`, to sign in again."
      else
        r.help = "Anthropic's usage endpoint returned status " .. tostring(math.floor(status)) .. "."
      end
      log.w("agents: claude usage check failed (status %s)", tostring(status))
      keep(r)
      if status == 429 and r.fetchedAt > 0 and now() - r.fetchedAt < CURRENT_ENOUGH then r.stale = false end
      r.status = (status == 401 or status == 403) and "Sign-in expired" or (#r.limits == 0 and "Claude limits unavailable" or "")
      done()
    end))
    headers = nil
  end)
end

---------------------------------------------------------------- Codex (session logs, local only)
local function sortedDesc(dir, pattern)
  local out = {}
  local ok = pcall(function()
    for f in hs.fs.dir(dir) do
      if f:match(pattern) then out[#out + 1] = f end
    end
  end)
  if not ok then return {} end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- The newest rollout files, newest first (looks at the last few days that have sessions).
local function recentRollouts(root, maxDays, maxFiles)
  local files, days = {}, 0
  for _, y in ipairs(sortedDesc(root, "^%d%d%d%d$")) do
    for _, mo in ipairs(sortedDesc(root .. "/" .. y, "^%d%d$")) do
      for _, d in ipairs(sortedDesc(root .. "/" .. y .. "/" .. mo, "^%d%d$")) do
        local dir = root .. "/" .. y .. "/" .. mo .. "/" .. d
        for _, f in ipairs(sortedDesc(dir, "^rollout%-.*%.jsonl$")) do
          local path = dir .. "/" .. f
          files[#files + 1] = { path = path, mtime = hs.fs.attributes(path, "modification") or 0 }
        end
        days = days + 1
        if days >= maxDays then break end
      end
      if days >= maxDays then break end
    end
    if days >= maxDays then break end
  end
  table.sort(files, function(a, b) return a.mtime > b.mtime end)
  while #files > maxFiles do table.remove(files) end
  return files
end

local function tail(path, bytes)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local size = fh:seek("end") or 0
  local start = size > bytes and size - bytes or 0
  fh:seek("set", start)
  local data = fh:read("a") or ""
  fh:close()
  if start > 0 then data = data:gsub("^[^\n]*\n", "") end   -- drop the partial first line
  return data
end

local function codexWindow(w, at)
  if type(w) ~= "table" then return nil end
  local used = num(w.used_percent or w.usedPercent)
  if not used then return nil end
  local mins = num(w.window_minutes or w.windowDurationMins) or 0
  local label
  if mins == 10080 then label = "Weekly (7-day)"
  elseif mins > 0 and mins % 60 == 0 then label = math.floor(mins / 60) .. "h window"
  elseif mins > 0 then label = math.floor(mins) .. "m window"
  else label = "Limit" end
  local reset = epoch(num(w.resets_at or w.resetsAt)) or 0
  if reset == 0 then
    local rel = num(w.resets_in_seconds)
    if rel and at then reset = at + math.floor(rel) end
  end
  return { label = label, percent = clamp01(used / 100), resetsAt = reset, minutes = mins }
end

local function spanTitle(mins)
  if mins >= 28 * 24 * 60 then return "Monthly" elseif mins >= 24 * 60 then return "Weekly" elseif mins > 0 then return "Session" end
  return ""
end

-- Latest rate_limits per limit bucket from the newest session log that has any.
local function codexSnapshot(root)
  for _, file in ipairs(recentRollouts(root, 14, 8)) do
    local data = tail(file.path, 512 * 1024)
    if data and data:find('"rate_limits"', 1, true) then
      local lines = {}
      for line in data:gmatch("[^\n]+") do
        if line:find('"token_count"', 1, true) and line:find('"rate_limits"%s*:%s*{') then lines[#lines + 1] = line end
      end
      data = nil
      local buckets, order, plan, at = {}, {}, nil, nil
      for i = #lines, 1, -1 do
        local ok, ev = pcall(hs.json.decode, lines[i])
        local p = ok and type(ev) == "table" and ev.payload
        local rl = type(p) == "table" and p.type == "token_count" and p.rate_limits
        if type(rl) == "table" then
          local id = str(rl.limit_id) or "codex"
          if not buckets[id] then
            local ts = epoch(ev.timestamp) or file.mtime
            buckets[id] = { rl = rl, at = ts }
            order[#order + 1] = id
            if not at or ts > at then at = ts end
            if not plan and str(rl.plan_type) then plan = rl.plan_type end
          end
        end
      end
      if #order > 0 then
        table.sort(order, function(a, b)
          if (a == "codex") ~= (b == "codex") then return a == "codex" end
          return a < b
        end)
        local limits = {}
        for _, id in ipairs(order) do
          local b = buckets[id]
          local general = id == "codex" or (#order == 1 and not str(b.rl.limit_name))
          local name = str(b.rl.limit_name) or id
          for _, key in ipairs({ "primary", "secondary" }) do
            local w = codexWindow(b.rl[key], b.at)
            if w then
              if not general then
                local span = spanTitle(w.minutes)
                w.title = span ~= "" and (name .. " " .. span) or name
              end
              w.minutes = nil
              limits[#limits + 1] = w
            end
          end
        end
        return { limits = limits, plan = plan, at = at or file.mtime }
      end
    end
  end
  return nil
end

local function collectCodex(done)
  local r = rec.codex
  local home = HOME .. "/.codex"
  r.inUse = isDir(home)
  if not r.inUse then
    r.limits, r.plan, r.status, r.help, r.stale = {}, "", "", "", false
    return done()
  end
  local hasAuth = exists(home .. "/auth.json")
  local ok, snap = pcall(codexSnapshot, home .. "/sessions")
  if not ok then
    log.w("agents: codex session scan failed: %s", tostring(snap))
    snap = nil
  end
  if snap and #snap.limits > 0 then
    r.limits, r.fetchedAt = snap.limits, snap.at
    if snap.plan then r.plan = CODEX_PLANS[snap.plan] or (snap.plan:gsub("_", " ")) end
    r.stale = now() - snap.at > CODEX_STALE
    r.status = ""
    r.help = r.stale and "Codex limits as of its last session; they update the next time Codex runs." or ""
  elseif not hasAuth then
    keep(r)
    r.status, r.help = "Waiting for auth", HELP.codexAuth
  else
    keep(r)
    r.status = #r.limits > 0 and "" or "Codex limits unavailable"
    r.help = "No Codex session has reported its limits yet. Start Codex to see them."
  end
  done()
end

---------------------------------------------------------------- Grok
local function grokAmount(v)
  if type(v) == "table" then v = v.val or 0 end
  if type(v) == "boolean" then return nil end
  return num(v)
end

local function grokCredits(data)
  local config = type(data) == "table" and data.config
  local period = type(config) == "table" and config.currentPeriod
  if type(period) ~= "table" then return nil, "invalid" end
  local ends = epoch(period["end"])
  local used = config.creditUsagePercent
  if type(used) ~= "number" and type(used) ~= "string" and type(used) ~= "table" then
    if config.isUnifiedBillingUser == true then return nil, "unified" end
    if not ends or ends <= now() then return nil, "invalid" end
    used = 0
  end
  local amount = grokAmount(used)
  if not amount then return nil, "invalid" end
  return { label = tostring(period.type or ""):find("WEEK", 1, true) and "Weekly" or "Monthly",
    percent = clamp01(amount / 100), resetsAt = ends or 0 }, nil
end

local function grokMonthly(data)
  local config = type(data) == "table" and data.config
  if type(config) ~= "table" then return nil end
  local quota, used = grokAmount(config.monthlyLimit), grokAmount(config.used)
  if not quota or quota <= 0 or not used then return nil end
  return { label = "Monthly", percent = clamp01(used / quota), resetsAt = epoch(config.billingPeriodEnd) or 0 }
end

local function grokPlan(home)
  local cached = readJSON(home .. "/settings_cache.json")
  if not cached or type(cached.payload) ~= "string" then return "" end
  local ok, payload = pcall(hs.json.decode, cached.payload)
  local settings = ok and type(payload) == "table" and payload.settings
  return type(settings) == "table" and type(settings.subscription_tier_display) == "string" and settings.subscription_tier_display or ""
end

local function collectGrok(force, done)
  local r = rec.grok
  local home = HOME .. "/.grok"
  r.inUse = isDir(home)
  if not r.inUse then
    r.limits, r.plan, r.status, r.help, r.stale = {}, "", "", "", false
    return done()
  end
  r.plan = grokPlan(home)
  local auth = readJSON(home .. "/auth.json")
  local token, expires, hasRefresh = "", 0, false
  if auth then
    for _, entry in pairs(auth) do
      if type(entry) == "table" and type(entry.key) == "string" and entry.key ~= "" then
        local e = epoch(entry.expires_at) or 0
        if token == "" or e > expires then
          token, expires = entry.key, e
          hasRefresh = type(entry.refresh_token) == "string" and entry.refresh_token ~= ""
        end
      end
    end
  end
  auth = nil
  if token == "" then
    keep(r)
    r.status, r.help = "Waiting for auth", HELP.grokAuth
    return done()
  end
  local t = now()
  if expires > 0 and expires <= t then
    token = nil
    keep(r)
    if hasRefresh and t - expires < GROK_REFRESH_LIFETIME then
      r.status = "Limits paused"
      r.help = "Grok's access token has lapsed" .. (#r.limits > 0 and " — showing the last known limits." or ".")
        .. " Start Grok to refresh it; signing in again is not needed."
    else
      r.status, r.help = "Sign-in expired", "Grok's saved sign-in expired. Start Grok to refresh it."
    end
    return done()
  end
  if not config.remote then
    token = nil
    keep(r)
    r.status, r.help = "Limits paused", HELP.remoteOff
    return done()
  end
  if not force and r.probedAt and t - r.probedAt < REUSE_SECONDS then
    token = nil
    return done()
  end
  r.probedAt = t
  local headers = { Authorization = "Bearer " .. token, Accept = "application/json" }
  token = nil
  local function fail(status)
    keep(r)
    if type(status) ~= "number" or status <= 0 then
      r.retry = true
      r.help = "Couldn't reach Grok's usage endpoint. Retrying shortly."
    elseif status == 401 or status == 403 then
      r.status = "Sign-in expired"
      r.help = "xAI refused Grok's saved sign-in. Start Grok, or run `grok login`, to sign in again."
    elseif status == 200 then
      r.help = "Grok's usage endpoint answered without a usable limit."
    else
      r.help = "Grok's usage endpoint returned status " .. tostring(math.floor(status)) .. "."
    end
    if r.status ~= "Sign-in expired" then r.status = #r.limits > 0 and "" or "Grok limits unavailable" end
    log.w("agents: grok usage check failed (status %s)", tostring(status))
    headers = nil
    done()
  end
  local function succeed(limits)
    headers = nil
    r.limits, r.fetchedAt, r.stale, r.status, r.help, r.retry = limits, now(), false, "", "", false
    done()
  end
  hs.http.asyncGet(GROK_CREDITS, headers, guarded(done, function(status, body)
    local ok, data = pcall(hs.json.decode, body or "")
    body = nil
    if status ~= 200 or not ok then return fail(status) end
    local weekly, why = grokCredits(data)
    local unified = type(data) == "table" and type(data.config) == "table" and data.config.isUnifiedBillingUser == true
    if not weekly and why ~= "unified" then return fail(200) end
    if weekly and not (unified and weekly.label == "Weekly") then return succeed({ weekly }) end
    -- Unified billing: the monthly included quota (beside the weekly credits when there are any).
    hs.http.asyncGet(GROK_MONTHLY, headers, guarded(done, function(status2, body2)
      local ok2, data2 = pcall(hs.json.decode, body2 or "")
      body2 = nil
      local monthly = status2 == 200 and ok2 and grokMonthly(data2) or nil
      if weekly and monthly then return succeed({ weekly, monthly }) end
      if weekly then return succeed({ weekly }) end
      if monthly then return succeed({ monthly }) end
      fail(status2 == 200 and 200 or status2)
    end))
  end))
end

---------------------------------------------------------------- display shaping (Panel.qml)
local function windowIsLong(text)
  return text:find("week", 1, true) or text:find("7-day", 1, true) or text:find("seven", 1, true)
    or text:find("month", 1, true) or text:find("30-day", 1, true)
end

local function windowTitle(label)
  local text = tostring(label or ""):lower()
  if text:find("month", 1, true) then return "Monthly" end
  if windowIsLong(text) then return "Weekly" end
  if text:find("session", 1, true) or text:match("%d+%s*%-?%s*h") or text:match("%d+%s*%-?%s*m") then return "Session" end
  local plain = tostring(label or ""):gsub("%s*%(.*%)%s*", ""):match("^%s*(.-)%s*$")
  return plain == "" and "Limit" or plain
end

local function scopedPart(title)
  local model, window = tostring(title or ""):match("^(.+) (Session)$")
  if not model then model, window = tostring(title or ""):match("^(.+) (Weekly)$") end
  if not model then model, window = tostring(title or ""):match("^(.+) (Monthly)$") end
  if model then return { model = model, window = window } end
  return nil
end

local function round3(v) return math.floor(v * 1000 + 0.5) / 1000 end

local function displayWindows(limits)
  local windows = {}
  for _, l in ipairs(limits or {}) do
    local title = (type(l.title) == "string" and l.title ~= "") and l.title or windowTitle(l.label)
    windows[#windows + 1] = { t = title, p = round3(l.percent or 0), r = math.floor(l.resetsAt or 0) }
  end
  local out, byTitle = {}, {}
  for _, w in ipairs(windows) do
    if not scopedPart(w.t) then
      out[#out + 1] = w
      byTitle[w.t] = w
    end
  end
  for _, w in ipairs(windows) do
    local part = scopedPart(w.t)
    if part then
      local base = byTitle[part.window]
      if base then
        base.s = base.s or {}
        base.s[#base.s + 1] = { t = part.model, p = w.p, r = w.r }
      else
        out[#out + 1] = w
      end
    end
  end
  return out
end

local function needsSignIn(r)
  return r.status == "Sign-in expired" or r.status == "Waiting for auth"
end

local function snapshot()
  local providers, choices = {}, {}
  for _, id in ipairs(ORDER) do
    local r = rec[id]
    choices[#choices + 1] = { id = id, name = NAMES[id], installed = r.installed and true or false }
    if config.enabled[id] and r.inUse and (#r.limits > 0 or r.plan ~= "" or r.status ~= "") then
      local signin = needsSignIn(r)
      local note = ""
      if not signin and (r.status ~= "" or (r.stale and r.help ~= "")) then
        note = r.help ~= "" and r.help or r.status
      end
      providers[#providers + 1] = {
        id = id, name = NAMES[id], plan = r.plan, status = r.status, note = note,
        signin = signin, signinHelp = signin and r.help or nil,
        stale = r.stale, fetched = math.floor(r.fetchedAt or 0), windows = displayWindows(r.limits),
      }
    end
  end
  return { v = 1, providers = providers, choices = choices }
end

local function publish()
  local ok, text = pcall(hs.json.encode, snapshot())
  if not ok or not text or text == lastJSON then return end
  lastJSON = text
  if publishTask and publishTask:isRunning() then publishTask:terminate() end
  local okTask, err = pcall(function()
    publishTask = hs.task.new(CTL, function(code, _, errOut)
      if code ~= 0 then
        lastJSON = nil
        log.w("agents: shell set failed: %s", tostring(errOut):sub(1, 160))
      end
    end, { "shell", "set", VAR, text })
    publishTask:start()
  end)
  if not okTask then
    lastJSON = nil
    log.e("agents: could not publish: %s", tostring(err))
  end
end

---------------------------------------------------------------- refresh
local function scheduleRetry()
  if retryTimer then return end
  retryTimer = hs.timer.doAfter(RETRY_SECONDS, function()
    retryTimer = nil
    local ids = {}
    for _, id in ipairs(ORDER) do if rec[id].retry then ids[#ids + 1] = id end end
    if #ids > 0 then M.refresh(false, ids) end
  end)
end

local function restartTimer()
  if timer then timer:stop() end
  timerInterval = config.interval
  timer = hs.timer.doEvery(config.interval, function() M.refresh(false) end)
end

function M.refresh(force, ids)
  -- A run that never came back (an endpoint or keychain prompt that hangs) gives way after 2 min.
  if running and now() - runningSince < 120 then
    if force or not queued then queued = { force = force, ids = ids } end
    return
  end
  running, runningSince = true, now()
  config = loadConfig()
  if timer and timerInterval ~= config.interval then restartTimer() end
  ids = ids or ORDER
  local pending = 0
  local finished = false
  local function done()
    pending = pending - 1
    if pending > 0 or finished then return end
    finished = true
    running = false
    for _, id in ipairs(ORDER) do rec[id].installed = findBinary(id) ~= nil end
    local okPub, err = pcall(publish)
    if not okPub then log.e("agents: publish failed: %s", tostring(err)) end
    for _, id in ipairs(ORDER) do if rec[id].retry then scheduleRetry() break end end
    if queued then
      local q = queued
      queued = nil
      M.refresh(q.force, q.ids)
    end
  end
  local list = {}
  for _, id in ipairs(ids) do if config.enabled[id] then list[#list + 1] = id end end
  pending = #list + 1
  for _, id in ipairs(list) do
    rec[id].retry = false
    local called = false
    local cb = function()
      if called then return end
      called = true
      local okDone, err = pcall(done)
      if not okDone then log.e("agents: refresh step failed: %s", tostring(err)) end
    end
    local ok, err = pcall(function()
      if id == "claude" then collectClaude(force, cb)
      elseif id == "codex" then collectCodex(cb)
      else collectGrok(force, cb) end
    end)
    if not ok then
      log.e("agents: %s collector failed: %s", id, tostring(err))
      cb()
    end
  end
  done()   -- the extra count: publishes even when every provider is off
end

---------------------------------------------------------------- actions
local function signin(x)
  local id = type(x) == "string" and x:match("^%s*(%a+)%s*$")
  if not id or not LOGIN_ARGS[id] then
    log.w("agents: signin refused, unknown provider")
    return
  end
  local bin = findBinary(id)
  if not bin then return toast.warn(NAMES[id] .. " is not installed") end
  -- Fixed command from our own table and a path from our own list; nothing from x is used.
  local command = "'" .. bin:gsub("'", "'\\''") .. "' " .. LOGIN_ARGS[id]
  require("omarchy.launch").tui(command, "agents-signin")
  if signinTimer then signinTimer:stop() end
  signinTimer = hs.timer.doAfter(60, function()
    signinTimer = nil
    keychainBlocked = false
    M.refresh(true)
  end)
end

local function toggle()
  local ok, err = pcall(function()
    hs.task.new(CTL, function(code, _, errOut)
      if code ~= 0 then log.w("agents: shell toggle failed: %s", tostring(errOut):sub(1, 160)) end
    end, { "shell", "toggle", WIDGET }):start()
  end)
  if not ok then log.e("agents: shell toggle: %s", tostring(err)) end
  M.refresh(false)   -- like Omarchy's open: limits that went stale on the wire, within the reuse window
end

M.actions = {
  ["agents.refresh"] = { fn = function()
    keychainBlocked = false
    M.refresh(true)
  end, desc = "Refresh AI agent usage limits now" },
  ["agents.toggle"] = { fn = function() toggle() end, desc = "Open or close the Agents bar panel" },
  ["agents.launch"] = { fn = function() require("omarchy.actions").run("agents") end, desc = "Start an AI agent (the agent picker)" },
  ["agents.signin"] = { fn = function(x) signin(x) end, desc = "Sign in to Claude Code, Codex or Grok in a terminal (x = claude|codex|grok)" },
}

---------------------------------------------------------------- lifecycle
function M.start()
  M.stop()
  config = loadConfig()
  restartTimer()
  appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.launched and app and app:bundleID() == OMNIWM then
      lastJSON = nil   -- OmniWM restarted: its vars are gone
      if kickTimer then kickTimer:stop() end
      kickTimer = hs.timer.doAfter(4, function() kickTimer = nil pcall(publish) end)
    end
  end)
  appWatcher:start()
  kickTimer = hs.timer.doAfter(3, function() kickTimer = nil M.refresh(false) end)
  return M
end

function M.stop()
  if timer then timer:stop() timer = nil end
  if retryTimer then retryTimer:stop() retryTimer = nil end
  if signinTimer then signinTimer:stop() signinTimer = nil end
  if kickTimer then kickTimer:stop() kickTimer = nil end
  if appWatcher then appWatcher:stop() appWatcher = nil end
  if keychainTask then pcall(function() keychainTask:terminate() end) keychainTask = nil end
  keychainLogin = nil
  if publishTask then pcall(function() if publishTask:isRunning() then publishTask:terminate() end end) publishTask = nil end
  running, queued = false, nil
end

return M
