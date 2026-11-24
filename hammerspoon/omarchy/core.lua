-- Omarchy on macOS: the Hammerspoon side.
--
-- What Hammerspoon owns (see ~/.config/omarchy-mac/bindings.toml):
--   * the "HS" Super and Super+Shift chords, as plain hs.hotkey (Carbon)
--     hotkeys read from omarchy/generated/bindings.lua (written by
--     `omarchy-keys generate`). Super = Ctrl+Option+Command, held by
--     Karabiner while Caps Lock is down.
--   * hammerspoon://omarchy?a=<action>&x=<arg> for Karabiner's layers
--   * the Omarchy menu, toasts, theme tint and wallpaper, screenshots
--   * Super+scroll (a scroll-wheel-only event tap)
--   * health: OmniWM relaunch, Secure Input notices, diag.json
--
-- There is no keyboard event tap anywhere in this config.
--
-- generated/bindings.lua format (version 1):
--   return {
--     version = 1,
--     generated = "2026-11-23T10:00:00",       -- optional
--     hotkeys = {                               -- HS-owned chords only
--       { mods = { "ctrl", "alt", "cmd" }, key = "space",
--         action = "menu", arg = nil,           -- a name from actions.lua
--         rep = false,                          -- repeat while held
--         desc = "Omarchy menu", chord = "SUPER+SPACE" },
--       ...
--     },
--     all = {                                   -- every binding, any owner
--       { chord = "SUPER+SPACE", desc = "Omarchy menu", owner = "HS",
--         action = "menu", arg = nil },         -- action/arg when it is HS
--       ...
--     },
--     tui_allow = { "btop", ... },              -- optional extra URL allowlist
--   }
-- Accepted aliases: hs = action, x = arg, ["repeat"] = rep, wm = "<omarchy-wm
-- args>" (same as action = "wm"), mods as a string ("ctrl+alt+cmd",
-- "Control+Option+Shift+Command", "super+shift"), or no mods/key but a
-- chord ("SUPER+SHIFT+RETURN").
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")
local toast = require("omarchy.toast")

M.MODULE = "omarchy.generated.bindings"
M.GEN_DIR = (hs.configdir or (u.HOME .. "/.hammerspoon")) .. "/omarchy/generated"

M.hotkeys = {}   -- { hk = hs.hotkey, entry = normalised entry }
M.failures = {}  -- chords that could not be bound
M.generated = nil
M.genError = nil
M.loadedAt = nil

-- Built-in URL allowlist for a=tui (exact command strings).
local TUI_DEFAULTS = {
  "btop", "nvim", "lazygit", "lazydocker", "tmux", "fastfetch", "herdr",
  u.HOME .. "/.local/bin/omarchy-agents",
}

------------------------------------------------------------------ parsing

local MOD = {
  super = { "ctrl", "alt", "cmd" }, hyper = { "ctrl", "alt", "cmd" },
  ctrl = "ctrl", control = "ctrl", ["⌃"] = "ctrl",
  alt = "alt", option = "alt", opt = "alt", ["⌥"] = "alt",
  cmd = "cmd", command = "cmd", ["⌘"] = "cmd",
  shift = "shift", ["⇧"] = "shift",
}

local KEY = {
  backspace = "delete", bs = "delete", enter = "return", ret = "return",
  esc = "escape", grave = "`", backtick = "`", backquote = "`",
  minus = "-", equal = "=", equals = "=", plus = "=", slash = "/",
  backslash = "\\", comma = ",", period = ".", dot = ".", semicolon = ";",
  quote = "'", apostrophe = "'", bracketleft = "[", bracketright = "]",
  leftbracket = "[", rightbracket = "]", spacebar = "space",
  arrowleft = "left", arrowright = "right", arrowup = "up", arrowdown = "down",
  print = "f13", printscreen = "f13",
}

local ORDER = { cmd = 1, alt = 2, ctrl = 3, shift = 4 }

