#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SSCLOAK_DIR="$APP_DIR/sscloak"
cd "$APP_DIR"

usage() {
  cat <<'EOF'
Usage: ./vpn.sh <command>

Commands:
  install   Install/update systemd services and resume hook
  on        Start VPN through Shadowsocks over Cloak
  off       Stop VPN and restore routes
  restart   Stop, clean, and start again
  status    Show service, route, and public IP status
  run       Foreground mode: start VPN, show logs, Ctrl-C stops it
EOF
}

need_sudo() {
  if (( EUID != 0 )); then
    exec sudo "$APP_DIR/vpn.sh" "$@"
  fi
}

detect_bin() {
  local env_name="$1"
  shift
  local configured="${!env_name:-}"
  local search_dirs="${BIN_SEARCH_DIRS:-/usr/local/bin:/usr/bin:/bin:/opt}"

  if [[ -n "$configured" ]]; then
    if [[ -x "$configured" ]]; then
      printf '%s\n' "$configured"
      return 0
    fi
    echo "$env_name is set but not executable: $configured" >&2
    return 1
  fi

  local candidate
  for candidate in "$@"; do
    if [[ "$candidate" == */* ]]; then
      [[ -x "$candidate" ]] && printf '%s\n' "$candidate" && return 0
    elif command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    else
      local search_dir found
      while IFS= read -r search_dir; do
        [[ -d "$search_dir" ]] || continue
        found="$(find "$search_dir" -type f -name "$candidate" -perm /111 -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
          printf '%s\n' "$found"
          return 0
        fi
      done < <(printf '%s\n' "$search_dirs" | tr ':' '\n')
    fi
  done

  return 1
}

write_runtime_env() {
  local ck_bin ss_bin tun2socks_bin remote_host vps_ip

  ck_bin="$(detect_bin CK_BIN ck-client)" || {
    echo "Could not find ck-client. Install Cloak client or set CK_BIN=/path/to/ck-client." >&2
    return 1
  }
  ss_bin="$(detect_bin SS_BIN ss-local)" || {
    echo "Could not find ss-local. Install shadowsocks-libev or set SS_BIN=/path/to/ss-local." >&2
    return 1
  }
  tun2socks_bin="$(detect_bin TUN2SOCKS_BIN tun2socks)" || {
    echo "Could not find tun2socks. Install tun2socks or set TUN2SOCKS_BIN=/path/to/tun2socks." >&2
    return 1
  }

  if [[ -f "$SSCLOAK_DIR/ck-client.json" ]]; then
    remote_host="$(sed -n 's/.*"RemoteHost"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SSCLOAK_DIR/ck-client.json" | head -n 1)"
  else
    remote_host=""
  fi

  vps_ip="${VPS_IP:-}"
  if [[ -z "$vps_ip" && "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    vps_ip="$remote_host"
  fi

  umask 022
  {
    printf 'CK_BIN=%q\n' "$ck_bin"
    printf 'SS_BIN=%q\n' "$ss_bin"
    printf 'TUN2SOCKS_BIN=%q\n' "$tun2socks_bin"
    printf 'SSCLOAK_DIR=%q\n' "$SSCLOAK_DIR"
    [[ -n "$remote_host" ]] && printf 'REMOTE_HOST=%q\n' "$remote_host"
    [[ -n "$vps_ip" ]] && printf 'VPS_IP=%q\n' "$vps_ip"
  } > "$SSCLOAK_DIR/runtime.env"
}

check_client_configs() {
  local missing=()

  [[ -f "$SSCLOAK_DIR/ck-client.json" ]] || missing+=("$SSCLOAK_DIR/ck-client.json")
  [[ -f "$SSCLOAK_DIR/ss-local.json" ]] || missing+=("$SSCLOAK_DIR/ss-local.json")

  if ((${#missing[@]})); then
    echo "Missing local client config:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Create them from the examples and fill in your server values:" >&2
    echo "  cp sscloak/ck-client.example.json sscloak/ck-client.json" >&2
    echo "  cp sscloak/ss-local.example.json sscloak/ss-local.json" >&2
    return 1
  fi
}

get_vps_ip() {
  local remote_host=""

  if [[ -f "$SSCLOAK_DIR/runtime.env" ]]; then
    # shellcheck disable=SC1090
    source "$SSCLOAK_DIR/runtime.env"
  fi

  if [[ -n "${VPS_IP:-}" ]]; then
    printf '%s\n' "$VPS_IP"
    return 0
  fi

  if [[ -n "${REMOTE_HOST:-}" ]]; then
    remote_host="$REMOTE_HOST"
  elif [[ -f "$SSCLOAK_DIR/ck-client.json" ]]; then
    remote_host="$(sed -n 's/.*"RemoteHost"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SSCLOAK_DIR/ck-client.json" | head -n 1)"
  fi

  [[ -n "$remote_host" ]] || return 1

  if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$remote_host"
    return 0
  fi

  getent ahostsv4 "$remote_host" 2>/dev/null | awk '{ print $1; exit }'
}

install_units() {
  local run_user="$1"
  local tmp_dir client_unit tun_unit sleep_hook

  tmp_dir="$(mktemp -d)"
  client_unit="$tmp_dir/sscloak-client.service"
  tun_unit="$tmp_dir/sscloak-tun.service"
  sleep_hook="$tmp_dir/sscloak-vpn"

  cat > "$client_unit" <<EOF
[Unit]
Description=Shadowsocks over Cloak local SOCKS client
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$run_user
WorkingDirectory=$SSCLOAK_DIR
EnvironmentFile=$SSCLOAK_DIR/runtime.env
ExecStartPre=/bin/rm -f /tmp/ck-client-sscloak-8443.pid /tmp/ss-local-sscloak-8443.pid
ExecStart=$SSCLOAK_DIR/local-start.sh
ExecStop=$SSCLOAK_DIR/local-stop.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "$tun_unit" <<EOF
[Unit]
Description=TUN routing through Shadowsocks over Cloak
After=sscloak-client.service
Requires=sscloak-client.service

[Service]
Type=simple
EnvironmentFile=$SSCLOAK_DIR/runtime.env
ExecStartPre=$SSCLOAK_DIR/tun-up.sh
ExecStart=$SSCLOAK_DIR/tun-start.sh
ExecStopPost=$SSCLOAK_DIR/tun-down.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  cat > "$sleep_hook" <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/run/sscloak-vpn-was-active"

case "\${1:-}" in
  pre)
    if systemctl is-active --quiet sscloak-tun.service; then
      touch "\$STATE_FILE"
    else
      rm -f "\$STATE_FILE"
    fi
    ;;
  post)
    if [[ -f "\$STATE_FILE" ]]; then
      systemctl stop sscloak-tun.service sscloak-client.service 2>/dev/null || true
      "$SSCLOAK_DIR/clean.sh" >/dev/null 2>&1 || true
      systemctl reset-failed sscloak-client.service sscloak-tun.service 2>/dev/null || true
      systemctl start sscloak-tun.service
      rm -f "\$STATE_FILE"
    fi
    ;;
esac
EOF

  sudo install -m 0755 "$sleep_hook" /usr/lib/systemd/system-sleep/sscloak-vpn
  sudo install -m 0644 "$client_unit" /etc/systemd/system/sscloak-client.service
  sudo install -m 0644 "$tun_unit" /etc/systemd/system/sscloak-tun.service
  rm -rf "$tmp_dir"
}

check_amnezia_blockers() {
  local blockers=()

  if pgrep -x openvpn >/dev/null 2>&1; then
    blockers+=("openvpn process is still running")
  fi

  if ip -br addr show tun0 >/dev/null 2>&1; then
    blockers+=("tun0 still exists")
  fi

  if ((${#blockers[@]})); then
    echo "Another tunnel still appears active:" >&2
    printf '  - %s\n' "${blockers[@]}" >&2
    echo >&2
    echo "Disconnect it first, then run this again." >&2
    exit 1
  fi
}

install_vpn() {
  local run_user
  run_user="${SUDO_USER:-$(id -un)}"

  chmod +x "$SSCLOAK_DIR"/*.sh "$APP_DIR/vpn.sh"
  check_client_configs
  write_runtime_env

  install_units "$run_user"

  sudo systemctl daemon-reload
  sudo systemctl enable sscloak-client.service sscloak-tun.service

  echo "Installed sscloak VPN."
  echo "Use: ./vpn.sh on | off | status | restart | run"
}

start_vpn() {
  if [[ ! -f "$SSCLOAK_DIR/runtime.env" ]]; then
    echo "Missing $SSCLOAK_DIR/runtime.env; running install first."
    install_vpn
  fi

  echo "Cleaning stale sscloak state..."
  sudo "$SSCLOAK_DIR/clean.sh" >/dev/null
  sudo systemctl reset-failed sscloak-client.service sscloak-tun.service 2>/dev/null || true

  check_amnezia_blockers

  sudo systemctl start sscloak-tun.service
  echo "Started sscloak VPN."
}

stop_vpn() {
  need_sudo "$@"
  "$SSCLOAK_DIR/clean.sh"
}

status_vpn() {
  echo "Services:"
  systemctl --no-pager --full status sscloak-client.service sscloak-tun.service 2>/dev/null || true

  echo
  echo "Interfaces:"
  ip -br addr

  echo
  echo "Routes:"
  ip -4 route show table main

  echo
  echo "Route decisions:"
  vps_ip="$(get_vps_ip || true)"
  if [[ -n "$vps_ip" ]]; then
    ip -4 route get "$vps_ip" || true
  else
    echo "Could not determine server IP; set VPS_IP and run ./vpn.sh install."
  fi
  ip -4 route get 8.8.8.8 || true

  echo
  echo "Relevant processes:"
  pgrep -a -f 'sscloak|ss-local-sscloak|ck-client-sscloak|tun2socks|openvpn' || true

  echo
  echo "Listening ports:"
  ss -lntup | grep -E '(:10810|:16789|sscloak|tun2socks|ck-client|ss-local)' || true

  echo
  echo "Public IPs:"
  printf "default route: "
  curl -4 --max-time 10 -sS ifconfig.me || true
  echo
  printf "local socks: "
  curl -4 --socks5-hostname 127.0.0.1:10810 --max-time 10 -sS ifconfig.me || true
  echo
}

restart_vpn() {
  sudo "$SSCLOAK_DIR/clean.sh" >/dev/null
  sleep 1
  start_vpn
}

run_vpn() {
  need_sudo "$@"

  cleanup() {
    echo
    echo "Stopping sscloak VPN..."
    "$SSCLOAK_DIR/clean.sh" >/dev/null 2>&1 || true
    echo "Stopped."
  }

  trap cleanup EXIT INT TERM

  echo "Cleaning stale sscloak state..."
  "$SSCLOAK_DIR/clean.sh" >/dev/null 2>&1 || true
  systemctl reset-failed sscloak-client.service sscloak-tun.service 2>/dev/null || true

  check_amnezia_blockers

  echo "Starting sscloak VPN..."
  systemctl start sscloak-tun.service

  echo
  echo "VPN is running. Press Ctrl-C to stop and restore routes."
  echo
  status_vpn

  echo
  echo "Live logs:"
  journalctl -f -u sscloak-client.service -u sscloak-tun.service
}

cmd="${1:-}"
shift || true

case "$cmd" in
  install) install_vpn "$@" ;;
  on) start_vpn "$@" ;;
  off) stop_vpn "$@" ;;
  status) status_vpn "$@" ;;
  restart) restart_vpn "$@" ;;
  run) run_vpn "$@" ;;
  -h|--help|help|"") usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
