-- omarchy reminders: port of the Omarchy 4.5 overlay plugin `omarchy.reminders` (the
-- interactive "Remind in minutes... / Reminder message..." flow) together with what it hands
-- off to: `omarchy-reminder <minutes> [message]`, `show`, `clear`, and the bar's Reminder
-- indicator (󰢌) from omarchy.indicators.
--
-- Backend: in-memory hs.timer reminders. Omarchy's reminders are transient systemd timers
-- whose message sits in a tmpfs file and that vanish on reboot; the closest macOS match that
-- never writes typed text to disk is a timer held by Hammerspoon. They are lost when
-- Hammerspoon reloads or quits (PORT.md says so). When one fires, an Omarchy-style card
-- ("󰢌 Reminder" + the message) appears at the top right of the main screen and stays until
-- clicked, with the system "Glass" sound. No notification permission is needed.
--
-- Privacy: the reminder message is typed text. It travels from the overlay page to Lua
-- through the WKWebView message handler (never a URL), lives only in this module's memory,
-- is shown only in the reminder's own cards, and is never logged, published or written to disk.
-- The OmniShell var carries only {count, next} for the bar indicator.
local M = { id = "reminders" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local VAR = "omarchy_reminders"
local GLYPH = "\u{F088C}"
local MAX_MINUTES = 525600     -- a year; Omarchy has no cap but hs.timer needs a sane one
local MAX_MESSAGE = 500        -- bytes kept of a typed message
local MAX_REMINDERS = 50

-- English strings from Omarchy's i18n catalogs (shell.json reminders.*, cli.json reminder.*).
local T = {
  minutesPrompt = "Remind in minutes...",
  messagePrompt = "Reminder message...",
  invalidTitle = "Invalid reminder",
  invalidBody = "Enter the number of minutes",
  title = "Reminder",
  upcoming = "Upcoming reminders",
  none = "No outstanding reminders",
  cleared = "All reminders have been cleared",
  setTooltip = "Set Reminder",
}

local function plural(n, one, other) return (n == 1 and one or other):gsub("%%1", tostring(n)) end
local function minutesUp(n) return (plural(n, "Your %1 minute is up", "Your %1 minutes are up")) end
local function setForMinutes(n) return (plural(n, "Reminder set for %1 minute", "Reminder set for %1 minutes")) end
local function minuteLabel(n) return tostring(n) .. "-min reminder" end

---------------------------------------------------------------- state
local reminders = {}        -- { id, minutes, at, message|nil, timer }
local nextId = 0
local lastPush
local view, ucc
local flow = { open = false, step = "minutes", minutes = nil }
local cards = {}            -- on-screen canvases, newest last
local wakeWatcher

local function publish()
  local nextAt = nil
  for _, r in ipairs(reminders) do
    if not nextAt or r.at < nextAt then nextAt = r.at end
  end
  local text = hs.json.encode({ v = 1, count = #reminders, next = nextAt and math.floor(nextAt) or nil })
  if not text or text == lastPush then return end
  lastPush = text
  if not hs.fs.attributes(CTL) then return end
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("reminders: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

local function clockAt(epoch)
  local t = os.date("*t", math.floor(epoch))
  return string.format("%d:%02d", t.hour, t.min)
end

local function remainingText(seconds)
  seconds = math.max(0, math.floor(seconds))
  local m, s = math.floor(seconds / 60), seconds % 60
  if m > 0 and s > 0 then return string.format("%dm %ds", m, s) end
  if m > 0 then return string.format("%dm", m) end
  return string.format("%ds", s)
end

-- Strip control characters and cap the length; keeps UTF-8 intact (cuts on a lead byte).
local function cleanMessage(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #s > MAX_MESSAGE then
    local cut = MAX_MESSAGE
    while cut > 0 do
      local b = s:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end
      cut = cut - 1
    end
    s = s:sub(1, cut)
  end
  return s
end

local function validMinutes(value)
  local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if not text:match("^%d+$") then return nil end
  local n = tonumber(text)
  if not n or n <= 0 or n > MAX_MINUTES then return nil end
  return math.floor(n)
end

---------------------------------------------------------------- cards (notification look)
local CARD_W, PAD, GAP = 360, 14, 10

local function layoutCards()
  local scr = hs.screen.mainScreen()
  if not scr then return end
  local f = scr:frame()
  local y = f.y + 12
  for _, c in ipairs(cards) do
    local fr = c.canvas:frame()
    c.canvas:frame({ x = f.x + f.w - CARD_W - 12, y = y, w = CARD_W, h = fr.h })
    y = y + fr.h + GAP
  end
end

local function dismissCard(card)
  for i, c in ipairs(cards) do
    if c == card then
      table.remove(cards, i)
      break
    end
  end
  if card.timer then card.timer:stop() card.timer = nil end
  pcall(function() card.canvas:delete() end)
  layoutCards()
end

-- A themed card: glyph, bold heading, body lines. sticky = stays until clicked.
local function showCard(heading, body, sticky)
  local font = theme.font
  local bold = font
  for _, f in ipairs({ "JetBrainsMonoNF-Bold", "JetBrainsMono Nerd Font Bold", "JetBrainsMonoNerdFont-Bold" }) do
    local ok, valid = pcall(hs.styledtext.validFont, f)
    if ok and valid then bold = f break end
  end
  local textW = CARD_W - PAD * 2 - 34
  local headText = tostring(heading or "")
  local bodyText = tostring(body or "")
  -- Height of wrapped text: each source line wraps to ceil(width / textW) lines of one height.
  local function wrappedHeight(text, fontName, size)
    if text == "" then return 0 end
    local style = { font = { name = fontName, size = size } }
    local okH, one = pcall(hs.drawing.getTextDrawingSize, hs.styledtext.new("Ag", style))
    local lineH = (okH and one and one.h and one.h > 0) and math.ceil(one.h) or (size + 5)
    local lines = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      local okL, sz = pcall(hs.drawing.getTextDrawingSize, hs.styledtext.new(line, style))
      local w = (okL and sz and sz.w) or textW
      lines = lines + math.max(1, math.ceil(w / textW))
    end
    return math.max(1, lines) * lineH + 2
  end
  local headH = math.max(20, wrappedHeight(headText, bold, 14))
  local bodyH = wrappedHeight(bodyText, font, 13)
  local h = PAD * 2 + headH + (bodyH > 0 and (bodyH + 6) or 0)
  local canvas = hs.canvas.new({ x = 0, y = 0, w = CARD_W, h = h })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary", "transient" })
  canvas:clickActivating(false)
  canvas[1] = { type = "rectangle", action = "strokeAndFill", fillColor = theme.color("background", 0.97),
    strokeColor = theme.color("accent"), strokeWidth = 2, roundedRectRadii = { xRadius = 0, yRadius = 0 },
    trackMouseUp = true }
  canvas[2] = { type = "text", text = hs.styledtext.new(GLYPH, { font = { name = font, size = 22 },
    color = theme.color("accent") }), frame = { x = PAD, y = PAD - 2, w = 30, h = 30 } }
  canvas[3] = { type = "text", text = hs.styledtext.new(headText, { font = { name = bold, size = 14 },
    color = theme.color("bright_foreground"), paragraphStyle = { lineBreak = "wordWrap" } }),
    frame = { x = PAD + 34, y = PAD, w = textW, h = headH } }
  if bodyH > 0 then
    canvas[4] = { type = "text", text = hs.styledtext.new(bodyText, { font = { name = font, size = 13 },
      color = theme.color("foreground"), paragraphStyle = { lineBreak = "wordWrap" } }),
      frame = { x = PAD + 34, y = PAD + headH + 6, w = textW, h = bodyH } }
  end
  local card = { canvas = canvas }
  canvas:mouseCallback(function(_, msg)
    if msg == "mouseUp" then dismissCard(card) end
  end)
  cards[#cards + 1] = card
  while #cards > 6 do dismissCard(cards[1]) end
  layoutCards()
  canvas:show()
  if not sticky then
    card.timer = hs.timer.doAfter(8, function() card.timer = nil dismissCard(card) end)
  end
  return card
end

---------------------------------------------------------------- reminders
local function removeReminder(id)
  for i, r in ipairs(reminders) do
    if r.id == id then
      if r.timer then r.timer:stop() end
      table.remove(reminders, i)
      break
    end
  end
  publish()
end

local function fire(id)
  local found
  for _, r in ipairs(reminders) do if r.id == id then found = r break end end
  if not found then return end
  local message = found.message or minutesUp(found.minutes)
  removeReminder(id)
  pcall(function()
    local snd = hs.sound.getByName("Glass")
    if snd then snd:play() end
  end)
  showCard(T.title, message, true)
  log.i("reminders: a %d-minute reminder fired", found.minutes)
end

-- Same as `omarchy-reminder <minutes> [message]`. message may be nil (Lua callers only).
function M.add(minutes, message)
  local n = validMinutes(minutes)
  if not n then
    showCard(T.invalidTitle, T.invalidBody, false)
    return false
  end
  if #reminders >= MAX_REMINDERS then
    toast.warn("Too many reminders queued")
    return false
  end
  local custom = message and cleanMessage(message) or ""
  nextId = nextId + 1
  local id = nextId
  local at = os.time() + n * 60
  local r = { id = id, minutes = n, at = at, message = custom ~= "" and custom or nil }
  r.timer = hs.timer.doAfter(n * 60, function() fire(id) end)
  reminders[#reminders + 1] = r
  publish()
  log.i("reminders: set for %d minute(s)%s", n, r.message and " with a message" or "")
  local heading = setForMinutes(n)
  if r.message then
    -- cli.json reminder.customInMinutes: "%1 in %2 minute(s)" (%1 = message, %2 = minutes).
    heading = r.message .. " in " .. tostring(n) .. (n == 1 and " minute" or " minutes")
  end
  showCard(heading, "You'll be reminded at " .. clockAt(at), false)
  return true
end

function M.show()
  if #reminders == 0 then
    showCard(T.upcoming, T.none, false)
    return
  end
  local sorted = {}
  for _, r in ipairs(reminders) do sorted[#sorted + 1] = r end
  table.sort(sorted, function(a, b) return a.at < b.at end)
  local now = os.time()
  local lines = {}
  for _, r in ipairs(sorted) do
    lines[#lines + 1] = string.format("%s in %s (%s)", r.message or minuteLabel(r.minutes),
      remainingText(r.at - now), clockAt(r.at))
  end
  showCard(T.upcoming, table.concat(lines, "\n"), false)
end

function M.clear()
  for _, r in ipairs(reminders) do if r.timer then r.timer:stop() end end
  reminders = {}
  publish()
  showCard(T.cleared, "", false)
end

-- Catch anything whose time passed while the Mac slept (NSTimer normally fires on wake too).
local function fireOverdue()
  local now = os.time()
  local due = {}
  for _, r in ipairs(reminders) do if r.at <= now then due[#due + 1] = r.id end end
  for _, id in ipairs(due) do fire(id) end
end

---------------------------------------------------------------- the setup flow (overlay)
local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function hexToRgba(hex, alpha)
  local r, g, b = tostring(hex):match("^#?(%x%x)(%x%x)(%x%x)")
  if not r then return "rgba(0,0,0," .. alpha .. ")" end
  return string.format("rgba(%d,%d,%d,%s)", tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), tostring(alpha))
end

local function page()
  local c = function(n) return theme.hex(n) end
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{background:transparent;height:100%;overflow:hidden;
    font-family:"JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace}
  #scrim{position:fixed;inset:0;background:]] .. hexToRgba(c("background"), 0.5) .. [[;
    display:flex;align-items:center;justify-content:center}
  #card{width:300px;max-width:calc(100vw - 40px);height:70px;background:]] .. c("background") .. [[;
    border:2px solid ]] .. c("foreground") .. [[;padding:0 18px;display:flex;align-items:center}
  #q{width:100%;background:transparent;border:0;outline:0;caret-color:]] .. c("foreground") .. [[;
    color:]] .. c("foreground") .. [[;font:inherit;font-size:16px;text-overflow:ellipsis}
  #q::placeholder{color:]] .. c("foreground") .. [[;opacity:.58}
  </style></head><body>
  <div id="scrim"><div id="card"><input id="q" autocomplete="off" spellcheck="false"></div></div>
  <script>
  const send=(m)=>window.webkit.messageHandlers.omarchy_reminders.postMessage(m);
  const q=document.getElementById('q');
  let step='minutes';
  window.omarchyStep=function(s,prompt){step=s;q.value='';q.placeholder=prompt;setTimeout(()=>q.focus(),20)};
  q.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();if(q.value)q.value='';else send({close:true})}
    else if(e.key==='Enter'){e.preventDefault();send({submit:step,value:String(q.value).slice(0,2000)})}
  });
  document.getElementById('scrim').addEventListener('mousedown',e=>{if(e.target.id==='scrim')send({close:true})});
  document.getElementById('card').addEventListener('mousedown',e=>{e.stopPropagation();setTimeout(()=>q.focus(),0)});
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({close:true})},150));
  window.omarchyStep('minutes',']] .. esc(T.minutesPrompt) .. [[');
  </script></body></html>]]
