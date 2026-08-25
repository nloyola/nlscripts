#!/usr/bin/env bash
# switch_dynamic_workspace.sh
# Argument $1 is the key number (1-9), "next"/"prev" for a relative switch, or
#   "@<num>" for an already-absolute workspace number (used by the quickshell
#   bar, whose workspace pills know the real number and need no mapping)
# Argument $2 is the optional i3 command (e.g., "move container to" or "workspace")

# Get the output and number of the workspace holding the focused container
read -r FOCUSED_OUTPUT FOCUSED_NUM < <(
    i3-msg -t get_workspaces |
        jq -r '.[] | select(.focused==true) | "\(.output) \(.num)"' | head -n 1
)

case "$1" in
    next) TARGET="next_on_output"; DIR=0 ;;
    prev) TARGET="prev_on_output"; DIR=1 ;;
    @*)
        TARGET="${1#@}"
        if [ "$TARGET" -lt "$FOCUSED_NUM" ]; then DIR=1; else DIR=0; fi
        ;;
    *)
        # Determine the target workspace number based on the output name
        if [ "$FOCUSED_OUTPUT" = "DP-0" ]; then
            # Monitor 2 (11-19)
            TARGET="1$1"
        else
            # DP-2, eDP/eDP-1, and any other monitor
            TARGET="$1"
        fi
        # 1 when the target sits to the left of where we are, else 0
        if [ "$TARGET" -lt "$FOCUSED_NUM" ]; then DIR=1; else DIR=0; fi
        ;;
esac

# Tell picom which way the switch goes. It only ever sees windows being hidden
# and shown, so without this its slide animation has no direction and every
# switch looks like it moves the same way. picom re-matches the _I3_SLIDE_DIR
# rule in ~/.config/picom/picom.conf on PropertyNotify, and X handles these
# requests before the map/unmap i3 is about to issue, so the stamp is in force
# by the time the animation starts. Tagging the whole tree (rather than just the
# two workspaces involved) keeps this a single cheap pass; running the xprops in
# parallel keeps it around 10ms.
i3-msg -t get_tree |
    jq -r '.. | objects | select(.window != null) | .window' |
    xargs -r -P 16 -I {} xprop -id {} -f _I3_SLIDE_DIR 32c -set _I3_SLIDE_DIR "$DIR"

# Send the dynamic command to i3
i3-msg "$2 workspace $TARGET"
