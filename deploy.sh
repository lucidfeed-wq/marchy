#!/bin/zsh
# deploy.sh - cut the live Mac over from the old Hammerspoon/F18 setup to the staged
# Omarchy-on-macOS build (Karabiner Super + OmniWM hotkeys + Hammerspoon actions).
#
# Run by the lead, from a terminal, with patient-facing windows closed:
#     ~/.config/omarchy-mac/build/deploy.sh --dry-run     # print every action, change nothing
#     ~/.config/omarchy-mac/build/deploy.sh               # do it
# Undo with ~/.config/omarchy-mac/build/rollback.sh
set -eu
setopt pipefail no_nomatch

usage() {
  cat <<'EOF'
Usage: deploy.sh [--dry-run] [--build DIR] [--skip-doctor] [--sandbox] [-h|--help]

Backs up every live target to ~/.config/omarchy-mac/backup-YYYY-MM-DD-HHMMSS/
(with a MANIFEST that rollback.sh reads), then in this order:
  1  copy omarchy-mac/bindings.toml, bin/*, templates/* into ~/.config/omarchy-mac
     and symlink the bins into ~/.local/bin
  2  omarchy-keys check + generate --out <tmp>; install settings.toml through
     'omarchy-omniwm-set --install' (flock, backup, atomic rename, ping);
     KEYBINDINGS.md into ~/.config/omarchy-mac
  3  replace ~/.hammerspoon/omarchy (staged modules + generated/bindings.lua) and
     ~/.hammerspoon/init.lua, then reload Hammerspoon (hs -c, deferred hs.reload)
  4  clear the hidutil Caps->F18 mapping
  5  install the generated karabiner.json atomically (mv), select profile Omarchy
  6  copy omniwm-shell/** into ~/.config/omniwm/shell (widgets first, then shell.toml),
     check the bar widgets load, add the app float rules (Citrix Viewer/AuthManager/
     Workspace, Ghostty ^omarchy-float- TUIs, utilities) and remove the Terminal.app
     float rule through 'omniwmctl rule' (idempotent)
  7  Ghostty config, Neovim files (+ 'nvim --headless +Lazy! install'), btop.conf (if
     staged), ~/.zshrc block (idempotent)
  8  omarchy-theme set "$(omarchy-theme current || echo tokyo-night)"
  9  omarchy-doctor --static

  --dry-run      print actions only. Read-only checks still run (syntax checks,
                 omarchy-keys check, generate into a temp dir with --diff).
  --build DIR    staging dir (default: the directory of this script)
  --skip-doctor  do not run step 9
  --sandbox      test mode for a FAKE \$HOME: real file operations under \$HOME, but skip
                 everything that touches the running system (hidutil, Hammerspoon reload,
                 karabiner_cli, OmniWM bar check + app rules, nvim plugin install, theme
                 apply, doctor). Refuses the real home.
Log: ~/.local/state/omarchy-mac/deploy.log
EOF
}

DRY=0
SANDBOX=0
SKIP_DOCTOR=0
BUILD=${0:A:h}
while (( $# )); do
  case $1 in
    --dry-run|-n) DRY=1 ;;
    --build) shift; BUILD=${1:A} ;;
    --skip-doctor) SKIP_DOCTOR=1 ;;
    --sandbox) SANDBOX=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "deploy.sh: unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

# ----------------------------------------------------------------------------- constants
OMNIWMCTL=/Applications/OmniWM.app/Contents/MacOS/omniwmctl
PY=/opt/homebrew/bin/python3; [[ -x $PY ]] || PY=/usr/bin/python3   # needs 3.11+ for the uv scripts' syntax
HS=/opt/homebrew/bin/hs
KCLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
[[ -x $KCLI ]] || KCLI=/Applications/Karabiner-Elements.app/Contents/Helpers/karabiner_cli
OM=$HOME/.config/omarchy-mac
OMB=$OM/bin
LBIN=$HOME/.local/bin
HSDIR=$HOME/.hammerspoon
OWDIR=$HOME/.config/omniwm
KJSON=$HOME/.config/karabiner/karabiner.json
STATE=$HOME/.local/state/omarchy-mac
LOG=$STATE/deploy.log
STAMP=$(/bin/date +%Y-%m-%d-%H%M%S)
BK=$OM/backup-$STAMP
ZMARK_BEGIN='# >>> omarchy-mac shell >>>'
ZMARK_END='# <<< omarchy-mac shell <<<'
STEP=preflight
GEN=""
LOCKDIR=$STATE/deploy.lock
HAVE_LOCK=0
LUAJIT=/opt/homebrew/bin/luajit

# ----------------------------------------------------------------------------- helpers
# hsq ARGS... - hs CLI with a hard wall-clock limit (hs -t alone does not stop a hung connect)
hsq() { /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' ${HSQ_TIMEOUT:-10} $HS -q -t 4 "$@"; }
say()  { print -r -- "$*"; (( DRY )) || print -r -- "$(/bin/date '+%F %T') $*" >>$LOG 2>/dev/null || true; }
step() { STEP=$1; shift; print; say "== [$STEP] $*"; }
warn() { print -u2 -r -- "WARN: $*"; (( DRY )) || print -r -- "$(/bin/date '+%F %T') WARN $*" >>$LOG 2>/dev/null || true; }
die()  {
  print -u2 -r -- "ERROR: $*"
  if (( ! DRY )) && [[ -n ${BK:-} && -f $BK/MANIFEST ]]; then
    print -u2 -r -- "!! deploy stopped in step [$STEP]. To undo: $BUILD/rollback.sh --backup $BK"
  fi
  exit 1
}

# lua_check FILE - compile FILE without running it. 0 = ok, 1 = syntax error (printed),
#   2 = no checker answered. Prefers Hammerspoon's own Lua 5.4 (hs -c loadfile); falls back
#   to luajit (Lua 5.1 syntax: a 5.4-only construct would be a false error, never a false ok).
LUA_VIA=""
lua_check() {
  local f=$1 out
  if [[ $LUA_VIA != luajit ]]; then
    if out=$(hsq -c "local f, e = loadfile('$f'); return f and 'ok' or e" 2>&1); then
      LUA_VIA=hs
      [[ $out == ok ]] && return 0
      print -u2 -r -- "lua: $f: $out"; return 1
    fi
    warn "hs CLI did not answer; Lua syntax checks use $LUAJIT (Lua 5.1 syntax)"
    LUA_VIA=luajit
  fi
  [[ -x $LUAJIT ]] || return 2
  out=$($LUAJIT -b $f /dev/null 2>&1) && return 0     # -b: compile to bytecode only, never runs the file
  print -u2 -r -- "lua(luajit): $f: $out"; return 1
}

# run CMD...  - execute (logged), or print in dry-run
run() {
  if (( DRY )); then
    print -r -- "   [dry-run] ${(j: :)${(q-)@}}"
  else
    print -r -- "$(/bin/date '+%F %T')    + ${(j: :)${(q-)@}}" >>$LOG
    "$@"
  fi
}

# sysrun CMD... - like run, but skipped in --sandbox (commands that touch the live system)
sysrun() {
  if (( SANDBOX )); then print -r -- "   [sandbox-skip] ${(j: :)${(q-)@}}"; return 0; fi
  run "$@"
}

# atomic_install SRC DST [MODE] - copy to a temp file next to DST, then rename over it
atomic_install() {
  local src=$1 dst=$2 mode=${3:-}
  local tmp=${dst:h}/.${dst:t}.omarchy-new.$$
  if (( DRY )); then
    print -r -- "   [dry-run] install ${src} -> ${dst}${mode:+ (mode $mode)} (temp + mv)"
    return
  fi
  /bin/mkdir -p -- ${dst:h}
  /bin/cp -p -- $src $tmp
  if [[ -n $mode ]]; then /bin/chmod $mode $tmp; fi
  /bin/mv -f -- $tmp $dst
  print -r -- "$(/bin/date '+%F %T')    installed $src -> $dst" >>$LOG
}

# backup TARGET NAME - copy TARGET into $BK/NAME and record it in the MANIFEST
#   kinds: file | dir | link (symlink, target recorded) | absent (rollback deletes it)
backup() {
  local target=$1 name=$2 kind
  if [[ -L $target ]]; then kind=link
  elif [[ -d $target ]]; then kind=dir
  elif [[ -e $target ]]; then kind=file
  else kind=absent
  fi
  if (( DRY )); then
    print -r -- "   [dry-run] backup ($kind) $target -> $BK/$name"
    return
  fi
  case $kind in
    link)   /bin/mkdir -p -- ${BK}/${name:h}; print -r -- "$(/usr/bin/readlink -- $target)" > $BK/$name.symlink ;;
    dir)    /bin/mkdir -p -- ${BK}/${name:h}; /bin/cp -pR -- $target $BK/$name ;;
    file)   /bin/mkdir -p -- ${BK}/${name:h}; /bin/cp -p -- $target $BK/$name ;;
  esac
  print -r -- "$kind	$target	$name" >> $BK/MANIFEST
}

on_err() {
  local rc=$?
  print -u2
  print -u2 -r -- "!! deploy FAILED in step [$STEP] (exit $rc)."
  if (( ! DRY )) && [[ -d $BK ]]; then
    print -u2 -r -- "!! Backup: $BK"
    print -u2 -r -- "!! To undo: $BUILD/rollback.sh --backup $BK"
  fi
}
cleanup() {
  if [[ -n $GEN && -d $GEN ]]; then /bin/rm -rf -- $GEN; fi
  # only the process that created the lock removes it
  if (( HAVE_LOCK )); then /bin/rmdir -- $LOCKDIR 2>/dev/null || true; fi
}
trap on_err ZERR
trap cleanup EXIT

export OMARCHY_PORTS_SRC=$BUILD/ports   # omarchy-keys: bundled port actions are valid bindings

# ----------------------------------------------------------------------------- preflight
(( DRY )) || /bin/mkdir -p -- $STATE     # before the first say/step: they append to $LOG
step preflight "build=$BUILD  dry-run=$DRY  sandbox=$SANDBOX"
if (( SANDBOX )); then
  real_home=$(/usr/bin/dscl . -read /Users/$(/usr/bin/id -un) NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -n $real_home && ${HOME:A} != ${real_home:A} ]] || die "--sandbox needs HOME pointing at a fake home"
fi
if (( ! DRY )); then
  /bin/mkdir -- $LOCKDIR 2>/dev/null || die "another deploy/rollback holds $LOCKDIR (remove it if stale)"
  HAVE_LOCK=1
fi

S_OM=$BUILD/omarchy-mac
S_GEN_HS_REL=hammerspoon/omarchy/generated/bindings.lua
missing=()
for f in $S_OM/bindings.toml $S_OM/bin/omarchy-keys $S_OM/bin/omarchy-wm $S_OM/bin/omarchy-omniwm-set \
         $S_OM/bin/omarchy-theme $S_OM/bin/omarchy-doctor $BUILD/hammerspoon/init.lua \
         $BUILD/hammerspoon/omarchy/core.lua $BUILD/hammerspoon/omarchy/actions.lua; do
  [[ -e $f ]] || missing+=$f
done
(( ${#missing} == 0 )) || { for f in $missing; do print -u2 "missing staged file: $f"; done; die "staging incomplete"; }
for app in /Applications/OmniWM.app /Applications/Hammerspoon.app /Applications/Karabiner-Elements.app; do
  [[ -d $app ]] || die "$app is not installed"
done
[[ -x $OMNIWMCTL ]] || die "omniwmctl missing: $OMNIWMCTL"
[[ -x $HS ]] || die "hs CLI missing: $HS"
$OMNIWMCTL ping >/dev/null 2>&1 || die "OmniWM is not answering 'omniwmctl ping' (start OmniWM first)"
/usr/bin/pgrep -x Hammerspoon >/dev/null || die "Hammerspoon is not running"
/usr/bin/pgrep -f Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service >/dev/null \
  || die "Karabiner-Core-Service is not running (Karabiner Settings > Setup)"

# syntax checks (read-only)
for f in $S_OM/bin/*(N.); do
  case $(/usr/bin/head -1 -- $f) in
    *uv\ run*|*python*) $PY -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' $f \
                          || die "python syntax error in $f" ;;
    *zsh*) /bin/zsh -n -- $f || die "zsh syntax error in $f" ;;
    *sh*)  /bin/sh -n -- $f || die "sh syntax error in $f" ;;
  esac
done
lua_errs=0
# (the generated bindings.lua is checked in step 2, right after it is regenerated)
for f in $BUILD/hammerspoon/init.lua $BUILD/hammerspoon/omarchy/**/*.lua(N.); do
  lua_check $f && continue
  case $? in
    1) lua_errs=$((lua_errs + 1)) ;;
    *) warn "no Lua checker (hs did not answer, $LUAJIT missing); Lua syntax check skipped"; break ;;
  esac
