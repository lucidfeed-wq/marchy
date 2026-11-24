-- Shared paths and helpers. Nothing in here blocks for long: processes are
-- started with hs.task, file reads are small.
local M = {}

M.HOME = os.getenv("HOME")
M.BASE = M.HOME .. "/.config/omarchy-mac"
M.BIN = M.BASE .. "/bin"
M.CURRENT = M.BASE .. "/current"
M.THEMES = M.BASE .. "/themes"
M.STATE = M.HOME .. "/.local/state/omarchy-mac"
M.CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
M.OPEN = "/usr/bin/open"
M.OMNIWM_BUNDLE = "com.barut.OmniWM"
M.GHOSTTY_BUNDLE = "com.mitchellh.ghostty"
M.CHROME_BUNDLE = "com.google.Chrome"

-- Hammerspoon starts from launchd with a minimal PATH; tasks get a usable one.
local PATH = table.concat({
  M.HOME .. "/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
  "/usr/bin", "/bin", "/usr/sbin", "/sbin",
}, ":")

function M.env()
  return {
    HOME = M.HOME,
    USER = os.getenv("USER") or "",
    LOGNAME = os.getenv("LOGNAME") or os.getenv("USER") or "",
    TMPDIR = os.getenv("TMPDIR") or "/tmp",
    LANG = "en_US.UTF-8",
    LC_ALL = "en_US.UTF-8",
    PATH = PATH,
    OMARCHY_CALLER = "hammerspoon",
  }
end

function M.exists(path)
  return path ~= nil and hs.fs.attributes(path) ~= nil
end

function M.isDir(path)
  return path ~= nil and hs.fs.attributes(path, "mode") == "directory"
end

function M.isExec(path)
  local perms = path and hs.fs.attributes(path, "permissions")
  return perms ~= nil and perms:sub(3, 3) == "x"
end

-- mkdir -p, without a shell.
function M.mkdirp(path)
  if M.isDir(path) then return true end
  local acc = ""
  for part in path:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    if not M.isDir(acc) then hs.fs.mkdir(acc) end
  end
  return M.isDir(path)
end

function M.readFile(path)
  local fh = path and io.open(path, "r")
  if not fh then return nil end
  local data = fh:read("a")
  fh:close()
  return data
end

-- First line, trimmed.
function M.readLine(path)
  local data = M.readFile(path)
  if not data then return nil end
  local line = data:match("^%s*([^\r\n]*)")
  line = line and line:gsub("%s+$", "")
  if line == "" then return nil end
  return line
end

-- Write a file atomically (temp file in the same directory, then rename).
function M.writeFile(path, data)
  local tmp = path .. ".tmp." .. tostring(math.random(100000, 999999))
  local fh, err = io.open(tmp, "w")
  if not fh then return false, err end
  fh:write(data)
  fh:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then os.remove(tmp) return false, rerr end
  return true
end

-- Last n lines of a file, reading at most the final 64 KB.
function M.tail(path, n)
  local fh = io.open(path, "r")
  if not fh then return {} end
  local size = fh:seek("end")
  local start = math.max(0, size - 65536)
  fh:seek("set", start)
  local data = fh:read("a") or ""
  fh:close()
  local lines = {}
  for line in data:gmatch("[^\n]+") do lines[#lines + 1] = line end
  if start > 0 then table.remove(lines, 1) end -- probably a partial line
  local out = {}
  for i = math.max(1, #lines - n + 1), #lines do out[#out + 1] = lines[i] end
  return out
end

function M.split(s)
  local out = {}
  for w in tostring(s or ""):gmatch("%S+") do out[#out + 1] = w end
  return out
end

function M.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Percent-encode a filesystem path for a file:// URL (keeps "/").
function M.fileURL(path)
  return "file://" .. path:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

function M.bin(name)
  return M.BIN .. "/" .. name
end

-- Run a program asynchronously. cb(exitCode, stdout, stderr) is optional.
-- Never blocks; failures to start are logged and reported as exit code -1.
function M.run(path, args, cb, opts)
  local log = require("omarchy.log")
  opts = opts or {}
  local task
  local ok, err = pcall(function()
    task = hs.task.new(path, function(code, out, errOut)
      if code ~= 0 and not opts.quiet then
        log.w("task %s %s exited %s: %s", path, table.concat(args or {}, " "),
          tostring(code), M.trim(errOut):sub(1, 300))
      end
      if cb then
        local cok, cerr = pcall(cb, code, out or "", errOut or "")
        if not cok then log.e("task callback for %s failed: %s", path, tostring(cerr)) end
      end
    end, args or {})
    task:setEnvironment(M.env())
    if opts.cwd then task:setWorkingDirectory(opts.cwd) end
    if not task:start() then error("could not start") end
  end)
  if not ok then
    log.e("task %s failed to start: %s", path, tostring(err))
    if cb then pcall(cb, -1, "", tostring(err)) end
    return nil
  end
  return task
end

-- Run a shell snippet with zsh (login, so brew/uv/mise are on PATH).
function M.sh(command, cb, opts)
  return M.run("/bin/zsh", { "-lc", command }, cb, opts)
end

-- Wait until the user has let go of Ctrl/Option/Command (Caps Lock), then
-- call fn. Gives up waiting after maxWait seconds and calls fn anyway.
function M.afterModifiersReleased(fn, maxWait)
  local deadline = hs.timer.secondsSinceEpoch() + (maxWait or 1.5)
  local function check()
    local m = hs.eventtap.checkKeyboardModifiers()
    if (m.ctrl or m.alt or m.cmd) and hs.timer.secondsSinceEpoch() < deadline then
      hs.timer.doAfter(0.05, check)
    else
      fn()
    end
  end
  check()
end

-- A sortable stamp like 2026-11-23_14-05-09.
function M.stamp()
  return os.date("%Y-%m-%d_%H-%M-%S")
end

return M
