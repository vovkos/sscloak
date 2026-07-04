#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "$SCRIPT_DIR/runtime.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/runtime.env"
fi

TUN_DEV="${TUN_DEV:-tun1}"
TUN_ADDR="${TUN_ADDR:-198.19.0.1/15}"
VPS_IP="${VPS_IP:-}"
STATE_FILE="${STATE_FILE:-/run/sscloak-vpn-default-route}"

if (( EUID != 0 )); then
  echo "Run via: ./vpn.sh on" >&2
  exit 1
fi

if [[ -z "$VPS_IP" ]]; then
  echo "VPS_IP is not set. Run ./vpn.sh install, or set VPS_IP explicitly." >&2
  exit 1
fi

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
else
  ORIG_GW="$(ip -4 route show default | awk -v tun="$TUN_DEV" '$5 != tun { print $3; exit }')"
  ORIG_DEV="$(ip -4 route show default | awk -v tun="$TUN_DEV" '$5 != tun { print $5; exit }')"

  if [[ -z "${ORIG_GW:-}" || -z "${ORIG_DEV:-}" ]]; then
    echo "Could not find a non-${TUN_DEV} default route" >&2
    exit 1
  fi

  umask 022
  printf 'ORIG_GW=%q\nORIG_DEV=%q\n' "$ORIG_GW" "$ORIG_DEV" > "$STATE_FILE"
fi

ip tuntap add mode tun dev "$TUN_DEV" 2>/dev/null || true
ip addr flush dev "$TUN_DEV"
ip addr add "$TUN_ADDR" dev "$TUN_DEV"
ip link set "$TUN_DEV" mtu 1500 up

ip route replace "$VPS_IP/32" via "$ORIG_GW" dev "$ORIG_DEV"

while read -r route; do
  [[ -z "$route" ]] && continue
  if [[ "$route" != *" dev $TUN_DEV"* ]]; then
    ip route del $route 2>/dev/null || true
  fi
done < <(ip -4 route show 0.0.0.0/1)

while read -r route; do
  [[ -z "$route" ]] && continue
  if [[ "$route" != *" dev $TUN_DEV"* ]]; then
    ip route del $route 2>/dev/null || true
  fi
done < <(ip -4 route show 128.0.0.0/1)

ip route replace default dev "$TUN_DEV" metric 1
ip route replace 0.0.0.0/1 dev "$TUN_DEV" metric 1
ip route replace 128.0.0.0/1 dev "$TUN_DEV" metric 1
ip route flush cache
