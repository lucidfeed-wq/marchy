-- omarchy.emojis: port of the Omarchy 4.5 shell plugin `omarchy.emojis` (search, copy, type emojis).
--
-- Omarchy: a 400 x 500 card centred on a dimmed screen (menu surface colours: background,
-- 2 px foreground border, scrim = background at 50 %). The header shows what you typed, or
-- "Search emojis…" at 58 % opacity. Below it a grid of 44 px emoji cells (24 px glyphs); the
-- cursor cell gets the menu's selected background. Type to filter by keyword (first 1000
-- matches), arrows / PageUp / PageDown move, Return inserts the emoji into the focused app and
-- closes, Esc clears the filter first and closes on an empty one, a click on the scrim closes.
-- No matches: the 󰈉 glyph in the accent colour and "No matches for “…”".
--
-- Here: an hs.webview covering the screen (transparent; scrim and card drawn in the page).
--   * Emoji data: Omarchy's emojis.json is not installed with the port. It is read from the
--     synced upstream checkout (~/.local/share/omarchy-mac/upstream/current/shell/plugins/
--     emojis/emojis.json, created by `omarchy-port sync`), validated, and cached in memory.
--     Missing or unreadable: a toast says so and a small built-in set is shown instead.
--   * Inserting: Omarchy copies the emoji and sends Shift+Insert. Here the emoji is typed into
--     the app that was frontmost before the picker opened as one synthetic Unicode key event,
--     so the clipboard is left alone. Never into Citrix Viewer (the EMR): when it is frontmost
--     the emoji is only copied to the clipboard and a toast says so.
--   * Extra (macOS): Shift+Return or Shift+click copies instead of typing.
--   * Privacy: picked emojis and search text are never logged.
--
-- Actions: emojis.open, emojis.toggle, emojis.close.
local M = { id = "emojis" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local DATA_FILE = os.getenv("HOME") .. "/.local/share/omarchy-mac/upstream/current/shell/plugins/emojis/emojis.json"
local CITRIX = "com.citrix.receiver.icaviewer.mac"
local HAMMERSPOON = "org.hammerspoon.Hammerspoon"
local MAX_ITEMS = 5000
local MAX_EMOJI_BYTES = 64
local MAX_KEYWORD_BYTES = 512
local MAX_UNICODE_UNITS = 20   -- CGEventKeyboardSetUnicodeString limit

-- Used only when the upstream file is missing (keywords in Omarchy's style).
local BUILTIN = {
  { e = "\u{1F600}", k = "grinning face smile happy" }, { e = "\u{1F602}", k = "face with tears of joy laugh lol" },
  { e = "\u{1F642}", k = "slightly smiling face" }, { e = "\u{1F609}", k = "wink winking face" },
  { e = "\u{1F60A}", k = "smiling face with smiling eyes blush" }, { e = "\u{1F60D}", k = "heart eyes love crush" },
  { e = "\u{1F914}", k = "thinking face hmm" }, { e = "\u{1F610}", k = "neutral face" },
  { e = "\u{1F62D}", k = "loudly crying face sob" }, { e = "\u{1F62E}", k = "face with open mouth wow" },
  { e = "\u{1F634}", k = "sleeping face tired zzz" }, { e = "\u{1F637}", k = "face with medical mask sick" },
  { e = "\u{1F44D}", k = "thumbs up +1 yes like" }, { e = "\u{1F44E}", k = "thumbs down -1 no" },
  { e = "\u{1F44F}", k = "clapping hands applause" }, { e = "\u{1F64F}", k = "folded hands please thanks pray" },
  { e = "\u{1F44B}", k = "waving hand hello bye" }, { e = "\u{1F4AA}", k = "flexed biceps strong" },
  { e = "\u{1F440}", k = "eyes look" }, { e = "\u{2764}\u{FE0F}", k = "red heart love" },
  { e = "\u{1F525}", k = "fire hot lit" }, { e = "\u{2728}", k = "sparkles shiny" },
  { e = "\u{1F389}", k = "party popper tada celebrate" }, { e = "\u{2705}", k = "check mark button done yes" },
  { e = "\u{274C}", k = "cross mark no wrong" }, { e = "\u{26A0}\u{FE0F}", k = "warning caution" },
  { e = "\u{2753}", k = "question mark" }, { e = "\u{1F4AF}", k = "hundred points 100 perfect" },
  { e = "\u{1F680}", k = "rocket launch ship" }, { e = "\u{1F4A1}", k = "light bulb idea" },
  { e = "\u{1F4DD}", k = "memo note write" }, { e = "\u{1F4C5}", k = "calendar date" },
  { e = "\u{23F0}", k = "alarm clock time" }, { e = "\u{2615}", k = "hot beverage coffee tea" },
  { e = "\u{1F37A}", k = "beer mug" }, { e = "\u{1F3E5}", k = "hospital" },
  { e = "\u{1FA7A}", k = "stethoscope doctor" }, { e = "\u{1F48A}", k = "pill medicine" },
  { e = "\u{1F489}", k = "syringe vaccine shot" }, { e = "\u{1F9E0}", k = "brain think" },
  { e = "\u{2600}\u{FE0F}", k = "sun sunny weather" }, { e = "\u{1F327}\u{FE0F}", k = "cloud with rain weather" },
  { e = "\u{1F436}", k = "dog face puppy" }, { e = "\u{1F431}", k = "cat face kitten" },
  { e = "\u{1F937}", k = "person shrugging shrug" }, { e = "\u{1F622}", k = "crying face sad tear" },
  { e = "\u{1F926}", k = "person facepalming facepalm" }, { e = "\u{1F64C}", k = "raising hands hooray" },
}

---------------------------------------------------------------- data
local cache = { list = nil, mtime = nil, builtin = false }

local function cleanString(v, limit)
  if type(v) ~= "string" or v == "" or #v > limit then return nil end
  if v:find("[%z\1-\31\127]") then return nil end
  return v
end

local function loadList()
  local mtime = hs.fs.attributes(DATA_FILE, "modification")
  if mtime and cache.list and not cache.builtin and cache.mtime == mtime then return cache.list, false end
  if mtime then
    local fh = io.open(DATA_FILE, "r")
    local raw = fh and fh:read("a")
    if fh then fh:close() end
    local ok, data = pcall(hs.json.decode, raw or "")
    if ok and type(data) == "table" then
      local out = {}
      for _, item in ipairs(data) do
        if #out >= MAX_ITEMS then break end
        local e = type(item) == "table" and cleanString(item.e, MAX_EMOJI_BYTES)
        if e then
          out[#out + 1] = { e = e, k = (cleanString(item.k, MAX_KEYWORD_BYTES) or ""):lower() }
        end
      end
      if #out > 0 then
        cache.list, cache.mtime, cache.builtin = out, mtime, false
        return out, false
      end
    end
    log.w("emojis: emojis.json could not be parsed, using the built-in set")
  else
    log.w("emojis: emojis.json not found (run omarchy-port sync), using the built-in set")
  end
  cache.list, cache.mtime, cache.builtin = BUILTIN, nil, true
  return BUILTIN, true
end

---------------------------------------------------------------- inserting
local function utf16Units(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + (b >= 0xF0 and 2 or 1) end
  end
  return n
end

local function copyOnly(emoji, why)
  local ok = pcall(hs.pasteboard.setContents, emoji)
  if ok then toast.show(why and (why .. ": copied " .. emoji) or ("Copied " .. emoji), 1.6)
  else toast.warn("Could not copy the emoji") end
end

-- One synthetic key event carrying the whole grapheme (ZWJ sequences and flags included),
-- so it arrives as a single insertion and the clipboard is untouched.
local function typeEmoji(emoji)
  local ok = pcall(function()
    local down = hs.eventtap.event.newKeyEvent({}, 0, true)
    down:setUnicodeString(emoji)
    down:post()
    local up = hs.eventtap.event.newKeyEvent({}, 0, false)
    up:setUnicodeString(emoji)
    up:post()
  end)
  if not ok then
    local ok2 = pcall(hs.eventtap.keyStrokes, emoji)
    if not ok2 then copyOnly(emoji, "Could not type") end
  end
end

local function insert(emoji, app, copy)
  if copy then return copyOnly(emoji) end
  if not app then return copyOnly(emoji, "No app to type into") end
  if app:bundleID() == CITRIX then return copyOnly(emoji, "Not typed into Citrix Viewer") end
  if utf16Units(emoji) > MAX_UNICODE_UNITS then return copyOnly(emoji, "Too long to type") end
  pcall(function() app:activate() end)
  hs.timer.doAfter(0.18, function()
    local front = hs.application.frontmostApplication()
    local bundle = front and front:bundleID()
    if bundle == CITRIX then return copyOnly(emoji, "Not typed into Citrix Viewer") end
    if bundle ~= app:bundleID() then return copyOnly(emoji, "Focus moved") end
    typeEmoji(emoji)
  end)
end

---------------------------------------------------------------- overlay
local view, ucc
local current = nil     -- { list = ..., app = <hs.application>, gen = n }
local gen = 0

local function rgba(hex, a)
  local h = tostring(hex or "#000000"):gsub("#", "")
  if #h < 6 then h = "000000" end
  local r, g, b = tonumber(h:sub(1, 2), 16) or 0, tonumber(h:sub(3, 4), 16) or 0, tonumber(h:sub(5, 6), 16) or 0
  return string.format("rgba(%d,%d,%d,%.3f)", r, g, b, a)
end

local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function deleteView()
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
end

local function dismiss(refocus)
  gen = gen + 1
  local app = current and current.app
  current = nil
  deleteView()
  if refocus and app then pcall(function() app:activate() end) end
end

function M.close() dismiss(true) end

local function page(list)
  local ok, data = pcall(hs.json.encode, list)
  if not ok or type(data) ~= "string" then data = "[]" end
  data = data:gsub("<", "\\u003c")
  local bg, fg, accent = theme.hex("background"), theme.hex("foreground"), theme.hex("accent")
  local font = esc(theme.font or "JetBrainsMono Nerd Font")
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%;background:transparent;overflow:hidden;-webkit-user-select:none;cursor:default}
  body{background:]] .. rgba(bg, 0.5) .. [[;display:flex;align-items:center;justify-content:center;
    font-family:"]] .. font .. [[","JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace;color:]] .. fg .. [[}
  #card{width:min(400px,calc(100vw - 10px));height:min(500px,calc(100vh - 10px));background:]] .. bg .. [[;
    border:2px solid ]] .. fg .. [[;padding:18px;display:flex;flex-direction:column;gap:6px}
  #head{height:34px;display:flex;align-items:center;flex:none}
  #q{width:100%;background:transparent;border:0;outline:0;color:]] .. fg .. [[;font:inherit;font-size:16px;caret-color:]] .. accent .. [[}
  #q::placeholder{color:]] .. fg .. [[;opacity:.58}
  #wrap{position:relative;flex:1;min-height:0}
  #grid{position:absolute;inset:0;overflow-y:auto;display:grid;grid-template-columns:repeat(auto-fill,44px);
    grid-auto-rows:44px;align-content:start}
  #grid::-webkit-scrollbar{width:0}
  .c{width:44px;height:44px;display:flex;align-items:center;justify-content:center;font-size:24px;
    font-family:"Apple Color Emoji","]] .. font .. [[",sans-serif;line-height:1}
  .c.sel{background:]] .. rgba(fg, 0.08) .. [[}
  #none{position:absolute;inset:0;display:none;flex-direction:column;align-items:center;justify-content:center;gap:8px;padding:0 18px}
  #none .g{font-size:28px;color:]] .. accent .. [[;opacity:.8}
  #none .t{font-size:14px;opacity:.7;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
  </style></head><body><div id="card"><div id="head"><input id="q" placeholder="Search emojis…" autofocus spellcheck="false" autocomplete="off"></div>
  <div id="wrap"><div id="grid"></div><div id="none"><div class="g">󰈉</div><div class="t" id="nt"></div></div></div></div>
  <script>
  const DATA=]] .. data .. [[;
  const send=(m)=>window.webkit.messageHandlers.omarchy_emojis.postMessage(m);
  const q=document.getElementById('q'),grid=document.getElementById('grid'),none=document.getElementById('none'),nt=document.getElementById('nt'),card=document.getElementById('card');
  let shown=[],sel=0,active=true;
  function cols(){return Math.max(1,Math.floor(grid.clientWidth/44))}
  function rows(){return Math.max(1,Math.floor(grid.clientHeight/44))}
  function draw(){grid.querySelectorAll('.c.sel').forEach(c=>c.classList.remove('sel'));
    if(!shown.length||!active)return;const el=grid.children[sel];if(el){el.classList.add('sel');el.scrollIntoView({block:'nearest'})}}
  function rebuild(){const n=q.value.trim().toLowerCase();shown=[];
    for(let i=0;i<DATA.length&&shown.length<1000;i++){if(!n||DATA[i].k.indexOf(n)>=0)shown.push(i)}
    const f=document.createDocumentFragment();
    shown.forEach((di,pos)=>{const c=document.createElement('div');c.className='c';c.textContent=DATA[di].e;c.dataset.p=pos;f.appendChild(c)});
    grid.replaceChildren(f);none.style.display=shown.length?'none':'flex';
    nt.textContent='No matches for “'+q.value+'”';
    sel=Math.min(Math.max(0,sel),Math.max(0,shown.length-1));active=shown.length>0;draw()}
  function pick(pos,copy){if(pos<0||pos>=shown.length)return;send({pick:shown[pos]+1,copy:!!copy})}
  function step(d){if(!shown.length)return;if(!active){active=true;sel=d<0?shown.length-1:0}else{sel=(sel+d+shown.length)%shown.length}draw()}
  function jump(d){if(!shown.length)return;if(!active){active=true;sel=d<0?shown.length-1:0}else{sel=Math.min(shown.length-1,Math.max(0,sel+d))}draw()}
  q.addEventListener('input',()=>{sel=0;active=true;rebuild()});
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();if(q.value){q.value='';sel=0;rebuild()}else send({close:true})}
    else if(e.key==='u'&&e.ctrlKey){e.preventDefault();q.value='';sel=0;rebuild()}
    else if(e.key==='ArrowLeft'){e.preventDefault();step(-1)}
    else if(e.key==='ArrowRight'){e.preventDefault();step(1)}
    else if(e.key==='ArrowUp'){e.preventDefault();jump(-cols())}
    else if(e.key==='ArrowDown'){e.preventDefault();jump(cols())}
    else if(e.key==='PageUp'){e.preventDefault();jump(-cols()*rows())}
    else if(e.key==='PageDown'){e.preventDefault();jump(cols()*rows())}
    else if(e.key==='Enter'){e.preventDefault();if(active)pick(sel,e.shiftKey);else if(shown.length){active=true;draw()}}
  });
  grid.addEventListener('mousemove',e=>{const c=e.target.closest('.c');if(c){const p=+c.dataset.p;if(p!==sel||!active){sel=p;active=true;draw()}}});
  grid.addEventListener('click',e=>{const c=e.target.closest('.c');if(c)pick(+c.dataset.p,e.shiftKey)});
  document.body.addEventListener('mousedown',e=>{if(!card.contains(e.target)){e.preventDefault();send({close:true})}});
  card.addEventListener('mousedown',e=>{if(e.target!==q)e.preventDefault()});
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({blur:true})},150));
  rebuild();setTimeout(()=>q.focus(),30);
  </script></body></html>]]
