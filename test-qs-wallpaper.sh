#!/usr/bin/env bash
# Tests the hyprlock include qs-wallpaper writes beside its state file. Nothing
# here touches the live desktop: hyprctl is a fixture file, and the state file
# and include land in a scratch dir.
#
# QS_WALLPAPER_SCRIPT points the cases at another copy, e.g. an older
# revision, to show which cases it fails.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="${QS_WALLPAPER_SCRIPT:-$script_dir/qs-wallpaper}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/qs-wallpaper-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0

fail() {
  printf 'not ok - %s\n' "$1"
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
}

# setup_case <name> <monitor>... - each monitor enabled, in the order given.
setup_case() {
  root="$tmp/$1"
  shift
  mkdir -p "$root/lib"
  for m in "$@"; do
    printf 'Monitor %s (ID 0):\n\tdisabled: false\n' "$m"
  done >"$root/hyprctl"
}

wallpaper() {
  QS_WALLPAPER_HYPRCTL="$root/hyprctl" QS_WALLPAPER_STATE="$root/state" \
    QS_WALLPAPER_FEHBG="$root/none" sh "$script" "$@" >/dev/null 2>&1
}

# The path hyprlock's background block names for <monitor>, "" for none.
lock_path() {
  awk -v want="$1" '
    $1 == "monitor" && $3 == want { hit = 1; next }
    hit && $1 == "path"           { sub(/^ *path = /, ""); print; exit }
  ' "$root/state-hyprlock.conf" 2>/dev/null
}

setup_case set DP-1 DP-2
touch "$root/lib/a.jpg" "$root/lib/b.jpg"
wallpaper set DP-1 "$root/lib/a.jpg"
wallpaper set DP-2 "$root/lib/b.jpg"
desc="set gives each monitor its own lock background"
[ "$(lock_path DP-1)" = "$root/lib/a.jpg" ] && [ "$(lock_path DP-2)" = "$root/lib/b.jpg" ] &&
  pass "$desc" || fail "$desc (DP-1 '$(lock_path DP-1)', DP-2 '$(lock_path DP-2)')"

desc="the include has exactly one background per monitor"
n=$(grep -c "^background {" "$root/state-hyprlock.conf" 2>/dev/null)
[ "${n:-0}" -eq 2 ] && pass "$desc" || fail "$desc (got $n)"

desc="generated backgrounds sit above the screenshot fallback"
[ "$(grep -c "zindex = -1" "$root/state-hyprlock.conf" 2>/dev/null)" = 2 ] && pass "$desc" || fail "$desc"

wallpaper set DP-2 "$root/lib/a.jpg"
desc="a later set rewrites the include"
[ "$(lock_path DP-2)" = "$root/lib/a.jpg" ] && pass "$desc" || fail "$desc (got '$(lock_path DP-2)')"

setup_case random DP-1 DP-2
touch "$root/lib/a.jpg" "$root/lib/b.jpg"
wallpaper random "$root/lib"
desc="random writes the include too"
[ -n "$(lock_path DP-1)" ] && [ -n "$(lock_path DP-2)" ] && pass "$desc" || fail "$desc"

setup_case hash DP-1
touch "$root/lib/no#1.jpg"
wallpaper set DP-1 "$root/lib/no#1.jpg"
desc="a '#' in a path is escaped so hyprlang does not cut it as a comment"
[ "$(lock_path DP-1)" = "$root/lib/no##1.jpg" ] && pass "$desc" || fail "$desc (got '$(lock_path DP-1)')"

setup_case refused DP-1
touch "$root/lib/clip.mp4"
wallpaper set DP-1 "$root/lib/clip.mp4"
desc="a refused set writes no include"
[ ! -e "$root/state-hyprlock.conf" ] && pass "$desc" || fail "$desc"

if ((failures)); then
  printf '%d failed\n' "$failures"
  exit 1
fi
echo "all passed"