done
(( lua_errs == 0 )) || die "$lua_errs Lua file(s) do not compile"
# validate the STAGED bindings before anything live is touched (step 1 replaces bin/ and bindings.toml)
$S_OM/bin/omarchy-keys check --bindings $S_OM/bindings.toml || die "omarchy-keys check failed on the staged bindings.toml"
$PY -I -c 'import json,sys; json.load(open(sys.argv[1]))' $BUILD/generated/karabiner.json 2>/dev/null \
  || warn "build/generated/karabiner.json missing or invalid (step 2 regenerates anyway)"
if [[ -f $BUILD/ghostty/config ]]; then
  gout=$(/Applications/Ghostty.app/Contents/MacOS/ghostty +validate-config --config-file=$BUILD/ghostty/config 2>&1) \
    || die "staged Ghostty config invalid: $gout"
fi
say "preflight ok"

# ----------------------------------------------------------------------------- backup
step backup "-> $BK"
if (( ! DRY )); then
  [[ -e $BK ]] && die "$BK already exists"
  /bin/mkdir -p -- $BK
  print -r -- "# omarchy-mac deploy backup $STAMP  (kind<TAB>target<TAB>name)" > $BK/MANIFEST
  # predeployed=1: this backup holds an already-deployed Omarchy state (a re-deploy), so
  # rollback.sh's default search skips it in favour of the pre-Omarchy backup.
  print -r -- "# predeployed=$([[ -f $OM/bindings.toml || -f $HSDIR/omarchy/core.lua ]] && echo 1 || echo 0)" >> $BK/MANIFEST
  /usr/bin/hidutil property --get UserKeyMapping > $BK/hidutil-UserKeyMapping.txt 2>&1 || true
