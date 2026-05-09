#!/usr/bin/env bash
# 1. Clear existing mappings
setxkbmap -option ""
# 2. Force the swap and set F-keys to standard mode
setxkbmap -option "altwin:swap_alt_win"
echo 2 | sudo tee /sys/module/hid_apple/parameters/fnmode