local function normMods(mods)
  local set = {}
  local function add(tok)
    tok = u.trim(tok):lower()
    if tok == "" then return end
    local m = MOD[tok]
    if type(m) == "table" then
      for _, x in ipairs(m) do set[x] = true end
    elseif m then
      set[m] = true
    else
      error("unknown modifier " .. tok)
    end
  end
  if type(mods) == "table" then
    for _, m in ipairs(mods) do add(m) end
  elseif type(mods) == "string" then
    for tok in mods:gmatch("[^%+%-%s,]+") do add(tok) end
  end
  local out = {}
  for m in pairs(set) do out[#out + 1] = m end
  table.sort(out, function(a, b) return ORDER[a] < ORDER[b] end)
  return out
end
M.normMods = normMods

local function normKey(key)
  if type(key) == "number" then return key end
  local k = tostring(key or ""):lower()
  k = KEY[k] or k
  if hs.keycodes.map[k] == nil then error("unknown key " .. tostring(key)) end
  return k
end
M.normKey = normKey

-- "SUPER+SHIFT+RETURN" -> mods, key. A trailing "+" key ("SUPER++") is "=".
local function parseChord(chord)
  local parts = {}
  for p in tostring(chord):gmatch("[^+]+") do parts[#parts + 1] = u.trim(p) end
  if tostring(chord):sub(-2) == "++" then parts[#parts + 1] = "=" end
  local key = table.remove(parts)
  return normMods(parts), normKey(key)
end

local function normEntry(e)
  if type(e) ~= "table" then error("binding is not a table") end
  local mods, key
  if e.key then
    mods, key = normMods(e.mods or "super"), normKey(e.key)
  elseif e.chord then
    mods, key = parseChord(e.chord)
  else
    error("binding has neither key nor chord")
  end
  local action, arg = e.action or e.hs, e.arg
  if arg == nil then arg = e.x end
  if not action and e.wm then action, arg = "wm", e.wm end
  if not action then error("binding has no action") end
  local rep = e.rep
  if rep == nil then rep = e["repeat"] end
  return {
    mods = mods, key = key, action = action, arg = arg, rep = rep and true or false,
    desc = e.desc or e.description or action, chord = e.chord,
    id = table.concat(mods, "+") .. "+" .. tostring(key),
  }
end

M._normEntry = normEntry
M._parseChord = parseChord

------------------------------------------------------------------ loading

local function loadGenerated()
  package.loaded[M.MODULE] = nil
  local ok, data = pcall(require, M.MODULE)
  if not ok then return nil, tostring(data) end
  if type(data) ~= "table" then return nil, "bindings.lua did not return a table" end
  return data
end

local function hotkeyList(gen)
  if not gen then return {} end
  return gen.hotkeys or gen.bindings or (gen[1] and gen) or {}
end

function M.unbindAll()
  for _, h in ipairs(M.hotkeys) do pcall(function() h.hk:delete() end) end
  M.hotkeys = {}
  M.failures = {}
end

function M.bindAll()
  M.unbindAll()
  local gen, err = loadGenerated()
  M.loadedAt = os.date("%Y-%m-%dT%H:%M:%S")
  if not gen then
    M.generated, M.genError = nil, err
    log.e("core: no generated bindings (%s)", tostring(err))
    toast.warn("Omarchy: generated keybindings missing. Run omarchy-keys install.")
    return 0
  end
  M.generated, M.genError = gen, nil

  local actions = require("omarchy.actions")
  local seen = {}
  for i, raw in ipairs(hotkeyList(gen)) do
    local ok, e = pcall(normEntry, raw)
    if not ok then
      log.e("core: binding %d skipped: %s", i, tostring(e))
      M.failures[#M.failures + 1] = { index = i, reason = tostring(e) }
    elseif seen[e.id] then
      log.e("core: duplicate chord %s (%s) skipped", e.id, e.desc)
      M.failures[#M.failures + 1] = { chord = e.id, reason = "duplicate" }
    elseif not actions.exists(e.action) then
      log.e("core: %s uses unknown action %s", e.id, tostring(e.action))
      M.failures[#M.failures + 1] = { chord = e.id, reason = "unknown action " .. tostring(e.action) }
    else
      seen[e.id] = true
      local fire = function() actions.run(e.action, e.arg) end
      local bok, hk = pcall(hs.hotkey.bind, e.mods, e.key, fire, nil, e.rep and fire or nil)
      if bok and hk then
        M.hotkeys[#M.hotkeys + 1] = { hk = hk, entry = e }
      else
        -- Carbon hotkeys are exclusive: another app (OmniWM, Moom ...) has it.
        log.e("core: could not bind %s (%s): %s", e.id, e.desc, bok and "taken by another app" or tostring(hk))
        M.failures[#M.failures + 1] = { chord = e.id, reason = bok and "taken" or tostring(hk) }
      end
    end
  end
  log.i("core: bound %d hotkeys, %d failed", #M.hotkeys, #M.failures)
  if #M.failures > 0 then
    toast.warn(string.format("Omarchy: %d hotkey(s) failed to bind. See hs.log.", #M.failures))
  end
  return #M.hotkeys
end

function M.hotkeyCount()
  return #M.hotkeys
end

function M.generatedInfo()
  local gen = M.generated
  return {
    loaded = gen ~= nil,
    error = M.genError,
    version = gen and gen.version or nil,
    generated = gen and gen.generated or nil,
    loadedAt = M.loadedAt,
    entries = gen and #hotkeyList(gen) or 0,
    path = M.GEN_DIR .. "/bindings.lua",
  }
end

local MOUSE_ROWS = {
  { chord = "SUPER+LEFT MOUSE DRAG", desc = "Move window", owner = "OW" },
  { chord = "SUPER+RIGHT MOUSE DRAG", desc = "Resize window", owner = "OW" },
  { chord = "SUPER+SCROLL", desc = "Next / previous workspace", owner = "HS" },
}

-- Rows for the Super+K viewer: { chord, desc, owner }.
function M.allBindings()
  local out, hasMouse = {}, false
  local gen = M.generated
  if gen and type(gen.all) == "table" and #gen.all > 0 then
    for _, b in ipairs(gen.all) do
      out[#out + 1] = { chord = b.chord or "?", desc = b.desc or b.description or "", owner = b.owner }
      local c = tostring(b.chord or ""):upper()
      if c:find("MOUSE") or c:find("SCROLL") then hasMouse = true end
    end
  else
    for _, h in ipairs(M.hotkeys) do
      out[#out + 1] = { chord = h.entry.chord or h.entry.id:upper(), desc = h.entry.desc, owner = "HS" }
    end
  end
  if not hasMouse then
    for _, r in ipairs(MOUSE_ROWS) do out[#out + 1] = r end
  end
  return out
end

-- Is this exact command allowed through hammerspoon://omarchy?a=tui ?
function M.tuiAllowed(cmd)
  cmd = u.trim(cmd)
  if cmd == "" then return false end
  for _, c in ipairs(TUI_DEFAULTS) do
    if c == cmd then return true end
  end
  local gen = M.generated
  if not gen then return false end
  local function check(list)
    for _, b in ipairs(list or {}) do
      if type(b) == "table" then
        local action = b.action or b.hs
        local arg = b.arg
        if arg == nil then arg = b.x end
        if action == "tui" and type(arg) == "string" and u.trim(arg) == cmd then return true end
      elseif type(b) == "string" and u.trim(b) == cmd then
        return true
      end
    end
    return false
  end
  return check(hotkeyList(gen)) or check(gen.all) or check(gen.tui_allow)
end

------------------------------------------------------------------ start

local function step(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    log.e("core: %s failed to start: %s", name, tostring(err))
    toast.warn("Omarchy: " .. name .. " failed to start (see hs.log)")
  end
  return ok
end

local function writeActionList()
  local actions = require("omarchy.actions")
  u.mkdirp(u.STATE)
  local ok, json = pcall(hs.json.encode, { actions = actions.names(), written = os.date("%Y-%m-%dT%H:%M:%S") }, true)
  if ok then u.writeFile(u.STATE .. "/hs-actions.json", json .. "\n") end
end

function M.watchGenerated()
  u.mkdirp(M.GEN_DIR)
  M.genDebounce = hs.timer.delayed.new(0.5, function()
    log.i("core: generated bindings changed; rebinding")
    local n = M.bindAll()
    if M.generated then toast.show(string.format("Keybindings reloaded (%d)", n)) end
  end)
  if M.genWatcher then M.genWatcher:stop() end
  M.genWatcher = hs.pathwatcher.new(M.GEN_DIR, function(paths)
    for _, p in ipairs(paths) do
      if p:match("%.lua$") then
        M.genDebounce:start()
        return
      end
    end
  end)
  M.genWatcher:start()
end

function M.start()
  log.i("core: starting (Hammerspoon %s)", tostring(hs.processInfo.version))
  pcall(function() hs.hotkey.setLogLevel("warning") end)
  u.mkdirp(u.STATE)

  step("theme", function() require("omarchy.theme").start() end)
  step("actions", writeActionList)
  step("url", function() require("omarchy.url").start() end)
  step("tray", function() require("omarchy.tray").start() end)
  step("netpanel", function() require("omarchy.netpanel").start() end)
  step("ports", function() require("omarchy.ports").start() end)
  step("hotkeys", M.bindAll)
  step("generated watcher", M.watchGenerated)
  step("scroll", function() require("omarchy.scroll").start() end)
  step("health", function() require("omarchy.health").start() end)
  step("layout watch", function() require("omarchy.layoutwatch").start() end)

  log.i("core: ready (%d hotkeys)", #M.hotkeys)
  return M
end

return M
