#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SSCLOAK_DIR="$APP_DIR/config-linux"
LOCAL_DIR="$APP_DIR/config-local"
CLIENT_ENV="$LOCAL_DIR/client.env"
cd "$APP_DIR"

usage() {
  cat <<'EOF'
Usage: ./vpn.sh <command>

Commands:
  configure Configure runtime files, systemd services, and resume hook
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

load_client_env() {
  if [[ ! -f "$CLIENT_ENV" ]]; then
    echo "Missing $CLIENT_ENV." >&2
    echo "Create it from config-local/client.example.env and fill in the shared client values." >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$CLIENT_ENV"

  local missing=()
  for name in SS_HOST SS_PORT SS_METHOD SS_PASSWORD CK_UID CK_PUBLIC_KEY; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done

  if ((${#missing[@]})); then
    echo "Missing required values in $CLIENT_ENV:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    return 1
  fi

  CK_SERVER_NAME="${CK_SERVER_NAME:-tile.openstreetmap.org}"
  CK_BROWSER_SIG="${CK_BROWSER_SIG:-chrome}"
  CK_PROXY_METHOD="${CK_PROXY_METHOD:-shadowsocks}"
  CK_ENCRYPTION_METHOD="${CK_ENCRYPTION_METHOD:-aes-gcm}"
  CK_TRANSPORT="${CK_TRANSPORT:-direct}"
  CK_STREAM_TIMEOUT="${CK_STREAM_TIMEOUT:-300}"
  CK_NUM_CONN="${CK_NUM_CONN:-1}"
  SS_LOCAL_SERVER="${SS_LOCAL_SERVER:-127.0.0.1}"
  SS_LOCAL_SERVER_PORT="${SS_LOCAL_SERVER_PORT:-16789}"
  SS_LOCAL_ADDRESS="${SS_LOCAL_ADDRESS:-127.0.0.1}"
  SS_LOCAL_PORT="${SS_LOCAL_PORT:-10810}"
  SS_TIMEOUT="${SS_TIMEOUT:-60}"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

write_client_configs() {
  load_client_env
  mkdir -p "$SSCLOAK_DIR"

  umask 077
  cat > "$SSCLOAK_DIR/ck-client.json" <<EOF
{
  "BrowserSig": "$(json_escape "$CK_BROWSER_SIG")",
  "EncryptionMethod": "$(json_escape "$CK_ENCRYPTION_METHOD")",
  "NumConn": $CK_NUM_CONN,
  "ProxyMethod": "$(json_escape "$CK_PROXY_METHOD")",
  "PublicKey": "$(json_escape "$CK_PUBLIC_KEY")",
  "RemoteHost": "$(json_escape "$SS_HOST")",
  "RemotePort": "$(json_escape "$SS_PORT")",
  "ServerName": "$(json_escape "$CK_SERVER_NAME")",
  "StreamTimeout": $CK_STREAM_TIMEOUT,
  "Transport": "$(json_escape "$CK_TRANSPORT")",
  "UID": "$(json_escape "$CK_UID")"
}
EOF

  cat > "$SSCLOAK_DIR/ss-local.json" <<EOF
{
  "server": "$(json_escape "$SS_LOCAL_SERVER")",
  "server_port": $SS_LOCAL_SERVER_PORT,
  "local_address": "$(json_escape "$SS_LOCAL_ADDRESS")",
  "local_port": $SS_LOCAL_PORT,
  "method": "$(json_escape "$SS_METHOD")",
  "password": "$(json_escape "$SS_PASSWORD")",
  "timeout": $SS_TIMEOUT
}
EOF
}

write_runtime_env() {
  local ck_bin ss_bin tun2socks_bin vps_ip
  mkdir -p "$SSCLOAK_DIR"

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

  vps_ip="${VPS_IP:-}"
  if [[ -z "$vps_ip" && "$SS_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    vps_ip="$SS_HOST"
  fi

  umask 022
  {
    printf 'CK_BIN=%q\n' "$ck_bin"
    printf 'SS_BIN=%q\n' "$ss_bin"
    printf 'TUN2SOCKS_BIN=%q\n' "$tun2socks_bin"
    printf 'SSCLOAK_DIR=%q\n' "$SSCLOAK_DIR"
    printf 'REMOTE_HOST=%q\n' "$SS_HOST"
    [[ -n "$vps_ip" ]] && printf 'VPS_IP=%q\n' "$vps_ip"
  } > "$SSCLOAK_DIR/runtime.env"
}

check_client_configs() {
  write_client_configs
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
WorkingDirectory=$APP_DIR
EnvironmentFile=$SSCLOAK_DIR/runtime.env
ExecStartPre=/bin/rm -f /tmp/ck-client-sscloak-8443.pid /tmp/ss-local-sscloak-8443.pid
ExecStart=$APP_DIR/vpn.sh __local-start
ExecStop=$APP_DIR/vpn.sh __local-stop
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
ExecStartPre=$APP_DIR/vpn.sh __tun-up
ExecStart=$APP_DIR/vpn.sh __tun-start
ExecStopPost=$APP_DIR/vpn.sh __tun-down
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  cat > "$sleep_hook" <<EOF
#!/usr/bin/env bash
set -euo pipefail

exec "$APP_DIR/vpn.sh" __sleep-hook "\${1:-}"
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

load_runtime_env() {
  if [[ -f "$SSCLOAK_DIR/runtime.env" ]]; then
    # shellcheck disable=SC1090
    source "$SSCLOAK_DIR/runtime.env"
  fi
}

start_detached() {
  local pid_file="$1"
  local log_file="$2"
  shift 2

  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" >"$log_file" 2>&1
    sleep 0.2
    pgrep -n -f "$*" >"$pid_file"
  else
    nohup "$@" >"$log_file" 2>&1 &
    echo "$!" >"$pid_file"
  fi
}

local_start() {
  load_runtime_env

  local ck_bin ss_bin ck_log ss_log ck_pid_file ss_pid_file
  ck_bin="$(detect_bin CK_BIN ck-client)"
  ss_bin="$(detect_bin SS_BIN ss-local)"
  ck_log="${CK_LOG:-/tmp/ck-client-sscloak-8443.log}"
  ss_log="${SS_LOG:-/tmp/ss-local-sscloak-8443.log}"
  ck_pid_file="${CK_PID_FILE:-/tmp/ck-client-sscloak-8443.pid}"
  ss_pid_file="${SS_PID_FILE:-/tmp/ss-local-sscloak-8443.pid}"

  if (( EUID == 0 )); then
    echo "Do not run local client startup as root." >&2
    exit 1
  fi

  if ss -lnt | awk '{print $4}' | grep -qx '127.0.0.1:16789'; then
    echo "Port 127.0.0.1:16789 is already in use" >&2
    exit 1
  fi

  if ss -lnt | awk '{print $4}' | grep -qx '127.0.0.1:10810'; then
    echo "Port 127.0.0.1:10810 is already in use" >&2
    exit 1
  fi

  start_detached "$ck_pid_file" "$ck_log" "$ck_bin" -c "$SSCLOAK_DIR/ck-client.json" -l 16789
  sleep 1

  if ! kill -0 "$(cat "$ck_pid_file")" 2>/dev/null; then
    echo "ck-client failed to start. Log:" >&2
    tail -80 "$ck_log" >&2
    exit 1
  fi

  start_detached "$ss_pid_file" "$ss_log" "$ss_bin" -c "$SSCLOAK_DIR/ss-local.json"
  sleep 1

  if ! kill -0 "$(cat "$ss_pid_file")" 2>/dev/null; then
    echo "ss-local failed to start. Log:" >&2
    tail -80 "$ss_log" >&2
    kill "$(cat "$ck_pid_file")" 2>/dev/null || true
    rm -f "$ck_pid_file"
    exit 1
  fi

  echo "sscloak local client is running on 127.0.0.1:10810"
}

local_stop() {
  load_runtime_env

  local ck_pid_file ss_pid_file
  ck_pid_file="${CK_PID_FILE:-/tmp/ck-client-sscloak-8443.pid}"
  ss_pid_file="${SS_PID_FILE:-/tmp/ss-local-sscloak-8443.pid}"

  if [[ -f "$ss_pid_file" ]] && kill -0 "$(cat "$ss_pid_file")" 2>/dev/null; then
    kill "$(cat "$ss_pid_file")" 2>/dev/null || true
    rm -f "$ss_pid_file"
  fi

  if [[ -f "$ck_pid_file" ]] && kill -0 "$(cat "$ck_pid_file")" 2>/dev/null; then
    kill "$(cat "$ck_pid_file")" 2>/dev/null || true
    rm -f "$ck_pid_file"
  fi

  pkill -f "ck-client .*$SSCLOAK_DIR/ck-client.json" 2>/dev/null || true
  pkill -f "ss-local .*$SSCLOAK_DIR/ss-local.json" 2>/dev/null || true
}

tun_up() {
  load_runtime_env

  local tun_dev tun_addr vps_ip state_file orig_gw orig_dev
  tun_dev="${TUN_DEV:-tun1}"
  tun_addr="${TUN_ADDR:-198.19.0.1/15}"
  vps_ip="${VPS_IP:-}"
  state_file="${STATE_FILE:-/run/sscloak-vpn-default-route}"

  if (( EUID != 0 )); then
    echo "Run via: ./vpn.sh on" >&2
    exit 1
  fi

  if [[ -z "$vps_ip" ]]; then
    echo "VPS_IP is not set. Run ./vpn.sh configure, or set VPS_IP explicitly." >&2
    exit 1
  fi

  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
  else
    orig_gw="$(ip -4 route show default | awk -v tun="$tun_dev" '$5 != tun { print $3; exit }')"
    orig_dev="$(ip -4 route show default | awk -v tun="$tun_dev" '$5 != tun { print $5; exit }')"

    if [[ -z "${orig_gw:-}" || -z "${orig_dev:-}" ]]; then
      echo "Could not find a non-${tun_dev} default route" >&2
      exit 1
    fi

    umask 022
    printf 'ORIG_GW=%q\nORIG_DEV=%q\n' "$orig_gw" "$orig_dev" > "$state_file"
  fi

  ip tuntap add mode tun dev "$tun_dev" 2>/dev/null || true
  ip addr flush dev "$tun_dev"
  ip addr add "$tun_addr" dev "$tun_dev"
  ip link set "$tun_dev" mtu 1500 up

  ip route replace "$vps_ip/32" via "$ORIG_GW" dev "$ORIG_DEV"

  while read -r route; do
    [[ -z "$route" ]] && continue
    if [[ "$route" != *" dev $tun_dev"* ]]; then
      ip route del $route 2>/dev/null || true
    fi
  done < <(ip -4 route show 0.0.0.0/1)

  while read -r route; do
    [[ -z "$route" ]] && continue
    if [[ "$route" != *" dev $tun_dev"* ]]; then
      ip route del $route 2>/dev/null || true
    fi
  done < <(ip -4 route show 128.0.0.0/1)

  ip route replace default dev "$tun_dev" metric 1
  ip route replace 0.0.0.0/1 dev "$tun_dev" metric 1
  ip route replace 128.0.0.0/1 dev "$tun_dev" metric 1
  ip route flush cache
}

tun_start() {
  load_runtime_env

  local tun_dev socks_addr tun2socks_bin
  tun_dev="${TUN_DEV:-tun1}"
  socks_addr="${SOCKS_ADDR:-127.0.0.1:10810}"
  tun2socks_bin="$(detect_bin TUN2SOCKS_BIN tun2socks)"

  exec "$tun2socks_bin" -device "tun://$tun_dev" -proxy "socks5://$socks_addr" -loglevel info
}

tun_down() {
  load_runtime_env

  local tun_dev vps_ip state_file
  tun_dev="${TUN_DEV:-tun1}"
  vps_ip="${VPS_IP:-}"
  state_file="${STATE_FILE:-/run/sscloak-vpn-default-route}"

  if (( EUID != 0 )); then
    echo "Run via: ./vpn.sh off" >&2
    exit 1
  fi

  while read -r route; do
    [[ -z "$route" ]] && continue
    ip route del $route 2>/dev/null || true
  done < <(ip -4 route show dev "$tun_dev" 2>/dev/null || true)

  if [[ -n "$vps_ip" ]]; then
    ip route del "$vps_ip/32" 2>/dev/null || true
  fi
  ip link set "$tun_dev" down 2>/dev/null || true
  ip tuntap del mode tun dev "$tun_dev" 2>/dev/null || ip link del "$tun_dev" 2>/dev/null || true

  rm -f "$state_file"
}

clean_vpn() {
  load_runtime_env

  local tun_dev vps_ip state_file
  tun_dev="${TUN_DEV:-tun1}"
  vps_ip="${VPS_IP:-}"
  state_file="${STATE_FILE:-/run/sscloak-vpn-default-route}"

  if (( EUID != 0 )); then
    echo "Run with sudo: sudo ./vpn.sh off" >&2
    exit 1
  fi

  systemctl stop sscloak-tun.service sscloak-client.service 2>/dev/null || true
  local_stop 2>/dev/null || true
  pkill -f 'tun2socks .*socks5://127\.0\.0\.1:10810' 2>/dev/null || true

  while read -r route; do
    [[ -z "$route" ]] && continue
    ip route del $route 2>/dev/null || true
  done < <(ip -4 route show dev "$tun_dev" 2>/dev/null || true)

  if [[ -n "$vps_ip" ]]; then
    ip route del "$vps_ip/32" 2>/dev/null || true
  fi
  ip link set "$tun_dev" down 2>/dev/null || true
  ip tuntap del mode tun dev "$tun_dev" 2>/dev/null || ip link del "$tun_dev" 2>/dev/null || true

  rm -f "$state_file" /tmp/ck-client-sscloak-8443.pid /tmp/ss-local-sscloak-8443.pid
  echo "sscloak stopped and cleaned"
}

sleep_hook() {
  local state_file="/run/sscloak-vpn-was-active"

  case "${1:-}" in
    pre)
      if systemctl is-active --quiet sscloak-tun.service; then
        touch "$state_file"
      else
        rm -f "$state_file"
      fi
      ;;
    post)
      if [[ -f "$state_file" ]]; then
        systemctl stop sscloak-tun.service sscloak-client.service 2>/dev/null || true
        "$APP_DIR/vpn.sh" __clean >/dev/null 2>&1 || true
        systemctl reset-failed sscloak-client.service sscloak-tun.service 2>/dev/null || true
        systemctl start sscloak-tun.service
        rm -f "$state_file"
      fi
      ;;
  esac
}

configure_vpn() {
  local run_user
  run_user="${SUDO_USER:-$(id -un)}"

  chmod +x "$APP_DIR/vpn.sh"
  check_client_configs
  write_runtime_env

  install_units "$run_user"

  sudo systemctl daemon-reload
  sudo systemctl enable sscloak-client.service sscloak-tun.service

  echo "Configured sscloak VPN."
  echo "Use: ./vpn.sh configure | on | off | status | restart | run"
}

start_vpn() {
  if [[ ! -f "$SSCLOAK_DIR/runtime.env" ]]; then
    echo "Missing $SSCLOAK_DIR/runtime.env; running configure first."
    configure_vpn
  else
    write_client_configs
    write_runtime_env
  fi

  echo "Cleaning stale sscloak state..."
  sudo "$APP_DIR/vpn.sh" __clean >/dev/null
  sudo systemctl reset-failed sscloak-client.service sscloak-tun.service 2>/dev/null || true

  check_amnezia_blockers

  sudo systemctl start sscloak-tun.service
  echo "Started sscloak VPN."
}

stop_vpn() {
  need_sudo "$@"
  clean_vpn
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
    echo "Could not determine server IP; set VPS_IP and run ./vpn.sh configure."
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
  sudo "$APP_DIR/vpn.sh" __clean >/dev/null
  sleep 1
  start_vpn
}

run_vpn() {
  need_sudo "$@"
  write_client_configs

  cleanup() {
    echo
    echo "Stopping sscloak VPN..."
    "$APP_DIR/vpn.sh" __clean >/dev/null 2>&1 || true
    echo "Stopped."
  }

  trap cleanup EXIT INT TERM

  echo "Cleaning stale sscloak state..."
  "$APP_DIR/vpn.sh" __clean >/dev/null 2>&1 || true
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
  configure) configure_vpn "$@" ;;
  on) start_vpn "$@" ;;
  off) stop_vpn "$@" ;;
  status) status_vpn "$@" ;;
  restart) restart_vpn "$@" ;;
  run) run_vpn "$@" ;;
  __local-start) local_start "$@" ;;
  __local-stop) local_stop "$@" ;;
  __tun-up) tun_up "$@" ;;
  __tun-start) tun_start "$@" ;;
  __tun-down) tun_down "$@" ;;
  __clean) clean_vpn "$@" ;;
  __sleep-hook) sleep_hook "$@" ;;
  -h|--help|help|"") usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
