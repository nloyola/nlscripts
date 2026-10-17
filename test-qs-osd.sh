#!/usr/bin/env bash
# Tests qs-osd's volume keys against stubs. Nothing here touches real audio:
# pulsemixer is a fake that keep the volume in a scratch file, and
# XDG_RUNTIME_DIR points at the scratch dir so the OSD payload and the
# held-key state land there too.
#
# The held-key cases drive qs-osd the way Hyprland's bindel does: one call for
# the press, the first repeat 600 ms later, then one call every 40 ms
# (repeat_delay 600, repeat_rate 25).
#
# QS_OSD_SCRIPT points the cases at another copy, e.g. an older revision, to
# show which cases it fails.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="${QS_OSD_SCRIPT:-$script_dir/qs-osd}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/qs-osd-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0

fail() {
  printf 'not ok - %s\n' "$1"
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
}

# setup_case <name> <start volume>
setup_case() {
  root="$tmp/$1"
  mkdir -p "$root/bin" "$root/run"
  echo "$2" >"$root/volume"

  cat >"$root/bin/pulsemixer" <<'EOF'
#!/usr/bin/env bash
vol=$(cat "$TEST_ROOT/volume")
case "$1" in
  --change-volume)
    vol=$((vol + $2))
    ((vol > 150)) && vol=150
    ((vol < 0)) && vol=0
    echo "$vol" >"$TEST_ROOT/volume"
    ;;
  --get-volume) echo "$vol $vol" ;;
  --get-mute) echo 0 ;;
esac
EOF

  chmod +x "$root/bin/"*
}

osd() {
  TEST_ROOT="$root" XDG_RUNTIME_DIR="$root/run" PATH="$root/bin:$PATH" \
    sh "$script" "$@" >/dev/null 2>&1
}

volume() {
  cat "$root/volume"
}

# hold <repeats> <verb> [step]: press, wait out the repeat delay, then repeat.
hold() {
  local repeats=$1
  shift
  osd "$@"
  sleep 0.6
  for _ in $(seq "$repeats"); do
    osd "$@"
    sleep 0.04
  done
}

# Separate presses, far enough apart that none of them is a repeat.
setup_case taps 0
for _ in $(seq 20); do
  osd volume-up
  sleep 0.3
done
desc="separate presses step 2% each and are never capped"
[ "$(volume)" -eq 40 ] && pass "$desc" || fail "$desc (got $(volume))"

# A key whose release never arrives: Hyprland repeats it until lan-mouse
# times out, which was most of a minute on 2026-10-17. 60 repeats at 2% would
# be +122 uncapped.
setup_case stuck 20
hold 60 volume-up
rise=$(($(volume) - 20))
desc="a held volume-up still ramps past the press and first repeat"
((rise > 4)) && pass "$desc" || fail "$desc (rose $rise)"
desc="a held volume-up stops at most 34 points above where it started"
((rise <= 34)) && pass "$desc" || fail "$desc (rose $rise)"

capped=$(volume)
sleep 0.3
osd volume-up
desc="a fresh press after the cap steps again"
[ "$(volume)" -eq $((capped + 2)) ] && pass "$desc" || fail "$desc (got $(volume), cap was $capped)"

setup_case precise 20
hold 60 volume-up 1
rise=$(($(volume) - 20))
desc="a held 1% volume-up is capped by points, not repeats"
((rise >= 30 && rise <= 32)) && pass "$desc" || fail "$desc (rose $rise)"

setup_case down 100
hold 20 volume-down
desc="a held volume-down is never capped"
[ "$(volume)" -eq $((100 - 21 * 2)) ] || [ "$(volume)" -eq 0 ] && pass "$desc" || fail "$desc (got $(volume))"

setup_case osd 30
osd volume-up
desc="the OSD payload carries the new volume"
grep -q '"value":32' "$root/run/quickshell-osd.json" && pass "$desc" || fail "$desc"

if ((failures)); then
  printf '%d failed\n' "$failures"
  exit 1
fi
echo "all passed"
