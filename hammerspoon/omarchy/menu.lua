-- The Omarchy menu (Super+Space) and the keybindings viewer (Super+K),
-- built on hs.chooser.
--
-- hs.chooser is a real key window: it gets keystrokes from the normal event
-- path (so it works while Secure Input is on), closes on Escape or when it
-- loses focus, and never grabs keys system-wide. No event tap is involved.
--
-- Layout follows Omarchy 4.5's omarchy-menu, trimmed to what works on macOS:
--   Apps · Learn · Appearance · Trigger · Setup · Install · Remove · Update ·
--   About · System
-- Submenus start with a "‹ Back" row. Typing filters the current level; at
-- the root, typing searches every item in every submenu (the path is shown
-- under each match). Escape closes.
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local chooser, kbChooser
local stack = {}   -- nodes from the root to the level on screen
local current = {} -- idx -> { node, chain, path } for the rows on screen
local flat = nil   -- root search index, rebuilt each time the menu opens
local query = ""

------------------------------------------------------------------ icons

local icons = nil
local function icon(id)
  if not icons then
    local raw = u.readFile(u.BASE .. "/menu-icons.json")
    local ok, data = pcall(hs.json.decode, raw or "")
    icons = (ok and type(data) == "table") and data or {}
  end
  return (id and icons[id]) or ""
end

------------------------------------------------------------------ tree

local function A(label, iconId, action, arg, extra)
  local n = { label = label, icon = iconId, action = action, arg = arg }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function F(label, iconId, fn, extra)
  local n = { label = label, icon = iconId, fn = fn }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function S(label, iconId, children, key)
  return { label = label, icon = iconId, children = children, key = key }
end

local function sq(s) -- single-quote for zsh
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function edit(path)
  return "nvim " .. sq(path)
end

local PAUSE = "; echo; read -k1 '?Done. Press any key to close.'"

local function brew(cmd)
  return cmd .. PAUSE
end

local function stroke(mods, key)
  return function()
    -- Let the chooser close and focus return to the previous window first.
    hs.timer.doAfter(0.15, function()
      u.afterModifiersReleased(function() hs.eventtap.keyStroke(mods, key, 0) end)
    end)
  end
end

local function onOff(v) return v and "On" or "Off" end

local function themeItems()
  local items = {}
  for _, name in ipairs(theme.list()) do
    items[#items + 1] = A(theme.pretty(name), "appearance.theme", "theme-set", name,
      { checked = name == theme.name, keywords = "theme " .. name })
  end
  if #items == 0 then items[1] = F("No themes installed", "appearance.theme", function() end) end
  return items
end

local function backgroundItems()
  return {
    A("Next background", "appearance.background", "next-background"),
    F("Open this theme's backgrounds", "appearance.background", function()
      local dir = u.THEMES .. "/" .. theme.name .. "/backgrounds"
      u.run(u.OPEN, { u.isDir(dir) and dir or u.THEMES })
    end),
  }
end

local function captureItems()
  return {
    A("Screenshot region", "trigger.capture.screenshot", "screenshot-region"),
    A("Screenshot window", "trigger.capture.screenshot", "screenshot-window"),
    A("Screenrecord", "trigger.capture.screenrecord", "screenrecord"),
    A("Color picker", "trigger.capture.color", "color-picker"),
  }
end

local function toggleItems()
  local actions = require("omarchy.actions")
  local gaps = tonumber(actions.omniwmSetting("gaps", "size") or "")
  local ffm = actions.omniwmSetting("focus", "followsMouse")
  local ovr = u.readFile(actions.ghosttyOverrides) or ""
  local opacity = tonumber(ovr:match("background%-opacity%s*=%s*([%d%.]+)") or "") or 1.0
  local awake = hs.caffeinate.get("displayIdle")
  return {
    A("Stay awake", awake and "trigger.toggle.idle-lock-off" or "trigger.toggle.idle-lock-on",
      "stay-awake", nil, { sub = onOff(awake) }),
    A("Top bar", "appearance.top-bar", "wm", "raw toggle-workspace-bar"),
    A("Gaps", "appearance.windows", "toggle-gaps", nil, { sub = gaps and onOff(gaps > 0) or nil }),
    A("Focus follows mouse", "setup.input", "toggle-focus-follows-mouse", nil,
      { sub = ffm and (onOff(ffm == "true") .. (ffm ~= "true" and "  (off is safer with the EMR)" or "")) or nil }),
    A("Transparency (Ghostty)", "appearance.windows", "toggle-transparency", nil,
      { sub = onOff(opacity < 1.0) }),
  }
end

local function pane(label, iconId, id)
  return A(label, iconId, "settings", id)
