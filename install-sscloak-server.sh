#!/usr/bin/env bash
# Sets up an sscloak server (Cloak + Shadowsocks) on a clean Ubuntu host.
# Result: running systemd services and a Shadowrocket QR-code PNG.
#
#   scp install-sscloak-server.sh user@server:~/
#   ssh -t user@server 'bash ~/install-sscloak-server.sh'
#
# The sudo password is asked once, when first needed.
set -euo pipefail

CLOAK_VERSION="${CLOAK_VERSION:-v2.12.0}"
SSRUST_VERSION="${SSRUST_VERSION:-v1.24.0}"

SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
SS_PORT="${SS_PORT:-443}"
SS_HOST="${SS_HOST:-}"
CK_SERVER_NAME="${CK_SERVER_NAME:-tile.openstreetmap.org}"
SS_BACKEND_PORT="${SS_BACKEND_PORT:-6789}"

REGENERATE="${REGENERATE:-0}"
SKIP_SELFTEST="${SKIP_SELFTEST:-0}"
OUT_DIR="${OUT_DIR:-$PWD}"

SUDO=""
APT_UPDATED=0
KEEPALIVE_PID=""
TMP_DIR=""
SELFTEST_PIDS=()

usage() {
  cat <<'EOF'
Usage: bash install-sscloak-server.sh [--help]

Installs ck-server + ssserver on this host, generates keys, starts systemd
services, opens the port, and writes a Shadowrocket QR-code PNG.

Environment variables (all optional):
  SS_HOST=<domain|IP>    address clients connect to (default: public IP)
  SS_PORT=443            public Cloak TCP port
  OUT_DIR=<dir>          where to write the QR code (default: current dir)
  REGENERATE=1           regenerate keys even if the server is already set up
  SKIP_SELFTEST=1        skip the local-client tunnel check
  CLOAK_VERSION, SSRUST_VERSION -- release versions
EOF
}

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m\nError: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  local pid
  for pid in ${SELFTEST_PIDS[@]+"${SELFTEST_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null || true
  [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

ask() { # ask "question" [default] -- without a terminal, takes the default
  local prompt="$1" def="${2:-}" ans
  if [[ ! -t 0 ]]; then
    printf '%s' "$def"
    return
  fi
  read -r -p "    $prompt${def:+ [$def]}: " ans || true
  printf '%s' "${ans:-$def}"
}

confirm() { # confirm "question" [y|n]
  local prompt="$1" def="${2:-y}" hint ans
  if [[ ! -t 0 ]]; then
    [[ "$def" == y ]]
    return
  fi
  if [[ "$def" == y ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "    $prompt [$hint]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^([yY]|[yY][eE][sS])$ ]]
}

init_sudo() {
  if (( EUID == 0 )); then
    SUDO=""
    return
  fi
  command -v sudo >/dev/null 2>&1 || die "Not root and no sudo."
  if ! sudo -n true 2>/dev/null; then
    say "Root required -- enter the sudo password"
    sudo -v
  fi
  # Ask once: keep the sudo timestamp alive until the install finishes.
  ( while true; do sleep 50; sudo -n true 2>/dev/null || exit; done ) &
  KEEPALIVE_PID=$!
  SUDO="sudo"
}

apt_install() {
  local pkg missing=()
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  ((${#missing[@]})) || return 0

  if (( ! APT_UPDATED )); then
    say "Updating package lists"
    $SUDO apt-get update -qq
    APT_UPDATED=1
  fi
  info "Installing: ${missing[*]}"
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  GO_ARCH="amd64"; SSRUST_TRIPLE="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) GO_ARCH="arm64"; SSRUST_TRIPLE="aarch64-unknown-linux-gnu" ;;
    *) die "Architecture $(uname -m) not supported by this script -- install binaries by hand (README.md)." ;;
  esac
}

fetch() { # fetch URL file
  curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1" || die "Download failed: $1"
}

install_bin() { # install_bin file name
  $SUDO install -m 0755 "$1" "/usr/local/bin/$2"
  info "Installed /usr/local/bin/$2"
}

install_cloak() { # install_cloak server|client
  local role="$1" name="ck-$1"
  if command -v "$name" >/dev/null 2>&1; then
    info "$name already present: $(command -v "$name")"
    return
  fi
  info "Downloading $name $CLOAK_VERSION"
  fetch "https://github.com/cbeuw/Cloak/releases/download/${CLOAK_VERSION}/ck-${role}-linux-${GO_ARCH}-${CLOAK_VERSION}" \
        "$TMP_DIR/$name"
  install_bin "$TMP_DIR/$name" "$name"
}

install_shadowsocks() { # install_shadowsocks ssserver|sslocal
  local want="$1" unpack="$TMP_DIR/ssrust" bin
  if command -v "$want" >/dev/null 2>&1; then
    info "$want already present: $(command -v "$want")"
    return
  fi
  mkdir -p "$unpack"
  if [[ ! -f "$TMP_DIR/ssrust.tar.xz" ]]; then
    info "Downloading shadowsocks-rust $SSRUST_VERSION"
    fetch "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SSRUST_VERSION}/shadowsocks-${SSRUST_VERSION}.${SSRUST_TRIPLE}.tar.xz" \
          "$TMP_DIR/ssrust.tar.xz"
    tar -xJf "$TMP_DIR/ssrust.tar.xz" -C "$unpack"
  fi
  bin="$(find "$unpack" -type f -name "$want" | head -n 1)"
  [[ -n "$bin" ]] || die "No $want in the shadowsocks-rust archive."
  install_bin "$bin" "$want"
}

json_string() { # json_string file Key
  $SUDO sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

env_value() { # env_value file KEY
  $SUDO sed -n "s/^$2=//p" "$1" | head -n 1
}

urlencode() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

write_unit() { # write_unit name description command after
  local name="$1" desc="$2" exec_line="$3" after="$4"
  cat > "$TMP_DIR/$name.service" <<EOF
[Unit]
Description=$desc
After=$after
Wants=$after

[Service]
ExecStart=$exec_line
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  $SUDO install -m 0644 "$TMP_DIR/$name.service" "/etc/systemd/system/$name.service"
}

# Check the whole path the way a phone would: local ck-client +
# sslocal -> Cloak -> Shadowsocks -> internet.
selftest() {
  local ck_port=41080 socks_port=41081 out=""

  install_cloak client
  install_shadowsocks sslocal

  cat > "$TMP_DIR/ck-test.json" <<EOF
{
  "BrowserSig": "firefox",
  "EncryptionMethod": "aes-gcm",
  "NumConn": 1,
  "ProxyMethod": "shadowsocks",
  "PublicKey": "$PUBLIC_KEY",
  "RemoteHost": "127.0.0.1",
  "RemotePort": "$SS_PORT",
  "ServerName": "$CK_SERVER_NAME",
  "StreamTimeout": 300,
  "Transport": "direct",
  "UID": "$CK_UID"
}
EOF

  cat > "$TMP_DIR/ss-test.json" <<EOF
{
  "server": "127.0.0.1",
  "server_port": $ck_port,
  "local_address": "127.0.0.1",
  "local_port": $socks_port,
  "method": "$SS_METHOD",
  "password": "$SS_PASSWORD",
  "timeout": 60
}
EOF

  ck-client -c "$TMP_DIR/ck-test.json" -l "$ck_port" >"$TMP_DIR/ck-test.log" 2>&1 &
  SELFTEST_PIDS+=($!)
  sleep 1
  sslocal -c "$TMP_DIR/ss-test.json" >"$TMP_DIR/ss-test.log" 2>&1 &
  SELFTEST_PIDS+=($!)
  sleep 2

  out="$(curl -4 --socks5-hostname "127.0.0.1:$socks_port" --max-time 20 -fsS https://ifconfig.me 2>>"$TMP_DIR/curl.log" || true)"

  local pid
  for pid in ${SELFTEST_PIDS[@]+"${SELFTEST_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  SELFTEST_PIDS=()

  if [[ -n "$out" ]]; then
    info "Tunnel works, external IP through it: $out"
    return 0
  fi

  warn "Self-test failed -- no traffic through the tunnel."
  warn "ck-client: $(tail -n 3 "$TMP_DIR/ck-test.log" 2>/dev/null | tr '\n' ' ')"
  warn "sslocal:   $(tail -n 3 "$TMP_DIR/ss-test.log" 2>/dev/null | tr '\n' ' ')"
  warn "Config is installed; check the service logs and the provider firewall."
  return 1
}

make_qr() {
  local userinfo plugin url txt png owner

  userinfo="$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  plugin="cloak"
  plugin+=";Transport=direct"
  plugin+=";ProxyMethod=shadowsocks"
  plugin+=";EncryptionMethod=aes-gcm"
  plugin+=";UID=${CK_UID}"
  plugin+=";PublicKey=${PUBLIC_KEY}"
  plugin+=";ServerName=${CK_SERVER_NAME}"
  plugin+=";BrowserSig=chrome"
  plugin+=";StreamTimeout=300"
  plugin+=";NumConn=4"

  url="ss://${userinfo}@${SS_HOST}:${SS_PORT}/?plugin=$(urlencode "$plugin")#sscloak-${SS_PORT}"

  [[ -d "$OUT_DIR" && -w "$OUT_DIR" ]] || OUT_DIR="${HOME:-/root}"
  txt="$OUT_DIR/shadowrocket-sscloak-${SS_PORT}.txt"
  png="$OUT_DIR/shadowrocket-sscloak-${SS_PORT}.png"

  ( umask 077
    printf '%s\n' "$url" > "$txt"
    qrencode -o "$png" -s 8 -m 2 "$url" )

  owner="${SUDO_USER:-}"
  if [[ -n "$owner" ]]; then
    chown "$owner" "$txt" "$png" 2>/dev/null || true
  fi

  say "Shadowrocket QR code"
  qrencode -t ANSIUTF8 "$url"
  info "PNG:  $png"
  info "Link: $txt"
  printf '\n%s\n' "$url"

  cat <<EOF

    Copy the PNG to your computer:
      scp ${SUDO_USER:-root}@${SS_HOST}:${png} .

    Import: Shadowrocket -> Servers tab -> "+" -> scanner icon -> QR.
    Then select the server, enable VPN; for a full tunnel set Global Routing -> Proxy.

    The PNG and .txt contain the password and keys -- delete them after import:
      shred -u ${png} ${txt}
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac

  command -v apt-get >/dev/null 2>&1 || die "Ubuntu/Debian only (needs apt-get)."
  command -v systemctl >/dev/null 2>&1 || die "systemd required."

  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR"

  detect_arch
  init_sudo

  say "Installing dependencies"
  apt_install curl xz-utils openssl ca-certificates qrencode
  install_cloak server
  install_shadowsocks ssserver

  say "Parameters"
  SS_PORT="$(ask 'Public Cloak TCP port' "$SS_PORT")"
  [[ "$SS_PORT" =~ ^[0-9]+$ ]] || die "Port must be a number: $SS_PORT"

  if [[ -z "$SS_HOST" ]]; then
    SS_HOST="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  fi
  SS_HOST="$(ask 'Server address for clients (domain or IP)' "$SS_HOST")"
  [[ -n "$SS_HOST" ]] || die "Server address required: SS_HOST=<domain|IP> bash install-sscloak-server.sh"

  local dir="/opt/sscloak-$SS_PORT" reuse=0
  if $SUDO test -f "$dir/client.env" && $SUDO test -f "$dir/ck-config.json" && (( ! REGENERATE )); then
    warn "$dir is already set up."
    if confirm "Keep existing keys (otherwise all current clients disconnect)?" y; then
      reuse=1
    fi
  fi

  if (( reuse )); then
    say "Reusing existing keys from $dir"
    PRIVATE_KEY="$(json_string "$dir/ck-config.json" PrivateKey)"
    CK_UID="$(env_value "$dir/client.env" CK_UID)"
    PUBLIC_KEY="$(env_value "$dir/client.env" CK_PUBLIC_KEY)"
    SS_PASSWORD="$(env_value "$dir/client.env" SS_PASSWORD)"
    SS_METHOD="$(env_value "$dir/client.env" SS_METHOD)"
    CK_SERVER_NAME="$(env_value "$dir/client.env" CK_SERVER_NAME)"
  else
    say "Generating Cloak keys and Shadowsocks password"
    local key_text uid_text
    key_text="$(ck-server -key | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
    uid_text="$(ck-server -uid | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
    PUBLIC_KEY="$(printf '%s\n' "$key_text"  | awk -F': *' '/PUBLIC key/{print $2}'  | awk '{print $1}')"
    PRIVATE_KEY="$(printf '%s\n' "$key_text" | awk -F': *' '/PRIVATE key/{print $2}' | awk '{print $1}')"
    CK_UID="$(printf '%s\n' "$uid_text"      | awk -F': *' '/UID/{print $2}'         | awk '{print $1}')"
    SS_PASSWORD="$(openssl rand -base64 32)"
  fi

  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$CK_UID" && -n "$SS_PASSWORD" ]] \
    || die "Could not obtain keys/password."

  say "Writing config to $dir"
  $SUDO install -d -m 700 "$dir"
  umask 077

  # ssudp + tcp_and_udp carry UDP through the tunnel (DNS in TUN_DNS_MODE=tunnel).
  cat > "$TMP_DIR/ck-config.json" <<EOF
{
  "ProxyBook": {
    "shadowsocks": ["tcp", "127.0.0.1:$SS_BACKEND_PORT"],
    "ssudp": ["udp", "127.0.0.1:$SS_BACKEND_PORT"]
  },
  "BypassUID": ["$CK_UID"],
  "BindAddr": [":$SS_PORT"],
  "RedirAddr": "$CK_SERVER_NAME",
  "PrivateKey": "$PRIVATE_KEY",
  "AdminUID": "$CK_UID",
  "DatabasePath": "$dir/userinfo.db",
  "StreamTimeout": 300
}
EOF

  cat > "$TMP_DIR/ss-config.json" <<EOF
{
  "server": "127.0.0.1",
  "server_port": $SS_BACKEND_PORT,
  "method": "$SS_METHOD",
  "password": "$SS_PASSWORD",
  "timeout": 60,
  "mode": "tcp_and_udp"
}
EOF

  cat > "$TMP_DIR/client.env" <<EOF
SS_HOST=$SS_HOST
SS_PORT=$SS_PORT
SS_METHOD=$SS_METHOD
SS_PASSWORD=$SS_PASSWORD
CK_UID=$CK_UID
CK_PUBLIC_KEY=$PUBLIC_KEY
CK_SERVER_NAME=$CK_SERVER_NAME
CK_BROWSER_SIG=firefox
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
CK_TRANSPORT=direct
CK_STREAM_TIMEOUT=300
CK_NUM_CONN=4
EOF

  $SUDO install -m 600 "$TMP_DIR/ck-config.json" "$dir/ck-config.json"
  $SUDO install -m 600 "$TMP_DIR/ss-config.json" "$dir/ss-config.json"
  $SUDO install -m 600 "$TMP_DIR/client.env"     "$dir/client.env"

  say "Starting services"
  write_unit "sscloak-ss-$SS_PORT" "Shadowsocks server for sscloak-$SS_PORT" \
    "/usr/local/bin/ssserver -c $dir/ss-config.json" "network-online.target"
  write_unit "sscloak-ck-$SS_PORT" "Cloak server for sscloak-$SS_PORT" \
    "/usr/local/bin/ck-server -c $dir/ck-config.json" "sscloak-ss-$SS_PORT.service"

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --quiet "sscloak-ss-$SS_PORT.service" "sscloak-ck-$SS_PORT.service"
  $SUDO systemctl restart "sscloak-ss-$SS_PORT.service" "sscloak-ck-$SS_PORT.service"

  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "Opening $SS_PORT/tcp in ufw"
    $SUDO ufw allow "$SS_PORT/tcp" >/dev/null
  fi

  sleep 2
  say "Checking services"
  local failed=0
  $SUDO systemctl is-active --quiet "sscloak-ss-$SS_PORT.service" || failed=1
  $SUDO systemctl is-active --quiet "sscloak-ck-$SS_PORT.service" || failed=1
  if (( failed )); then
    $SUDO journalctl -u "sscloak-ss-$SS_PORT" -u "sscloak-ck-$SS_PORT" -n 30 --no-pager || true
    die "Services failed to start -- see the log above."
  fi
  info "sscloak-ss-$SS_PORT and sscloak-ck-$SS_PORT are running"
  $SUDO ss -lntp 2>/dev/null | grep -E ":$SS_PORT|:$SS_BACKEND_PORT" || true

  local selftest_ok=1
  if (( SKIP_SELFTEST )); then
    info "Self-test skipped (SKIP_SELFTEST=1)"
  else
    say "Checking the tunnel with a local client"
    selftest || selftest_ok=0
  fi

  make_qr

  say "Done"
  info "Desktop client values: $dir/client.env (config-local/client.env in the repo)"
  info "Logs:    journalctl -u sscloak-ck-$SS_PORT -u sscloak-ss-$SS_PORT -f"
  info "Restart: systemctl restart sscloak-ss-$SS_PORT sscloak-ck-$SS_PORT"
  warn "If the provider has its own firewall (DigitalOcean, Hetzner, AWS), open $SS_PORT/tcp there too."
  (( selftest_ok )) || warn "Tunnel self-test failed -- server is up, but check network/firewall."
}

main "$@"
