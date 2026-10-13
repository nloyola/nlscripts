#!/usr/bin/env bash
# Tests su_vpn.sh's Docker NAT upkeep and su_vpn_docker_watch.sh against stubs.
# Nothing here touches the real firewall, routes or resolv.conf: sudo, ip,
# iptables, docker and FortiClient are all fakes that write to a scratch dir.
#
# SU_VPN_SCRIPT points the su_vpn.sh cases at another copy, e.g. an older
# revision, to show which cases it fails.

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="${SU_VPN_SCRIPT:-$script_dir/su_vpn.sh}"
watcher="$script_dir/su_vpn_docker_watch.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/su-vpn-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0

fail() {
  printf 'not ok - %s\n' "$1"
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
}

check() {
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

VPN_SNAT='-A POSTROUTING -s 10.123.45.0/24 ! -d 127.0.0.0/8 ! -o lo -m comment --comment su_vpn.sh-docker-vpn -j SNAT --to-source 10.240.228.7'

setup_case() {
  root="$tmp/$1"
  mkdir -p "$root/bin"
  : >"$root/rules"
  : >"$root/calls"

  # sudo runs only the fakes below; anything else (ln over /etc/resolv.conf,
  # systemctl restart tailscaled, ...) is recorded and skipped.
  cat >"$root/bin/sudo" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ip|iptables|timeout) exec "$@" ;;
  *) printf 'sudo %s\n' "$*" >>"$TEST_ROOT/calls" ;;
esac
EOF

  cat >"$root/bin/iptables" <<'EOF'
#!/usr/bin/env bash
rules="$TEST_ROOT/rules"
args=()
while (($#)); do
  case "$1" in
    -w) shift 2 ;;
    -t) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
op="${args[0]}"; chain="${args[1]}"
case "$op" in
  -S) echo "-P $chain ACCEPT"; cat "$rules" ;;
  -C) grep -qxF -- "-A $chain ${args[*]:2}" "$rules" ;;
  -I) { echo "-A $chain ${args[*]:3}"; cat "$rules"; } >"$rules.new"; mv "$rules.new" "$rules" ;;
  -D) grep -vxF -- "-A $chain ${args[*]:2}" "$rules" >"$rules.new"; mv "$rules.new" "$rules" ;;
esac
EOF

  cat >"$root/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-4 route show default") echo "$TEST_DEFAULT_ROUTE" ;;
  *addr\ show*) ;;
  *) printf 'ip %s\n' "$*" >>"$TEST_ROOT/calls" ;;
esac
EOF

  # One Docker network whose bridge is `lo`, so the /sys/class/net check holds.
  cat >"$root/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "network ls") echo abcdef123456 ;;
  "network inspect") printf 'abcdef1234567890\t10.123.45.0/24\tlo\n' ;;
  "events "*) exec sleep "${TEST_EVENTS_FOR:-0}" ;;
esac
EOF

  cat >"$root/bin/fortivpn" <<'EOF'
#!/usr/bin/env bash
printf 'fortivpn %s\n' "$*" >>"$TEST_ROOT/calls"
[[ "$1" == status ]] && printf '%s\n' "$TEST_FORTI_STATUS"
EOF

  # `systemctl cat` answers whether the watcher unit is installed.
  cat >"$root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == cat && -n "${TEST_HAVE_UNIT:-}" ]]
