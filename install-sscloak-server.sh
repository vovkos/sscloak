#!/usr/bin/env bash
# Разворачивает сервер sscloak (Cloak + Shadowsocks) на чистом Ubuntu.
# На выходе: работающие systemd-сервисы и PNG с QR-кодом для Shadowrocket.
#
#   scp ubuntu-server-setup.sh user@server:~/
#   ssh user@server 'bash ~/ubuntu-server-setup.sh'
#
# Пароль sudo спрашивается один раз, когда он нужен.
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
Использование: bash ubuntu-server-setup.sh [--help]

Ставит на этот сервер ck-server + ssserver, генерирует ключи, поднимает
systemd-сервисы, открывает порт и кладёт рядом PNG с QR-кодом для Shadowrocket.

Переменные окружения (все необязательные):
  SS_HOST=<домен|IP>     адрес для клиентов (по умолчанию -- публичный IP)
  SS_PORT=443            публичный TCP-порт Cloak
  OUT_DIR=<каталог>      куда положить QR-код (по умолчанию -- текущий каталог)
  REGENERATE=1           перегенерировать ключи, даже если сервер уже настроен
  SKIP_SELFTEST=1        не проверять туннель локальным клиентом
  CLOAK_VERSION, SSRUST_VERSION -- версии релизов
