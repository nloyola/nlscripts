#!/usr/bin/env bash
# Looks after su_vpn.sh's Docker<->VPN NAT and routes for the life of one VPN
# session. `su_vpn.sh connect` starts this (as su-vpn-docker-nat.service) once
# the tunnel is up; it is never started at boot.
#
# Two things go wrong after connect that su_vpn.sh cannot see:
#   - A later `compose up` / container restart makes Docker rebuild its
#     iptables and create fresh bridges the connect-time rules no longer cover,
#     so containers fail outbound with "Host is unreachable". Docker network
#     events trigger `su_vpn.sh refresh-docker`; a burst of them (a stack coming
#     up spawns one network + many container connects) is coalesced into a
#     single apply.
#   - The tunnel dies on its own, with no Docker event, and its SNAT rules go on
#     rewriting container traffic to an address that no longer exists. When no
#     event has arrived for POLL seconds this runs `su_vpn.sh check`, which tears
#     the routes and NAT down once FortiClient says the tunnel is gone.
#
# Either call exits NO_SESSION (3) once there is no session left - the tunnel
# was torn down here, or by `disconnect` - and this exits 0 with it. The unit's
# Restart=on-failure leaves a clean exit stopped, and restarts a crash.
set -uo pipefail

SU_VPN="${SU_VPN:-/home/nelson/.local/bin/su_vpn.sh}"
DEBOUNCE="${DEBOUNCE:-2}"
POLL="${POLL:-30}"
NO_SESSION=3

# Run one su_vpn.sh action, and stop when it says the session is over.
run() {
  "$SU_VPN" "$1"
  if (( $? == NO_SESSION )); then
    exit 0
  fi
}

# Apply once at startup: containers may have come up while connect ran, and a
# service restart mid-session must re-check too.
run refresh-docker

# Stream network lifecycle events; drain each burst within the debounce window,
# then apply exactly once. A read that times out (status above 128) is the
# poll. Any other failure is end of file: `docker events` ended (daemon
# restart), which is a failure for systemd to restart, mid-session as it is.
#
# Process substitution, not a pipe: the loop must run in this shell, so that
# `exit` in run() ends the script. At the end of a pipe it would end only the
# loop's subshell, and the script would then wait on `docker events`, which does
# not exit until Docker next has an event to write. systemd kills the orphaned
# `docker events` along with the rest of the unit's cgroup.
while :; do
  read -r -t "$POLL" _action
  rc=$?
  if (( rc == 0 )); then
    while read -r -t "$DEBOUNCE" _drain; do :; done
    run refresh-docker
  elif (( rc > 128 )); then
    run check
  else
    exit 1
  fi
done < <(docker events --filter 'type=network' \
  --filter 'event=create'  --filter 'event=destroy' \
  --filter 'event=connect' --filter 'event=disconnect' \
  --format '{{.Action}}' 2>/dev/null)