end

local function systemItems()
  return {
    A("Lock", "system.lock", "lock"),
    F("Screensaver", "system.screensaver", function() hs.caffeinate.startScreensaver() end),
    F("Sleep", "system.suspend", function() hs.caffeinate.systemSleep() end),
    F("Log Out", "system.logout", function() hs.caffeinate.logOut() end, { confirm = "Log out now?" }),
    F("Restart", "system.reboot", function() hs.caffeinate.restartSystem() end, { confirm = "Restart now?" }),
    F("Shut Down", "system.shutdown", function() hs.caffeinate.shutdownSystem() end, { confirm = "Shut down now?" }),
  }
end

local function regenerateKeys()
  local bin = u.bin("omarchy-keys")
  if not u.isExec(bin) then return toast.warn("omarchy-keys is not installed") end
  toast.show("Regenerating keybindings…")
  u.run(bin, { "install" }, function(code, out, err)
    if code == 0 then
      toast.show("Keybindings regenerated")
    else
      local msg = u.trim(err ~= "" and err or out)
      toast.warn("omarchy-keys install failed: " .. msg:sub(1, 160))
    end
  end)
end

local function tree()
  local H = u.HOME
  return S("Omarchy", nil, {
    A("Apps", "apps", "wm", "raw open-command-palette applications", { keywords = "launcher applications" }),
    S("Learn", "learn", {
      A("Keybindings", "learn.keybindings", "keybindings"),
      A("Omarchy manual", "learn.omarchy", "webapp", "https://omarchy.org/manual/"),
      A("OmniWM docs", "learn.hyprland", "webapp", "https://omniwm.app/"),
      A("Neovim (LazyVim)", "learn.neovim", "webapp", "https://www.lazyvim.org/keymaps"),
      A("Ghostty", "learn.bash", "webapp", "https://ghostty.org/docs"),
    }, "learn"),
    S("Appearance", "appearance", {
      A("Theme", "appearance.theme", "menu-theme"),
      A("Background", "appearance.background", "menu-background"),
      A("Top bar", "appearance.top-bar", "wm", "raw toggle-workspace-bar"),
      A("Window gaps", "appearance.windows", "toggle-gaps"),
      A("Terminal transparency", "appearance.windows", "toggle-transparency"),
      A("Workspace layout (dwindle / scrolling)", "appearance.workspace-layout", "wm", "cycle-layout"),
    }, "appearance"),
    S("Trigger", "trigger", {
      S("Capture", "trigger.capture", captureItems, "capture"),
      S("Toggle", "trigger.toggle", toggleItems, "toggle"),
      F("Emoji", "trigger.emoji", stroke({ "ctrl", "cmd" }, "space")),
      F("Clipboard history", "trigger.clipboard-history", stroke({ "ctrl", "alt", "shift", "cmd" }, "v")),
      A("Overview", "trigger.hardware", "wm", "raw toggle-overview"),
      A("Notification Center", "trigger.toggle.notifications-on", "notification-center"),
      A("Show time", "update.time", "show-time"),
      A("Show battery", "trigger.hardware", "show-battery"),
    }, "trigger"),
    S("Setup", "setup", {
      pane("Wi-Fi", "setup.network", "com.apple.wifi-settings-extension"),
      pane("Bluetooth", "setup.input", "com.apple.BluetoothSettings"),
      pane("Audio", "setup.default", "com.apple.Sound-Settings.extension"),
      pane("Displays", "setup.region", "com.apple.Displays-Settings.extension"),
      pane("Keyboard", "setup.keyboard", "com.apple.Keyboard-Settings.extension"),
      S("Config", "setup.config", {
        A("Keybindings (bindings.toml)", "setup.config", "tui", edit(u.BASE .. "/bindings.toml")),
        A("Window manager (OmniWM settings.toml)", "setup.config", "tui", edit(H .. "/.config/omniwm/settings.toml")),
        A("Top bar (shell.toml)", "setup.config", "tui", edit(H .. "/.config/omniwm/shell/shell.toml")),
        A("Terminal (Ghostty config)", "setup.config", "tui", edit(H .. "/.config/ghostty/config")),
      }, "config"),
      F("Regenerate keybindings", "learn.keybindings", regenerateKeys, { keywords = "omarchy-keys install" }),
    }, "setup"),
    S("Install", "install", {
      A("Package (brew)", "install.package", "tui", brew(
        "pkgs=$(brew formulae | fzf --multi --prompt='Install> ' --preview 'brew info {}'); [ -n \"$pkgs\" ] && brew install ${=pkgs}")),
      A("App (brew cask)", "install.browser", "tui", brew(
        "pkgs=$(brew casks | fzf --multi --prompt='Install app> ' --preview 'brew info --cask {}'); [ -n \"$pkgs\" ] && brew install --cask ${=pkgs}")),
    }, "install"),
    S("Remove", "remove", {
      A("Package (brew)", "remove.package", "tui", brew(
        "pkgs=$(brew leaves | fzf --multi --prompt='Remove> ' --preview 'brew info {}'); [ -n \"$pkgs\" ] && brew uninstall ${=pkgs}")),
      A("App (brew cask)", "remove.browser", "tui", brew(
        "pkgs=$(brew list --cask | fzf --multi --prompt='Remove app> '); [ -n \"$pkgs\" ] && brew uninstall --cask ${=pkgs}")),
    }, "remove"),
    S("Update", "update", {
      A("Packages (brew update && upgrade)", "update.process", "tui", brew("brew update && brew upgrade")),
      A("Restart Hammerspoon", "update.process.shell", "reload"),
      pane("macOS", "update.config", "com.apple.Software-Update-Settings.extension"),
    }, "update"),
    A("About", "system.about", "tui", "fastfetch" .. PAUSE),
    S("System", "system", systemItems, "system"),
  }, "root")
