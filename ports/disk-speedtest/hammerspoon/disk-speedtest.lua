-- omarchy disk-speedtest: port of the Omarchy 4.5 panel plugin `omarchy.disk-speedtest`.
--
-- A full-screen gauge-cluster overlay (borderless, transparent hs.webview over a dimmed
-- scrim) with two dials, Read and Write, in MB/s, titled with the model of the disk under
-- test. One run streams both phases (read, then write) once a second and settles each dial on
-- the phase's steady-state average; dismissing the overlay (Esc, clicking the scrim, focus
-- loss, or `disk-speedtest.close`) stops the run and removes its scratch file.
--
-- The Linux plugin runs `omarchy-disk-speedtest`. That script does not exist on macOS, so the
-- measurement is a fixed Perl program (/usr/bin/perl ships with macOS) that writes a scratch
-- file in the user's temp folder with F_NOCACHE (bypasses the unified buffer cache, so reads
-- really hit the SSD) and F_FULLFSYNC (writes really reach the media). It prints the same
-- line protocol as omarchy-disk-speedtest: "read <MB/s>" ... "write <MB/s>".
-- The disk model comes from `diskutil info` (physical store of the boot volume).
--
-- No URL argument is used by any action; nothing user-supplied reaches a process.
local M = { id = "disk-speedtest" }

local log = require("omarchy.log")
local toast = require("omarchy.toast")
local theme = require("omarchy.theme")

local CTL = "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
local PERL = "/usr/bin/perl"
local DISKUTIL = "/usr/sbin/diskutil"
local VAR = "omarchy_disk-speedtest"

local FILE_MIB = 1024        -- scratch file size (prepared before the read phase)
local PHASE_SECONDS = 6      -- each phase streams for this long ...
local WRITE_CAP_MIB = 8192   -- ... and the write phase stops early after this much data

-- I18n strings used by the plugin (en).
local T = {
  read = "Read",
  write = "Write",
  failed = "Disk speed test failed",
  measureAgain = "Measure again",
}

-- Measurement program. Args: path, file MiB, seconds per phase, write cap MiB.
-- stdout: "read <MB/s>" once a second then the phase average, same for "write".
-- stderr: one human-readable line on failure (exit 1). Removes the file on exit or SIGTERM.
local BENCH = [=[
use strict; use warnings; use Fcntl; use Time::HiRes qw(time);
$| = 1;
my ($path, $fileMiB, $secs, $capMiB) = @ARGV;
my $MB = 1000000; my $BS = 8 * 1048576; my $total = $fileMiB * 1048576;
my $cap = $capMiB * 1048576;
my $F_NOCACHE = 48; my $F_FULLFSYNC = 51;
my $fh;
sub cleanup { if ($fh) { close($fh); undef $fh; } unlink($path); }
sub fail { my $m = shift; cleanup(); print STDERR "$m\n"; exit 1; }
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { cleanup(); exit 143; };
my $chunk = pack('L*', map { int(rand(4294967296)) } 1 .. 16384);
my $buf = $chunk x ($BS / length($chunk));
sysopen($fh, $path, O_RDWR | O_CREAT | O_EXCL, 0600) or fail("Could not create the test file: $!");
fcntl($fh, $F_NOCACHE, 1);
my $w = 0;
while ($w < $total) {
  my $n = syswrite($fh, $buf, $BS);
  fail($!{ENOSPC} ? "Not enough free disk space for the test" : "Write failed: $!") unless defined $n;
  $w += $n;
}
fcntl($fh, $F_FULLFSYNC, 0);
sub phase {
  my ($name, $isWrite) = @_;
  my $t0 = time; my $last = $t0; my $done = 0; my $since = 0; my $pos = 0; my $data;
  sysseek($fh, 0, 0) or fail("Seek failed: $!");
  while (1) {
    if ($pos >= $total) { sysseek($fh, 0, 0) or fail("Seek failed: $!"); $pos = 0; }
    my $n = $isWrite ? syswrite($fh, $buf, $BS) : sysread($fh, $data, $BS);
    fail(($isWrite ? "Write" : "Read") . " failed: $!") unless defined $n;
    fail("Unexpected end of the test file") if $n == 0;
    $pos += $n; $done += $n; $since += $n;
    my $now = time;
    if ($now - $last >= 1) {
      printf("%s %.1f\n", $name, $since / $MB / ($now - $last));
      $last = $now; $since = 0;
    }
    last if ($now - $t0 >= $secs) || ($isWrite && $done >= $cap);
  }
  fcntl($fh, $F_FULLFSYNC, 0) if $isWrite;
  my $el = time - $t0; $el = 0.001 if $el <= 0;
  printf("%s %.1f\n", $name, $done / $MB / $el);
}
phase("read", 0);
phase("write", 1);
cleanup();
exit 0;
]=]

