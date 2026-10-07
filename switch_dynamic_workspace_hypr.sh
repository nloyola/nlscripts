#!/usr/bin/env bash
# switch_dynamic_workspace_hypr.sh
#
# Hyprland counterpart of switch_dynamic_workspace.sh (i3). Maps a 1-9 keypress
# onto the workspace set belonging to whichever monitor currently has focus:
# 11-19 on the head the workspace rules pin them to, 1-9 everywhere else. The
# rules come from the active hyprmoncfg profile (user/.config/hyprmoncfg in
# home_config); on asterix that puts 11-19 on DP-1 and 1-9 on DP-2.
#
# Argument $1 is the key number (1-9), "next"/"prev" for a relative switch, or
#   "@<num>" for an already-absolute workspace number (the quickshell bar's
#   workspace pills know the real number and need no mapping)
# Argument $2 is "move" to send the focused window and follow it across, or
#   "movesilent" to send it and stay put (Omarchy's $mod+SHIFT+ALT+<n>)
#
# WHY THIS EXISTS RATHER THAN A PORT OF switch_dynamic_workspace_sway.sh:
# that script branches on the focused output being "DP-0", which is the X11/i3
# connector name. Sway and Hyprland both call that head "DP-1", so under sway
# the branch never matched, every keypress fell through to the 1-9 set, and the
# 11-19 workspaces were unreachable by keybinding. (The i3 script is right as
# it stands - under X11 the head really is DP-0.)
#
# No connector name is hard-coded here at all. A name is per host and per port:
# a second head on gudrun is HDMI-A-1, and a DP-1 check sent its keys back to
# the panel's 1-9. The pin rules already say which head owns 11-19, so ask them.
#
# That sway script also never made it into this checkout: it lives as a loose
# unmanaged file in ~/.local/bin. This one is tracked and linked through
# nix/nlscripts.nix, like every other script on PATH.

set -euo pipefail

FOCUSED=$(hyprctl monitors -j | jq -c '.[] | select(.focused) | {name, description}')

# Whether workspace $1 is pinned to the focused head. hyprmoncfg writes rules
# as `desc:<description>`, a prefix match in Hyprland; a plain connector name
# is matched exactly.
pinned_here() {
    hyprctl workspacerules -j | jq -e --arg ws "$1" --argjson mon "$FOCUSED" '
        any(.[]; .workspaceString == $ws and ((.monitor // "") as $m |
            $m == $mon.name or
            ($m | startswith("desc:")) and ($mon.description | startswith($m[5:]))))
    ' >/dev/null
}

case "${1:-}" in
    next) TARGET="m+1" ;;
    prev) TARGET="m-1" ;;
    @*)   TARGET="${1#@}" ;;
    *)
        if pinned_here "1$1"; then
            # A head that owns the 11-19 set.
            TARGET="1$1"
        else
            # Anything else (the primary head, a single-head fallback).
            TARGET="$1"
        fi
        ;;
esac

case "${2:-}" in
    move)
        # Follows the window across, which is what the i3 binding did.
        hyprctl dispatch movetoworkspace "$TARGET"
        ;;
    movesilent)
        # Omarchy's "move there without following" ($mod+SHIFT+ALT+<n>): the
        # window lands on the target set and focus stays where it is.
        hyprctl dispatch movetoworkspacesilent "$TARGET"
        ;;
    *)
        hyprctl dispatch workspace "$TARGET"
        ;;
esac
