-- omarchy.picker: Omarchy-style image grid picker (theme picker, background picker).
-- A borderless, themed hs.webview with large preview tiles: type to filter, arrows to move,
-- Return to pick, Escape (or clicking away) to close.
--
--   require("omarchy.picker").show{
--     title = "Theme",
--     items = { { id = "tokyo-night", label = "Tokyo Night", image = "/path/preview.png", checked = true }, ... },
--     onPick = function(id) ... end,
--   }
--
-- Images are shrunk once into ~/.cache/omarchy-mac/thumbs (sips) and embedded as data URIs,
-- so the page never needs file:// access.
local M = {}

local log = require("omarchy.log")
local theme = require("omarchy.theme")

local THUMBS = os.getenv("HOME") .. "/.cache/omarchy-mac/thumbs"
local view, ucc, current

local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- Cached JPEG thumbnail for an image path (created with sips on first use).
local function thumb(path)
  if not path or not hs.fs.attributes(path) then return nil end
  hs.fs.mkdir(os.getenv("HOME") .. "/.cache/omarchy-mac")
  hs.fs.mkdir(THUMBS)
  local key = path:gsub("^.*/themes/", ""):gsub("[^%w]", "_")
  local out = THUMBS .. "/" .. key .. ".jpg"
  local src, dst = hs.fs.attributes(path), hs.fs.attributes(out)
  if not dst or (src and dst.modification < src.modification) then
    hs.execute(string.format("/usr/bin/sips -s format jpeg -s formatOptions 80 -Z 520 %q --out %q >/dev/null 2>&1", path, out))
  end
  local fh = io.open(out, "rb")
  if not fh then return nil end
  local data = fh:read("a")
  fh:close()
  return "data:image/jpeg;base64," .. hs.base64.encode(data)
end

function M.close()
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
  current = nil
end

local function page(opts)
  local c = function(n) return theme.hex(n) end
  local tiles = {}
  for i, it in ipairs(opts.items) do
    local img = it.data or thumb(it.image)
    tiles[#tiles + 1] = string.format(
      '<div class="t%s" data-i="%d" data-k="%s"><div class="img">%s</div><div class="lbl">%s%s</div></div>',
      it.checked and " cur" or "", i, esc((it.label or "") .. " " .. (it.id or "")):lower(),
      img and ('<img src="' .. img .. '">') or '<span class="none">no preview</span>',
      esc(it.label or it.id), it.checked and ' <span class="chk">●</span>' or "")
  end
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{background:]] .. c("background") .. [[;color:]] .. c("foreground") .. [[;
    font-family:"JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace;overflow:hidden;height:100%}
  body{border:2px solid ]] .. c("accent") .. [[;display:flex;flex-direction:column}
  header{display:flex;align-items:center;gap:14px;padding:14px 18px 10px}
  h1{font-size:13px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;color:]] .. c("dark_foreground") .. [[}
  input{flex:1;background:transparent;border:0;outline:0;color:]] .. c("bright_foreground") .. [[;font:inherit;font-size:15px}
  input::placeholder{color:]] .. c("dark_foreground") .. [[}
  #grid{flex:1;overflow-y:auto;display:grid;grid-template-columns:repeat(4,1fr);gap:14px;padding:6px 18px 18px}
  .t{cursor:pointer;border:2px solid transparent;padding:6px}
  .t .img{aspect-ratio:16/10;overflow:hidden;background:]] .. c("selection") .. [[;display:flex;align-items:center;justify-content:center}
  .t img{width:100%;height:100%;object-fit:cover;display:block}
  .none{font-size:12px;color:]] .. c("dark_foreground") .. [[}
  .lbl{font-size:13px;padding:7px 2px 1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .chk{color:]] .. c("accent") .. [[}
  .t.sel{border-color:]] .. c("accent") .. [[;background:]] .. c("selection") .. [[}
  .t.hide{display:none}
  footer{padding:8px 18px 12px;font-size:11px;color:]] .. c("dark_foreground") .. [[}
  </style></head><body>
  <header><h1>]] .. esc(opts.title or "Pick") .. [[</h1><input id="q" placeholder="type to filter" autofocus></header>
  <div id="grid">]] .. table.concat(tiles) .. [[</div>
  <footer>↑ ↓ ← → move · Return choose · Esc close</footer>
  <script>
  const send=(m)=>window.webkit.messageHandlers.omarchy.postMessage(m);
  const q=document.getElementById('q'), grid=document.getElementById('grid');
  const all=[...grid.querySelectorAll('.t')]; let sel=Math.max(0,all.findIndex(t=>t.classList.contains('cur')));
  const vis=()=>all.filter(t=>!t.classList.contains('hide'));
  function cols(){const v=vis();if(v.length<2)return 1;const top=v[0].offsetTop;let n=0;for(const t of v){if(t.offsetTop!==top)break;n++}return n}
  function draw(){all.forEach(t=>t.classList.remove('sel'));const v=vis();if(!v.length)return;
    if(!v.includes(all[sel]))sel=all.indexOf(v[0]);all[sel].classList.add('sel');all[sel].scrollIntoView({block:'nearest'})}
  function move(d){const v=vis();if(!v.length)return;let i=v.indexOf(all[sel]);i=Math.min(v.length-1,Math.max(0,i+d));sel=all.indexOf(v[i]);draw()}
  q.addEventListener('input',()=>{const w=q.value.toLowerCase().split(/\s+/).filter(Boolean);
    all.forEach(t=>t.classList.toggle('hide',!w.every(x=>t.dataset.k.includes(x))));draw()});
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();send({close:true})}
    else if(e.key==='Enter'){e.preventDefault();if(vis().includes(all[sel]))send({pick:+all[sel].dataset.i})}
    else if(e.key==='ArrowRight'){e.preventDefault();move(1)}
    else if(e.key==='ArrowLeft'){e.preventDefault();move(-1)}
    else if(e.key==='ArrowDown'){e.preventDefault();move(cols())}
    else if(e.key==='ArrowUp'){e.preventDefault();move(-cols())}});
  all.forEach(t=>t.addEventListener('click',()=>send({pick:+t.dataset.i})));
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({close:true})},150));
  draw();setTimeout(()=>q.focus(),30);
  </script></body></html>]]
