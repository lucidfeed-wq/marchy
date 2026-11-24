-- omarchy speedtest: port of the Omarchy 4.5 panel plugin `omarchy.speedtest`.
--
-- Summoning it opens Omarchy's shared gauge-cluster overlay (SpeedTestOverlay) and starts a
-- fresh run: download, then upload, each dial in Mbps, titled with the connection under test.
-- Dismissing it (Esc, the scrim, focus loss or `speedtest.close`) stops the traffic.
--
-- Omarchy runs `omarchy-network-speedtest down|up` (its own client). macOS ships
-- /usr/bin/networkQuality, Apple's capacity/responsiveness test, so each phase runs it with
-- fixed arguments and computer-readable output:
--   down: networkQuality -c -u -M 15   (no upload test, implies sequential)
--   up:   networkQuality -c -d -M 15   (no download test)
-- and reads dl_throughput / ul_throughput (bits per second) from the JSON it prints at the
-- end of the phase. A 30 s watchdog per phase stands in for Omarchy's 20 s one.
--
-- The overlay is a full-screen transparent hs.webview drawn like SpeedTestOverlay: a near-black
-- scrim, two floating 270° dials with tick rings, an accent value arc with under-glow, a
-- hubless gradient needle, the digital readout, the ignition sweep on open, one shared
-- full-scale latch (100 / 250 / 500 / 1000 / 2500 / 5000 / 10000 Mbps), the "Run Again"
-- button and the error line.
--
-- No action takes a URL argument except `speedtest.open`'s optional connection name, which
-- is only displayed (HTML-escaped, 64 chars). Nothing from `x` reaches a process.
local M = { id = "speedtest" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local NQ = "/usr/bin/networkQuality"
local VAR = "omarchy_speedtest"
local MAX_RUNTIME = "15"     -- seconds networkQuality may spend on one direction
local WATCHDOG = 30          -- seconds before a phase that never exits is stopped

-- Omarchy's en strings (speedtest.*, network.ethernet).
local T = {
  download = "DOWNLOAD",
  upload = "UPLOAD",
  failed = "Speed test failed",
  runAgain = "Run Again",
  measureAgainVia = "Measure again via %1",
  ethernet = "Ethernet",
}

---------------------------------------------------------------- state (mirrors Panel.qml)
local S = {
  opened = false, running = false, expectedStop = false, pendingRun = false,
  phase = "", connectionName = "", downloadMbps = 0, uploadMbps = 0, error = "",
}
local task, watchdog
local view, ucc
local lastPush

local function publish()
  local text = hs.json.encode({
    v = 1, open = S.opened, running = S.running, phase = S.phase,
    download = (S.downloadMbps > 0) and S.downloadMbps or nil,
    upload = (S.uploadMbps > 0) and S.uploadMbps or nil,
    error = S.error ~= "" and S.error or nil,
  })
  if not text or text == lastPush then return end
  lastPush = text
  if not hs.fs.attributes(CTL) then return end
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("speedtest: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

local function viewState()
  return {
    title = S.connectionName,
    running = S.running,
    left = S.downloadMbps,
    right = S.uploadMbps,
    leftLive = S.running and S.phase == "down",
    rightLive = S.running and S.phase == "up",
    error = S.error,
  }
end

local function render()
  publish()
  if not view then return end
  local js = "window.omarchyUpdate && window.omarchyUpdate(" .. hs.json.encode(viewState()) .. ")"
  pcall(function() view:evaluateJavaScript(js) end)
end

---------------------------------------------------------------- connection name
-- Omarchy: omarchy-network-status -> "wifi\t<ssid>" or "ethernet\t<dev>". Here: the primary
-- interface; an SSID when macOS lets Hammerspoon read it (Location permission), else "Wi-Fi".
local function refreshConnectionName()
  local name = ""
  pcall(function()
    local v4 = hs.network.primaryInterfaces()
    local iface = type(v4) == "string" and v4 or nil
    if not iface then return end
    local wifiDetails = hs.wifi.interfaceDetails(iface)
    if wifiDetails then
      name = hs.wifi.currentNetwork(iface) or "Wi-Fi"
    elseif iface:match("^en%d+$") then
      name = T.ethernet
    end
  end)
  S.connectionName = name
end

---------------------------------------------------------------- the measurement
local runSpeedTest, startPhase, finishPhase

local function stopWatchdog()
  if watchdog then watchdog:stop() watchdog = nil end
end

local function toMbps(bits)
  local v = tonumber(bits)
  if v and v == v and v > 0 and v < math.huge then return v / 1000000 end
  return 0
end

-- networkQuality -c prints one JSON object; error runs carry error_code / error_domain.
local function readResult(phase, out)
  local ok, obj = pcall(hs.json.decode, out or "")
  if not ok or type(obj) ~= "table" then return nil, nil end
  local field = phase == "down" and obj.dl_throughput or obj.ul_throughput
  local mbps = toMbps(field)
  local errText = nil
  if obj.error_code ~= nil or obj.error_domain ~= nil then
    errText = "networkQuality: " .. tostring(obj.error_domain or "error") .. " " .. tostring(obj.error_code or "")
  end
  return mbps, errText
end

local function stopPhase()
  stopWatchdog()
  S.error = T.failed
  S.phase = ""
  S.running = false
  if task then
    S.expectedStop = true
    pcall(function() task:terminate() end)
  else
    finishPhase()
  end
  render()
end

finishPhase = function()
  if S.phase == "down" then
    startPhase("up")
    return
  end
  S.phase = ""
  S.running = false
  S.expectedStop = false
  render()
end

local function onExited(phase, code, out, err)
  task = nil
  stopWatchdog()
  if S.pendingRun then
    S.pendingRun = false
    S.expectedStop = false
    if S.opened then hs.timer.doAfter(0, function() runSpeedTest() end) end
    return
  end
  if S.expectedStop then
    S.expectedStop = false
    render()
    return
  end
  local mbps, errText = readResult(phase, out)
  if code ~= 0 or not mbps or mbps <= 0 then
    local stderrText = tostring(err or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 200)
    S.error = errText or (stderrText ~= "" and stderrText) or T.failed
    S.phase = ""
    S.running = false
    log.w("speedtest: %s phase failed (exit %s): %s", phase, tostring(code), S.error)
    render()
    return
  end
  if phase == "down" then S.downloadMbps = mbps else S.uploadMbps = mbps end
  render()
  finishPhase()
end

startPhase = function(nextPhase)
  S.expectedStop = false
  S.phase = nextPhase
  if not hs.fs.attributes(NQ) then
    S.error = "/usr/bin/networkQuality is missing (macOS 12 or later is needed)"
    S.phase, S.running = "", false
    return render()
  end
  local args = nextPhase == "down" and { "-c", "-u", "-M", MAX_RUNTIME } or { "-c", "-d", "-M", MAX_RUNTIME }
  task = hs.task.new(NQ, function(code, out, err) onExited(nextPhase, code, out, err) end, args)
  if not task:start() then
    task = nil
    S.error = T.failed
    S.phase, S.running = "", false
    log.e("speedtest: could not start networkQuality")
    return render()
  end
  stopWatchdog()
  watchdog = hs.timer.doAfter(WATCHDOG, function() watchdog = nil stopPhase() end)
  render()
end

runSpeedTest = function()
  if task then
    -- A dismissal's SIGTERM is still in flight: queue the fresh run for the exit.
    if S.expectedStop then S.pendingRun = true end
    return
  end
  S.error = ""
  S.downloadMbps, S.uploadMbps = 0, 0
  S.running = true
  render()
  startPhase("down")
end

---------------------------------------------------------------- overlay
local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function page()
  local accent = theme.hex("accent")
  if type(accent) ~= "string" or not (accent:match("^#%x%x%x%x%x%x$") or accent:match("^#%x%x%x%x%x%x%x%x$")) then
    accent = "#7aa2f7"
  end
  local tip = (T.measureAgainVia:gsub("%%1", "networkQuality"))
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{background:transparent;height:100%;overflow:hidden;color:#fff;
    font-family:"JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace;user-select:none;-webkit-user-select:none}
  #scrim{position:fixed;inset:0;background:rgba(0,0,0,.78);display:flex;align-items:center;justify-content:center}
  #cluster{display:flex;flex-direction:column;align-items:center;gap:16px;transform-origin:center}
  #title{font-size:10px;font-weight:700;letter-spacing:2px;color:rgba(255,255,255,.55);text-transform:uppercase;min-height:0}
  #title:empty{display:none}
  #dials{display:flex;gap:48px}
  .dial{position:relative;width:210px;height:210px;transition:opacity .24s cubic-bezier(.33,1,.68,1)}
  .dial svg{position:absolute;inset:0;overflow:visible}
  .read{position:absolute;left:0;right:0;top:119px;text-align:center}
  .num{font-size:24px;font-weight:700;color:#fff;line-height:1.15}
  .unit{font-size:10px;color:rgba(255,255,255,.55)}
  .lbl{position:absolute;left:0;right:0;bottom:0;text-align:center;font-size:10px;font-weight:700;
    letter-spacing:1.5px;color:rgba(255,255,255,.55)}
  #again{position:relative;background:transparent;color:#fff;border:1px solid rgba(255,255,255,.55);
    font:inherit;font-size:11px;padding:4px 14px;cursor:pointer;transition:opacity .24s cubic-bezier(.33,1,.68,1)}
  #again:hover{border-color:#fff;background:rgba(255,255,255,.08)}
  #again[disabled]{opacity:0;pointer-events:none}
  #again .tip{position:absolute;bottom:calc(100% + 8px);left:50%;transform:translateX(-50%);white-space:nowrap;
    font-size:11px;background:rgba(0,0,0,.9);border:1px solid rgba(255,255,255,.25);padding:3px 8px;display:none}
  #again:hover .tip{display:block}
  #err{color:#ff6b6b;font-size:11px;max-width:440px;text-align:center;word-wrap:break-word}
  #err:empty{display:none}
  </style></head><body>
  <div id="scrim"><div id="cluster">
    <div id="title"></div>
    <div id="dials"><div class="dial" id="d0"></div><div class="dial" id="d1"></div></div>
    <button id="again" disabled>]] .. esc(T.runAgain) .. [[<span class="tip">]] .. esc(tip) .. [[</span></button>
    <div id="err"></div>
  </div></div>
  <script>
  const send=(m)=>window.webkit.messageHandlers.omarchy_speedtest.postMessage(m);
  const ACC=']] .. accent .. [[';
  const STOPS=[100,250,500,1000,2500,5000,10000];
  const D=210,AW=4,R=D/2-AW,START=135,SWEEP=270,TICKS=46;
  let fullScale=STOPS[0],shownScale=STOPS[0],running=false;
  const rad=a=>a*Math.PI/180;
  function pt(a,r){return [D/2+r*Math.cos(rad(a)),D/2+r*Math.sin(rad(a))]}
  function arc(a0,sweep,r){
    if(sweep<=0.01)return '';
    const [x0,y0]=pt(a0,r),[x1,y1]=pt(a0+sweep,r);
    return 'M'+x0.toFixed(2)+' '+y0.toFixed(2)+' A'+r+' '+r+' 0 '+(sweep>180?1:0)+' 1 '+x1.toFixed(2)+' '+y1.toFixed(2);
  }
  function ticks(){
    let s='';
    for(let i=0;i<TICKS;i++){
      const major=i%5===0,a=START+i/(TICKS-1)*SWEEP,off=major?0:2;
      const [ax,ay]=pt(a,R-AW-off),[bx,by]=pt(a,R-AW-off-(major?10:6));
      s+='<line x1="'+ax.toFixed(2)+'" y1="'+ay.toFixed(2)+'" x2="'+bx.toFixed(2)+'" y2="'+by.toFixed(2)+'" stroke="rgba(255,255,255,'+(major?0.3:0.12)+')" stroke-width="'+(major?2:1)+'" stroke-linecap="round"/>';
    }
    return s;
  }
  function build(el,label){
    el.innerHTML='<svg viewBox="0 0 '+D+' '+D+'" width="'+D+'" height="'+D+'">'+
      '<defs><linearGradient id="g'+el.id+'" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="1">'+
      '<stop offset="0" stop-color="'+ACC+'"/><stop offset="0.55" stop-color="'+ACC+'"/>'+
      '<stop offset="1" stop-color="'+ACC+'" stop-opacity="0"/></linearGradient></defs>'+
      '<path class="track" d="'+arc(START,SWEEP,R)+'" fill="none" stroke="rgba(255,255,255,.14)" stroke-width="'+AW+'" stroke-linecap="round"/>'+
      '<path class="glow" fill="none" stroke="'+ACC+'" stroke-opacity=".18" stroke-width="'+(AW*3)+'" stroke-linecap="round"/>'+
      '<path class="val" fill="none" stroke="'+ACC+'" stroke-width="'+AW+'" stroke-linecap="round"/>'+
      ticks()+
      '<g class="needle"><rect x="'+(D/2-1.5)+'" y="'+(AW*2+10)+'" width="3" height="'+(D*0.32)+'" rx="1.5" fill="url(#g'+el.id+')"/></g>'+
      '</svg><div class="read"><div class="num">0.0</div><div class="unit">Mbps</div></div><div class="lbl">'+label+'</div>';
    const svg=el.querySelector('svg'),grad=svg.querySelector('linearGradient');
    grad.setAttribute('y1',String(AW*2+10));grad.setAttribute('y2',String(AW*2+10+D*0.32));
    return {el,glow:el.querySelector('.glow'),val:el.querySelector('.val'),needle:el.querySelector('.needle'),
      num:el.querySelector('.num'),value:0,shown:0,from:0,t0:0,dur:600,live:false,ign:null};
  }
  const dials=[build(document.getElementById('d0'),']] .. esc(T.download) .. [['),
               build(document.getElementById('d1'),']] .. esc(T.upload) .. [[')];
  const easeOutCubic=t=>1-Math.pow(1-t,3),easeInOutCubic=t=>t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;
  function fmt(v){return v<10?v.toFixed(1):String(Math.round(v))}
  function expand(v){
    for(const s of STOPS){if(v<=s*0.92){if(s>fullScale)fullScale=s;return}}
    fullScale=STOPS[STOPS.length-1];
  }
  function ignite(d){d.ign={t0:performance.now()}}
  function glide(d,to){d.from=d.shown;d.value=to;d.t0=performance.now()}
  let scaleFrom=fullScale,scaleT0=0,lastScale=fullScale;
  function frame(now){
    if(fullScale!==lastScale){scaleFrom=shownScale;scaleT0=now;lastScale=fullScale}
    const st=Math.min(1,(now-scaleT0)/400);shownScale=scaleFrom+(fullScale-scaleFrom)*easeOutCubic(st);
    for(const d of dials){
      let reading;
      if(d.ign){
        const t=now-d.ign.t0;
        if(t<550)d.shown=shownScale*easeInOutCubic(t/550);
        else if(t<1200)d.shown=shownScale*(1-easeOutCubic((t-550)/650));
        else{d.ign=null;d.shown=d.value;d.from=d.value}
        reading=d.value;
      }else{
        const t=Math.min(1,(now-d.t0)/d.dur);d.shown=d.from+(d.value-d.from)*easeOutCubic(t);reading=d.shown;
      }
      const f=shownScale>0?Math.max(0,Math.min(1,d.shown/shownScale)):0;
      const p=f>0.004?arc(START,SWEEP*f,R):'';
      d.val.setAttribute('d',p);d.glow.setAttribute('d',p);
      d.needle.setAttribute('transform','rotate('+(START+f*SWEEP-270)+' '+D/2+' '+D/2+')');
      d.num.textContent=fmt(reading);
      d.el.style.opacity=(d.live||d.value>0)?'1':'0.5';
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  function fit(){
    const c=document.getElementById('cluster');c.style.transform='none';
    const s=Math.min(1,(innerWidth-32)/Math.max(1,c.offsetWidth),(innerHeight-32)/Math.max(1,c.offsetHeight));
    c.style.transform='scale('+s+')';
  }
  window.addEventListener('resize',fit);
  window.omarchyUpdate=function(s){
    document.getElementById('title').textContent=String(s.title||'').toUpperCase();
    if(s.running&&!running){fullScale=STOPS[0]}
    running=!!s.running;
    const vals=[Number(s.left)||0,Number(s.right)||0],live=[!!s.leftLive,!!s.rightLive];
    dials.forEach((d,i)=>{d.live=live[i];if(vals[i]!==d.value){expand(vals[i]);glide(d,vals[i])}});
    document.getElementById('again').disabled=running;
    document.getElementById('err').textContent=String(s.error||'');
    fit();
  };
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();send({close:true})}
    else if(e.key==='Enter'&&!running){e.preventDefault();send({again:true})}
  });
  document.getElementById('scrim').addEventListener('mousedown',e=>{if(e.target.id==='scrim')send({close:true})});
  document.getElementById('again').addEventListener('click',e=>{e.stopPropagation();if(!running)send({again:true})});
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({close:true})},150));
  window.omarchyUpdate(]] .. hs.json.encode(viewState()) .. [[);
  dials.forEach(ignite);
  send({ready:true});
  </script></body></html>]]
