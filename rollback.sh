#!/bin/zsh
# rollback.sh - undo deploy.sh: restore the most recent PRE-Omarchy deploy backup and, when
# that brings back the old Hammerspoon super.lua, put Karabiner back on the old Caps Lock ->
# F18 simple modification (super.lua then re-applies its own hidutil mapping when it loads).
set -eu
setopt pipefail no_nomatch

usage() {
  cat <<'EOF'
Usage: rollback.sh [--dry-run] [--backup DIR] [--no-reload] [-h|--help]

Restores every target listed in DIR/MANIFEST (written by deploy.sh):
  file / dir  -> copied back (temp + rename for files; dirs swapped via a temp dir)
  link        -> symlink re-created with its old target
  absent      -> the file deploy.sh created is removed
~/.zshrc is not overwritten: only the '# >>> omarchy-mac shell >>>' block is removed
(the full old copy stays in DIR/zshrc).
Then: OmniWM settings.toml restored atomically + 'omniwmctl ping'; karabiner.json
restored from the backup; if the backup lacks the Caps->F18 simple modification AND the
restored ~/.hammerspoon has the old omarchy/super.lua (which listens for F18), it is reset
to Caps->F18 instead; Hammerspoon reloaded (deferred hs.reload via hs -c).

  --backup DIR   backup to restore. Default: the newest ~/.config/omarchy-mac/backup-YYYY-MM-DD-HHMMSS
                 with a MANIFEST that is NOT 'predeployed' (i.e. taken before Omarchy was first
                 deployed; a re-deploy's backup only holds the previous Omarchy state). Falls back
                 to the newest backup, with a warning, when every backup is predeployed.
  --dry-run      print actions only
  --no-reload    do not reload Hammerspoon (for tests against a fake \$HOME)
Log: ~/.local/state/omarchy-mac/deploy.log

Not reverted (outside the backed-up paths; harmless leftovers of deploy step 8, theme):
  ~/.config/btop/themes/omarchy.theme, ~/.config/herdr-app/themes/omarchy.json,
  the desktop wallpaper and the macOS light/dark appearance.
EOF
}

DRY=0
NORELOAD=0
BK=""
while (( $# )); do
  case $1 in
    --dry-run|-n) DRY=1 ;;
    --no-reload) NORELOAD=1 ;;
    --backup) shift; BK=${1:A} ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "rollback.sh: unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

OM=$HOME/.config/omarchy-mac
OMNIWMCTL=/Applications/OmniWM.app/Contents/MacOS/omniwmctl
PY=/opt/homebrew/bin/python3; [[ -x $PY ]] || PY=/usr/bin/python3   # needs 3.11+ for the uv scripts' syntax
HS=/opt/homebrew/bin/hs
KJSON=$HOME/.config/karabiner/karabiner.json
STATE=$HOME/.local/state/omarchy-mac
LOG=$STATE/deploy.log
LOCKDIR=$STATE/deploy.lock
HAVE_LOCK=0
ZMARK_BEGIN='# >>> omarchy-mac shell >>>'
ZMARK_END='# <<< omarchy-mac shell <<<'

# hsq ARGS... - hs CLI with a hard wall-clock limit (hs -t alone does not stop a hung connect)
hsq() { /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' ${HSQ_TIMEOUT:-10} $HS -q -t 4 "$@"; }
say()  { print -r -- "$*"; (( DRY )) || print -r -- "$(/bin/date '+%F %T') rollback: $*" >>$LOG 2>/dev/null || true; }
warn() { print -u2 -r -- "WARN: $*"; (( DRY )) || print -r -- "$(/bin/date '+%F %T') rollback WARN $*" >>$LOG 2>/dev/null || true; }
die()  { print -u2 -r -- "ERROR: $*"; exit 1; }
run() {
  if (( DRY )); then print -r -- "   [dry-run] ${(j: :)${(q-)@}}"
  else print -r -- "$(/bin/date '+%F %T')    rollback + ${(j: :)${(q-)@}}" >>$LOG; "$@"; fi
}
cleanup() { if (( HAVE_LOCK )); then /bin/rmdir -- $LOCKDIR 2>/dev/null || true; fi; }   # only our own lock
trap cleanup EXIT
(( DRY )) || /bin/mkdir -p -- $STATE     # before the first say: it appends to $LOG

# predeployed BACKUPDIR - true if the backup holds an already-deployed Omarchy state.
# deploy.sh records '# predeployed=0|1'; older backups without the line are judged by content.
predeployed() {
  local m=$1/MANIFEST
  /usr/bin/grep -qx -- '# predeployed=1' $m && return 0
  /usr/bin/grep -qx -- '# predeployed=0' $m && return 1
  [[ -f $1/hammerspoon/omarchy/core.lua || -f $1/omarchy-mac/bindings.toml ]]
}
if [[ -z $BK ]]; then
  newest=""
  for d in $OM/backup-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9](N/On); do
    [[ -f $d/MANIFEST ]] || continue
    [[ -n $newest ]] || newest=$d
    if predeployed $d; then say "skip   $d (predeployed: holds an earlier Omarchy deploy)"; continue; fi
    BK=$d; break
  done
  if [[ -z $BK && -n $newest ]]; then
    BK=$newest
    warn "every deploy backup is predeployed; using the newest ($BK). This restores the previous Omarchy state, not the pre-Omarchy setup."
  fi
