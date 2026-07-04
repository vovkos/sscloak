#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${SSCLOAK_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
STATE_FILE="/run/sscloak-vpn-was-active"

case "${1:-}" in
  pre)
    if systemctl is-active --quiet sscloak-tun.service; then
      touch "$STATE_FILE"
    else
      rm -f "$STATE_FILE"
    fi
    ;;
  post)
    if [[ -f "$STATE_FILE" ]]; then
      systemctl stop sscloak-tun.service sscloak-client.service 2>/dev/null || true
      "$SCRIPT_DIR/clean.sh" >/dev/null 2>&1 || true
      systemctl reset-failed sscloak-client.service sscloak-tun.service 2>/dev/null || true
      systemctl start sscloak-tun.service
      rm -f "$STATE_FILE"
    fi
    ;;
esac
