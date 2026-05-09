#!/usr/bin/env bash
# Usage: ./vpn.sh {connect|disconnect|restore}
#
# Works around a FortiClient Linux quirk where `fortivpn connect` fails with
# "IPsec VPN failed to configure routes and DNS" because it issues
# `ip route add default ...` instead of `replace` and the kernel rejects it
# with EEXIST when a default route already exists.
#
# Before connecting we pin a /32 host route to the VPN concentrator via the
# current gateway, then remove the default. On disconnect (or on a failed
# connect) we clean up the host route and restore the default. The host route
# must remain in place for the life of the tunnel — without it, VPN peer
# packets would route through the tunnel and form a loop.

set -euo pipefail

ACTION="${1:-}"
VPN_PEER="130.237.242.68"
STATE_FILE="/tmp/vpn.sh.state"

save_default_route() {
  local line gw dev
  line="$(ip -4 route show default | head -n1)"
  [[ -n "$line" ]] || return 1
  gw="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$line")"
  dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$line")"
  [[ -n "$gw" && -n "$dev" ]] || return 1
  printf 'GATEWAY=%s\nDEVICE=%s\n' "$gw" "$dev" > "$STATE_FILE"
}

restore_routes() {
  [[ -f "$STATE_FILE" ]] || return 0
  local GATEWAY="" DEVICE=""
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  sudo ip route del "$VPN_PEER/32" 2>/dev/null || true
  if [[ -z "$(ip -4 route show default)" && -n "$GATEWAY" && -n "$DEVICE" ]]; then
    sudo ip route add default via "$GATEWAY" dev "$DEVICE"
  fi
  rm -f "$STATE_FILE"
}

case "$ACTION" in
  connect)
    if ! save_default_route; then
      echo "vpn.sh: no default route found; cannot determine gateway." >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    # If the connect step below exits without reaching the success branch,
    # restore routes so the user isn't left offline.
    trap restore_routes EXIT

    sudo ip route replace "$VPN_PEER/32" via "$GATEWAY" dev "$DEVICE"
    sudo ip route del default 2>/dev/null || true

    rc=0
    expect -c '
      set timeout 60
      log_user 1
      spawn /opt/forticlient/fortivpn connect SU-Linux-vpn -u nelo6128
      set connected 0
      expect {
        -re "(?i)Password:" {
          send -- "[exec pass su.se]\r"
          exp_continue
        }
        "Status: Connected" {
          set connected 1
          exp_continue
        }
        "Status: Disconnected" { }
        eof { }
        timeout { }
      }
      exit [expr {$connected ? 0 : 1}]
    ' || rc=$?

    if [[ $rc -eq 0 ]]; then
      trap - EXIT
      echo "vpn.sh: VPN connected. Run 'vpn.sh disconnect' to tear down and restore routes."
    else
      echo "vpn.sh: connect failed; restoring routes." >&2
      exit "$rc"
    fi
    ;;
  disconnect)
    /opt/forticlient/fortivpn disconnect || pkill fortivpn || true
    restore_routes
    echo "VPN Disconnected."
    ;;
  restore)
    # Emergency restore if the tunnel died but routes were left in place.
    restore_routes
    echo "Routes restored."
    ;;
  *)
    echo "Usage: $0 {connect|disconnect|restore}" >&2
    exit 1
    ;;
esac