fi
[[ -n $BK && -f $BK/MANIFEST ]] || die "no deploy backup with a MANIFEST found (use --backup DIR)"
say "restoring from $BK  (dry-run=$DRY)"
if (( ! DRY )); then
  /bin/mkdir -- $LOCKDIR 2>/dev/null || die "another deploy/rollback holds $LOCKDIR (remove it if stale)"
  HAVE_LOCK=1
fi

restore_file() {   # src dst : temp file next to dst, then rename
  local src=$1 dst=$2 tmp=${2:h}/.${2:t}.omarchy-rollback.$$
  run /bin/mkdir -p -- ${dst:h}
  run /bin/cp -p -- $src $tmp
  run /bin/mv -f -- $tmp $dst
}
restore_dir() {    # src dst : copy to a sibling temp dir, then swap
  local src=$1 dst=$2 tmp=${2:h}/.${2:t}.omarchy-rollback.$$ old=${2:h}/.${2:t}.omarchy-old.$$
  run /bin/mkdir -p -- ${dst:h}
  run /bin/rm -rf -- $tmp
  run /bin/cp -pR -- $src $tmp
  if [[ -e $dst || -L $dst ]]; then run /bin/mv -- $dst $old; fi
  run /bin/mv -- $tmp $dst
  run /bin/rm -rf -- $old
}

# --- generic MANIFEST restore (OmniWM settings, Karabiner and zshrc get special handling below)
SETTINGS_SRC="" KARABINER_SRC="" KARABINER_KIND="" HS_SRC=""
while IFS=$'\t' read -r kind target name; do
  [[ -z $kind || $kind == \#* ]] && continue
  case $target in
    $HOME/.config/omniwm/settings.toml) SETTINGS_SRC=$BK/$name; [[ $kind == file ]] || SETTINGS_SRC=""; continue ;;
    $KJSON) KARABINER_SRC=$BK/$name; KARABINER_KIND=$kind; continue ;;
    $HOME/.zshrc) continue ;;
    $HOME/.hammerspoon) if [[ $kind == dir ]]; then HS_SRC=$BK/$name; fi ;;   # restored generically below
  esac
  case $kind in
    file)   say "file   $target"; restore_file $BK/$name $target ;;
    dir)    say "dir    $target"; restore_dir $BK/$name $target ;;
    link)   say "link   $target -> $(<$BK/$name.symlink)"; run /bin/ln -sfn -- "$(<$BK/$name.symlink)" $target ;;
    absent) if [[ -e $target || -L $target ]]; then say "remove $target (created by deploy)"; run /bin/rm -rf -- $target; fi ;;
    *) warn "unknown manifest kind '$kind' for $target" ;;
  esac
done < $BK/MANIFEST

# --- ~/.zshrc: remove only the marked block
if [[ -f $HOME/.zshrc ]] && /usr/bin/grep -qF -- $ZMARK_BEGIN $HOME/.zshrc; then
  say "zshrc  remove '$ZMARK_BEGIN' block"
  if (( ! DRY )); then
    zdst=${${:-$HOME/.zshrc}:A}
    ztmp=${zdst:h}/.zshrc.omarchy-rollback.$$
    /usr/bin/awk -v b="$ZMARK_BEGIN" -v e="$ZMARK_END" '$0 == b {skip=1; next} $0 == e {skip=0; next} !skip' $zdst > $ztmp
    /bin/chmod 644 $ztmp; /bin/mv -f -- $ztmp $zdst
  fi