end

------------------------------------------------------------------ helpers

local function kids(node)
  local c = node.children
  if type(c) == "function" then
    local ok, res = pcall(c)
    if not ok then
      log.e("menu: building %s failed: %s", node.label, tostring(res))
      return {}
    end
    return res
  end
  return c or {}
end

-- Depth-first search for the node with key; returns the chain root..node.
local function findChain(root, key)
  local function walk(node, chain)
    chain[#chain + 1] = node
    if node.key == key then return chain end
    if node.children then
      for _, child in ipairs(kids(node)) do
        if child.children then
          local copy = { table.unpack(chain) }
          local hit = walk(child, copy)
          if hit then return hit end
        end
      end
    end
    return nil
  end
  return walk(root, {})
end

local function buildFlat(root)
  local out = {}
  local function walk(node, chain, path)
    for _, child in ipairs(kids(node)) do
      local childChain = { table.unpack(chain) }
      childChain[#childChain + 1] = child
      out[#out + 1] = { node = child, chain = childChain, path = path }
      if child.children then
        walk(child, childChain, (path ~= "" and (path .. " › ") or "") .. child.label)
      end
    end
  end
  walk(root, { root }, "")
  return out
end

local function words(q)
  local w = {}
  for x in q:lower():gmatch("%S+") do w[#w + 1] = x end
  return w
end

local function filter(entries, q)
  local ws = words(q)
  if #ws == 0 then return entries end
  local ql = q:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local scored = {}
  for i, e in ipairs(entries) do
    local label = e.node.label:lower()
    local hay = label .. " " .. (e.path or ""):lower() .. " " .. (e.node.keywords or ""):lower()
    local ok = true
    for _, w in ipairs(ws) do
      if not hay:find(w, 1, true) then ok = false break end
    end
    if ok then
      local s = (label:sub(1, #ql) == ql) and 0 or (label:find(ql, 1, true) and 1 or 2)
      scored[#scored + 1] = { e = e, s = s, i = i }
    end
  end
  table.sort(scored, function(a, b)
    if a.s ~= b.s then return a.s < b.s end
    return a.i < b.i
  end)
  local out = {}
  for _, x in ipairs(scored) do out[#out + 1] = x.e end
  return out
end

local function styled(str, colorName, size)
  return hs.styledtext.new(str, {
    font = { name = theme.font, size = size or 15 },
    color = theme.color(colorName or "foreground"),
  })
end

local useIcons = function() return theme.font ~= ".AppleSystemUIFont" end

local BACK = { label = "‹ Back", back = true }

local function toChoices(entries)
  local choices = {}
  current = {}
  for i, e in ipairs(entries) do
    local n = e.node
    local glyph = (useIcons() and not n.back) and icon(n.icon) or ""
    local text = (glyph ~= "" and (glyph .. "   ") or "") .. n.label
    if n.checked then text = text .. "   ✓" end
    if n.children then text = text .. "  ›" end
    local sub = n.sub
    if e.path and e.path ~= "" then sub = e.path .. (sub and ("  ·  " .. sub) or "") end
    choices[i] = {
      text = styled(text, n.checked and "accent" or (n.back and "dark_foreground" or "foreground")),
      subText = sub and styled(sub, "dark_foreground", 12) or nil,
      idx = i,
    }
    current[i] = e
  end
  return choices
end

local function level() return stack[#stack] end

local function refresh()
  if not chooser or #stack == 0 then return end
  local node = level()
  local entries
  if query == "" or query == nil then
    entries = {}
    if #stack > 1 then entries[1] = { node = BACK } end
    for _, c in ipairs(kids(node)) do entries[#entries + 1] = { node = c } end
  elseif #stack == 1 then
    flat = flat or buildFlat(node)
    entries = filter(flat, query)
  else
    local here = {}
    for _, c in ipairs(kids(node)) do here[#here + 1] = { node = c } end
    entries = filter(here, query)
  end
  chooser:choices(toChoices(entries))
end

local function title()
  if #stack <= 1 then return "Search apps, settings and commands" end
  local parts = {}
  for i = 2, #stack do parts[#parts + 1] = stack[i].label end
  return table.concat(parts, " › ")
end

local function place(c, maxWidth)
  local sf = hs.screen.mainScreen():frame()
  local w = math.min(maxWidth, sf.w - 80)
  c:width(math.max(10, math.min(90, w / sf.w * 100)))
  return hs.geometry.point(sf.x + (sf.w - w) / 2, sf.y + math.floor(sf.h * 0.18))
end

local function applyColors(c)
  c:bgDark(theme.isDark())
  c:fgColor(theme.color("foreground"))
  c:subTextColor(theme.color("dark_foreground"))
end

local function reset()
  stack, current, flat, query = {}, {}, nil, ""
end

local show -- forward

local function runNode(node)
  if node.fn then
    hs.timer.doAfter(0, function()
      local ok, err = xpcall(node.fn, debug.traceback)
      if not ok then
        log.e("menu: %s failed: %s", node.label, tostring(err))
        toast.warn("Failed: " .. node.label)
      end
    end)
  elseif node.action then
    require("omarchy.actions").run(node.action, node.arg)
  end
end

local function onChoose(choice)
  if not choice then reset() return end -- Escape or clicked away
  local e = current[choice.idx]
  if not e then reset() return end
  local node = e.node
  if node.back then
    if #stack > 1 then table.remove(stack) end
    query = ""
    return hs.timer.doAfter(0, show)
  end
  if node.children then
    if e.chain then stack = e.chain else stack[#stack + 1] = node end
    query = ""
    return hs.timer.doAfter(0, show)
  end
  if node.confirm and not node.confirmed then
    local yes = {}
    for k, v in pairs(node) do yes[k] = v end
    yes.confirmed, yes.label = true, "Yes, " .. node.label:lower()
    if e.chain then stack = { table.unpack(e.chain, 1, #e.chain - 1) } end
    stack[#stack + 1] = { label = node.confirm, children = { yes, { label = "Cancel", back = true } } }
    query = ""
    return hs.timer.doAfter(0, show)
  end
  reset()
  log.i("menu: %s", node.label)
  runNode(node)
end

local function ensureChooser()
  if chooser then return chooser end
  chooser = hs.chooser.new(function(choice)
    local ok, err = pcall(onChoose, choice)
    if not ok then
      log.e("menu: selection failed: %s", tostring(err))
      reset()
    end
  end)
  chooser:queryChangedCallback(function(q)
    query = q or ""
    local ok, err = pcall(refresh)
    if not ok then log.e("menu: filter failed: %s", tostring(err)) end
  end)
  chooser:rows(12)
  chooser:searchSubText(true)
  applyColors(chooser)
  return chooser
end

show = function()
  ensureChooser()
  if #stack == 0 then stack = { tree() } end
  query = ""
  applyColors(chooser)
  chooser:placeholderText(title())
  chooser:query("")
  refresh()
  chooser:show(place(chooser, 720))
end

------------------------------------------------------------------ public

-- Open the menu at the root, or at the submenu with this key (system, theme,
-- background, capture, toggle, setup, learn, appearance, trigger, config,
-- install, remove, update).
function M.open(key)
  reset()
  local root = tree()
  local chain = key and key ~= "root" and findChain(root, key) or nil
  if key and key ~= "root" and not chain then log.w("menu: no submenu %s", key) end
  stack = chain or { root }
  show()
end

function M.toggle()
  if chooser and chooser:isVisible() then
    chooser:hide()
  else
    M.open()
  end
end

function M.isOpen()
  return (chooser and chooser:isVisible()) or (kbChooser and kbChooser:isVisible()) or false
end

-- Theme a chooser like the Omarchy menu and return where to show it (used by appmenu.lua).
function M.style(c, maxWidth)
  applyColors(c)
  return place(c, maxWidth or 720)
end

local function prettyChord(chord)
  local parts = {}
  for p in tostring(chord or ""):gmatch("[^+]+") do
    p = u.trim(p)
    parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2):lower()
  end
  return table.concat(parts, " + ")
end
M.prettyChord = prettyChord

-- Herdr's own shortcuts, from ~/.config/herdr-app/keys.json
-- ({section = {"cmd-shift-]" = "tab.next", ...}}). Returns nil if unreadable.
local HERDR_KEYS = u.HOME .. "/.config/herdr-app/keys.json"
local HERDR_MODS = { cmd = "Cmd", ctrl = "Ctrl", alt = "Opt", shift = "Shift" }

local function prettyHerdrKey(k)
  k = tostring(k)
  local key, mods = k, ""
  if k:sub(-2) == "--" then
    key, mods = "-", k:sub(1, -3)
  else
    mods, key = k:match("^(.*)%-([^%-]+)$")
    if not key then mods, key = "", k end
  end
  local parts = {}
  for m in mods:gmatch("[^%-]+") do parts[#parts + 1] = HERDR_MODS[m] or m end
  local named = { left = "←", right = "→", up = "↑", down = "↓", enter = "Return",
    backspace = "Delete", tab = "Tab", escape = "Esc", space = "Space" }
  parts[#parts + 1] = named[key] or (#key == 1 and key:upper()) or key:upper()
  return table.concat(parts, " + ")
end
M._prettyHerdrKey = prettyHerdrKey

local function herdrDesc(v)
  if type(v) ~= "string" then
    local ok, s = pcall(hs.json.encode, v)
    v = ok and s or "?"
  end
  if v:find("^send:") then return "Send keys to the terminal" end
  return (v:gsub("[%c]", ""):gsub("[_:]", " "):gsub("%.", " · ", 1))
end

local function herdrChoices()
  if not u.exists(HERDR_KEYS) then return nil end
  local ok, data = pcall(hs.json.read, HERDR_KEYS)
  if not ok or type(data) ~= "table" then return nil end
  local sections = {}
  for name in pairs(data) do sections[#sections + 1] = name end
  table.sort(sections, function(a, b)
    if a == "global" then return true elseif b == "global" then return false end
    return a < b
  end)
  local choices = {}
  for _, sec in ipairs(sections) do
    if type(data[sec]) == "table" then
      local rows = {}
      for k, v in pairs(data[sec]) do
        rows[#rows + 1] = { text = herdrDesc(v), subText = prettyHerdrKey(k) .. "   ·   herdr " .. sec, _k = tostring(k) }
      end
      table.sort(rows, function(a, b) return a.text == b.text and a._k < b._k or a.text < b.text end)
      for _, r in ipairs(rows) do r._k = nil; choices[#choices + 1] = r end
    end
  end
  return choices
end
M._herdrChoices = herdrChoices

-- Super+K: every binding, searchable by description or chord. Picking a row
-- only closes the viewer. filter (optional): "herdr" shows Herdr's own
-- shortcuts from its keys.json; anything else pre-fills the search box.
function M.keybindings(filter)
  filter = filter and u.trim(filter) or ""
  local choices, label, query0 = nil, "Keybindings", filter
  if filter:lower() == "herdr" then
    choices = herdrChoices()
    if choices then label, query0 = "Herdr keybindings", "" end
  end
  if not choices then
    local core = require("omarchy.core")
    choices = {}
    for _, b in ipairs(core.allBindings()) do
      local sub = prettyChord(b.chord)
      if b.owner and b.owner ~= "" then sub = sub .. "   ·   " .. b.owner end
      choices[#choices + 1] = { text = b.desc or b.chord or "?", subText = sub }
    end
  end
  if not kbChooser then
    kbChooser = hs.chooser.new(function() end)
    kbChooser:searchSubText(true)
    kbChooser:rows(16)
  end
  applyColors(kbChooser)
  kbChooser:placeholderText(label .. " (" .. #choices .. ")")
  kbChooser:choices(choices)
  kbChooser:query(query0)
  kbChooser:show(place(kbChooser, 900))
end

-- Called by theme.lua after a theme change.
function M.retint()
  if chooser then
    applyColors(chooser)
    if chooser:isVisible() then pcall(refresh) end
  end
  if kbChooser then applyColors(kbChooser) end
end

-- For tests: the full root search index as plain rows.
function M.index()
  local rows = {}
  for _, e in ipairs(buildFlat(tree())) do
    rows[#rows + 1] = { label = e.node.label, path = e.path, action = e.node.action,
      arg = e.node.arg, submenu = e.node.children ~= nil, key = e.node.key }
  end
  return rows
end

M._filter = filter
M._findChain = function(key) return findChain(tree(), key) end

return M
