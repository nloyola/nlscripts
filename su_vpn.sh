#!/usr/bin/env bash
# Usage: ./su_vpn.sh {connect|disconnect|restore|refresh-docker|check}
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
VPN_PEER="130.237.242.68"
VPN_PASS_ENTRY="su.se/nelo6128"
STATE_FILE="${SU_VPN_STATE_FILE:-/tmp/su_vpn.sh.state}"
LOCK_FILE="${SU_VPN_LOCK_FILE:-/tmp/su_vpn.sh.lock}"
RESOLV_BACKUP="${SU_VPN_RESOLV_BACKUP:-/tmp/su_vpn.sh.resolv.conf}"
FORTIVPN="${FORTIVPN:-/opt/forticlient/fortivpn}"
TAILSCALE_OPERSTATE="${SU_VPN_TAILSCALE_OPERSTATE:-/sys/class/net/tailscale0/operstate}"
WATCHER_UNIT="su-vpn-docker-nat.service"
# refresh-docker and check exit with this when there is no VPN session to look
# after, so the watcher knows to stop.
NO_SESSION=3

take_lock() {
  # connect, disconnect and restore change routes and NAT in several steps.
  # The watcher's refresh-docker and check run from a systemd service at any
  # moment, and check tears everything down when it sees no tunnel. Run during
  # connect, before FortiClient is up, it would undo the connect in progress.
  # Holding one lock across every action stops that.
  exec 9>"$LOCK_FILE"
  flock 9
}

try_lock() {
  # The watcher's form of take_lock: skip this round rather than wait. Whatever
  # holds the lock is about to leave the routes in a known state anyway.
  exec 9>"$LOCK_FILE"
  flock -n 9
}

tunnel_status() {
  # up, down or unknown. Only FortiClient knows whether the tunnel is up: the
  # state file outlives a tunnel that dies on its own (suspend, network change,
  # server timeout), because nothing runs `disconnect`. A status that times out
  # or reads as anything else is unknown, never down - tearing down a live
  # tunnel is worse than leaving a dead one for the next check.
  local status
  status="$(timeout 3 "$FORTIVPN" status 2>&1 || true)"
  if grep -q "Status: Connected" <<<"$status"; then
    echo up
  elif grep -qE "Status: (Not Running|Disconnected)" <<<"$status"; then
    echo down
  else
    echo unknown
  fi
}