end

local function destroyView()
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
end

function M.close()
  flow.open, flow.step, flow.minutes = false, "minutes", nil
  destroyView()
end

local function setStep(step)
  flow.step = step
  if not view then return end
  local prompt = step == "message" and T.messagePrompt or T.minutesPrompt
  pcall(function()
    view:evaluateJavaScript("window.omarchyStep && window.omarchyStep(" .. hs.json.encode(step) .. ","
      .. hs.json.encode(prompt) .. ")")
  end)
end

-- The page's Return. value is untrusted page input; the message never leaves memory.
local function onSubmit(step, value)
  if type(value) ~= "string" then return end
  if step ~= flow.step then return end
  if step == "minutes" then
    if value:match("^%s*$") then return M.close() end
    local n = validMinutes(value)
    if not n then
      showCard(T.invalidTitle, T.invalidBody, false)
      return
    end
    flow.minutes = n
    setStep("message")
  elseif step == "message" and flow.minutes then
    local n = flow.minutes
    M.close()
    M.add(n, value)
  end
end

function M.open()
  if view then
    flow.open = true
    setStep("minutes")
    pcall(function() view:bringToFront(true) local w = view:hswindow() if w then w:focus() end end)
    return
  end
  flow.open, flow.step, flow.minutes = true, "minutes", nil
  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy_reminders")
    ucc:setCallback(function(msg)
      local body = type(msg) == "table" and type(msg.body) == "table" and msg.body or {}
      if body.close == true then
        hs.timer.doAfter(0, M.close)
      elseif body.submit == "minutes" or body.submit == "message" then
        local step, value = body.submit, body.value
        hs.timer.doAfter(0, function() onSubmit(step, value) end)
      end
    end)
  end
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  local ok, err = pcall(function()
    view = hs.webview.new(sf, { developerExtrasEnabled = false }, ucc)
      :windowStyle({ "borderless" })
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.modalPanel)
      :shadow(false)
      :closeOnEscape(false)
      :deleteOnClose(true)
    pcall(function() view:transparent(true) end)
    view:html(page())
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
  if not ok then
    log.e("reminders: could not open the overlay: %s", tostring(err))
    destroyView()
    flow.open = false
    toast.warn("Reminder flow failed to open")
  end
