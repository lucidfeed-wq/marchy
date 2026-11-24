#!/bin/zsh
# omarchy-mac bootstrap: turn a Mac into an Omarchy-style desktop.
#
#   git clone https://github.com/<you>/omarchy-mac ~/omarchy-mac && ~/omarchy-mac/bootstrap.sh
#
# What it does (asks before anything that needs your password):
#   1. Checks for Apple Silicon + macOS 26 or newer, and Homebrew.
#   2. Installs the stack with Homebrew: OmniWM (tiling + bar), Karabiner-Elements (Caps Lock =
#      Super), Hammerspoon (shortcuts, menu, pickers), Ghostty, Maccy, JetBrainsMono Nerd Font and
#      the terminal tools (neovim, btop, lazygit, eza, fzf, zoxide, starship, uv, luajit, blueutil).
#   3. Fetches Omarchy's official themes (MIT) from the Omarchy repo release.
#   4. Runs deploy.sh: backs up your current config, installs everything, generates the
#      keybindings for Karabiner/OmniWM/Hammerspoon, applies a theme and runs omarchy-doctor.
#   5. Tells you which macOS permissions to approve.
#
# Flags: --dry-run (show what would happen)   --no-brew (skip Homebrew installs)
#        --theme <name> (default tokyo-night) --omarchy-tag <tag> (default v4.5.0)
set -euo pipefail

HERE=${0:A:h}
DRY=0 BREW=1 THEME=tokyo-night TAG=v4.5.0
while (( $# )); do
  case $1 in
    --dry-run) DRY=1 ;;
    --no-brew) BREW=0 ;;
    --theme) THEME=$2; shift ;;
    --omarchy-tag) TAG=$2; shift ;;
    -h|--help) sed -n '2,20p' $0; exit 0 ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
  shift
done

say()  { print -P "%F{blue}==>%f $*"; }
warn() { print -P "%F{yellow}warning:%f $*"; }
die()  { print -P "%F{red}error:%f $*" >&2; exit 1; }
run()  { if (( DRY )); then print "   [dry-run] $*"; else "$@"; fi; }

# ----------------------------------------------------------------------------- 1. checks
say "Checking this Mac"
[[ $(uname -m) == arm64 ]] || die "Apple Silicon is required (OmniWM is arm64-only)"
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || die "macOS 26 or newer is required (OmniWM 0.8); this is $(sw_vers -productVersion)"
BREWBIN=/opt/homebrew/bin/brew
[[ -x $BREWBIN ]] || die "Homebrew is required: https://brew.sh"
eval "$($BREWBIN shellenv)"

# ----------------------------------------------------------------------------- 2. packages
CASKS=(omniwm karabiner-elements hammerspoon ghostty maccy font-jetbrains-mono-nerd-font)
FORMULAE=(uv luajit blueutil neovim btop lazygit eza fzf zoxide starship bat fd ripgrep fastfetch git)
if (( BREW )); then
  say "Installing Homebrew packages (Karabiner's installer asks for your password once)"
  for c in $CASKS; do
    if brew list --cask $c >/dev/null 2>&1; then print "   have $c"; else run brew install --cask $c; fi
  done
  missing=()
  for f in $FORMULAE; do brew list --formula $f >/dev/null 2>&1 || missing+=$f; done
  (( ${#missing} )) && run brew install $missing || print "   have all formulae"
fi
command -v uv >/dev/null || die "uv is missing (brew install uv)"

# ----------------------------------------------------------------------------- 3. themes
THEMES=$HOME/.config/omarchy-mac/themes
UP=$HOME/.local/share/omarchy-mac/upstream
if [[ ! -d $THEMES ]] || [[ -z $(ls -A $THEMES 2>/dev/null) ]]; then
  say "Fetching Omarchy $TAG themes"
  if [[ ! -d $UP/$TAG ]]; then
    run mkdir -p $UP
    run git clone -q --depth 1 --branch $TAG https://github.com/basecamp/omarchy $UP/$TAG
  fi
  run ln -sfn $UP/$TAG $UP/current
  run mkdir -p $THEMES
  if (( ! DRY )); then
    for t in $UP/$TAG/themes/*(/); do cp -R $t $THEMES/; done
    [[ -f $UP/$TAG/LICENSE ]] && cp $UP/$TAG/LICENSE $THEMES/LICENSE-omarchy
  fi
  print "   $(ls $THEMES 2>/dev/null | wc -l | tr -d ' ') themes"
else
  print "   themes already present ($THEMES)"
fi

# ----------------------------------------------------------------------------- 4. launch the apps once
say "Starting OmniWM, Hammerspoon and Karabiner-Elements"
for app in OmniWM Hammerspoon Karabiner-Elements; do run open -g -a $app || warn "could not start $app"; done
(( DRY )) || sleep 4

# ----------------------------------------------------------------------------- 5. deploy
say "Installing the Omarchy layer (deploy.sh backs up your current config first)"
if (( DRY )); then
  $HERE/deploy.sh --dry-run
else
  $HERE/deploy.sh
  run $HOME/.config/omarchy-mac/bin/omarchy-theme set $THEME || warn "theme $THEME failed"
fi

# ----------------------------------------------------------------------------- 6. permissions
cat <<'EOF'

Almost done. Approve these once in System Settings, then log out and back in:

  Privacy & Security > Accessibility     : OmniWM, Hammerspoon
  Privacy & Security > Input Monitoring  : OmniWM, Karabiner-Core-Service
  General > Login Items & Extensions     : turn on OmniWM, Hammerspoon, Maccy;
                                           Driver Extensions: Karabiner-DriverKit-VirtualHIDDevice
  Privacy & Security > Location Services : Hammerspoon (Wi-Fi network names in the bar)

Then check everything:   omarchy-doctor --static
Test your real keys:      omarchy-doctor --interactive
Hold Caps Lock = Super. Super+K lists every shortcut, Super+Space opens the menu.
EOF