end

function M.show(opts)
  M.close()
  current = opts
  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy")
    ucc:setCallback(function(msg)
      local body = msg and msg.body or {}
      local o = current
      if body.pick and o and o.items[body.pick] then
        local id = o.items[body.pick].id
        M.close()
        hs.timer.doAfter(0.05, function()
          local ok, err = pcall(o.onPick, id)
          if not ok then log.e("picker: onPick failed: %s", tostring(err)) end
        end)
      elseif body.close then
        M.close()
      end
    end)
  end
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local w = math.min(1180, sf.w - 120)
  local h = math.min(760, sf.h - 120)
  local frame = { x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2.4, w = w, h = h }
  local ok, err = pcall(function()
    view = hs.webview.new(frame, { developerExtrasEnabled = false }, ucc)
      :windowStyle({ "borderless" })
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.modalPanel)
      :shadow(true)
      :closeOnEscape(false)
      :deleteOnClose(true)
      :html(page(opts))
    view:show()
    view:bringToFront(true)
    local win = view:hswindow()
    if win then win:focus() end
  end)
  if not ok then
    log.e("picker: could not open: %s", tostring(err))
    M.close()
  end
end

---------------------------------------------------------------- the two Omarchy pickers
function M.themes()
  local items = {}
  for _, name in ipairs(theme.list()) do
    local dir = require("omarchy.util").THEMES .. "/" .. name
    local preview = dir .. "/preview.png"
    if not hs.fs.attributes(preview) then
      -- fall back to the theme's first background
      for f in hs.fs.dir(dir .. "/backgrounds") or function() end do
        if f:match("%.%a+$") and not f:match("^%.") then preview = dir .. "/backgrounds/" .. f break end
      end
    end
    items[#items + 1] = { id = name, label = theme.pretty(name), image = preview, checked = name == theme.name }
  end
  M.show{ title = "Theme", items = items, onPick = function(id) theme.set(id) end }
end

function M.backgrounds()
  local u = require("omarchy.util")
  local out = hs.execute(string.format("%q bg-list --json 2>/dev/null", u.bin("omarchy-theme")))
  local ok, list = pcall(hs.json.decode, out or "")
  if not ok or type(list) ~= "table" or #list == 0 then
    return require("omarchy.toast").warn("No backgrounds for this theme")
  end
  local items = {}
  for _, b in ipairs(list) do
    local name = (b.path or ""):match("([^/]+)%.%a+$") or tostring(b.index)
    name = name:gsub("^%d+%-", ""):gsub("[-_]", " ")
    items[#items + 1] = { id = tostring(b.index), label = name, image = b.path, checked = b.current }
  end
  M.show{ title = "Background · " .. theme.pretty(theme.name), items = items, onPick = function(id)
    u.run(u.bin("omarchy-theme"), { "bg-set", id }, function(code, _, err)
      if code ~= 0 then require("omarchy.toast").warn("Background failed: " .. u.trim(err):sub(1, 120)) end
    end)
  end }
end

return M
