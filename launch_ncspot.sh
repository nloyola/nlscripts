#!/usr/bin/env bash
# Launch ncspot on workspace 9 with a dedicated WM_CLASS so i3 rules can match.
i3-msg 'workspace number 9' >/dev/null
WINIT_X11_CLASS=ncspot WINIT_X11_INSTANCE=ncspot exec alacritty --class ncspot,ncspot --title ncspot -e ncspot "$@"