fi

# --- OmniWM settings.toml (atomic, then ping)
if [[ -n $SETTINGS_SRC && -f $SETTINGS_SRC ]]; then
  say "file   ~/.config/omniwm/settings.toml (atomic) + ping"
  restore_file $SETTINGS_SRC $HOME/.config/omniwm/settings.toml
  if (( ! DRY )); then
    /bin/sleep 1
    $OMNIWMCTL ping >/dev/null 2>&1 && say "OmniWM answers ping" || warn "OmniWM does not answer ping"
  fi
else
  warn "no settings.toml in backup; OmniWM settings left as they are"
fi

# --- Karabiner: restore, and guarantee the old caps_lock -> f18 simple modification
OLD_KARABINER='{
    "profiles": [
        {
            "name": "Default profile",
            "selected": true,
            "simple_modifications": [
                { "from": { "key_code": "caps_lock" }, "to": [{ "key_code": "f18" }] }
            ],
            "virtual_hid_keyboard": { "keyboard_type_v2": "ansi" }
        }
    ]
}'
has_f18() {
  $PY -I -c '
import json, sys
c = json.load(open(sys.argv[1]))
p = next((p for p in c.get("profiles", []) if p.get("selected")), {})
ok = any((m.get("from") or {}).get("key_code") == "caps_lock" and
         any(t.get("key_code") == "f18" for t in m.get("to") or []) for m in p.get("simple_modifications") or [])
sys.exit(0 if ok else 1)' $1 2>/dev/null
}
# Caps->F18 is only right when the restored Hammerspoon is the OLD one (super.lua handles F18).
# Checked in the backup copy, which is what was just restored (and works in --dry-run too).
OLD_HS=0
if [[ -n $HS_SRC && -f $HS_SRC/omarchy/super.lua ]]; then OLD_HS=1; fi
KTMP=${KJSON:h}/.karabiner.json.omarchy-rollback.$$
KMODE=""
if [[ $KARABINER_KIND == file && -f $KARABINER_SRC ]] && has_f18 $KARABINER_SRC; then
  KMODE=backup; say "file   $KJSON (backup has caps_lock -> f18)"
elif (( OLD_HS )); then
  KMODE=f18; say "file   $KJSON (reset to the old caps_lock -> f18 simple modification for super.lua)"
elif [[ $KARABINER_KIND == file && -f $KARABINER_SRC ]]; then
  KMODE=backup; say "file   $KJSON (restored as-is: the restored Hammerspoon has no super.lua, so no Caps->F18)"
elif [[ $KARABINER_KIND == absent ]]; then
  KMODE=absent
  if [[ -e $KJSON ]]; then say "remove $KJSON (absent in the backup)"; run /bin/rm -f -- $KJSON; fi
else
  KMODE=keep; warn "karabiner.json: no usable copy in the backup and no super.lua; left as it is"
fi
if [[ $KMODE == backup || $KMODE == f18 ]]; then
  run /bin/mkdir -p -- ${KJSON:h}
  if [[ $KMODE == backup ]]; then run /bin/cp -p -- $KARABINER_SRC $KTMP
  elif (( DRY )); then print -r -- "   [dry-run] write default profile with caps_lock -> f18 to $KTMP"
  else print -r -- $OLD_KARABINER > $KTMP; fi
  run /bin/chmod 600 $KTMP
  run /bin/mv -f -- $KTMP $KJSON
fi

# --- Hammerspoon: reload the restored (old) config; deferred so hs -c returns first
if (( NORELOAD )); then
  say "Hammerspoon reload skipped (--no-reload)"
elif /usr/bin/pgrep -x Hammerspoon >/dev/null; then
  run hsq -c '_G.__omarchy_rollback_reload = hs.timer.doAfter(0.5, hs.reload); return "reload scheduled"' \
    || warn "hs -c failed; reload Hammerspoon from its menu bar icon"
else
  warn "Hammerspoon is not running; start it to load the restored config"
fi

if (( OLD_HS )); then
  say "rollback complete from $BK. The old super.lua re-applies the hidutil Caps->F18 mapping on load."
  say "Check: hidutil property --get UserKeyMapping ; Karabiner should show 'Default profile'."
else
  say "rollback complete from $BK (an Omarchy-era state: Karabiner keeps its Caps rules, hidutil untouched)."
  say "Check: omarchy-doctor --static"
fi
