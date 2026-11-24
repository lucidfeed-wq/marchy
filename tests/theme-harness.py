#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Dry-run test harness for omarchy-theme (staging build).

Builds a fake HOME from COPIES of the live files, runs
`HOME=<fake> omarchy-theme set <name> --dry-run` for every theme and checks
every output (TOML/JSON/Lua parse, hex colours, Ghostty validate-config, OmniWM
border values, wallpaper JPEG, theme.name written last). It never writes
outside the build directory and never signals or talks to running apps.

usage: theme-harness.py [--keep] [--themes a,b,...] [--nvim]
  --keep     keep the previous fake home (faster; skips the copy)
  --themes   only these themes
  --nvim     also run a headless Neovim (isolated XDG dirs) against the
             generated spec and exercise the SIGUSR1 hot-reload
"""
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib

REAL = os.path.expanduser("~")
# uv (the scripts' shebang) keeps using the real cache / managed Pythons under a fake HOME.
UV_ENV = {"UV_CACHE_DIR": os.path.join(REAL, ".cache/uv"),
          "UV_PYTHON_INSTALL_DIR": os.path.join(REAL, ".local/share/uv/python")}
BUILD = os.path.join(REAL, ".config/omarchy-mac/build")
WORK = os.path.join(BUILD, "tmp/theme")
H = os.path.join(WORK, "home")
SCRIPT = os.path.join(BUILD, "omarchy-mac/bin/omarchy-theme")
GHOSTTY = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
LUAJIT = "/opt/homebrew/bin/luajit"
HEX6 = re.compile(r"^#[0-9a-fA-F]{6}$")
HEX68 = re.compile(r"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")

LIVE_WATCH = [  # live files whose content must not change during the run
    ".config/omarchy-mac/current/theme.name", ".config/omarchy-mac/current/colors.json",
    ".config/omarchy-mac/current/ghostty.conf", ".config/omniwm/settings.toml",
    ".config/omniwm/shell/themes/omarchy.toml", ".config/omniwm/shell/shell.toml",
    ".config/btop/btop.conf", ".config/btop/themes/omarchy.theme",
    ".config/nvim/lua/plugins/omarchy-theme.lua", ".config/ghostty/config", ".zshrc",
]


def digest(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def copytree(src, dst, **kw):
    if os.path.exists(src):
        shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True, **kw)


def copyfile(src, dst):
    if os.path.exists(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)


STUB = r'''#!/bin/sh
# Test stub for omarchy-omniwm-set: logs its argv, and applies borders.color.*
# to the --file copy with a line edit so the harness can check the values.
set -eu
log="$HOME/.local/state/omarchy-mac/omniwm-set-stub.log"
mkdir -p "$(dirname "$log")"
echo "$*" >> "$log"
file=""; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) file="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --help) echo "stub"; exit 0 ;;
    borders.color.*=*) k=${1#borders.color.}; k=${k%%=*}; v=${1#*=}
       [ -n "$file" ] && /usr/bin/sed -i '' -e "/^\[borders\.color\]/,/^\[/ s/^$k = .*/$k = $v/" "$file"; shift ;;
    *) shift ;;
  esac
done
'''


def build_home(keep):
    if not keep:
        shutil.rmtree(H, ignore_errors=True)
    om = os.path.join(H, ".config/omarchy-mac")
    os.makedirs(om, exist_ok=True)
    for d in ("themes", "templates", "current"):
        copytree(os.path.join(REAL, ".config/omarchy-mac", d), os.path.join(om, d))
    # Staged files replace the live ones, as the deploy will.
    copytree(os.path.join(BUILD, "omarchy-mac/templates"), os.path.join(om, "templates"))
    copytree(os.path.join(BUILD, "omarchy-mac/bin"), os.path.join(om, "bin"))
    if not os.path.exists(os.path.join(BUILD, "omarchy-mac/bin/omarchy-omniwm-set")):
        p = os.path.join(om, "bin/omarchy-omniwm-set")
        with open(p, "w") as fh:
            fh.write(STUB)
        os.chmod(p, 0o755)
    copyfile(os.path.join(REAL, ".config/omniwm/settings.toml"), os.path.join(H, ".config/omniwm/settings.toml"))
    for rel in ("shell/shell.toml",):
        copyfile(os.path.join(REAL, ".config/omniwm", rel), os.path.join(H, ".config/omniwm", rel))
    copytree(os.path.join(REAL, ".config/omniwm/shell/themes"), os.path.join(H, ".config/omniwm/shell/themes"))
    copytree(os.path.join(REAL, ".config/btop"), os.path.join(H, ".config/btop"))
    copytree(os.path.join(REAL, ".config/nvim"), os.path.join(H, ".config/nvim"))
    copytree(os.path.join(BUILD, "nvim"), os.path.join(H, ".config/nvim"))
    copytree(os.path.join(REAL, ".config/herdr-app/themes"), os.path.join(H, ".config/herdr-app/themes"))
    os.makedirs(os.path.join(H, ".local/state/omarchy-mac"), exist_ok=True)


def run_theme(*args, env_extra=None, python=None):
    env = dict(os.environ, HOME=H, **UV_ENV)
    env.update(env_extra or {})
    cmd = ([python] if python else []) + [SCRIPT] + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=300)


def default_roles():
    with open(os.path.join(REAL, ".config/omniwm/shell/default/themes/tokyo-night.toml"), "rb") as fh:
        d = tomllib.load(fh)
    return set(d["light"]), set(d["dark"])


def check_theme(name, roles):
    errs = []
    om = os.path.join(H, ".config/omarchy-mac")
    cur = os.path.join(om, "current")
    t0 = time.time()
    res = run_theme("set", name, "--dry-run")
    dt = time.time() - t0
    if res.returncode != 0:
        return ["exit %d: %s" % (res.returncode, res.stderr.strip()[:300])], dt, {}
    warn = [l for l in res.stderr.splitlines() if l.strip()]
    if warn:
        errs.append("stderr: " + " | ".join(warn)[:300])

    if (open(os.path.join(cur, "theme.name")).read().strip()) != name:
        errs.append("theme.name mismatch")
    try:
        colors = json.load(open(os.path.join(cur, "colors.json")))
        for k, v in colors.items():
            if k in ("name", "title", "mode", "hyprland_active_border", "hyprland_inactive_border"):
                continue
            vals = v if isinstance(v, list) else [v]
            for x in vals:
                if not HEX6.match(str(x)):
                    errs.append("colors.json %s=%r not hex" % (k, x))
        if colors.get("mode") not in ("light", "dark"):
            errs.append("bad mode")
    except Exception as exc:
        errs.append("colors.json: %s" % exc)
        colors = {}

    gh = os.path.join(cur, "ghostty.conf")
    r = subprocess.run([GHOSTTY, "+validate-config", "--config-file=" + gh], capture_output=True, text=True)
    if r.returncode != 0:
        errs.append("ghostty validate: " + (r.stdout + r.stderr).strip()[:200])
    for line in open(gh):
        m = re.match(r"^(palette = \d+=|[a-z-]+ = )(.*)$", line.strip())
        if m and not HEX6.match(m.group(2)):
            errs.append("ghostty non-hex: " + line.strip())

    bt = os.path.join(H, ".config/btop/themes/omarchy.theme")
    for line in open(bt):
        m = re.match(r'^theme\[[a-z_0-9]+\]="(.*)"$', line.strip())
        if m and m.group(1) and not HEX6.match(m.group(1)):
            errs.append("btop non-hex: " + line.strip())
    conf = open(os.path.join(H, ".config/btop/btop.conf")).read()
    if 'color_theme = "omarchy"' not in conf:
        errs.append("btop.conf color_theme not set")

    nv = os.path.join(H, ".config/nvim/lua/plugins/omarchy-theme.lua")
    chk = os.path.join(WORK, "luacheck.lua")
    with open(chk, "w") as fh:
        fh.write("local f = assert(loadfile(arg[1])); local t = f(); assert(type(t) == 'table' and #t >= 1, 'spec is not a list')\n")
    r = subprocess.run([LUAJIT, chk, nv], capture_output=True, text=True)
    if r.returncode != 0:
        errs.append("neovim lua: " + r.stderr.strip()[:200])
    if "{{" in open(nv).read():
        errs.append("neovim lua has placeholders")

    try:
        pal = tomllib.load(open(os.path.join(H, ".config/omniwm/shell/themes/omarchy.toml"), "rb"))
        for sec, want in (("light", roles[0]), ("dark", roles[1])):
            got = set(pal.get(sec, {}))
            if got != want:
                errs.append("shell [%s] roles differ: +%s -%s" % (sec, sorted(got - want), sorted(want - got)))
            for k, v in pal.get(sec, {}).items():
                if not HEX68.match(v):
                    errs.append("shell %s.%s=%r" % (sec, k, v))
        if pal.get("light") == pal.get("dark"):
            errs.append("shell light == dark")
        native = pal["dark" if colors.get("mode") == "dark" else "light"]
        if native["background"].lower() != colors.get("background", "").lower():
            errs.append("shell native section background != theme background")
    except Exception as exc:
        errs.append("shell toml: %s" % exc)

    try:
        hd = json.load(open(os.path.join(H, ".config/herdr-app/themes/omarchy.json")))
        ok = (set(hd) <= {"background", "foreground", "selection", "cursor", "ansi", "colors"}
              and all(HEX6.match(hd[k]) for k in ("background", "foreground", "selection", "cursor"))
              and len(hd["ansi"]) == 16 and all(HEX6.match(x) for x in hd["ansi"])
              and all(HEX68.match(x) for x in hd.get("colors", {}).values()))
        if not ok:
            errs.append("herdr json fails upstream schema")
    except Exception as exc:
        errs.append("herdr json: %s" % exc)

    try:
        st = tomllib.load(open(os.path.join(H, ".config/omniwm/settings.toml"), "rb"))
        col = st["borders"]["color"]
        want = [round(int(colors["border"][i:i + 2], 16) / 255, 3) for i in (1, 3, 5)]
        got = [col["red"], col["green"], col["blue"]]
        if any(abs(a - b) > 0.0015 for a, b in zip(want, got)) or col.get("alpha") != 1.0:
            errs.append("omniwm border %s != %s" % (got, want))
    except Exception as exc:
        errs.append("settings.toml: %s" % exc)

    bgp = open(os.path.join(cur, "background")).read().strip()
    if not (os.path.isabs(bgp) and os.path.isfile(bgp) and bgp.startswith(os.path.join(cur, "backgrounds"))):
        errs.append("background path bad: " + bgp)
    else:
        r = subprocess.run(["/usr/bin/sips", "-g", "format", bgp], capture_output=True, text=True)
        if "jpeg" not in r.stdout:
            errs.append("background not jpeg")

    tn = os.path.getmtime(os.path.join(cur, "theme.name"))
    for p in (os.path.join(cur, "colors.json"), gh, bt, nv, os.path.join(cur, "background"),
              os.path.join(H, ".config/omniwm/shell/themes/omarchy.toml")):
        if os.path.getmtime(p) > tn:
            errs.append("%s newer than theme.name" % os.path.basename(p))
    if glob.glob(os.path.join(cur, ".next-theme-*")) or glob.glob(os.path.join(cur, ".old-theme-*")):
        errs.append("staging dirs left behind")
    info = {"mode": colors.get("mode"), "border": colors.get("border"), "bg": os.path.basename(bgp)}
    return errs, dt, info


def extra_tests():
    out = []
    om = os.path.join(H, ".config/omarchy-mac")
    cur = os.path.join(om, "current")

    def t(label, ok, detail=""):
        out.append(("PASS" if ok else "FAIL", label, detail))

    # same theme again advances the background (upstream behaviour)
    run_theme("set", "gruvbox", "--dry-run")
    b1 = open(os.path.join(cur, "background")).read().strip()
    run_theme("set", "gruvbox", "--dry-run")
    b2 = open(os.path.join(cur, "background")).read().strip()
    t("re-set same theme advances background", b1 != b2, "%s -> %s" % (os.path.basename(b1), os.path.basename(b2)))
    r = run_theme("bg-next", "--dry-run")
    b3 = open(os.path.join(cur, "background")).read().strip()
    t("bg-next", r.returncode == 0 and b3 != b2, os.path.basename(b3))
    r = run_theme("bg-set", "0", "--dry-run")
    t("bg-set 0", r.returncode == 0 and open(os.path.join(cur, "gruvbox.index") if False else os.path.join(cur, "backgrounds/gruvbox.index")).read().strip() == "0")
    r = run_theme("bg-list", "--json")
    t("bg-list --json", r.returncode == 0 and len(json.loads(r.stdout)) >= 1)
    jpgs = glob.glob(os.path.join(cur, "backgrounds/*.jpg"))
    t("old backgrounds pruned", all(os.path.basename(j).startswith("gruvbox--") or j == b3 for j in jpgs) or len(jpgs) <= 7,
      "%d jpgs" % len(jpgs))
    r = run_theme("list", "--json")
    lst = json.loads(r.stdout) if r.returncode == 0 else []
    t("list --json", len(lst) == 23 and all("mode" in e for e in lst), "%d themes" % len(lst))
    r = run_theme("current")
    t("current", r.stdout.strip() == "gruvbox")
    r = run_theme("set", "Tokyo Night", "--dry-run")
    t('name normalisation ("Tokyo Night")', r.returncode == 0 and run_theme("current").stdout.strip() == "tokyo-night")
    r = run_theme("set", "does-not-exist", "--dry-run")
    t("unknown theme rejected, nothing written", r.returncode == 1 and run_theme("current").stdout.strip() == "tokyo-night")
    r = run_theme("set", "../etc", "--dry-run")
    t("path-like name rejected", r.returncode == 1)
    # Explicit Apple python 3.9: clear error, nothing written
    before = open(os.path.join(cur, "theme.name")).read()
    r = run_theme("set", "nord", "--dry-run", python="/usr/bin/python3")
    t("/usr/bin/python3 (3.9) refuses with a clear error", r.returncode != 0 and "3.11" in r.stderr
      and open(os.path.join(cur, "theme.name")).read() == before, r.stderr.strip()[:120])
    # minimal PATH (what Hammerspoon/Karabiner give): the uv shebang finds a Python by itself
    r = subprocess.run(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + H]
                       + ["%s=%s" % kv for kv in UV_ENV.items()] + [SCRIPT, "set", "kanagawa", "--dry-run"],
                       capture_output=True, text=True)
    t("minimal PATH (Hammerspoon env) works", r.returncode == 0 and run_theme("current").stdout.strip() == "kanagawa",
      r.stderr.strip()[:200])
    # --dry-run with the real HOME is refused before anything is written. Exercised
    # on the test home made to count as real (the script never lets the real home
    # count as a test home), so a regression cannot touch live files.
    snap = {p: digest(p) for p in glob.glob(os.path.join(cur, "*")) + glob.glob(os.path.join(H, ".config/nvim/lua/plugins/*"))}
    log_before = os.path.getsize(os.path.join(H, ".local/state/omarchy-mac/theme.log"))
    codes = []
    for argv in (["set", "nord", "--dry-run"], ["--dry-run", "bg-next"], ["bg-set", "0", "--dry-run"]):
        rr = run_theme(*argv, env_extra={"OMARCHY_THEME_TREAT_AS_REAL_HOME": H})
        codes.append(rr.returncode)
    snap2 = {p: digest(p) for p in snap}
    t("--dry-run with the real HOME refused (exit 2), nothing written", codes == [2, 2, 2] and snap == snap2,
      "codes=%s" % codes)
    rr = run_theme("check", "nord", env_extra={"OMARCHY_THEME_TREAT_AS_REAL_HOME": H})
    t("check still allowed with the real HOME", rr.returncode == 0)
    # a test home without --dry-run is forced into dry-run (bg-next: no side effects either way)
    rr = run_theme("bg-next")
    newlog = open(os.path.join(H, ".local/state/omarchy-mac/theme.log")).read()[log_before:]
    t("test HOME without --dry-run is forced to dry-run", rr.returncode == 0 and "running as --dry-run" in rr.stderr
      and "[dry-run] background" in newlog, rr.stderr.strip()[:160])
    # concurrency: 4 parallel switches serialize on the lock; end state is consistent
    procs = [subprocess.Popen([SCRIPT, "set", n, "--dry-run"], env=dict(os.environ, HOME=H),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
             for n in ("rose-pine", "matte-black", "white", "hackerman")]
    codes = [p.wait(timeout=300) for p in procs]
    final = run_theme("current").stdout.strip()
    cj = json.load(open(os.path.join(cur, "colors.json")))
    t("4 parallel sets: all exit 0, colors.json matches theme.name", codes == [0, 0, 0, 0] and cj["name"] == final,
      "codes=%s final=%s" % (codes, final))
    # dry-run sent nothing: every side effect is logged as skipped
    log = open(os.path.join(H, ".local/state/omarchy-mac/theme.log")).read()
    t("dry-run skipped pkill/omniwmctl/osascript", "dry-run skip: /usr/bin/pkill -USR2 -x ghostty" in log
      and "dry-run skip: /Applications/OmniWM.app/Contents/MacOS/omniwmctl shell theme omarchy" in log
      and "macOS dark mode" in log)
    calls = [l for l in log.splitlines() if "omniwm-set:" in l]
    t("omarchy-omniwm-set called with --file <fake> --no-ping, exit 0",
      bool(calls) and all(("--file " + H) in l and "--no-ping" in l and l.endswith("-> 0") for l in calls),
      "%d calls; last: %s" % (len(calls), calls[-1][-120:] if calls else None))
    t("omarchy-omniwm-set called with --keep 20", bool(calls) and all("--keep 20 " in l for l in calls))
    # borders.darkColor (dark appearance) follows the theme when the file has one
    st_path = os.path.join(H, ".config/omniwm/settings.toml")
    with open(st_path, "a") as fh:
        fh.write("\n[borders.darkColor]\nalpha = 0.5\nblue = 0.0\ngreen = 0.0\nred = 1.0\n")
    r = run_theme("set", "everforest", "--dry-run")
    st = tomllib.load(open(st_path, "rb"))
    cj = json.load(open(os.path.join(cur, "colors.json")))
    want = [round(int(cj["border"][i:i + 2], 16) / 255, 3) for i in (1, 3, 5)] + [1.0]
    got = {k: [st["borders"][k][c] for c in ("red", "green", "blue", "alpha")] for k in ("color", "darkColor")}
    t("borders.darkColor set too when present", r.returncode == 0 and all(
        all(abs(a - b) < 0.0015 for a, b in zip(v, want)) for v in got.values()), "%s want %s" % (got, want))
    lp = os.path.join(H, ".local/state/omarchy-mac/theme.log")
    size = os.path.getsize(lp)
    r = run_theme("set", "everforest", "--dry-run")
    new = open(lp).read()[size:]
    t("unchanged color + darkColor: omarchy-omniwm-set not called", r.returncode == 0
      and "omniwm border already" in new and "omniwm-set:" not in new)
    # synthetic themes exercise the fallback cascade
    syn = os.path.join(om, "themes/zz-legacy")
    os.makedirs(syn, exist_ok=True)
    with open(os.path.join(syn, "colors.toml"), "w") as fh:
        fh.write("\n".join('color%d = "#%02x%02x%02x"' % (i, 16 * i, 255 - 16 * i, 128) for i in range(16)) + "\n")
    r = run_theme("set", "zz-legacy", "--dry-run")
    cj = json.load(open(os.path.join(cur, "colors.json"))) if r.returncode == 0 else {}
    t("legacy color0..15-only theme resolves", r.returncode == 0 and cj.get("brown") and cj.get("dark_background"),
      r.stderr.strip()[:200])
    syn2 = os.path.join(om, "themes/zz-minimal")
    os.makedirs(syn2, exist_ok=True)
    with open(os.path.join(syn2, "colors.toml"), "w") as fh:
        fh.write('bg = "#F0F0F0"\nfg = "#202020"\nred = "#cc0000"\n')
    r = run_theme("set", "zz-minimal", "--dry-run")
    cj = json.load(open(os.path.join(cur, "colors.json"))) if r.returncode == 0 else {}
    t("minimal bg/fg/red theme: luminance -> light, all keys", r.returncode == 0 and cj.get("mode") == "light"
      and cj.get("bright_red") == "#d63333", "bright_red=%s" % cj.get("bright_red"))
    syn3 = os.path.join(om, "themes/zz-broken")
    os.makedirs(syn3, exist_ok=True)
    with open(os.path.join(syn3, "colors.toml"), "w") as fh:
        fh.write('background = "#000000"\nforeground = "not a colour"\n')
    before = open(os.path.join(cur, "colors.json")).read()
    r = run_theme("set", "zz-broken", "--dry-run")
    t("broken theme aborts before writing anything", r.returncode == 1 and open(os.path.join(cur, "colors.json")).read() == before,
      r.stderr.strip()[:160])
    for d in (syn, syn2, syn3):
        shutil.rmtree(d)
    return out


NVIM_TEST = r'''
-- Run inside the isolated headless nvim: report colorscheme, then wait.
local out = os.getenv("OMARCHY_NVIM_REPORT")
local function report(tag)
  local f = io.open(out, "a"); f:write(tag .. " " .. (vim.g.colors_name or "nil") .. " " .. vim.o.background .. "\n"); f:close()
end
vim.api.nvim_create_autocmd("ColorScheme", { callback = function() report("colorscheme") end })
vim.defer_fn(function() report("startup") end, 3000)
'''


NVIM_PROBE = r'''
-- Startup probe: Normal background + which aether copy loaded, then quit.
vim.defer_fn(function()
  local hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local cfg = require("lazy.core.config")
  local function st(n)
    local p = cfg.plugins[n]
    return p and (p._.loaded and "loaded" or "unloaded") or "absent"
  end
  io.stdout:write(string.format("PROBE %s #%06x aether=%s aether.nvim=%s\n", vim.g.colors_name or "nil",
    hl.bg or 0, st("aether"), st("aether.nvim")))
  vim.cmd("qa!")
end, 2500)
'''


def nvim_startup_colors(env, runs=3):
    """Fresh nvim starts on templated (aether) themes and hackerman: the Normal
    background must equal the theme background every time."""
    res = []
    probe = os.path.join(WORK, "nvim-probe.lua")
    with open(probe, "w") as fh:
        fh.write(NVIM_PROBE)
    for name in ("ethereal", "white", "jade-horse", "hackerman"):
        run_theme("set", name, "--dry-run")
        want = json.load(open(os.path.join(H, ".config/omarchy-mac/current/colors.json")))["background"].lower()
        got = []
        for _ in range(runs):
            r = subprocess.run(["nvim", "--headless", "-c", "luafile " + probe], env=env, capture_output=True,
                               text=True, timeout=60)
            line = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith("PROBE")]
            got.append(line[-1].split()[2] if line else "none")
        res.append(("PASS" if all(g == want for g in got) else "FAIL",
                    "startup Normal bg -> %s (%d runs)" % (name, runs), "want %s got %s" % (want, ",".join(got))))
    return res


def nvim_test():
    """Headless LazyVim in an isolated XDG tree (copy of the installed plugins)."""
    res = []
    xdg = os.path.join(WORK, "xdg")
    data = os.path.join(xdg, "data")
    if not os.path.isdir(os.path.join(data, "nvim/lazy/LazyVim")):
        copytree(os.path.join(REAL, ".local/share/nvim/lazy"), os.path.join(data, "nvim/lazy"))
    env = dict(os.environ, HOME=H, XDG_CONFIG_HOME=os.path.join(H, ".config"), XDG_DATA_HOME=data,
               XDG_STATE_HOME=os.path.join(xdg, "state"), XDG_CACHE_HOME=os.path.join(xdg, "cache"),
               GIT_TERMINAL_PROMPT="0")
    # install the declared theme plugins into the isolated data dir
    r = subprocess.run(["nvim", "--headless", "+Lazy! install", "+qa"], env=env, capture_output=True, text=True, timeout=600)
    missing = [n for n in ("everforest-nvim", "flexoki-neovim", "gruvbox.nvim", "hackerman.nvim", "aether",
                           "kanagawa.nvim", "lumon.nvim", "matteblack.nvim", "nightfox.nvim", "retro-82.nvim", "rose-pine",
                           "ashen.nvim", "catppuccin", "tokyonight.nvim")
               if not os.path.isdir(os.path.join(data, "nvim/lazy", n))]
    res.append(("PASS" if not missing else "FAIL", "Lazy install of all theme plugins", "missing=%s" % missing))
    res.extend(nvim_startup_colors(env))
    report = os.path.join(WORK, "nvim-report.txt")
    themes_to_try = ["gruvbox", "catppuccin-latte", "ethereal", "hackerman", "rose-pine", "nord", "everforest", "solitude",
                     "matte-black", "lumon", "retro-82", "kanagawa", "flexoki-light", "white", "tokyo-night"]
    run_theme("set", themes_to_try[0], "--dry-run")
    test_lua = os.path.join(WORK, "nvim-test.lua")
    with open(test_lua, "w") as fh:
        fh.write(NVIM_TEST)
    if os.path.exists(report):
        os.unlink(report)
    env["OMARCHY_NVIM_REPORT"] = report
    p = subprocess.Popen(["nvim", "--headless", "-c", "luafile " + test_lua], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(6)
    expect = {"gruvbox": "gruvbox", "catppuccin-latte": "catppuccin-latte", "ethereal": "aether", "hackerman": "hackerman",
              "rose-pine": "rose-pine", "nord": "nordfox", "everforest": "everforest", "solitude": "ashen",
              "matte-black": "matteblack", "lumon": "lumon", "retro-82": "retro-82", "kanagawa": "kanagawa",
              "flexoki-light": "flexoki", "white": "aether", "tokyo-night": "tokyonight-night"}
    lines = open(report).read().splitlines() if os.path.exists(report) else []
    start = [l for l in lines if l.startswith("startup")]
    res.append(("PASS" if start and start[-1].split()[1] == "gruvbox" else "FAIL", "startup colorscheme from spec", str(start[-1:])))
    for name in themes_to_try[1:]:
        before = len(open(report).read().splitlines()) if os.path.exists(report) else 0
        run_theme("set", name, "--dry-run")
        os.kill(p.pid, signal.SIGUSR1)  # only the isolated test nvim, never pkill
        deadline = time.time() + 15
        got = None
        while time.time() < deadline:
            lines = open(report).read().splitlines()
            new = [l for l in lines[before:] if l.startswith("colorscheme")]
            if new and new[-1].split()[1] == expect[name]:
                got = new[-1]
                break
            time.sleep(0.3)
        mode = json.load(open(os.path.join(H, ".config/omarchy-mac/current/colors.json")))["mode"]
        ok = got is not None and got.split()[2] == mode
        res.append(("PASS" if ok else "FAIL", "SIGUSR1 hot-reload -> %s" % name, got or ("last=%s" % (lines[-1:] if lines else None))))
    p.terminate()
    try:
        _, err = p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        _, err = p.communicate()
    errlines = [l for l in (err or "").splitlines() if re.search(r"(?i)error|failed", l)]
    res.append(("PASS" if not errlines else "FAIL", "no nvim errors on stderr", " | ".join(errlines)[:300]))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--themes")
    ap.add_argument("--nvim", action="store_true")
    a = ap.parse_args()
    live_before = {p: digest(os.path.join(REAL, p)) for p in LIVE_WATCH}
    build_home(a.keep)
    roles = default_roles()
    names = a.themes.split(",") if a.themes else sorted(
        d for d in os.listdir(os.path.join(H, ".config/omarchy-mac/themes"))
        if os.path.isfile(os.path.join(H, ".config/omarchy-mac/themes", d, "colors.toml")))
    failures = 0
    print("%-18s %-6s %-5s %-8s %-34s %s" % ("theme", "result", "mode", "border", "background", "time"))
    for n in names:
        errs, dt, info = check_theme(n, roles)
        failures += bool(errs)
        print("%-18s %-6s %-5s %-8s %-34s %.2fs" % (n, "FAIL" if errs else "ok", info.get("mode", "-"), info.get("border", "-"),
                                                   (info.get("bg") or "-")[:34], dt))
        for e in errs:
            print("    - " + e)
    if not a.themes:
        print("\nextra tests")
        for status, label, detail in extra_tests():
            failures += status == "FAIL"
            print("  %s %s %s" % (status, label, ("(" + detail + ")") if detail else ""))
    if a.nvim:
        print("\nneovim (isolated headless LazyVim)")
        for status, label, detail in nvim_test():
            failures += status == "FAIL"
            print("  %s %s %s" % (status, label, ("(" + detail + ")") if detail else ""))
    live_after = {p: digest(os.path.join(REAL, p)) for p in LIVE_WATCH}
    changed = [p for p in LIVE_WATCH if live_before[p] != live_after[p]]
    print("\nlive files unchanged: %s" % ("yes" if not changed else "NO: %s" % changed))
    failures += bool(changed)
    print("TOTAL FAILURES: %d" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