end

local function onMessage(msg)
  local body = msg and msg.body
  if type(body) ~= "table" then return end
  local cur = current
  if body.close == true then
    dismiss(true)
  elseif body.blur == true then
    dismiss(false)
  elseif body.pick ~= nil and cur then
    local i = tonumber(body.pick)
    if not i or i ~= math.floor(i) or i < 1 or i > #cur.list then return end
    local emoji = cur.list[i].e
    local app = cur.app
    local copy = body.copy == true
    dismiss(false)
    insert(emoji, app, copy)
  end
end

function M.open()
  dismiss(false)
  gen = gen + 1
  local list, fallback = loadList()
  if fallback then toast.warn("Emoji list not found: run omarchy-port sync. Showing a small built-in set.") end
  local front = hs.application.frontmostApplication()
  local app = nil
  if front and front:bundleID() ~= HAMMERSPOON then app = front end
  current = { list = list, app = app, gen = gen }
  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy_emojis")
    ucc:setCallback(function(msg)
      local ok, err = pcall(onMessage, msg)
      if not ok then log.e("emojis: message handler failed: %s", tostring(err)) end
    end)
  end
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local ok, err = pcall(function()
    view = hs.webview.new(screen:fullFrame(), { developerExtrasEnabled = false }, ucc)
      :windowStyle({ "borderless" })
      :transparent(true)
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.modalPanel)
      :shadow(false)
      :closeOnEscape(false)
      :deleteOnClose(true)
      :html(page(list))
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
  if not ok then
    log.e("emojis: could not open: %s", tostring(err))
    dismiss(false)
    toast.warn("Emojis could not open")
  end
end

function M.toggle()
  if view then M.close() else M.open() end
end

M.actions = {
  ["emojis.open"] = { fn = function() M.open() end, desc = "Emoji picker: search, then type the emoji into the focused app" },
  ["emojis.toggle"] = { fn = function() M.toggle() end, desc = "Toggle the emoji picker" },
  ["emojis.close"] = { fn = function() M.close() end, desc = "Close the emoji picker" },
}

function M.start()
  M.stop()
  return M
end

function M.stop()
  dismiss(false)
  ucc = nil
  cache.list, cache.mtime, cache.builtin = nil, nil, false
end

return M
