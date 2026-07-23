#!/usr/bin/env bash
# Watches Docker network events and re-applies su_vpn.sh's Docker<->VPN NAT and
# routes whenever bridges change *while the VPN is up*. This closes the ordering
# gap where `su_vpn.sh connect` wires the tunnel NAT once, but a later
# `compose up` / container restart makes Docker rebuild its iptables and create
# fresh bridges the connect-time rules no longer cover (containers then fail
# outbound with "Host is unreachable").
#
# `su_vpn.sh refresh-docker` is a no-op unless the VPN is up, so this is safe to
# run continuously. Bursts of events (a stack coming up spawns one network +
# many container connects) are coalesced into a single apply.
#
# Runs as a systemd service: su-vpn-docker-nat.service.
set -uo pipefail

SU_VPN="${SU_VPN:-/home/nelson/.local/bin/su_vpn.sh}"
DEBOUNCE="${DEBOUNCE:-2}"

apply() { "$SU_VPN" refresh-docker || true; }

# Apply once at startup in case the service (re)starts with the VPN already up
# and containers already running.
apply

# Stream network lifecycle events; drain each burst within the debounce window,
# then apply exactly once. If `docker events` ends (daemon restart), the loop
# exits and systemd restarts the unit.
docker events --filter 'type=network' \
  --filter 'event=create'  --filter 'event=destroy' \
  --filter 'event=connect' --filter 'event=disconnect' \
  --format '{{.Action}}' 2>/dev/null |
while read -r _action; do
  while read -r -t "$DEBOUNCE" _drain; do :; done
  apply
done
