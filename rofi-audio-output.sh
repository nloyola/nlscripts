#!/usr/bin/env bash
# Pick the default audio output, by description, from a dmenu-style list.
#
# WHY NOT pactl, WHICH THIS USED TO USE. `pactl` ships in pulseaudio-utils, a
# package neither pipewire nor wireplumber pulls in - it is on asterix and not on
# gudrun, so every call here failed silently on the laptop and SHIFT+XF86AudioMute
# did nothing at all. Both hosts run pipewire with wireplumber, so the tools that
# are always there are pw-dump and wpctl: pw-dump lists, wpctl switches.
#
# NOT pulsemixer for the listing either, even though qs-osd depends on it: its
# `sink-<n>` is the PulseAudio index from pipewire-pulse, not the pipewire node
# id wpctl wants. The two coincide for ALSA devices and diverge for bluetooth
# ones (EMBERTON is sink-6134 to pulsemixer and node 78 to wpctl), so the pairing
# would have worked on the speakers and switched to the wrong device - or none -
# on the headphones. pw-dump's ids are wpctl's ids.

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

# One "<node id>\t<description>" line per sink, which is the same set and the
# same ids `wpctl status` shows under Audio -> Sinks.
sinks() {
    pw-dump 2>/dev/null | jq -r '
        .[]
        | select(.info.props."media.class" == "Audio/Sink")
        | "\(.id)\t\(.info.props."node.description" // .info.props."node.name")"
    ' 2>/dev/null
}

# If user selected an output
if [ $# -gt 0 ]; then
    desc="$*"
    device=$(sinks | awk -F'\t' -v d="$desc" '$2 == d {print $1; exit}')

    if [ -n "$device" ] && wpctl set-default "$device"; then
        $SEND -t 2000 -r 2 -u low "Activated: $desc"
    else
        $SEND -t 2000 -r 2 -u critical "Error activating $desc"
    fi
else
    choices=()
    for x in $(sinks | cut -f2- | sort); do
        choices+=("$x")
    done

    if [ ${#choices[@]} -eq 0 ]; then
        $SEND -t 2000 -r 2 -u critical "No audio outputs found"
        exit 1
    fi

    # The quickshell command menu where there is one, rofi everywhere else;
    # qs-dmenu picks. The name stays rofi-audio-output.sh: it is called by that
    # name from the Hyprland binding and from the menu tree.
    selection=$(printf '%s\n' "${choices[@]}" | qs-dmenu -p "Audio Output")
    [ -n "$selection" ] && "$0" "$selection"
fi