EOF
}

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m\nОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
  local pid
  for pid in ${SELFTEST_PIDS[@]+"${SELFTEST_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null || true
  [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

ask() { # ask "вопрос" [умолчание] -- без терминала просто берёт умолчание
  local prompt="$1" def="${2:-}" ans
  if [[ ! -t 0 ]]; then
    printf '%s' "$def"
    return
  fi
  read -r -p "    $prompt${def:+ [$def]}: " ans || true
  printf '%s' "${ans:-$def}"
}

confirm() { # confirm "вопрос" [y|n]
  local prompt="$1" def="${2:-y}" hint ans
  if [[ ! -t 0 ]]; then
    [[ "$def" == y ]]
    return
  fi
  if [[ "$def" == y ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "    $prompt [$hint]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^([yY]|[дД]|yes|да)$ ]]
}

init_sudo() {
  if (( EUID == 0 )); then
    SUDO=""
    return
  fi
  command -v sudo >/dev/null 2>&1 || die "Нет sudo, а скрипт запущен не от root."
  if ! sudo -n true 2>/dev/null; then
    say "Нужны права root -- введите пароль sudo"
    sudo -v
  fi
  # Пароль спрашиваем один раз: держим таймаут sudo живым до конца установки.
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
    say "Обновляю списки пакетов"
    $SUDO apt-get update -qq
    APT_UPDATED=1
  fi
  info "Ставлю: ${missing[*]}"
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  GO_ARCH="amd64"; SSRUST_TRIPLE="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) GO_ARCH="arm64"; SSRUST_TRIPLE="aarch64-unknown-linux-gnu" ;;
    *) die "Архитектура $(uname -m) не поддерживается скриптом -- ставьте бинарники вручную (README-ru.md)." ;;
  esac
}

fetch() { # fetch URL файл
  curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1" || die "Не удалось скачать $1"
}

install_bin() { # install_bin файл имя
  $SUDO install -m 0755 "$1" "/usr/local/bin/$2"
  info "Установлен /usr/local/bin/$2"
}

install_cloak() { # install_cloak server|client
  local role="$1" name="ck-$1"
  if command -v "$name" >/dev/null 2>&1; then
    info "$name уже есть: $(command -v "$name")"
    return
  fi
  info "Скачиваю $name $CLOAK_VERSION"
  fetch "https://github.com/cbeuw/Cloak/releases/download/${CLOAK_VERSION}/ck-${role}-linux-${GO_ARCH}-${CLOAK_VERSION}" \
        "$TMP_DIR/$name"
  install_bin "$TMP_DIR/$name" "$name"
}

install_shadowsocks() { # install_shadowsocks ssserver|sslocal
  local want="$1" unpack="$TMP_DIR/ssrust" bin
  if command -v "$want" >/dev/null 2>&1; then
    info "$want уже есть: $(command -v "$want")"
    return
  fi
  mkdir -p "$unpack"
  if [[ ! -f "$TMP_DIR/ssrust.tar.xz" ]]; then
    info "Скачиваю shadowsocks-rust $SSRUST_VERSION"
    fetch "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SSRUST_VERSION}/shadowsocks-${SSRUST_VERSION}.${SSRUST_TRIPLE}.tar.xz" \
          "$TMP_DIR/ssrust.tar.xz"
    tar -xJf "$TMP_DIR/ssrust.tar.xz" -C "$unpack"
  fi
  bin="$(find "$unpack" -type f -name "$want" | head -n 1)"
  [[ -n "$bin" ]] || die "В архиве shadowsocks-rust нет $want."
  install_bin "$bin" "$want"
}

json_string() { # json_string файл Ключ
  $SUDO sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

env_value() { # env_value файл КЛЮЧ
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

write_unit() { # write_unit имя описание команда after
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

# Проверяем весь путь так же, как это сделает телефон: локальный ck-client +
# sslocal -> Cloak -> Shadowsocks -> интернет.
selftest() {
  local ck_port=41080 socks_port=41081 out=""

  install_cloak client
  install_shadowsocks sslocal

  cat > "$TMP_DIR/ck-test.json" <<EOF
{
  "BrowserSig": "chrome",
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
    info "Туннель работает, внешний IP через него: $out"
    return 0
  fi

  warn "Самопроверка не прошла -- трафик через туннель не пошёл."
  warn "ck-client: $(tail -n 3 "$TMP_DIR/ck-test.log" 2>/dev/null | tr '\n' ' ')"
  warn "sslocal:   $(tail -n 3 "$TMP_DIR/ss-test.log" 2>/dev/null | tr '\n' ' ')"
  warn "Конфигурация установлена; проверьте логи сервисов и фаервол провайдера."
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

  say "QR-код для Shadowrocket"
  qrencode -t ANSIUTF8 "$url"
  info "PNG:    $png"
  info "Ссылка: $txt"
  printf '\n%s\n' "$url"

  cat <<EOF

    Забрать PNG на свой компьютер:
      scp ${SUDO_USER:-root}@${SS_HOST}:${png} .

    Импорт: Shadowrocket -> вкладка Servers -> "+" -> иконка сканера -> QR.
    Дальше выбрать сервер, включить VPN, для полного туннеля Global Routing -> Proxy.

    В PNG и .txt лежат пароль и ключи -- после импорта удалите:
      shred -u ${png} ${txt}
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac

  command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Ubuntu/Debian (нужен apt-get)."
  command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."

  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR"

  detect_arch
  init_sudo

  say "Ставлю зависимости"
  apt_install curl xz-utils openssl ca-certificates qrencode
  install_cloak server
  install_shadowsocks ssserver

  say "Параметры"
  SS_PORT="$(ask 'Публичный TCP-порт Cloak' "$SS_PORT")"
  [[ "$SS_PORT" =~ ^[0-9]+$ ]] || die "Порт должен быть числом: $SS_PORT"

  if [[ -z "$SS_HOST" ]]; then
    SS_HOST="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  fi
  SS_HOST="$(ask 'Адрес сервера для клиентов (домен или IP)' "$SS_HOST")"
  [[ -n "$SS_HOST" ]] || die "Нужен адрес сервера: SS_HOST=<домен|IP> bash ubuntu-server-setup.sh"

  local dir="/opt/sscloak-$SS_PORT" reuse=0
  if $SUDO test -f "$dir/client.env" && $SUDO test -f "$dir/ck-config.json" && (( ! REGENERATE )); then
    warn "$dir уже настроен."
    if confirm "Оставить существующие ключи (иначе все текущие клиенты отвалятся)?" y; then
      reuse=1
    fi
  fi

  if (( reuse )); then
    say "Использую существующие ключи из $dir"
    PRIVATE_KEY="$(json_string "$dir/ck-config.json" PrivateKey)"
    CK_UID="$(env_value "$dir/client.env" CK_UID)"
    PUBLIC_KEY="$(env_value "$dir/client.env" CK_PUBLIC_KEY)"
    SS_PASSWORD="$(env_value "$dir/client.env" SS_PASSWORD)"
    SS_METHOD="$(env_value "$dir/client.env" SS_METHOD)"
    CK_SERVER_NAME="$(env_value "$dir/client.env" CK_SERVER_NAME)"
  else
    say "Генерирую ключи Cloak и пароль Shadowsocks"
    local key_text uid_text
    key_text="$(ck-server -key | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
    uid_text="$(ck-server -uid | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
    PUBLIC_KEY="$(printf '%s\n' "$key_text"  | awk -F': *' '/PUBLIC key/{print $2}'  | awk '{print $1}')"
    PRIVATE_KEY="$(printf '%s\n' "$key_text" | awk -F': *' '/PRIVATE key/{print $2}' | awk '{print $1}')"
    CK_UID="$(printf '%s\n' "$uid_text"      | awk -F': *' '/UID/{print $2}'         | awk '{print $1}')"
    SS_PASSWORD="$(openssl rand -base64 32)"
  fi

  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$CK_UID" && -n "$SS_PASSWORD" ]] \
    || die "Не удалось получить ключи/пароль."

  say "Пишу конфигурацию в $dir"
  $SUDO install -d -m 700 "$dir"
  umask 077

  # ssudp + tcp_and_udp нужны для UDP через туннель (DNS в режиме TUN_DNS_MODE=tunnel).
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
CK_BROWSER_SIG=chrome
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
CK_TRANSPORT=direct
CK_STREAM_TIMEOUT=300
CK_NUM_CONN=4
EOF

  $SUDO install -m 600 "$TMP_DIR/ck-config.json" "$dir/ck-config.json"
  $SUDO install -m 600 "$TMP_DIR/ss-config.json" "$dir/ss-config.json"
  $SUDO install -m 600 "$TMP_DIR/client.env"     "$dir/client.env"

  say "Поднимаю сервисы"
  write_unit "sscloak-ss-$SS_PORT" "Shadowsocks server for sscloak-$SS_PORT" \
    "/usr/local/bin/ssserver -c $dir/ss-config.json" "network-online.target"
  write_unit "sscloak-ck-$SS_PORT" "Cloak server for sscloak-$SS_PORT" \
    "/usr/local/bin/ck-server -c $dir/ck-config.json" "sscloak-ss-$SS_PORT.service"

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --quiet "sscloak-ss-$SS_PORT.service" "sscloak-ck-$SS_PORT.service"
  $SUDO systemctl restart "sscloak-ss-$SS_PORT.service" "sscloak-ck-$SS_PORT.service"

  if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "Открываю $SS_PORT/tcp в ufw"
    $SUDO ufw allow "$SS_PORT/tcp" >/dev/null
  fi

  sleep 2
  say "Проверяю сервисы"
  local failed=0
  $SUDO systemctl is-active --quiet "sscloak-ss-$SS_PORT.service" || failed=1
  $SUDO systemctl is-active --quiet "sscloak-ck-$SS_PORT.service" || failed=1
  if (( failed )); then
    $SUDO journalctl -u "sscloak-ss-$SS_PORT" -u "sscloak-ck-$SS_PORT" -n 30 --no-pager || true
    die "Сервисы не поднялись -- смотрите лог выше."
  fi
  info "sscloak-ss-$SS_PORT и sscloak-ck-$SS_PORT запущены"
  $SUDO ss -lntp 2>/dev/null | grep -E ":$SS_PORT|:$SS_BACKEND_PORT" || true

  local selftest_ok=1
  if (( SKIP_SELFTEST )); then
    info "Самопроверка пропущена (SKIP_SELFTEST=1)"
  else
    say "Проверяю туннель локальным клиентом"
    selftest || selftest_ok=0
  fi

  make_qr

  say "Готово"
  info "Значения для десктопных клиентов: $dir/client.env (config-local/client.env в репозитории)"
  info "Логи:       journalctl -u sscloak-ck-$SS_PORT -u sscloak-ss-$SS_PORT -f"
  info "Перезапуск: systemctl restart sscloak-ss-$SS_PORT sscloak-ck-$SS_PORT"
  warn "Если у провайдера свой внешний фаервол (DigitalOcean, Hetzner, AWS) -- откройте $SS_PORT/tcp и там."
  (( selftest_ok )) || warn "Самопроверка туннеля не прошла -- сервер поднят, но проверьте сеть/фаервол."
}

main "$@"