fi
backup $HSDIR                         hammerspoon
backup $OWDIR/settings.toml           omniwm/settings.toml
backup $OWDIR/shell                   omniwm/shell
backup $KJSON                         karabiner/karabiner.json
backup $HOME/.config/ghostty/config   ghostty/config
backup $HOME/.config/nvim/lua         nvim/lua
backup $OM/bin                        omarchy-mac/bin
backup $OM/templates                  omarchy-mac/templates
backup $OM/current                    omarchy-mac/current
backup $OM/bindings.toml              omarchy-mac/bindings.toml
backup $OM/KEYBINDINGS.md             omarchy-mac/KEYBINDINGS.md
if [[ -f $BUILD/btop/btop.conf ]]; then backup $HOME/.config/btop/btop.conf btop/btop.conf; fi
backup $HOME/.zshrc                   zshrc
for f in $S_OM/bin/*(N.); do
  backup $LBIN/${f:t} local-bin/${f:t}
done
(( DRY )) || say "backup written ($(/usr/bin/wc -l < $BK/MANIFEST | tr -d ' ') manifest lines)"

# ----------------------------------------------------------------------------- 1 omarchy-mac files
step 1 "bindings.toml, bin/*, templates/* -> $OM ; bins -> $LBIN"
run /bin/mkdir -p -- $OMB $OM/templates $LBIN
atomic_install $S_OM/bindings.toml $OM/bindings.toml 644
for f in $S_OM/bin/*(N.); do
  atomic_install $f $OMB/${f:t} 755
done
for f in $S_OM/templates/*(N.); do
  atomic_install $f $OM/templates/${f:t} 644
done
# omarchy-port converter: contract + Linux->macOS capability map (out/, specs/, state stay local)
run /bin/mkdir -p -- $OM/port
for f in $S_OM/port/*(N.); do
  atomic_install $f $OM/port/${f:t} 644
done
[[ -f $S_OM/CHEATSHEET.md ]] && atomic_install $S_OM/CHEATSHEET.md $OM/CHEATSHEET.md 644
# Omarchy shell settings for ports (idle timers default to off = macOS keeps its own); never overwrite
[[ -f $S_OM/shell.json && ! -f $OM/shell.json ]] && atomic_install $S_OM/shell.json $OM/shell.json 644
for f in $S_OM/bin/*(N.); do
  t=$LBIN/${f:t}
  if [[ -e $t && ! -L $t ]]; then run /bin/rm -f -- $t; fi   # regular file: backed up above
  run /bin/ln -sfn -- $OMB/${f:t} $t
done
# Karabiner and Hammerspoon run these with a minimal PATH: pin the uv shebang to an absolute path.
UVBIN=${commands[uv]:-$HOME/.local/bin/uv}
[[ -x $UVBIN ]] || UVBIN=/opt/homebrew/bin/uv
for f in $OMB/*(N.); do
  run /usr/bin/sed -i '' "1s|^#!/usr/bin/env -S [^ ]*uv run|#!/usr/bin/env -S $UVBIN run|" $f
done

# ----------------------------------------------------------------------------- 2 generate + OmniWM settings
# Interactive Bluetooth panel (omarchy-bluetooth widget) needs blueutil.
if (( ! SANDBOX )) && [[ ! -x /opt/homebrew/bin/blueutil ]]; then run /opt/homebrew/bin/brew install blueutil || warn "brew install blueutil failed; Bluetooth panel will say so"; fi

step 2 "omarchy-keys check/generate; install settings.toml"
GEN=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/omarchy-gen.XXXXXX")
if (( DRY )); then
  # Preview with the STAGED generator and bindings (reads live settings/karabiner, writes only $GEN).
  # (omarchy-keys check on the staged bindings already ran in preflight)
  $S_OM/bin/omarchy-keys generate --out $GEN --bindings $S_OM/bindings.toml --diff | /usr/bin/sed 's/^/   | /' \
    || die "omarchy-keys generate failed"
  KEYS=$S_OM/bin/omarchy-keys
else
  KEYS=$OMB/omarchy-keys
  run $KEYS check
  run $KEYS generate --out $GEN
fi
for f in settings.toml karabiner.json $S_GEN_HS_REL KEYBINDINGS.md; do
  [[ -s $GEN/$f ]] || die "generator did not write $f"
done
# the freshly generated bindings.lua is what step 3 installs: compile it first
if lua_check $GEN/$S_GEN_HS_REL; then say "generated bindings.lua compiles ($LUA_VIA)"
else
  case $? in
    1) die "generated bindings.lua does not compile" ;;
    *) warn "no Lua checker answered; generated bindings.lua not syntax-checked" ;;
  esac
fi
run $OMB/omarchy-omniwm-set --install $GEN/settings.toml
atomic_install $GEN/KEYBINDINGS.md $OM/KEYBINDINGS.md 644

# ----------------------------------------------------------------------------- 3 Hammerspoon
step 3 "replace ~/.hammerspoon/omarchy + init.lua; reload Hammerspoon"
NEWHS=$HSDIR/.omarchy.new.$$
run /bin/rm -rf -- $NEWHS
run /bin/mkdir -p -- $NEWHS/generated
run /usr/bin/rsync -a --exclude '.DS_Store' --exclude 'generated/' -- $BUILD/hammerspoon/omarchy/ $NEWHS/
run /bin/cp -p -- $GEN/$S_GEN_HS_REL $NEWHS/generated/bindings.lua
# omarchy-port ports: keep the ones already installed, then add/refresh those bundled in ports/
run /bin/mkdir -p -- $NEWHS/ports
[[ -d $HSDIR/omarchy/ports ]] && run /usr/bin/rsync -a -- $HSDIR/omarchy/ports/ $NEWHS/ports/
for f in $BUILD/ports/*/hammerspoon/*.lua(N.); do
  run /bin/cp -p -- $f $NEWHS/ports/${f:t}
done
if [[ -d $HSDIR/omarchy ]]; then
  run /bin/mv -- $HSDIR/omarchy $BK/hammerspoon-omarchy.replaced
fi
run /bin/mv -- $NEWHS $HSDIR/omarchy
atomic_install $BUILD/hammerspoon/init.lua $HSDIR/init.lua 644
# Deferred reload: hs -c returns before the Lua state is torn down, so the CLI never
# sees its port die mid-conversation (that is what triggered the hs.ipc recursion flood).
sysrun hsq -c '_G.__omarchy_deploy_reload = hs.timer.doAfter(0.5, hs.reload); return "reload scheduled"' \
  || warn "hs -c reload request failed; reload Hammerspoon from its menu bar icon"
if (( ! DRY && ! SANDBOX )); then
  for i in {1..40}; do       # up to ~10 s for the new config to answer
    /bin/sleep 0.25
    out=$(HSQ_TIMEOUT=4 hsq -c 'return (package.loaded["omarchy.core"] and "new") or "old"' 2>/dev/null) || continue
    [[ $out == new ]] && break
  done
  if [[ ${out:-} == new ]]; then say "Hammerspoon reloaded with the new config"
  else warn "Hammerspoon did not report the new config yet (check ~/.local/state/omarchy-mac/hs.log)"; fi
fi

# ----------------------------------------------------------------------------- 4 hidutil
step 4 "clear hidutil UserKeyMapping (Caps->F18)"
sysrun /usr/bin/hidutil property --set '{"UserKeyMapping":[]}'

# ----------------------------------------------------------------------------- 5 Karabiner
step 5 "install karabiner.json (atomic mv)"
run /bin/mkdir -p -- ${KJSON:h}
atomic_install $GEN/karabiner.json $KJSON 600
if (( ! DRY && ! SANDBOX )); then
  CUL=$HOME/.local/share/karabiner/log/console_user_server.log
  t0=$(/bin/date +%s)
  loaded=0
  for i in {1..20}; do
    /bin/sleep 0.25
    last=$(/usr/bin/grep -n 'karabiner.json' $CUL 2>/dev/null | /usr/bin/tail -1) || true
    lts=${${last#*\[}%%\]*}; lts=${lts%%.*}
    if [[ -n $lts ]] && (( $(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$lts" +%s 2>/dev/null || echo 0) >= t0 - 1 )); then
      loaded=1; break
    fi
  done
  if (( loaded )); then say "Karabiner reloaded karabiner.json"; else warn "no fresh 'Load karabiner.json' line yet in $CUL"; fi
  cur=$("$KCLI" --show-current-profile-name 2>/dev/null || true)
  if [[ $cur != Omarchy ]]; then
    run "$KCLI" --select-profile Omarchy
  fi
fi

# ----------------------------------------------------------------------------- 6 OmniShell bar
step 6 "omniwm-shell -> $OWDIR/shell (widgets first, then shell.toml) ; bar check ; app rules"
# Bar report: the three omarchy-* widget folders must be in place BEFORE shell.toml names them
# (a plain rsync writes shell.toml first: 's' < 'w'). OmniWM live-reloads shell.toml itself;
# no 'omniwmctl shell init|eject|profile|theme' call is needed (omarchy-theme in step 8 runs
# 'shell theme omarchy'). The global [workspaceBar] values came with settings.toml in step 2.
if [[ -d $BUILD/omniwm-shell ]]; then
  run /bin/mkdir -p -- $OWDIR/shell
  run /usr/bin/rsync -a --exclude '.DS_Store' --exclude '/shell.toml' -- $BUILD/omniwm-shell/ $OWDIR/shell/
  for w in $BUILD/ports/*/widget/omarchy-*(N/); do    # bar widgets of bundled ports
    run /usr/bin/rsync -a --exclude '.DS_Store' -- $w/ $OWDIR/shell/widgets/${w:t}/
  done
  if [[ -f $BUILD/omniwm-shell/shell.toml ]]; then
    atomic_install $BUILD/omniwm-shell/shell.toml $OWDIR/shell/shell.toml 644
  fi
