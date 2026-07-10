#!/usr/bin/env bash
# Usage: ./lunenfeld_vpn.sh {connect|disconnect|restore}
#
# Works around a FortiClient Linux quirk where `fortivpn connect` fails with
# "IPsec VPN failed to configure routes and DNS" because it issues
# `ip route add default ...` instead of `replace` and the kernel rejects it
# with EEXIST when a default route already exists.
#
# Before connecting we pin a /32 host route to the VPN concentrator via the
# current gateway, then remove the default. On disconnect (or on a failed
# connect) we clean up the host route and restore the default. The host route
# must remain in place for the life of the tunnel - without it, VPN peer
# packets would route through the tunnel and form a loop.

set -euo pipefail

ACTION="${1:-}"
VPN_PEER="fg.lunenfeld.ca"
LUNENFELD_ROUTES=(10.197.0.0/16)
LUNENFELD_HOSTS=(biobankarchive.lunenfeld.ca)
STATE_FILE="/tmp/lunenfeld_vpn.sh.state"
RESOLV_BACKUP="/tmp/lunenfeld_vpn.sh.resolv.conf"
VPN_PEER_ROUTE=""

save_resolv_conf() {
  sudo cp /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
  sudo chown "$(id -u):$(id -g)" "$RESOLV_BACKUP" 2>/dev/null || true
}

restore_resolv_conf() {
  if [[ -s "$RESOLV_BACKUP" ]]; then
    sudo cp "$RESOLV_BACKUP" /etc/resolv.conf 2>/dev/null || true
  elif [[ -s /run/NetworkManager/resolv.conf ]]; then
    sudo cp /run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
  fi
  rm -f "$RESOLV_BACKUP"
}

wait_vpn_stopped() {
  local status
  for _ in {1..3}; do
    status="$(timeout 2 /opt/forticlient/fortivpn status 2>&1 || true)"
    grep -q "Status: Not Running" <<<"$status" && return 0
    sleep 1
  done
  return 1
}

save_default_route() {
  local line gw dev
  # Pick the first default route that has a real "via" gateway. While a
  # FortiClient tunnel is up it can leave a gatewayless
  # "default dev <if> proto static scope link" route behind; a naive head -n1
  # would grab that on a reconnect, find no gateway, and abort. Skip any
  # default route without a "via" and use the real gateway'd one.
  while IFS= read -r line; do
    [[ "$line" == *" via "* ]] || continue
    gw="$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$line")"
    dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$line")"
    [[ -n "$gw" && -n "$dev" ]] || continue
    printf 'GATEWAY=%s\nDEVICE=%s\n' "$gw" "$dev" > "$STATE_FILE"
    return 0
  done < <(ip -4 route show default)
  return 1
}

warn_if_tailscale_exit_node() {
  command -v tailscale >/dev/null 2>&1 || return 0
  # A Tailscale *exit node* (full-tunnel) routes all traffic through Tailscale
  # and can capture packets before this VPN's routes are consulted; a normal
  # Tailscale session routes just 100.64/10 in its own table and coexists fine,
  # so we don't touch it. Detect the exit-node case via the 0.0.0.0/1
  # split-default route Tailscale installs in its routing table (table 52) when
  # an exit node is active, and only warn - never disable it, since Tailscale
  # may be the user's remote-access path.
  if ip route show table 52 2>/dev/null | grep -q '^0\.0\.0\.0/1 '; then
    echo "lunenfeld_vpn.sh: warning: a Tailscale exit node looks active (full-tunnel)." >&2
    echo "lunenfeld_vpn.sh: it may capture traffic and conflict with the VPN." >&2
    echo "lunenfeld_vpn.sh: run 'tailscale set --exit-node=' first if the VPN misbehaves." >&2
  fi
}

resolve_vpn_peer_route() {
  local peer_ip
  peer_ip="$(getent ahostsv4 "$VPN_PEER" | awk 'NR == 1 {print $1}')"
  [[ -n "$peer_ip" ]] || return 1
  VPN_PEER_ROUTE="$peer_ip/32"
  printf 'VPN_PEER_ROUTE=%q\n' "$VPN_PEER_ROUTE" >> "$STATE_FILE"
}

