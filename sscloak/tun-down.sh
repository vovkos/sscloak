#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "$SCRIPT_DIR/runtime.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/runtime.env"
fi

TUN_DEV="${TUN_DEV:-tun1}"
VPS_IP="${VPS_IP:-}"
STATE_FILE="${STATE_FILE:-/run/sscloak-vpn-default-route}"

if (( EUID != 0 )); then
  echo "Run via: ./vpn.sh off" >&2
  exit 1
fi

while read -r route; do
  [[ -z "$route" ]] && continue
  ip route del $route 2>/dev/null || true
done < <(ip -4 route show dev "$TUN_DEV" 2>/dev/null || true)

if [[ -n "$VPS_IP" ]]; then
  ip route del "$VPS_IP/32" 2>/dev/null || true
fi
ip link set "$TUN_DEV" down 2>/dev/null || true
ip tuntap del mode tun dev "$TUN_DEV" 2>/dev/null || ip link del "$TUN_DEV" 2>/dev/null || true

rm -f "$STATE_FILE"
