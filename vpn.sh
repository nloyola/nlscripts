#!/usr/bin/env bash
# Usage: ./vpn.sh {connect|disconnect}

set -euo pipefail

ACTION="${1:-}"

case "$ACTION" in
  connect)
    # Use expect inline (works the same as your working one-liner)
    expect -c '
      set timeout -1
      log_user 1
      spawn forticlient vpn connect SU-Linux-vpn -u nelo6128
      expect -re "(?i)Password:"
      send -- "[exec pass su.se]\r"
      interact
    '
    ;;
  disconnect)
    forticlient vpn disconnect
    ;;
  *)
    echo "Usage: $0 {connect|disconnect}" >&2
    exit 1
    ;;
esac
