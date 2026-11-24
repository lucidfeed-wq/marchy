-- Current Omarchy theme: colours for the menu and toasts, and the wallpaper.
--
-- `omarchy-theme set <name>` renders everything into ~/.config/omarchy-mac/
-- current/ and writes current/theme.name LAST. This module watches that
-- folder (it never gets called through `hs -c`), then re-reads colors.json,
-- retints the menu and toasts, and sets the wallpaper on every screen from
-- current/background (a one-line file holding the absolute image path).
local M = {}

local u = require("omarchy.util")
local log = require("omarchy.log")

local fallback = {
  mode = "dark", background = "#1a1b26", foreground = "#a9b1d6", accent = "#7aa2f7",
  selection = "#292e42", muted = "#414868", bright_foreground = "#c0caf5",
  dark_foreground = "#565f89", red = "#f7768e", green = "#9ece6a", yellow = "#e0af68",
}

M.colors = setmetatable({}, { __index = fallback })
M.name = "tokyo-night"
M.mode = "dark"
M.background = nil

local function pickFont()
  for _, f in ipairs({ "JetBrainsMonoNF-Regular", "JetBrainsMono Nerd Font", "JetBrainsMonoNerdFont-Regular" }) do
    local ok, valid = pcall(hs.styledtext.validFont, f)
    if ok and valid then return f end
  end
  return ".AppleSystemUIFont"
end
M.font = pickFont()

function M.hex(name)
  return M.colors[name] or fallback[name] or "#ffffff"
end

function M.color(name, alpha)
  return { hex = M.hex(name), alpha = alpha or 1 }
end

function M.isDark()
  return M.mode ~= "light"
end

-- "tokyo-night" -> "Tokyo Night"
function M.pretty(name)
  return (tostring(name):gsub("[-_]", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

function M.load()
  local raw = u.readFile(u.CURRENT .. "/colors.json")
  if raw then
    local ok, colors = pcall(hs.json.decode, raw)
    if ok and type(colors) == "table" then
      M.colors = setmetatable(colors, { __index = fallback })
    else
      log.w("theme: could not parse current/colors.json")
    end
  end
  M.name = u.readLine(u.CURRENT .. "/theme.name") or M.name
  M.mode = (M.colors.mode == "light") and "light" or "dark"
  M.background = M.backgroundPath()
  return M.name
end

local IMAGE = { jpg = true, jpeg = true, png = true, heic = true, webp = true, tiff = true, gif = true }

local function firstImage(dir)
  if not u.isDir(dir) then return nil end
  local names = {}
  for f in hs.fs.dir(dir) do
    local ext = f:match("%.([%w]+)$")
    if ext and IMAGE[ext:lower()] and f:sub(1, 1) ~= "." then names[#names + 1] = f end
  end
  table.sort(names)
  return names[1] and (dir .. "/" .. names[1]) or nil
end

-- current/background (written by omarchy-theme) wins; then the older
-- current/backgrounds/<theme>-<index>.jpg layout; then the theme's first image.
function M.backgroundPath()
  local p = u.readLine(u.CURRENT .. "/background")
  if p then
    if p:sub(1, 2) == "~/" then p = u.HOME .. p:sub(2) end
    if u.exists(p) then return p end
    log.w("theme: current/background points at a missing file")
  end
  local idx = u.readLine(u.CURRENT .. "/backgrounds/" .. M.name .. ".index") or "0"
  for _, ext in ipairs({ "jpg", "png", "jpeg" }) do
    local legacy = u.CURRENT .. "/backgrounds/" .. M.name .. "-" .. idx .. "." .. ext
    if u.exists(legacy) then return legacy end
  end
  return firstImage(u.THEMES .. "/" .. M.name .. "/backgrounds")
end

-- Set the wallpaper on every screen. Without force, screens already showing
-- the image are left alone.
function M.applyWallpaper(force)
  local path = M.background or M.backgroundPath()
  if not path then return end
  local url = u.fileURL(path)
  local changed = 0
  for _, s in ipairs(hs.screen.allScreens()) do
    local ok, cur = pcall(function() return s:desktopImageURL() end)
    if force or not ok or cur ~= url then
      local sok, err = pcall(function() s:desktopImageURL(url) end)
      if sok then changed = changed + 1 else log.w("theme: wallpaper failed on a screen: %s", tostring(err)) end
    end
  end
  if changed > 0 then log.i("theme: wallpaper %s on %d screen(s)", path, changed) end
end

function M.retint()
  pcall(function() require("omarchy.toast").retint() end)
  pcall(function() require("omarchy.menu").retint() end)
end

-- Installed themes, sorted (folder names under ~/.config/omarchy-mac/themes).
function M.list()
  local out = {}
  if not u.isDir(u.THEMES) then return out end
  for f in hs.fs.dir(u.THEMES) do
    if f:sub(1, 1) ~= "." and u.isDir(u.THEMES .. "/" .. f) then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end

function M.set(name)
  local bin = u.bin("omarchy-theme")
  if not u.isExec(bin) then
    return require("omarchy.toast").warn("omarchy-theme is not installed")
  end
  log.i("theme: set %s", name)
  u.run(bin, { "set", name }, function(code, _, err)
    if code ~= 0 then
      require("omarchy.toast").warn("Theme failed: " .. u.trim(err):sub(1, 120))
    end
  end)
end

function M.nextBackground()
  local bin = u.bin("omarchy-theme")
  if not u.isExec(bin) then
    return require("omarchy.toast").warn("omarchy-theme is not installed")
  end
  u.run(bin, { "bg-next" }, function(code, _, err)
    if code ~= 0 then
      require("omarchy.toast").warn("Background failed: " .. u.trim(err):sub(1, 120))
    end
  end)
end

local function onCurrentChanged()
  local oldName, oldBg = M.name, M.background
  M.load()
  M.retint()
  local themeChanged = M.name ~= oldName
  local bgChanged = M.background ~= oldBg
  if themeChanged then
    log.i("theme: applied %s (wallpaper %s)", M.name, tostring(M.background))
    require("omarchy.toast").show("Theme  " .. M.pretty(M.name))
  end
  if themeChanged or bgChanged then M.applyWallpaper(true) end
end

function M.start()
  M.load()
  M.retint()
  M.applyWallpaper(false)

  -- Debounced: omarchy-theme writes many files in a burst.
  M.debounce = hs.timer.delayed.new(0.3, function()
    local ok, err = pcall(onCurrentChanged)
    if not ok then log.e("theme: reload failed: %s", tostring(err)) end
  end)

  -- Watch the parent folder so an atomic swap of current/ is still seen.
  local prefix = u.CURRENT
  M.watcher = hs.pathwatcher.new(u.BASE, function(paths)
    for _, p in ipairs(paths) do
      if p:sub(1, #prefix) == prefix then
        M.debounce:start()
        return
      end
    end
  end)
  M.watcher:start()

  -- A screen plugged in later gets the wallpaper too.
  M.screenWatcher = hs.screen.watcher.new(function()
    hs.timer.doAfter(1, function() pcall(M.applyWallpaper, false) end)
  end)
  M.screenWatcher:start()
end

return M