EOF

  for cmd in tailscale dig resolvectl pkill; do
    printf '#!/usr/bin/env bash\nexit 1\n' >"$root/bin/$cmd"
  done
  chmod +x "$root"/bin/*

  export TEST_ROOT="$root"
  export PATH="$root/bin:$PATH"
  export FORTIVPN="$root/bin/fortivpn"
  export SU_VPN_STATE_FILE="$root/state"
  export SU_VPN_LOCK_FILE="$root/lock"
  export SU_VPN_RESOLV_BACKUP="$root/resolv.backup"
  export TEST_DEFAULT_ROUTE='default via 192.168.50.1 dev br0 proto dhcp src 192.168.50.3 metric 425'
  export TEST_FORTI_STATUS='Status: Not Running'
}

# What the box looked like on 2026-10-13: a tunnel that died without
# `disconnect`, its state file and SNAT rule still in place.
dead_tunnel_leftovers() {
  printf 'GATEWAY=192.168.50.1\nDEVICE=br0\nVPN_SOURCE=10.240.228.7\n' >"$SU_VPN_STATE_FILE"
  echo "$VPN_SNAT" >"$TEST_ROOT/rules"
}

no_vpn_snat() { ! grep -q su_vpn.sh-docker-vpn "$TEST_ROOT/rules"; }
has_vpn_snat() { grep -qxF -- "$VPN_SNAT" "$TEST_ROOT/rules"; }
fortivpn_not_called() { ! grep -q fortivpn "$TEST_ROOT/calls"; }
systemctl_not_called() { ! grep -q systemctl "$TEST_ROOT/calls"; }

setup_case check-dead
dead_tunnel_leftovers
"$script" check >/dev/null 2>&1
desc='check removes the SNAT a dead tunnel left behind'; check no_vpn_snat
desc='check removes the dead tunnel state file'; check test ! -e "$SU_VPN_STATE_FILE"

setup_case refresh-dead
dead_tunnel_leftovers
"$script" refresh-docker >/dev/null 2>&1
desc='refresh-docker with a dead tunnel leaves no su_vpn SNAT'; check no_vpn_snat
desc='refresh-docker with a dead tunnel removes the state file'; check test ! -e "$SU_VPN_STATE_FILE"

setup_case refresh-live
printf 'GATEWAY=192.168.50.1\nDEVICE=br0\n' >"$SU_VPN_STATE_FILE"
export TEST_FORTI_STATUS='Status: Connected'
export TEST_DEFAULT_ROUTE='default dev vpn0 proto static scope link src 10.240.228.7'
"$script" refresh-docker >/dev/null 2>&1
"$script" refresh-docker >/dev/null 2>&1
desc='refresh-docker with a live tunnel SNATs the bridge to the VPN address'; check has_vpn_snat
desc='refresh-docker leaves exactly one SNAT rule per bridge'
check test "$(grep -c su_vpn.sh-docker-vpn "$TEST_ROOT/rules")" = 1
desc='refresh-docker records VPN_SOURCE once, not once per run'
check test "$(grep -c '^VPN_SOURCE=' "$SU_VPN_STATE_FILE")" = 1

setup_case check-live
dead_tunnel_leftovers
export TEST_FORTI_STATUS='Status: Connected'
"$script" check >/dev/null 2>&1
desc='check leaves a live tunnel alone'; check has_vpn_snat

setup_case check-unknown
dead_tunnel_leftovers
export TEST_FORTI_STATUS='some FortiClient error'
"$script" check >/dev/null 2>&1
desc='check leaves things alone when FortiClient status is unreadable'; check has_vpn_snat
desc='check keeps the state file when FortiClient status is unreadable'; check test -e "$SU_VPN_STATE_FILE"

setup_case check-locked
dead_tunnel_leftovers
exec 8>"$SU_VPN_LOCK_FILE"
flock 8
"$script" check >/dev/null 2>&1
exec 8>&-
desc='check skips while another su_vpn.sh action holds the lock'; check has_vpn_snat

setup_case check-never-connected
"$script" check >/dev/null 2>&1
desc='check without a state file does not call FortiClient'; check fortivpn_not_called

setup_case exit-codes
"$script" check >/dev/null 2>&1
rc=$?
desc='check exits NO_SESSION when there is no VPN session'; check test "$rc" = 3
dead_tunnel_leftovers
"$script" check >/dev/null 2>&1
rc=$?
desc='check exits NO_SESSION after tearing down a dead tunnel'; check test "$rc" = 3
dead_tunnel_leftovers
export TEST_FORTI_STATUS='Status: Connected'
"$script" check >/dev/null 2>&1
rc=$?
desc='check exits 0 while the tunnel is up'; check test "$rc" = 0
"$script" refresh-docker >/dev/null 2>&1
rc=$?
desc='refresh-docker exits 0 while the tunnel is up'; check test "$rc" = 0
rm -f "$SU_VPN_STATE_FILE"
"$script" refresh-docker >/dev/null 2>&1
rc=$?
desc='refresh-docker exits NO_SESSION when there is no VPN session'; check test "$rc" = 3

setup_case restore-stops-watcher
dead_tunnel_leftovers
TEST_HAVE_UNIT=1 "$script" restore >/dev/null 2>&1
desc='restore stops the watcher'
check grep -qxF 'sudo systemctl stop --no-block su-vpn-docker-nat.service' "$TEST_ROOT/calls"

setup_case restore-without-unit
dead_tunnel_leftovers
"$script" restore >/dev/null 2>&1
desc='restore on a host without the watcher unit leaves systemd alone'
check systemctl_not_called

# The watcher, against a fake su_vpn.sh that records each action and answers
# NO_SESSION (3) once the fake session flag is gone.
fake_su_vpn() {
  cat >"$TEST_ROOT/bin/fake-su-vpn" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$TEST_ROOT/calls"
[[ "$1" == check && -e "$TEST_ROOT/end-on-check" ]] && rm -f "$TEST_ROOT/session"
[[ -e "$TEST_ROOT/session" ]] || exit 3
EOF
  chmod +x "$TEST_ROOT/bin/fake-su-vpn"
  export SU_VPN="$TEST_ROOT/bin/fake-su-vpn" POLL=1
}

setup_case watcher-no-session
fake_su_vpn
TEST_EVENTS_FOR=30 timeout 10 "$watcher"
rc=$?
desc='the watcher exits cleanly when started with no VPN session'; check test "$rc" = 0
desc='the watcher with no VPN session does not poll'; check test "$(wc -l <"$TEST_ROOT/calls")" = 1

setup_case watcher-poll
fake_su_vpn
touch "$TEST_ROOT/session"
TEST_EVENTS_FOR=3 timeout 10 "$watcher"
rc=$?
desc='the watcher runs check when no Docker event arrives'; check grep -qx check "$TEST_ROOT/calls"
desc='the watcher fails, for systemd to restart, when docker events ends mid-session'; check test "$rc" = 1

setup_case watcher-session-ends
fake_su_vpn
touch "$TEST_ROOT/session" "$TEST_ROOT/end-on-check"
started=$SECONDS
TEST_EVENTS_FOR=30 timeout 10 "$watcher"
rc=$?
desc='the watcher exits cleanly once check ends the session'; check test "$rc" = 0
desc='the watcher exits without waiting on docker events'; check test $((SECONDS - started)) -lt 5

if ((failures)); then
  printf '%d failed\n' "$failures"
  exit 1
fi
echo 'all passed'
