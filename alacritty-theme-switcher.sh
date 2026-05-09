#!/usr/bin/env bash

THEME_DIR="$HOME/.config/alacritty/themes/themes"
CONFIG_FILE="$HOME/.config/alacritty/alacritty.yml"

# Let the user pick a theme using rofi
THEME=$(ls "$THEME_DIR" | rofi -dmenu -p "Select Alacritty Theme")

# Exit if no theme selected
[ -z "$THEME" ] && exit 1

alacritty msg config "$(cat $THEME_DIR/$THEME)"