docker_bridge_routes() {
  docker network ls -q 2>/dev/null \
    | xargs -r docker network inspect \
        --format '{{.Id}}{{"\t"}}{{range .IPAM.Config}}{{.Subnet}}{{end}}{{"\t"}}{{(index .Options "com.docker.network.bridge.name")}}' 2>/dev/null \
    | while IFS=$'\t' read -r id subnet bridge; do
        [[ -n "$subnet" ]] || continue
        if [[ -z "$bridge" || "$bridge" == "<no value>" ]]; then
          bridge="br-${id:0:12}"
        fi
        [[ -d "/sys/class/net/$bridge" ]] || continue
        printf '%s\t%s\n' "$subnet" "$bridge"
      done
}

pin_docker_routes() {
  local subnet iface
  while IFS=$'\t' read -r subnet iface; do
    [[ -n "$subnet" && -n "$iface" ]] || continue
    sudo ip route replace "$subnet" dev "$iface" 2>/dev/null || true
  done < <(docker_bridge_routes)
}

default_route_source() {
  ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

vpn_source_addr() {
  local source
  source="$(default_route_source)"
  if [[ -n "$source" ]]; then
    printf '%s\n' "$source"
    return 0
  fi

  ip -o -4 addr show scope global \
    | awk '$4 ~ /^10[.].*\/32$/ {sub("/32", "", $4); print $4; exit}'
}

vpn_dns_servers() {
  awk '/^nameserver / {print $2}' /etc/resolv.conf 2>/dev/null
}

resolve_with_server() {
  local host="$1" server="$2"
  dig +short A "$host" "@$server" 2>/dev/null | awk 'NR == 1 {print $1; exit}'
}

pin_lunenfeld_routes() {
  local vpn_source vpn_device route host server ip
  vpn_source="$(vpn_source_addr)"
  [[ -n "$vpn_source" ]] || return 0
  vpn_device="$(ip -o -4 addr show | awk -v ip="$vpn_source" '$4 == ip "/32" {print $2; exit}')"
  [[ -n "$vpn_device" ]] || return 0

  for route in "${LUNENFELD_ROUTES[@]}"; do
    sudo ip route replace "$route" via "$vpn_source" dev "$vpn_device" 2>/dev/null || true
    printf 'LUNENFELD_ROUTE=%q\n' "$route" >> "$STATE_FILE"
  done

  while read -r server; do
    [[ -n "$server" ]] || continue
    for host in "${LUNENFELD_HOSTS[@]}"; do
      ip="$(resolve_with_server "$host" "$server")"
      [[ -n "$ip" ]] || continue
      sudo ip route replace "$ip/32" via "$vpn_source" dev "$vpn_device" 2>/dev/null || true
      printf 'LUNENFELD_ROUTE=%q\n' "$ip/32" >> "$STATE_FILE"
    done
  done < <(vpn_dns_servers)
}

configure_docker_vpn_nat() {
  local vpn_source subnet iface
  vpn_source="$(default_route_source)"
  [[ -n "$vpn_source" ]] || return 0
  printf 'VPN_SOURCE=%q\n' "$vpn_source" >> "$STATE_FILE"

  # Remove any older lunenfeld_vpn.sh rules first. Stale rules can reference deleted
  # Docker bridges, and rules without the localhost exclusion break published
  # ports reached through http://localhost:PORT/ while the VPN is up.
  remove_docker_vpn_nat

  while IFS=$'\t' read -r subnet iface; do
    [[ -n "$subnet" && -n "$iface" ]] || continue
    sudo iptables -t nat -C POSTROUTING -s "$subnet" ! -d 127.0.0.0/8 ! -o "$iface" \
      -m comment --comment lunenfeld_vpn.sh-docker-vpn -j SNAT --to-source "$vpn_source" 2>/dev/null \
      || sudo iptables -t nat -I POSTROUTING 1 -s "$subnet" ! -d 127.0.0.0/8 ! -o "$iface" \
        -m comment --comment lunenfeld_vpn.sh-docker-vpn -j SNAT --to-source "$vpn_source" 2>/dev/null || true
  done < <(docker_bridge_routes)
}

remove_docker_vpn_nat() {
  # Delete all rules managed by this script, including stale rules for Docker
  # bridges that no longer exist.
  while read -r rule; do
    [[ -n "$rule" ]] || continue
    sudo timeout 5 bash -c "iptables -w 2 -t nat ${rule/-A POSTROUTING/-D POSTROUTING}" 2>/dev/null || true
  done < <(sudo iptables -t nat -S POSTROUTING 2>/dev/null | grep -- 'lunenfeld_vpn.sh-docker-vpn' || true)
}

remove_vpn_source_addr() {
  [[ -n "${VPN_SOURCE:-}" ]] || return 0

  ip -o -4 addr show | awk -v ip="$VPN_SOURCE" '$4 == ip "/32" {print $2}' \
    | while read -r iface; do
        [[ -n "$iface" ]] || continue
        sudo ip addr del "$VPN_SOURCE/32" dev "$iface" 2>/dev/null || true
      done
}

remove_stale_vpn_addrs() {
  # FortiClient can leave its assigned /32 behind after suspend/resume. If that
  # stale address remains, the next IPsec setup may be brought down immediately.
  ip -o -4 addr show scope global \
    | awk '$4 ~ /^10[.]240[.].*\/32$/ && $2 !~ /^(lo|docker|br-|tun|ppp)/ {print $2, $4}' \
    | while read -r iface cidr; do
        [[ -n "$iface" && -n "$cidr" ]] || continue
        sudo ip addr del "$cidr" dev "$iface" 2>/dev/null || true
      done
}

restore_routes() {
  remove_docker_vpn_nat
  if [[ ! -f "$STATE_FILE" ]]; then
    remove_stale_vpn_addrs
    restore_resolv_conf
    return 0
  fi
  local GATEWAY="" DEVICE="" VPN_SOURCE="" VPN_PEER_ROUTE="" LUNENFELD_ROUTE=""
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "$VPN_PEER_ROUTE" ]] || VPN_PEER_ROUTE="$VPN_PEER/32"
  sudo ip route del "$VPN_PEER_ROUTE" 2>/dev/null || true
  while read -r route; do
    [[ -n "$route" ]] || continue
    sudo ip route del "$route" 2>/dev/null || true
  done < <(grep '^LUNENFELD_ROUTE=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- | xargs -r -n1 printf '%b\n')
  remove_docker_vpn_nat
  remove_vpn_source_addr
  remove_stale_vpn_addrs
  if [[ -n "$GATEWAY" && -n "$DEVICE" ]]; then
    sudo ip route replace default via "$GATEWAY" dev "$DEVICE"
  fi
  restore_resolv_conf
  rm -f "$STATE_FILE"
}

