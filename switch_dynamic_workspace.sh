#!/bin/bash
# switch_dynamic_workspace.sh
# Argument $1 is the key number (1-9)
# Argument $2 is the optional i3 command (e.g., "move container to" or "workspace")

# Get the name of the output where the currently focused container is located
FOCUSED_OUTPUT=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused==true).output' | head -n 1)

# Determine the target workspace number based on the output name
if [ "$FOCUSED_OUTPUT" = "DP-2" ]; then
    TARGET_WS="$1"
elif [ "$FOCUSED_OUTPUT" = "DP-0" ]; then
    # Monitor 2 (11-19)
    TARGET_WS="1$1"
elif [ "$FOCUSED_OUTPUT" = "eDP" ] || [ "$FOCUSED_OUTPUT" = "eDP-1" ]; then
    # Monitor 3 (21-29) - Checking for both 'eDP' and 'eDP-1' for robustness
    TARGET_WS="$1"
else
    # Fallback for any other monitor
    TARGET_WS="$1"
fi

# Send the dynamic command to i3
i3-msg "$2 workspace $TARGET_WS"
