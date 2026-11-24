#!/bin/zsh
# SUDO_ASKPASS helper: Homebrew runs `sudo -A` (for Karabiner's keyboard driver) and sudo asks here.
/usr/bin/osascript <<'OSA'
set r to display dialog "Marchy is installing Karabiner-Elements' keyboard driver with Homebrew. Enter your Mac password to allow it." with title "Marchy" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution
return text returned of r
OSA