case "$ACTION" in
  connect)
    warn_if_tailscale_exit_node
    remove_stale_vpn_addrs
    save_resolv_conf
    if ! save_default_route; then
      echo "lunenfeld_vpn.sh: no default route found; cannot determine gateway." >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    # If the connect step below exits without reaching the success branch,
    # restore routes so the user isn't left offline.
    trap restore_routes EXIT

    if ! resolve_vpn_peer_route; then
      echo "lunenfeld_vpn.sh: cannot resolve $VPN_PEER." >&2
      exit 1
    fi

    pin_docker_routes
    sudo ip route replace "$VPN_PEER_ROUTE" via "$GATEWAY" dev "$DEVICE"

    rc=0
    expect -c '
      set timeout 60
      log_user 1
      spawn /opt/forticlient/fortivpn connect lunenfeld
      set connected 0
      expect {
        -re "(?i)Password:" {
          send -- "[exec pass lunenfeld.ca/vpn/nelsonloyola]\r"
          exp_continue
        }
        -re {Confirm \(y/n\).*:} {
          send -- "y\r"
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
      pin_lunenfeld_routes
      sudo ip route replace default via "$GATEWAY" dev "$DEVICE"
      restore_resolv_conf
      # Re-pin Docker routes after restoring the normal default route.
      pin_docker_routes
      echo "lunenfeld_vpn.sh: VPN connected. Run 'lunenfeld_vpn.sh disconnect' to tear down and restore routes."
    else
      echo "lunenfeld_vpn.sh: connect failed; restoring routes." >&2
      exit "$rc"
    fi
    ;;
  disconnect)
    timeout 5 /opt/forticlient/fortivpn disconnect || pkill fortivpn || true
    wait_vpn_stopped || pkill fortivpn || true
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