---------------------------------------------------------------- state (mirrors Panel.qml)
local S = {
  opened = false, running = false, expectedStop = false, pendingRun = false,
  phase = "", diskName = "", writeMBps = "", readMBps = "", error = "", stderrText = "",
}
local task, diskTask, scratch, exitedCode
local view, ucc, lineBuf = nil, nil, ""
local lastPush

local function toRate(raw)
  local v = tonumber(raw)
  if v and v == v and v > 0 and v < math.huge then return v end
  return 0
end

-- Publish a coarse summary for any bar widget / script (live per-second figures are only in
-- the overlay; the var gets each phase's settled average).
local function publish()
  local out = {
    v = 1, open = S.opened, running = S.running, phase = S.phase, disk = S.diskName,
    read = (S.phase ~= "read" or not S.running) and toRate(S.readMBps) or nil,
    write = (not S.running) and toRate(S.writeMBps) or nil,
    error = S.error ~= "" and S.error or nil,
  }
  local text = hs.json.encode(out)
  if not text or text == lastPush then return end
  lastPush = text
  if not hs.fs.attributes(CTL) then return end
  hs.task.new(CTL, function(code, _, err)
    if code ~= 0 then log.w("disk-speedtest: shell set failed: %s", tostring(err):sub(1, 160)) end
  end, { "shell", "set", VAR, text }):start()
end

local function viewState()
  return {
    title = S.diskName,
    running = S.running,
    read = toRate(S.readMBps),
    write = toRate(S.writeMBps),
    readLive = S.running and S.phase == "read",
    writeLive = S.running and S.phase == "write",
    error = S.error,
  }
end

local function render()
  publish()
  if not view then return end
  local js = "window.omarchyUpdate && window.omarchyUpdate(" .. hs.json.encode(viewState()) .. ")"
  pcall(function() view:evaluateJavaScript(js) end)
end

---------------------------------------------------------------- disk model
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function field(text, name)
  for line in (text or ""):gmatch("[^\n]+") do
    local k, v = line:match("^%s*(.-):%s*(.-)%s*$")
    if k == name then return v end
  end
  return nil
end

-- Boot volume -> APFS physical store (disk0s2) -> whole disk (disk0) -> "APPLE SSD AP0512Z".
local function lookupDisk(done)
  if not hs.fs.attributes(DISKUTIL) then return done("") end
  diskTask = hs.task.new(DISKUTIL, function(code, out)
    local store = code == 0 and (field(out, "APFS Physical Store") or field(out, "Part of Whole")) or nil
    local whole = store and store:match("^(disk%d+)")
    if not whole then
      diskTask = nil
      return done(code == 0 and (field(out, "Device / Media Name") or "") or "")
    end
    diskTask = hs.task.new(DISKUTIL, function(code2, out2)
      diskTask = nil
      done(code2 == 0 and (field(out2, "Device / Media Name") or "") or "")
    end, { "info", whole })
    if not diskTask:start() then diskTask = nil; done("") end
  end, { "info", "/" })
  if not diskTask:start() then diskTask = nil; done("") end
end

---------------------------------------------------------------- process
local runTest

local function updateLine(line)
  local parts = {}
  for p in trim(line):gmatch("%S+") do parts[#parts + 1] = p end
  if #parts < 2 then return end
  local value = tonumber(parts[2])
  if not value or value ~= value or value < 0 then return end
  if parts[1] == "write" then
    S.phase = "write"
    S.writeMBps = tostring(value)
  elseif parts[1] == "read" then
    S.phase = "read"
    S.readMBps = tostring(value)
  end
  render()
end

local function removeScratch()
  if scratch and hs.fs.attributes(scratch) then os.remove(scratch) end
  scratch = nil
end

local function onExited(code, stderr)
  task = nil
  removeScratch()
  S.stderrText = trim(stderr):sub(1, 200)
  if S.pendingRun then
    S.pendingRun = false
    S.expectedStop = false
    if S.opened then hs.timer.doAfter(0, function() runTest() end) end
    return
  end
  if not S.expectedStop and code ~= 0 then
    S.error = S.stderrText ~= "" and S.stderrText or T.failed
    S.phase = ""
    S.running = false
    log.w("disk-speedtest: run failed (exit %s): %s", tostring(code), S.error)
    render()
    return
  end
  S.expectedStop = false
  S.phase = ""
  S.running = false
  render()
end

local function startBench()
  if not S.running or task then return end
  if not hs.fs.attributes(PERL) then
    S.error = "/usr/bin/perl is missing; it is needed to run the test"
    S.running, S.phase = false, ""
    return render()
  end
  local tmp = (hs.fs.temporaryDirectory and hs.fs.temporaryDirectory()) or os.getenv("TMPDIR") or "/tmp/"
  if tmp:sub(-1) ~= "/" then tmp = tmp .. "/" end
  scratch = string.format("%somarchy-disk-speedtest-%d-%d.bin", tmp, os.time(), math.random(100000, 999999))
  lineBuf = ""
  local errText = ""
  task = hs.task.new(PERL, function(code, out, err)
    if out and out ~= "" then lineBuf = lineBuf .. out end
    for line in lineBuf:gmatch("[^\n]+") do updateLine(line) end
    lineBuf = ""
    -- Depending on the hs.task version the final callback repeats or omits streamed stderr.
    onExited(code, (err and err ~= "") and err or errText)
  end, function(_, out, err)
    if err and err ~= "" then errText = (errText .. err):sub(-400) end
    if out and out ~= "" then
      lineBuf = lineBuf .. out
      while true do
        local nl = lineBuf:find("\n", 1, true)
        if not nl then break end
        local line = lineBuf:sub(1, nl - 1)
        lineBuf = lineBuf:sub(nl + 1)
        updateLine(line)
      end
    end
    return true
  end, { "-e", BENCH, scratch, tostring(FILE_MIB), tostring(PHASE_SECONDS), tostring(WRITE_CAP_MIB) })
  if not task:start() then
    task = nil
    removeScratch()
    S.error = T.failed
    S.running, S.phase = false, ""
    log.e("disk-speedtest: could not start perl")
  end
  render()
end

runTest = function()
  if task then
    -- A dismissal's SIGTERM is still in flight: queue the fresh run for the exit.
    if S.expectedStop then S.pendingRun = true end
    return
  end
  S.error, S.diskName, S.writeMBps, S.readMBps, S.stderrText = "", "", "", "", ""
  S.phase = "read"
  S.running = true
  render()
  lookupDisk(function(name)
    if S.running then
      S.diskName = trim(name)
      render()
    end
  end)
  startBench()
end

---------------------------------------------------------------- overlay
local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- For a single-quoted JS string whose value is then injected via innerHTML.
local function jsstr(s)
  return (esc(s):gsub("\\", "\\\\"))
end

local function page()
  local c = function(n) return theme.hex(n) end
  local scrim = theme.isDark() and "rgba(0,0,0,.55)" or "rgba(0,0,0,.35)"
  return [[<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{background:transparent;height:100%;overflow:hidden;
    font-family:"JetBrainsMono Nerd Font","JetBrains Mono",ui-monospace,monospace;color:]] .. c("foreground") .. [[}
  #scrim{position:fixed;inset:0;background:]] .. scrim .. [[;display:flex;align-items:center;justify-content:center}
  #card{background:]] .. c("background") .. [[;border:2px solid ]] .. c("accent") .. [[;padding:22px 34px 18px;
    min-width:640px;display:flex;flex-direction:column;align-items:center;gap:6px;box-shadow:0 18px 60px rgba(0,0,0,.45)}
  #title{font-size:15px;font-weight:600;color:]] .. c("bright_foreground") .. [[;min-height:20px;letter-spacing:.04em;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:560px}
  #dials{display:flex;gap:48px;margin-top:8px}
  .dial{display:flex;flex-direction:column;align-items:center;width:240px}
  .dial svg{width:240px;height:210px;overflow:visible}
  .track{fill:none;stroke:]] .. c("selection") .. [[;stroke-width:12}
  .arc{fill:none;stroke:]] .. c("accent") .. [[;stroke-width:12;transition:stroke .3s}
  .tick{fill:]] .. c("dark_foreground") .. [[;font-size:11px;font-family:inherit}
  .val{fill:]] .. c("bright_foreground") .. [[;font-size:40px;font-weight:700;font-family:inherit}
  .unit{fill:]] .. c("dark_foreground") .. [[;font-size:12px;font-family:inherit;letter-spacing:.08em}
  .lbl{font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:]] .. c("dark_foreground") .. [[;margin-top:-18px}
  .live .lbl{color:]] .. c("accent") .. [[}
  .live .arc{animation:pulse 1.2s ease-in-out infinite}
  .idle .arc{stroke:]] .. c("dark_foreground") .. [[}
  .done .arc{stroke:]] .. c("accent") .. [[}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.55}}
  #foot{display:flex;align-items:center;justify-content:center;gap:12px;min-height:34px;margin-top:6px}
  #err{color:]] .. c("red") .. [[;font-size:13px;max-width:560px;text-align:center}
  #again{background:transparent;border:1px solid ]] .. c("selection") .. [[;color:]] .. c("foreground") .. [[;
    font:inherit;font-size:18px;width:34px;height:34px;cursor:pointer;display:none;position:relative}
  #again:hover{border-color:]] .. c("accent") .. [[;color:]] .. c("accent") .. [[}
  #again .tip{position:absolute;bottom:40px;left:50%;transform:translateX(-50%);white-space:nowrap;font-size:11px;
    background:]] .. c("background") .. [[;border:1px solid ]] .. c("selection") .. [[;padding:3px 7px;display:none;color:]] .. c("foreground") .. [[}
  #again:hover .tip{display:block}
  </style></head><body>
  <div id="scrim"><div id="card">
    <div id="title"></div>
    <div id="dials">
      <div class="dial idle" id="d0"></div>
      <div class="dial idle" id="d1"></div>
    </div>
    <div id="foot"><span id="err"></span>
      <button id="again"><span>&#xf0450;</span><span class="tip">]] .. esc(T.measureAgain) .. [[</span></button></div>
  </div></div>
  <script>
  const send=(m)=>window.webkit.messageHandlers.omarchy.postMessage(m);
  const STOPS=[500,1000,2500,5000,10000,15000];
  const R=82,C=2*Math.PI*R,SPAN=0.75;
  function fmtStop(v){return v>=1000?(v/1000)+'k':String(v)}
  function fmt(v){return v<=0?'0':(v<100?v.toFixed(1):String(Math.round(v)))}
  function scaleFor(v){for(const s of STOPS)if(v<=s)return s;return STOPS[STOPS.length-1]}
  function build(el,label){
    el.innerHTML='<svg viewBox="-120 -110 240 210">'+
      '<circle class="track" r="'+R+'" stroke-dasharray="'+(C*SPAN)+' '+C+'" transform="rotate(135)"/>'+
      '<circle class="arc" r="'+R+'" stroke-dasharray="0 '+C+'" transform="rotate(135)"/>'+
      '<text class="tick t0" x="-62" y="86" text-anchor="middle">0</text>'+
      '<text class="tick tm" x="62" y="86" text-anchor="middle">500</text>'+
      '<text class="val" x="0" y="10" text-anchor="middle">0</text>'+
      '<text class="unit" x="0" y="34" text-anchor="middle">MB/s</text></svg>'+
      '<div class="lbl">'+label+'</div>';
    return {el,arc:el.querySelector('.arc'),val:el.querySelector('.val'),tm:el.querySelector('.tm'),shown:0,target:0,max:500,shownMax:500};
  }
  const dials=[build(document.getElementById('d0'),']] .. jsstr(T.read) .. [['),
               build(document.getElementById('d1'),']] .. jsstr(T.write) .. [[')];
  function frame(){
    for(const d of dials){
      d.shown+=(d.target-d.shown)*0.12; if(Math.abs(d.target-d.shown)<0.05)d.shown=d.target;
      d.shownMax+=(d.max-d.shownMax)*0.12; if(Math.abs(d.max-d.shownMax)<1)d.shownMax=d.max;
      const f=Math.max(0,Math.min(1,d.shown/d.shownMax));
      d.arc.setAttribute('stroke-dasharray',(C*SPAN*f)+' '+C);
      d.val.textContent=fmt(d.shown);
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  window.omarchyUpdate=function(s){
    document.getElementById('title').textContent=s.title||'';
    const vals=[s.read,s.write],live=[s.readLive,s.writeLive];
    dials.forEach((d,i)=>{
      d.target=vals[i]||0; d.max=scaleFor(d.target); d.tm.textContent=fmtStop(d.max);
      d.el.className='dial '+(live[i]?'live':(d.target>0?'done':'idle'));
    });
    document.getElementById('err').textContent=s.error||'';
    document.getElementById('again').style.display=s.running?'none':'inline-block';
  };
  document.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();send({close:true})}
    else if((e.key==='r'||e.key==='Enter')&&document.getElementById('again').style.display!=='none'){e.preventDefault();send({again:true})}
  });
  document.getElementById('scrim').addEventListener('mousedown',e=>{if(e.target.id==='scrim')send({close:true})});
  document.getElementById('again').addEventListener('click',e=>{e.stopPropagation();send({again:true})});
  window.addEventListener('blur',()=>setTimeout(()=>{if(!document.hasFocus())send({close:true})},150));
  window.omarchyUpdate(]] .. hs.json.encode(viewState()) .. [[);
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

-- Host-initiated close: stop the run (cleared phase first, so the exit reads as dismissal).
function M.close()
  S.opened = false
  S.pendingRun = false
  S.phase = ""
  S.running = false
  if diskTask then pcall(function() diskTask:terminate() end); diskTask = nil end
  if task then
    S.expectedStop = true
    pcall(function() task:terminate() end)
  end
  destroyView()
  publish()
end

local function showView()
  if view then
    pcall(function() view:bringToFront(true) end)
    return
  end
  if not ucc then
    ucc = hs.webview.usercontent.new("omarchy")
    ucc:setCallback(function(msg)
      local body = type(msg) == "table" and type(msg.body) == "table" and msg.body or {}
      if body.close then
        hs.timer.doAfter(0, M.close)
      elseif body.again then
        if S.opened and not S.running then hs.timer.doAfter(0, runTest) end
      elseif body.ready then
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
    log.e("disk-speedtest: could not open overlay: %s", tostring(err))
    destroyView()
    toast.warn(T.failed)
    return false
  end
  return true
end

function M.open()
  S.opened = true
  if not showView() then
    S.opened = false
    return
  end
  runTest()
end

M.actions = {
  ["disk-speedtest.open"] = { fn = function() M.open() end, desc = "Disk speed test: open the overlay and measure" },
  ["disk-speedtest.toggle"] = { fn = function() if S.opened then M.close() else M.open() end end,
    desc = "Disk speed test: open or dismiss the overlay" },
  ["disk-speedtest.close"] = { fn = function() if S.opened then M.close() end end, desc = "Disk speed test: dismiss (stops the run)" },
  ["disk-speedtest.run"] = { fn = function()
    if not S.opened then return M.open() end
    if not S.running then runTest() end
  end, desc = "Disk speed test: measure again" },
}

function M.start()
  math.randomseed(os.time())
  publish()
end

function M.stop()
  S.pendingRun = false
  if diskTask then pcall(function() diskTask:terminate() end); diskTask = nil end
  if task then
    S.expectedStop = true
    pcall(function() task:terminate() end)
    task = nil
  end
  removeScratch()
  destroyView()
  S.opened, S.running, S.phase = false, false, ""
end

return M
