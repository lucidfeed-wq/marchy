-- App menu search (Super+/): every command in the frontmost app's menu bar, in a
-- type-to-search list. Works with the macOS menu bar hidden, because it reads the
-- menus through Accessibility (hs.application:getMenuItems) and runs the chosen item
-- with hs.application:selectMenuItem, exactly as a click would.
--
-- Type any words in any order ("export csv", "csv"); the menu path and the item's
-- own shortcut are shown under each match. Items the app reports as disabled are listed
-- last and marked, because apps often refresh that state only when a menu opens.
--
-- Privacy: menu titles can contain document and window names (the Window menu), so
-- they are shown but never logged.
local M = {}

local log = require("omarchy.log")
local toast = require("omarchy.toast")

local chooser
local target   -- hs.application the menus belong to
local items = {} -- { title, path = {..}, where, keys, hay }
local token = 0  -- ignores menu reads that finish after the list was closed or reopened

local SKIP_MENUS = { Apple = true }

------------------------------------------------------------------ shortcuts

local MOD_GLYPH = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘" }

local function mods(raw)
  local set = {}
  if type(raw) == "table" then
    for _, m in ipairs(raw) do set[tostring(m):lower()] = true end
  elseif type(raw) == "number" then -- raw AX value: 1 shift, 2 option, 4 control, 8 no command
    if raw & 1 ~= 0 then set.shift = true end
    if raw & 2 ~= 0 then set.alt = true end
    if raw & 4 ~= 0 then set.ctrl = true end
    if raw & 8 == 0 then set.cmd = true end
  end
  if set.option then set.alt = true end
  if set.control then set.ctrl = true end
  if set.command then set.cmd = true end
  local out = ""
  for _, m in ipairs({ "ctrl", "alt", "shift", "cmd" }) do
    if set[m] then out = out .. MOD_GLYPH[m] end
  end
  return out
end

local function shortcut(item)
  local ch = item.AXMenuItemCmdChar
  if type(ch) ~= "string" or ch == "" then return nil end
  return mods(item.AXMenuItemCmdModifiers) .. ch:upper()
end

------------------------------------------------------------------ menus

local function walk(list, path, out)
  for _, it in ipairs(list or {}) do
    local t = it.AXTitle
    if type(t) == "string" and t ~= "" then
      local p = { table.unpack(path) }
      p[#p + 1] = t
      local kids = it.AXChildren and it.AXChildren[1]
      if type(kids) == "table" and #kids > 0 then
        walk(kids, p, out)
      else
        local where = table.concat(path, " › ")
        out[#out + 1] = {
          title = t, path = p, where = where, keys = shortcut(it), off = it.AXEnabled == false,
          hay = (t .. " " .. where):lower(),
        }
      end
    end
  end
end

local function flatten(bar)
  local out = {}
  for _, menu in ipairs(bar or {}) do
    local t = menu.AXTitle
    if type(t) == "string" and t ~= "" and not SKIP_MENUS[t] then
      walk(menu.AXChildren and menu.AXChildren[1], { t }, out)
    end
  end
  return out
end

------------------------------------------------------------------ list

local function words(q)
  local out = {}
  for w in (q or ""):lower():gmatch("%S+") do out[#out + 1] = w end
  return out
end

local function choicesFor(q)
  local ws = words(q)
  local scored = {}
  for i, it in ipairs(items) do
    local ok = true
    for _, w in ipairs(ws) do
      if not it.hay:find(w, 1, true) then ok = false break end
    end
    if ok then
      local s = 2
      if #ws > 0 then
        local tl = it.title:lower()
        if tl:sub(1, #ws[1]) == ws[1] then s = 0 elseif tl:find(ws[1], 1, true) then s = 1 end
      end
      if it.off then s = s + 3 end
      scored[#scored + 1] = { s = s, i = i }
    end
  end
  table.sort(scored, function(a, b) if a.s ~= b.s then return a.s < b.s end return a.i < b.i end)
  local out = {}
  for _, e in ipairs(scored) do
    local it = items[e.i]
    out[#out + 1] = {
      text = it.title,
      subText = it.where .. (it.keys and ("   " .. it.keys) or "") .. (it.off and "   (unavailable)" or ""),
      idx = e.i,
    }
  end
  return out
end

local function refresh(q)
  if chooser then chooser:choices(choicesFor(q)) end
end

local function run(it, app)
  hs.timer.doAfter(0.05, function()
    if app:isRunning() then app:activate() end
    hs.timer.doAfter(0.15, function()
      local ok = app:selectMenuItem(it.path)
      if not ok then toast.warn("Couldn't run " .. it.title .. " (it may be unavailable right now)") end
    end)
  end)
end

local function ensureChooser()
  if chooser then return chooser end
  chooser = hs.chooser.new(function(choice)
    token = token + 1
    local app = target
    target = nil
    if not choice or not app then return end
    local it = items[choice.idx]
    if it then run(it, app) end
  end)
  chooser:queryChangedCallback(function(q)
    local ok, err = pcall(refresh, q)
    if not ok then log.e("appmenu: filter failed: %s", tostring(err)) end
  end)
  chooser:rows(12)
  return chooser
end

------------------------------------------------------------------ public

function M.isOpen()
  return chooser ~= nil and chooser:isVisible()
end

function M.toggle()
  if M.isOpen() then chooser:hide() return end
  local app = hs.application.frontmostApplication()
  if not app or app:bundleID() == "org.hammerspoon.Hammerspoon" then
    toast.show("No app in front")
    return
  end
  target, items = app, {}
  token = token + 1
  local mine = token
  local name = app:name() or "app"

  ensureChooser()
  local style = require("omarchy.menu").style
  local at = style(chooser, 720)
  chooser:placeholderText("Reading " .. name .. " menus…")
  chooser:query("")
  chooser:choices({})
  chooser:show(at)

  app:getMenuItems(function(bar)
    if mine ~= token then return end
    if type(bar) ~= "table" then
      chooser:placeholderText("Couldn't read " .. name .. " menus (Accessibility permission?)")
      return
    end
    items = flatten(bar)
    log.i("appmenu: %d commands", #items)
    chooser:placeholderText("Search " .. name .. " menus")
    refresh(chooser:query())
  end)
end

return M
