#!/usr/bin/env bash
#
# steam-start.sh - launch Steam scaled for a 4K display at scale 1.
#
# Not on PATH, by omission rather than accident: this script is in no tier in
# nix/nlscripts.nix, so nothing links it into ~/.local/bin and it has to be run
# by its full path. The app menu starts /usr/games/steam directly and always
# has - Steam owns ~/.local/share/applications/steam.desktop (it is a symlink
# into ~/.steam/debian-installation/deb-installer/), so there is no override
# there to carry the scaling. The flag below therefore applies only to Steam
# started from this script.
#
# -forcedesktopscaling rather than GDK_SCALE: Steam's client UI is CEF/VGUI,
# which GDK_SCALE does not reach - it scales only the GTK bootstrap dialogs.
# That is why the GDK_SCALE=2 this script used to set looked like it scaled
# Steam and did not.
#
# Two things were dropped as dead when this was rewritten:
#
#   psk "/compton/"                          - compton was replaced by picom
#     long ago, and picom is X11-only, so under Hyprland there is no compositor
#     of that lineage running to kill.
#
#   sudo sysctl dev.i915.perf_stream_paranoid=0  - an Intel iGPU perf-counter
#     knob, carried over from a laptop. This host is NVIDIA; it never applied.

exec /usr/games/steam -forcedesktopscaling 2 "$@"
