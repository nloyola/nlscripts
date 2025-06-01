#!/usr/bin/env bash
LANG="en_US.utf8"
IFS=$'\n'

# Determine notification command
if command -v notify-send > /dev/null 2>&1; then
    SEND="notify-send"
elif command -v dunstify > /dev/null 2>&1; then
    SEND="dunstify"
else
    SEND="/bin/false"
fi

# If user selected an output
if [ $# -gt 0 ]; then
    desc="$*"
    # Get sink name from description
    device=$(pactl list sinks | grep -C2 -F "Description: $desc" | grep Name | cut -d: -f2 | xargs)

    # Attempt to set default sink
    if pactl set-default-sink "$device"; then
        $SEND -t 2000 -r 2 -u low "Activated: $desc"
    else
        $SEND -t 2000 -r 2 -u critical "Error activating $desc"
    fi
else
    choices=()
    for x in $(pactl list sinks | grep -i "Description:" | cut -d: -f2 | sort); do
        choices+=("$(echo "$x" | xargs)")
    done

    # Show choices in rofi
    selection=$(printf '%s\n' "${choices[@]}" | rofi -dmenu -p "Audio Output")
    [ -n "$selection" ] && "$0" "$selection"
fi