fi
bar_commands() {
  # No state-changing shell commands are needed (bar report, cutover notes 2-5). Wait up to
  # ~6 s for OmniWM to reload shell.toml, then require problems == [] and the three omarchy-*
  # widgets 'loaded'. Read-only.
  if (( DRY )); then
    print -r -- "   [dry-run] wait for 'omniwmctl query shell-widgets': problems [] and omarchy-logo, omarchy-workspaces, omarchy-clock loaded"
    return 0
  fi
  local res="" i
  for i in {1..24}; do
    /bin/sleep 0.25
    res=$($OMNIWMCTL query shell-widgets --format json 2>/dev/null | $PY -I -c '
import json, sys
p = json.load(sys.stdin)["result"]["payload"]
want = {"omarchy-logo", "omarchy-workspaces", "omarchy-clock"}
st = {w.get("name"): w.get("state") for w in p.get("widgets") or []}
probs = p.get("problems") or []
missing = sorted(n for n in want if st.get(n) != "loaded")
print("ok" if not probs and not missing else
      "problems=%d not-loaded=%s" % (len(probs), ",".join(missing) or "-"))' 2>/dev/null) || res="query failed"
    [[ $res == ok ]] && break
  done
  if [[ $res == ok ]]; then say "OmniShell: no widget problems; omarchy-logo/workspaces/clock loaded"
  else warn "OmniShell: $res (omniwmctl query shell-widgets; /usr/bin/log show --last 5m --predicate 'process == \"OmniWM\" AND category == \"shell\"')"; fi
}
if (( SANDBOX )); then say "   [sandbox-skip] bar_commands"; else bar_commands; fi

# App rules (architect.md 'App rules'), through omniwmctl rule (OmniWM writes [[appRules]] into
# settings.toml itself; rollback restores the pre-deploy settings.toml, rules included).
# Idempotent: rules that already exist are left alone. Citrix Viewer is deliberately NOT
# floated: the user chose to tile the EMR session (2026-11-23).
# Format: bundle-id<TAB>title-regex ('' = none). 1Password is not installed: not listed.
APP_FLOAT_RULES=(
  # Omarchy tiles almost everything (user, 2026-11-23). Only fixed-size or transient windows float;
  # Wispr Flow / iPhone Mirroring / Calculator float via the user's own pre-existing rules.
  "com.citrix.AuthManagerMac	"
  "com.citrix.receiver.nomas	"
  "com.apple.archiveutility	"
  "org.p0deje.Maccy	"
)
app_rules() {
  local plan line op a b
  plan=$($OMNIWMCTL query rules --format json 2>/dev/null | $PY -I -c '
import json, sys
rules = json.load(sys.stdin)["result"]["payload"].get("rules") or []
want = [l.split("\t", 1) for l in sys.argv[1:]]
def matchers(r):
    return {k: r.get(k) for k in ("appNameSubstring", "titleSubstring", "axRole", "axSubrole") if r.get(k)}
for bundle, regex in want:
    same = [r for r in rules if r.get("bundleId") == bundle and (r.get("titleRegex") or "") == regex
            and not matchers(r)]
    if any(r.get("layout") == "float" for r in same):
        print("have\t%s\t%s" % (bundle, regex)); continue
    if same and not regex:
        print("warn\t%s\tan existing non-float rule for this app comes first; fix it in OmniWM > App Rules" % bundle)
    print("add\t%s\t%s" % (bundle, regex))
# Terminal.app float rule is KEPT (OmniWM metrics: ~90% of its AX writes fail when tiled)
for r in []:
    if r.get("bundleId") == "com.apple.Terminal" and r.get("layout") == "float" and not r.get("titleRegex") \
            and not matchers(r):
        print("remove\t%s\tcom.apple.Terminal" % r.get("id"))
' "${APP_FLOAT_RULES[@]}") || plan=""
  if [[ -z $plan ]]; then warn "could not read 'omniwmctl query rules'; app rules NOT changed"; return 0; fi
  while IFS=$'\t' read -r op a b; do
    case $op in
      have)   say "   rule ok: $a${b:+ title~$b} floats" ;;
      warn)   warn "rule $a: $b" ;;
      add)    if [[ -n $b ]]; then run $OMNIWMCTL rule add --bundle-id $a --title-regex $b --layout float \
                || warn "rule add failed: $a title~$b"
              else run $OMNIWMCTL rule add --bundle-id $a --layout float || warn "rule add failed: $a"; fi ;;
      remove) run $OMNIWMCTL rule remove $a || warn "rule remove failed: $a ($b)" ;;
    esac
  done <<< "$plan"
}
if (( SANDBOX )); then say "   [sandbox-skip] app_rules"; else app_rules; fi