end

function M.toggle()
  if flow.open then M.close() else M.open() end
end

-- Lua-only API (no values cross a URL): count and next due time.
function M.state()
  local nextAt
  for _, r in ipairs(reminders) do if not nextAt or r.at < nextAt then nextAt = r.at end end
  return { count = #reminders, next = nextAt }
end

M.actions = {
  ["reminders.open"] = { fn = function() M.open() end, desc = "Reminders: set one (minutes, then message)" },
  ["reminders.toggle"] = { fn = function() M.toggle() end, desc = "Reminders: open or close the setup flow" },
  ["reminders.close"] = { fn = function() M.close() end, desc = "Reminders: close the setup flow" },
  ["reminders.show"] = { fn = function() M.show() end, desc = "Reminders: show upcoming reminders" },
  ["reminders.clear"] = { fn = function() M.clear() end, desc = "Reminders: clear all reminders" },
  -- x = minutes only (digits). A message cannot come through a URL: it would be logged.
  ["reminders.set"] = { fn = function(x)
    if validMinutes(x) then M.add(x, nil) else showCard(T.invalidTitle, T.invalidBody, false) end
  end, desc = "Reminders: remind in x minutes (default message)" },
  ["reminders.indicator"] = { fn = function()
    if #reminders > 0 then M.show() else M.open() end
  end, desc = "Reminders: bar indicator click (show if any, else set one)" },
}

function M.start()
  publish()
  wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then hs.timer.doAfter(2, fireOverdue) end
  end)
  wakeWatcher:start()
end

function M.stop()
  if wakeWatcher then wakeWatcher:stop() wakeWatcher = nil end
  for _, r in ipairs(reminders) do if r.timer then r.timer:stop() end end
  reminders = {}
  while #cards > 0 do dismissCard(cards[#cards]) end
  M.close()
  lastPush = nil
  publish()
end

return M