set_state() {
  # Replace KEY in the state file rather than append to it: refresh-docker runs
  # on every Docker network event, so appending grew the file by one line each
  # time.
  local key="$1" value="$2" tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  grep -v "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

reap_dead_tunnel() {
  # The tunnel died without `disconnect`. Its SNAT rules still rewrite every
  # container's traffic to the VPN address, which no longer exists, so the
  # containers lose the internet while the host, back on the LAN, never
  # notices. Tear down exactly as `disconnect` would. Callers have already
  # seen tunnel_status say down.
  echo "su_vpn.sh: the VPN tunnel is gone but its routes and NAT are still in place; restoring." >&2
  restore_routes
}

check_pass_entry() {
  # `pass <name>` on a *directory* prints a tree listing and still exits 0, so
  # renaming an entry breaks us silently: expect types the listing into the
  # password prompt, the FortiClient EAP exchange stalls with no reply and no
  # failure, and connect hangs until the expect timeout. Validate the shape up
  # front so a rename fails loudly and early instead. Only a verdict crosses
  # the pipe - the secret itself never lands in a variable.
  local verdict
  verdict="$(pass "$VPN_PASS_ENTRY" 2>/dev/null \
    | awk 'NR==1                  { blank = ($0 ~ /^[[:space:]]*$/) }
           /[|+`\\]--|[└├│]/      { tree = 1 }
           END   { if (NR == 0)   print "empty"
                   else if (tree) print "tree"
                   else if (blank) print "blank"
                   else print "ok" }')" || true

  case "$verdict" in
    ok) return 0 ;;
    tree)
      echo "su_vpn.sh: pass entry '$VPN_PASS_ENTRY' returned a directory listing, not a" >&2
      echo "su_vpn.sh: password. It was probably renamed - check 'pass ls su.se'." >&2
      ;;
    blank)
      echo "su_vpn.sh: pass entry '$VPN_PASS_ENTRY' has an empty first line." >&2
      ;;
    *)
      echo "su_vpn.sh: pass entry '$VPN_PASS_ENTRY' is missing or would not decrypt." >&2
      ;;
  esac
  return 1
}

save_resolv_conf() {
  sudo cp /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
  sudo chown "$(id -u):$(id -g)" "$RESOLV_BACKUP" 2>/dev/null || true
}

clear_resolved_global_dns() {
  # FortiClient pins SU's resolver as systemd-resolved's *global* (manager,
  # ifindex 0) DNS at connect and never reverts it on disconnect, leaving it
  # stranded where it can shadow the per-link DNS NetworkManager configures - so
  # e.g. a LAN Pi-hole silently stops being used. `resolvectl revert` only
  # touches per-link config and there is no CLI to clear a runtime global
  # server, but a reload makes resolved re-read resolved.conf and drop the
  # in-memory global while keeping every per-link (NM/tailscale) config and the
  # DNS cache intact. Guarded to a no-op unless resolved is running, resolved.conf
  # configures no global DNS of its own (so any global server present is runtime
  # cruft, not intended config), and a global server is in fact set.
  systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
  grep -qsE '^[[:space:]]*DNS[[:space:]]*=[[:space:]]*[^[:space:]]' \
      /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf 2>/dev/null && return 0
  resolvectl status 2>/dev/null | awk '
    /^Global$/          { g = 1; next }
    /^Link /            { g = 0 }
    g && /DNS Servers:/ { sub(/.*DNS Servers:[[:space:]]*/, ""); if (length($0)) found = 1 }
    END                 { exit(found ? 0 : 1) }
  ' || return 0
  sudo systemctl reload systemd-resolved 2>/dev/null || true
}

restore_networkmanager_dns() {
  # FortiClient can also put SU's resolver on the LAN link itself (per-link,
  # e.g. "Link br0: 193.11.30.200"), replacing NetworkManager's servers, and
  # unreachable once the tunnel is gone. Have NetworkManager push its own
  # per-link DNS back into resolved. A device reapply does not do this.
  command -v nmcli >/dev/null 2>&1 || return 0
  sudo nmcli general reload dns-full 2>/dev/null || true
}

restore_resolv_conf() {
  # On systemd-resolved hosts /etc/resolv.conf is a symlink to resolved's stub;
  # restore that symlink rather than copying a flat file over it, which would
  # strip resolved's split-DNS / MagicDNS integration. Fall back to the flat-file
  # restore on hosts without resolved.
  if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
  elif [[ -s "$RESOLV_BACKUP" ]]; then
    sudo cp "$RESOLV_BACKUP" /etc/resolv.conf 2>/dev/null || true
  elif [[ -s /run/NetworkManager/resolv.conf ]]; then
    sudo cp /run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
  fi
  # The symlink restore above only fixes the stub file; resolved's stranded
  # global DNS lives in its runtime state and must be cleared separately.
  clear_resolved_global_dns
  restore_networkmanager_dns
  rm -f "$RESOLV_BACKUP"
}

wait_vpn_stopped() {
  local status
  for _ in {1..3}; do
    status="$(timeout 2 "$FORTIVPN" status 2>&1 || true)"
    grep -q "Status: Not Running" <<<"$status" && return 0
    sleep 1
  done
  return 1
}

save_default_route() {
  local line gw dev
  # Pick the first default route that has a real "via" gateway. While the
  # tunnel is up FortiClient leaves a gatewayless
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
  # Only a Tailscale *exit node* (full-tunnel) conflicts with the SU full
  # tunnel; a normal Tailscale session routes just 100.64/10 in its own table
  # and coexists fine, so we don't touch it. Detect the exit-node case via the
  # 0.0.0.0/1 split-default route Tailscale installs in its routing table
  # (table 52) when an exit node is active, and only warn - never disable it,
  # since Tailscale may be the user's remote-access path.
  if ip route show table 52 2>/dev/null | grep -q '^0\.0\.0\.0/1 '; then
    echo "su_vpn.sh: warning: a Tailscale exit node looks active (full-tunnel)." >&2
    echo "su_vpn.sh: it may capture traffic and conflict with the SU VPN." >&2
    echo "su_vpn.sh: run 'tailscale set --exit-node=' first if the VPN misbehaves." >&2
  fi
}

resolves_external_via() {
  # True if $1 can resolve a public name. one.one.one.one is short, stable, and
  # not the sort of thing a LAN Pi-hole blocklist touches. Captured into a
  # variable rather than piped into `grep -q`, because grep would exit on the
  # first match, SIGPIPE dig, and `set -o pipefail` would then report the whole
  # pipeline as failed even though the name resolved.
  local server="$1" answer
  answer="$(timeout 3 dig +short +time=2 +tries=1 A one.one.one.one "@$server" 2>/dev/null \
    | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' || true)"
  [[ -n "$answer" ]]
}

reference_resolver() {
  # A resolver to sanity-check a failing probe against, so a plain internet or
  # upstream-DNS outage is not misread as broken local DNS config. Prefer
  # systemd-resolved's stub, whose per-link config NetworkManager restores on its
  # own; otherwise the first nameserver NetworkManager knows about that isn't one
  # of Tailscale's own listeners.
  if systemctl is-active --quiet systemd-resolved 2>/dev/null \
     && [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    echo 127.0.0.53
    return 0
  fi
  awk '/^nameserver / && $2 != "100.100.100.100" && $2 !~ /^fd7a:/ { print $2; exit }' \
    /run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
}

resolv_conf_dns_broken() {
  # The failure this catches: FortiClient replaces /etc/resolv.conf with a flat
  # file while connected, which drops tailscaled out of systemd-resolved per-link
  # mode into direct mode. In direct mode it writes itself (100.100.100.100) into
  # resolv.conf as the *only* nameserver and must forward everything, using the
  # base resolvers it snapshotted when it took over - the VPN's. Those are
  # unreachable once the tunnel is gone, so every lookup dies, and restoring the
  # stub symlink does not clear the snapshot. A daemon restart re-detects
  # resolved and reinstalls per-link config.
  #
  # nsswitch consumers (getent, curl, ssh, browsers) never notice, because
  # resolved's own per-link config recovers on disconnect. Anything reading
  # /etc/resolv.conf directly does: nix eats curl's 15s DNS timeout per lookup
  # and silently falls back to cached flake pins.
  #
  # Probe exactly what resolv.conf names, nothing else. Do NOT probe
  # 100.100.100.100 as such: in resolved mode it correctly refuses to forward
  # anything but ts.net (Tailscale installs split-DNS routes and lets resolved
  # handle the rest), so treating that as a fault would restart tailscaled on
  # every healthy teardown.
  command -v dig >/dev/null 2>&1 || return 1
  local server saw_any=0
  while read -r server; do
    saw_any=1
    resolves_external_via "$server" && return 1
  done < <(awk '/^nameserver / { print $2 }' /etc/resolv.conf 2>/dev/null)
  [[ "$saw_any" == 1 ]] || return 1

  # Every listed resolver failed. Only call it broken if a reference resolver
  # can in fact resolve - otherwise this is an outage, not a config problem.
  local reference
  reference="$(reference_resolver)"
  [[ -n "$reference" ]] || return 1
  resolves_external_via "$reference"
}

tailscale_running() {
  # True when Tailscale is meant to be up, so nothing here overrides the user's
  # prefs. `|| true`: tailscale status fails while tailscaled is stopped, and
  # under pipefail that would abort the teardown before it removes the state
  # file.
  command -v tailscale >/dev/null 2>&1 || return 1
  local state
  state="$(tailscale status --json 2>/dev/null | awk -F'"' '/"BackendState"/ {print $4; exit}' || true)"
  [[ "$state" == "Running" ]]
}

revive_tailscale_tun() {
  # Our default-route churn during connect, and FortiClient while the tunnel is
  # up, can leave tailscale0 administratively down with no address. tailscaled
  # still reports Running and `tailscale ping` still answers over UDP, but there
  # are no tailnet routes and no MagicDNS, so `ssh <tailnet host>` fails with
  # "Could not resolve hostname" (2026-10-23, with the tunnel up). A plain
  # `tailscale up` will not recreate a downed TUN link; only a daemon restart
  # reliably brings tailscale0 back and reinstalls routes + DNS. Returns 0 only
  # if it restarted the daemon.
  local op
  op="$(cat "$TAILSCALE_OPERSTATE" 2>/dev/null || echo down)"
  [[ "$op" == "down" ]] || return 1
  echo "su_vpn.sh: tailscale0 is down; restarting tailscaled." >&2
  sudo systemctl restart tailscaled 2>/dev/null || true
}

reassert_tailscale() {
  # Our default-route churn during connect (delete default, reconnect) can race
  # tailscaled and leave tailscale0 down with no tailnet routes and MagicDNS
  # stripped from /etc/resolv.conf by our flat-file resolv restore, or leave the
  # daemon forwarding to the VPN's now-unreachable resolvers. Called from
  # restore_routes so every teardown leaves Tailscale intact. Respects the
  # user's prefs: only acts when Tailscale is meant to be running.
  tailscale_running || return 0

  if revive_tailscale_tun; then
    :
  elif [[ ! -L /etc/resolv.conf ]] \
       && tailscale dns status 2>/dev/null | grep -q "Tailscale DNS: enabled" \
       && ! grep -q '^nameserver 100\.100\.100\.100' /etc/resolv.conf 2>/dev/null; then
    # Flat-file resolv.conf host (no systemd-resolved): MagicDNS is enabled but
    # our resolv restore dropped it. Re-assert (idempotent: already enabled, so
    # no pref changes). On resolved hosts resolv.conf is a symlink and MagicDNS
    # lives in resolved's per-link config, so this branch is skipped.
    sudo tailscale set --accept-dns=true 2>/dev/null || true
  elif resolv_conf_dns_broken; then
    # Nothing in resolv.conf resolves, but a reference resolver does - tailscaled
    # is in direct mode forwarding to the VPN's dead resolvers (see the probe
    # above). Only a restart makes it re-read the base config. Gated on the probe
    # rather than run on every teardown, because a restart briefly drops the
    # tailnet - which would cut off anyone running this over Tailscale SSH.
    echo "su_vpn.sh: no resolver in /etc/resolv.conf works; restarting tailscaled." >&2
    sudo systemctl restart tailscaled 2>/dev/null || true
  fi
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

configure_docker_vpn_nat() {
  local vpn_source subnet iface
  vpn_source="$(default_route_source)"
  [[ -n "$vpn_source" ]] || return 0
  set_state VPN_SOURCE "$vpn_source"

  # Remove any older su_vpn.sh rules first. Stale rules can reference deleted
  # Docker bridges, and rules without the localhost exclusion break published
  # ports reached through http://localhost:PORT/ while the VPN is up.
  remove_docker_vpn_nat

  while IFS=$'\t' read -r subnet iface; do
    [[ -n "$subnet" && -n "$iface" ]] || continue
    sudo iptables -t nat -C POSTROUTING -s "$subnet" ! -d 127.0.0.0/8 ! -o "$iface" \
      -m comment --comment su_vpn.sh-docker-vpn -j SNAT --to-source "$vpn_source" 2>/dev/null \
      || sudo iptables -t nat -I POSTROUTING 1 -s "$subnet" ! -d 127.0.0.0/8 ! -o "$iface" \
        -m comment --comment su_vpn.sh-docker-vpn -j SNAT --to-source "$vpn_source" 2>/dev/null || true
  done < <(docker_bridge_routes)
}

remove_docker_vpn_nat() {
  # Delete all rules managed by this script, including stale rules for Docker
  # bridges that no longer exist.
  while read -r rule; do
    [[ -n "$rule" ]] || continue
    sudo timeout 5 bash -c "iptables -w 2 -t nat ${rule/-A POSTROUTING/-D POSTROUTING}" 2>/dev/null || true
  done < <(sudo iptables -t nat -S POSTROUTING 2>/dev/null | grep -- 'su_vpn.sh-docker-vpn' || true)
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

remove_forticlient_default_routes() {
  # FortiClient's default route is the one without a gateway:
  # "default dev br0 proto static scope link src <VPN address>". Found in the
  # live table rather than the state file, because it can outlive that file: a
  # shutdown with the tunnel up loses /tmp, yet FortiClient puts the route back
  # at boot. It can also be there twice. Prints the device of each one removed.
  local dev
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    sudo ip route del default dev "$dev" proto static scope link 2>/dev/null || true
    echo "$dev"
  done < <(ip -4 route show default \
    | awk '!/ via / && / proto static / && / scope link / {
             for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); break }
           }')
}

restore_routes() {
  local GATEWAY="" DEVICE="" VPN_SOURCE="" stranded dev
  remove_docker_vpn_nat
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  sudo ip route del "$VPN_PEER/32" 2>/dev/null || true
  stranded="$(remove_forticlient_default_routes)"
  remove_vpn_source_addr
  remove_stale_vpn_addrs
  if [[ -n "$GATEWAY" && -n "$DEVICE" ]]; then
    sudo ip route replace default via "$GATEWAY" dev "$DEVICE"
  elif command -v nmcli >/dev/null 2>&1; then
    # No saved gateway to put back - the state file went with /tmp - so let
    # NetworkManager reinstall the routes it owns on each device we stripped.
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      sudo nmcli device reapply "$dev" 2>/dev/null || true
    done < <(sort -u <<<"$stranded")
  fi
  restore_resolv_conf
  reassert_tailscale
  rm -f "$STATE_FILE"
}

start_watcher() {
  # The watcher (su_vpn_docker_watch.sh) runs only while connected: it keeps the
  # SNAT ahead of Docker's own rules and tears everything down if the tunnel
  # dies on its own. Hosts without the unit (it comes from the docker_vpn
  # Ansible role) simply go without it.
  systemctl cat "$WATCHER_UNIT" >/dev/null 2>&1 || return 0
  sudo systemctl start "$WATCHER_UNIT" 2>/dev/null \
    || echo "su_vpn.sh: warning: could not start $WATCHER_UNIT." >&2
}

stop_watcher() {
  # --no-block: the watcher would stop on its own within POLL seconds anyway,
  # so don't hold up disconnect waiting for it.
  systemctl cat "$WATCHER_UNIT" >/dev/null 2>&1 || return 0
  sudo systemctl stop --no-block "$WATCHER_UNIT" 2>/dev/null || true
}

require_forticlient() {
  # FortiClient Linux is a registration-gated manual install, so it is
  # not on every host this script can now reach. Check before anything else in
  # `connect`: everything below deletes the default route and relies on the EXIT
  # trap to put it back, so discovering the binary is missing at the `spawn`
  # line would cost a round trip through being offline for no reason at all.
  [ -x "$FORTIVPN" ] && return 0
  echo "su_vpn.sh: $FORTIVPN is not installed." >&2
  echo "su_vpn.sh: FortiClient Linux is a manual, registration-gated download -" >&2
  echo "su_vpn.sh: https://www.fortinet.com/support/product-downloads" >&2
  return 1
}

case "$ACTION" in
  connect)
    # Check credentials before touching any routes: a bad pass entry must fail
    # while the network is still intact, not after we have deleted the default.
    require_forticlient || exit 1
    check_pass_entry || exit 1
    take_lock
    warn_if_tailscale_exit_node
    remove_stale_vpn_addrs
    save_resolv_conf
    if ! save_default_route; then
      echo "su_vpn.sh: no default route found; cannot determine gateway." >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    # If the connect step below exits without reaching the success branch,
    # restore routes so the user isn't left offline.
    trap restore_routes EXIT

    pin_docker_routes
    sudo ip route replace "$VPN_PEER/32" via "$GATEWAY" dev "$DEVICE"
    sudo ip route del default 2>/dev/null || true

    rc=0
    # The entry *name* (not the secret) is passed through the environment so the
    # expect script below can stay single-quoted and share the constant above.
    # `9>&-`: the FortiClient daemon this spawns outlives the script, and an
    # inherited lock descriptor would hold the lock for the life of the tunnel.
    # shellcheck disable=SC2016 # $env(...) is expect's, not the shell's
    VPN_PASS_ENTRY="$VPN_PASS_ENTRY" FORTIVPN="$FORTIVPN" expect -c '
      set timeout 60
      log_user 1
      spawn $env(FORTIVPN) connect SU-Linux-vpn -u nelo6128
      set connected 0
      expect {
        -re "(?i)Password:" {
          send -- "[exec pass $env(VPN_PASS_ENTRY) | head -n 1]\r"
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
    ' 9>&- || rc=$?

    if [[ $rc -eq 0 ]]; then
      trap - EXIT
      # Re-pin Docker routes and SNAT container traffic to the VPN source address.
      pin_docker_routes
      configure_docker_vpn_nat
      if tailscale_running; then revive_tailscale_tun || true; fi
      start_watcher
      echo "su_vpn.sh: VPN connected. Run 'su_vpn.sh disconnect' to tear down and restore routes."
    else
      echo "su_vpn.sh: connect failed; restoring routes." >&2
      exit "$rc"
    fi
    ;;
  disconnect)
    take_lock
    timeout 5 "$FORTIVPN" disconnect 9>&- || pkill fortivpn || true
    wait_vpn_stopped || pkill fortivpn || true
    restore_routes
    stop_watcher
    echo "VPN Disconnected."
    ;;
  restore)
    # Emergency restore if the tunnel died but routes were left in place.
    take_lock
    restore_routes
    stop_watcher
    echo "Routes restored."
    ;;
  refresh-docker)
    # Re-apply the Docker<->VPN routes and NAT for the *current* set of bridges.
    # Safe to call anytime: a no-op unless the VPN is up. A state file left by
    # a tunnel that died is torn down instead, since NAT to its address would
    # cut the containers off. Exits NO_SESSION once there is no session left.
    # Docker rebuilds its iptables and can create new bridges on every
    # `compose up`, which leaves connect-time rules stale/mis-ordered; the
    # su-vpn-docker-nat.service watcher calls this on Docker network events so
    # containers (re)started AFTER `connect` still route out the tunnel instead
    # of black-holing with "Host is unreachable".
    [[ -f "$STATE_FILE" ]] || exit "$NO_SESSION"
    try_lock || exit 0
    case "$(tunnel_status)" in
      up)
        pin_docker_routes
        configure_docker_vpn_nat
        ;;
      down)
        reap_dead_tunnel
        exit "$NO_SESSION"
        ;;
      *) ;;
    esac
    ;;
  check)
    # Tear down if the tunnel has died. A dying tunnel raises no Docker event,
    # so the watcher also calls this on a timer. While the tunnel is up, bring
    # back a tailscale0 that went down mid-session. Exits NO_SESSION once there
    # is no session left: none to begin with, or this call just tore it down.
    [[ -f "$STATE_FILE" ]] || exit "$NO_SESSION"
    try_lock || exit 0
    [[ -f "$STATE_FILE" ]] || exit "$NO_SESSION"
    case "$(tunnel_status)" in
      up)
        if tailscale_running; then revive_tailscale_tun || true; fi
        ;;
      down)
        reap_dead_tunnel
        exit "$NO_SESSION"
        ;;
      *) ;;
    esac
    ;;
  *)
    echo "Usage: $0 {connect|disconnect|restore|refresh-docker|check}" >&2
    exit 1
    ;;
esac