# ----------------------------------------------------------------------------- 7 Ghostty / Neovim / btop / zsh
step 7 "Ghostty config, Neovim, btop, ~/.zshrc block"
if [[ -f $BUILD/ghostty/config ]]; then atomic_install $BUILD/ghostty/config $HOME/.config/ghostty/config 644; fi
if [[ -d $BUILD/nvim ]]; then
  run /bin/mkdir -p -- $HOME/.config/nvim
  run /usr/bin/rsync -a --exclude '.DS_Store' -- $BUILD/nvim/ $HOME/.config/nvim/
  # Theme report: preinstall every colorscheme plugin once (needs the network), so a theme
  # switch never starts Neovim on a missing plugin. Non-fatal; hard 300 s limit.
  NVIM=/opt/homebrew/bin/nvim
  if [[ -x $NVIM ]]; then
    sysrun /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' 300 $NVIM --headless '+Lazy! install' +qa \
      || warn "nvim '+Lazy! install' failed (offline?). Run later: nvim --headless '+Lazy! install' +qa"
  else
    warn "$NVIM not found; Neovim theme plugins not preinstalled"
  fi
fi
if [[ -f $BUILD/btop/btop.conf ]]; then atomic_install $BUILD/btop/btop.conf $HOME/.config/btop/btop.conf 644; fi
if [[ -f $BUILD/zshrc.snippet ]]; then
  if (( DRY )); then
    if /usr/bin/grep -qF -- $ZMARK_BEGIN $HOME/.zshrc 2>/dev/null; then
      print -r -- "   [dry-run] replace the existing '$ZMARK_BEGIN' block in ~/.zshrc"
    else
      print -r -- "   [dry-run] append zshrc.snippet ($(/usr/bin/wc -l < $BUILD/zshrc.snippet | tr -d ' ') lines) to ~/.zshrc"
    fi
  else
    ztmp=$HOME/.zshrc.omarchy-new.$$
    # drop any previous block (idempotent), then append the snippet (which carries the markers)
    /usr/bin/awk -v b="$ZMARK_BEGIN" -v e="$ZMARK_END" '
      $0 == b {skip=1; next}  $0 == e {skip=0; next}  !skip' $HOME/.zshrc > $ztmp 2>/dev/null || : > $ztmp
    if [[ -s $ztmp && $(/usr/bin/tail -c1 $ztmp | /usr/bin/xxd -p) != 0a ]]; then print >> $ztmp; fi
    /usr/bin/grep -qF -- $ZMARK_BEGIN $BUILD/zshrc.snippet || print -r -- $ZMARK_BEGIN >> $ztmp
    /bin/cat $BUILD/zshrc.snippet >> $ztmp
    /usr/bin/grep -qF -- $ZMARK_END $BUILD/zshrc.snippet || print -r -- $ZMARK_END >> $ztmp
    /bin/zsh -n $ztmp || { /bin/rm -f $ztmp; die "new ~/.zshrc does not parse; left unchanged"; }
    zdst=${${:-$HOME/.zshrc}:A}      # follow a symlinked ~/.zshrc
    /bin/chmod 644 $ztmp; /bin/mv -f -- $ztmp $zdst
    say "~/.zshrc: omarchy-mac block installed"
  fi
fi

# ----------------------------------------------------------------------------- 8 theme
step 8 "re-apply the current theme"
THEME=$($OMB/omarchy-theme current 2>/dev/null || /bin/cat $OM/current/theme.name 2>/dev/null || echo tokyo-night)
THEME=${THEME:-tokyo-night}
sysrun $OMB/omarchy-theme set $THEME

# ----------------------------------------------------------------------------- 9 doctor
step 9 "omarchy-doctor --static"
if (( SKIP_DOCTOR || SANDBOX )); then
  say "skipped (--skip-doctor or --sandbox)"
elif (( DRY )); then
  print -r -- "   [dry-run] $OMB/omarchy-doctor --static"
else
  /bin/sleep 1
  if $OMB/omarchy-doctor --static; then dr=0; else dr=$?; fi
  say "omarchy-doctor exit $dr"
fi

STEP=done
print
if (( DRY )); then
  say "DRY RUN complete: nothing was changed."
else
  say "Deploy complete. Backup: $BK   Undo: $BUILD/rollback.sh --backup $BK"
  say "Next: omarchy-doctor --interactive (then --secure-input); user steps are in architect.md section 4."
fi
