#!/usr/bin/env bash
# switch_dynamic_workspace_hypr.sh
#
# Hyprland counterpart of switch_dynamic_workspace.sh (i3). Maps a 1-9 keypress
# onto the workspace set belonging to whichever monitor currently has focus:
# 1-9 on DP-2, 11-19 on DP-1. See ~/.config/hypr/hosts/asterix.conf for the
# workspace-to-monitor bindings this mirrors.
#
# Argument $1 is the key number (1-9), "next"/"prev" for a relative switch, or
#   "@<num>" for an already-absolute workspace number (the quickshell bar's
#   workspace pills know the real number and need no mapping)
# Argument $2 is "move" to send the focused window instead of following it
#
# WHY THIS EXISTS RATHER THAN A PORT OF switch_dynamic_workspace_sway.sh:
# that script branches on the focused output being "DP-0", which is the X11/i3
# connector name. Sway and Hyprland both call that head "DP-1", so under sway
# the branch never matched, every keypress fell through to the 1-9 set, and the
# 11-19 workspaces were unreachable by keybinding. The name is corrected here.
# (The i3 script is right as it stands - under X11 the head really is DP-0.)
#
# That sway script also never made it into this checkout: it lives as a loose
# unmanaged file in ~/.local/bin. This one is tracked and linked through
# nix/nlscripts.nix, like every other script on PATH.

set -euo pipefail

FOCUSED_MONITOR=$(hyprctl activeworkspace -j | jq -r '.monitor')

case "${1:-}" in
    next) TARGET="m+1" ;;
    prev) TARGET="m-1" ;;
    @*)   TARGET="${1#@}" ;;
    *)
        if [ "$FOCUSED_MONITOR" = "DP-1" ]; then
            # Left head: the 11-19 set.
            TARGET="1$1"
        else
            # DP-2 and anything else (laptop panels, a single-head fallback).
            TARGET="$1"
        fi
        ;;
esac

if [ "${2:-}" = "move" ]; then
    # movetoworkspace follows the window across; use movetoworkspacesilent to
    # stay put. sway's binding followed, so this matches it.
    hyprctl dispatch movetoworkspace "$TARGET"
else
    hyprctl dispatch workspace "$TARGET"
fi