end

local function destroyView()
  if view then
    local v = view
    view = nil
    pcall(function() v:delete() end)
  end
end

-- Mirrors Panel.qml close(): clear the phase before killing the process.
function M.close()
  S.opened = false
  S.pendingRun = false
  stopWatchdog()
  S.phase = ""
  S.running = false
  if task then
    S.expectedStop = true
    pcall(function() task:terminate() end)
  end
  destroyView()
  publish()
end

local function showView()
  if view then
    pcall(function() view:bringToFront(true) local w = view:hswindow() if w then w:focus() end end)
    return true
  end
  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy_speedtest")
    ucc:setCallback(function(msg)
      local body = type(msg) == "table" and type(msg.body) == "table" and msg.body or {}
      if body.close == true then
        hs.timer.doAfter(0, M.close)
      elseif body.again == true then
        if S.opened and not S.running then hs.timer.doAfter(0, runSpeedTest) end
      elseif body.ready == true then
        render()
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
    log.e("speedtest: could not open the overlay: %s", tostring(err))
    destroyView()
    toast.warn(T.failed)
    return false
  end
  return true
end

-- x (optional) = the connection's display name, like the plugin's {"connection": "..."}.
function M.open(x)
  if type(x) == "string" and x ~= "" then
    S.connectionName = x:gsub("[%c]", " "):sub(1, 64)
  else
    refreshConnectionName()
  end
  S.opened = true
  if not showView() then
    S.opened = false
    return
  end
  runSpeedTest()
end

M.actions = {
  ["speedtest.open"] = { fn = function(x) M.open(x) end,
    desc = "Internet speed test: open the dials and measure (x = optional connection name)" },
  ["speedtest.toggle"] = { fn = function() if S.opened then M.close() else M.open(nil) end end,
    desc = "Internet speed test: open or dismiss" },
  ["speedtest.close"] = { fn = function() if S.opened then M.close() end end,
    desc = "Internet speed test: dismiss (stops the traffic)" },
  ["speedtest.run"] = { fn = function()
    if not S.opened then return M.open(nil) end
    if not S.running then runSpeedTest() end
  end, desc = "Internet speed test: run again" },
}

function M.start()
  publish()
end

function M.stop()
  S.pendingRun = false
  stopWatchdog()
  if task then
    S.expectedStop = true
    pcall(function() task:terminate() end)
    task = nil
  end
  destroyView()
  S.opened, S.running, S.phase = false, false, ""
end

return M
