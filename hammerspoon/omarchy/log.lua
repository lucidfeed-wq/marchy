-- Plain-text log at ~/.local/state/omarchy-mac/hs.log, rotated at 1 MB
-- (one old copy kept as hs.log.1).
--
-- Nothing here prints to the Hammerspoon console: with hs.ipc loaded, print()
-- is mirrored to every attached `hs` command-line client, and a dead client
-- turns that into a recursion flood (audit item 12).
--
-- Never log window titles or clipboard contents.
local M = {}

local DIR = os.getenv("HOME") .. "/.local/state/omarchy-mac"
M.file = DIR .. "/hs.log"
local MAX = 1024 * 1024
local ready = false

local function ensureDir()
  if ready then return true end
  local acc = ""
  for part in DIR:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    if hs.fs.attributes(acc, "mode") ~= "directory" then hs.fs.mkdir(acc) end
  end
  ready = hs.fs.attributes(DIR, "mode") == "directory"
  return ready
end

local function rotate()
  local size = hs.fs.attributes(M.file, "size")
  if size and size > MAX then
    os.remove(M.file .. ".1")
    os.rename(M.file, M.file .. ".1")
  end
end

function M.write(level, fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  pcall(function()
    if not ensureDir() then return end
    rotate()
    local fh = io.open(M.file, "a")
    if not fh then return end
    fh:write(os.date("%Y-%m-%dT%H:%M:%S"), " ", level, " ", (msg:gsub("\n", " | ")), "\n")
    fh:close()
  end)
  return msg
end

function M.i(fmt, ...) return M.write("INFO", fmt, ...) end
function M.w(fmt, ...) return M.write("WARN", fmt, ...) end
function M.e(fmt, ...) return M.write("ERROR", fmt, ...) end

return M
