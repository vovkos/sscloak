# Shadowsocks поверх Cloak — VPN

Перевод [README.md](README.md).

Инструкции и скрипты для сервера на Ubuntu и для клиентов на iPhone, Windows и
Linux.

Все клиенты в итоге используют один и тот же путь на стороне сервера:

```text
клиент, транспорт Cloak -> сервер Cloak -> сервер Shadowsocks -> интернет
```

## Схема трафика

iPhone с Shadowrocket:

```text
приложения iPhone
  -> VPN-профиль iOS
  -> клиент Shadowsocks в Shadowrocket
  -> плагин Cloak в Shadowrocket
  -> сервер Cloak
  -> сервер Shadowsocks
  -> интернет
```

Windows, режим полного туннеля:

```text
приложения Windows
  -> разделённые маршруты по умолчанию
  -> TUN-адаптер tun2socks
  -> ss-local
  -> ck-client
  -> сервер Cloak
  -> сервер Shadowsocks
  -> интернет
```

Linux, режим полного туннеля:

```text
приложения Linux
  -> маршруты через TUN
  -> tun2socks
  -> ss-local
  -> ck-client
  -> сервер Cloak
  -> сервер Shadowsocks
  -> интернет
```

## Установка сервера

Сервер — это два статических бинарника под systemd: `ck-server` из Cloak и
`ssserver` из shadowsocks-rust. Здесь сознательно не используются ни Xray, ни
Docker, ни контейнерные образы AmneziaVPN.

### Автоматическая установка

`install-sscloak-server.sh` делает всё, что описано в этом разделе, на чистом
Ubuntu и в конце печатает QR-код для Shadowrocket:

```bash
scp install-sscloak-server.sh user@server:~/
ssh user@server 'bash ~/install-sscloak-server.sh'
```

Скрипт один раз спрашивает пароль sudo, ставит бинарники, генерирует учётные
данные, пишет `/opt/sscloak-<порт>/`, включает systemd-юниты, открывает порт в
`ufw`, проверяет туннель одноразовым локальным клиентом и кладёт рядом с собой
`shadowrocket-sscloak-<порт>.png` и `.txt` со ссылкой `ss://`.

Необязательные переменные окружения:

```bash
SS_HOST=vpn.example.com SS_PORT=8443 bash install-sscloak-server.sh
OUT_DIR=/tmp bash install-sscloak-server.sh      # куда положить QR-код
REGENERATE=1 bash install-sscloak-server.sh      # новые ключи, старые клиенты отвалятся
SKIP_SELFTEST=1 bash install-sscloak-server.sh   # без проверки туннеля
CLOAK_VERSION=v2.12.0 SSRUST_VERSION=v1.24.0 bash install-sscloak-server.sh
```

Повторный запуск безопасен: для уже настроенного порта ключи по умолчанию
сохраняются, перезаписываются только конфиги, юниты и QR-код. После самопроверки
на сервере остаются `ck-client` и `sslocal` в `/usr/local/bin` — удалите их, если
хотите оставить хост чистым.

Всё остальное в этом разделе — та же установка вручную.

### Значения сервера

Используйте эти обозначения единообразно:

```text
SS_HOST=<имя хоста или IP сервера>
SS_PORT=<публичный порт Cloak, обычно 8443>
SS_METHOD=chacha20-ietf-poly1305
SS_PASSWORD=<сгенерированный пароль Shadowsocks>
CK_UID=<сгенерированный UID Cloak>
CK_PUBLIC_KEY=<сгенерированный публичный ключ Cloak>
CK_SERVER_NAME=tile.openstreetmap.org
CK_BROWSER_SIG=chrome
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
```

Шаги вручную ниже предполагают чистый хост с Ubuntu, права root (`sudo -i`) и
свободный публичный TCP-порт.

### Установка бинарников сервера

```bash
apt update && apt install -y curl xz-utils openssl qrencode

# сервер Cloak
curl -fsSL -o /usr/local/bin/ck-server \
  https://github.com/cbeuw/Cloak/releases/download/v2.12.0/ck-server-linux-amd64-v2.12.0
chmod +x /usr/local/bin/ck-server

# сервер Shadowsocks, из shadowsocks-rust
curl -fsSL -o /tmp/ss.tar.xz \
  https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.24.0/shadowsocks-v1.24.0.x86_64-unknown-linux-gnu.tar.xz
tar -xJf /tmp/ss.tar.xz -C /usr/local/bin ssserver
chmod +x /usr/local/bin/ssserver
```

Для arm64 возьмите `ck-server-linux-arm64-v2.12.0` и
`shadowsocks-v1.24.0.aarch64-unknown-linux-gnu.tar.xz`. Эти же версии зафиксированы
в install-скрипте; более свежие релизы работают так же.

### Генерация учётных данных

Выполнить на сервере:

```bash
KEY_TEXT=$(ck-server -key | sed -r 's/\x1B\[[0-9;]*[mK]//g')
UID_TEXT=$(ck-server -uid | sed -r 's/\x1B\[[0-9;]*[mK]//g')

PUBLIC_KEY=$(printf '%s\n' "$KEY_TEXT" | awk -F': *' '/PUBLIC key/{print $2}' | awk '{print $1}')
PRIVATE_KEY=$(printf '%s\n' "$KEY_TEXT" | awk -F': *' '/PRIVATE key/{print $2}' | awk '{print $1}')
CK_UID=$(printf '%s\n' "$UID_TEXT" | awk -F': *' '/UID/{print $2}' | awk '{print $1}')
SS_PASSWORD=$(openssl rand -base64 32)
```

Убедитесь, что ничего не пустое:

```bash
printf 'PUBLIC_KEY=%s\nPRIVATE_KEY=%s\nCK_UID=%s\nSS_PASSWORD=%s\n' "$PUBLIC_KEY" "$PRIVATE_KEY" "$CK_UID" "$SS_PASSWORD"
```

### Конфиги сервера

Задайте публичный хост и порт, затем создайте файлы конфигурации сервера:

```bash
SS_HOST="your.server.example"
SS_PORT="8443"

install -d -m 700 /opt/sscloak-8443

cat >/opt/sscloak-8443/ck-config.json <<EOF
{
  "ProxyBook": {
    "shadowsocks": ["tcp", "127.0.0.1:6789"],
    "ssudp": ["udp", "127.0.0.1:6789"]
  },
  "BypassUID": ["$CK_UID"],
  "BindAddr": [":$SS_PORT"],
  "RedirAddr": "tile.openstreetmap.org",
  "PrivateKey": "$PRIVATE_KEY",
  "AdminUID": "$CK_UID",
  "DatabasePath": "/opt/sscloak-8443/userinfo.db",
  "StreamTimeout": 300
}
EOF

cat >/opt/sscloak-8443/ss-config.json <<EOF
{
  "server": "127.0.0.1",
  "server_port": 6789,
  "method": "chacha20-ietf-poly1305",
  "password": "$SS_PASSWORD",
  "timeout": 60,
  "mode": "tcp_and_udp"
}
EOF

cat >/opt/sscloak-8443/client.env <<EOF
SS_HOST=$SS_HOST
SS_PORT=$SS_PORT
SS_METHOD=chacha20-ietf-poly1305
SS_PASSWORD=$SS_PASSWORD
CK_UID=$CK_UID
CK_PUBLIC_KEY=$PUBLIC_KEY
CK_SERVER_NAME=tile.openstreetmap.org
CK_BROWSER_SIG=chrome
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
CK_TRANSPORT=direct
CK_STREAM_TIMEOUT=300
CK_NUM_CONN=4
EOF

chmod 600 /opt/sscloak-8443/*.json /opt/sscloak-8443/client.env
```

Запись `ssudp` и режим `tcp_and_udp` пропускают UDP через туннель — это нужно
дефолтному для Windows режиму `TUN_DNS_MODE=tunnel`. Для сервера только с TCP
уберите строку `ssudp` и поставьте `"mode": "tcp_only"`.

### Запуск под systemd

```bash
cat >/etc/systemd/system/sscloak-ss-8443.service <<'EOF'
[Unit]
Description=Shadowsocks server for sscloak-8443
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /opt/sscloak-8443/ss-config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/sscloak-ck-8443.service <<'EOF'
[Unit]
Description=Cloak server for sscloak-8443
After=sscloak-ss-8443.service
Requires=sscloak-ss-8443.service

[Service]
ExecStart=/usr/local/bin/ck-server -c /opt/sscloak-8443/ck-config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sscloak-ss-8443.service sscloak-ck-8443.service
```

Оба юнита работают от root, потому что Cloak пишет `userinfo.db` в
`/opt/sscloak-8443`.

### Открыть порт

```bash
ufw allow 8443/tcp
```

Cloak слушает только TCP; UDP едет внутри той же TCP-сессии. Если у провайдера
свой фаервол (DigitalOcean, Hetzner, AWS) — откройте порт и там.

### Проверка сервера

```bash
systemctl --no-pager status sscloak-ss-8443 sscloak-ck-8443
ss -lntup | grep -E ":$SS_PORT|:6789"
journalctl -u sscloak-ck-8443 -n 30 --no-pager
```

Ожидается:

```text
active (running)  # оба юнита
shadowsocks tcp server listening on 127.0.0.1:6789
Listening on :<SS_PORT>
```

Эти проверки подтверждают только то, что процессы слушают порты. Чтобы проверить
весь путь целиком, нужно подключить клиента: `install-sscloak-server.sh` делает
это сам — поднимает одноразовые `ck-client` и `sslocal` против
`127.0.0.1:$SS_PORT` и дёргает `ifconfig.me` через получившийся SOCKS-порт; то же
самое вручную — это Linux-клиент ниже плюс `./vpn.sh status`.

## Значения для клиентов

В файле `/opt/sscloak-8443/client.env` на сервере лежит всё, что нужно клиентам.
Скопируйте его в единственный локальный файл значений:

```bash
cp config-local/client.example.env config-local/client.env
```

Впишите в `config-local/client.env` адрес сервера, UID и публичный ключ Cloak и
пароль Shadowsocks. Скрипты Linux и Windows читают этот же файл. Для iPhone те же
значения вводятся в Shadowrocket вручную либо импортируются из QR-кода, который
сделал серверный install-скрипт.

Настоящий `config-local/client.env`, сгенерированные рантайм-файлы для десктопа и
файлы импорта для Shadowrocket внутри `config-local/` не попадают в git, потому
что содержат секреты.

## iPhone: настройка Shadowrocket

Установите Shadowrocket из App Store. На iPhone Shadowrocket подключается прямо к
серверу Cloak/Shadowsocks, поэтому ему не нужны ни AmneziaVPN, ни `tun2socks`, ни
значения локальных слушателей из `config-local/client.env`.

Самый быстрый путь — QR-код от `install-sscloak-server.sh`: вкладка Servers ->
`+` -> иконка сканера -> отсканировать `shadowrocket-sscloak-<порт>.png`. Ручной
эквивалент — ниже.

Добавьте новый сервер Shadowsocks в Shadowrocket с такими значениями:

```text
Type: Shadowsocks
Address: SS_HOST
Port: SS_PORT
Method: SS_METHOD
Password: SS_PASSWORD
Plugin: cloak
```

Настройте плагин Cloak соответствующими значениями:

```text
UID: CK_UID
Public Key: CK_PUBLIC_KEY
Server Name: CK_SERVER_NAME
Browser Sig: CK_BROWSER_SIG
Proxy Method: CK_PROXY_METHOD
Encryption Method: CK_ENCRYPTION_METHOD
Transport: CK_TRANSPORT
Stream Timeout: CK_STREAM_TIMEOUT
Num Conn: CK_NUM_CONN
```

Используйте те же значения, что и в `config-local/client.env`. Перечисленные ниже
настройки локальных слушателей нужны только на десктопе и в Shadowrocket не
вводятся:

```text
SS_LOCAL_SERVER
SS_LOCAL_SERVER_PORT
SS_LOCAL_ADDRESS
SS_LOCAL_PORT
TUN_*
```

Сохранив сервер, выберите его в Shadowrocket и включите переключатель VPN.
Включите Global Routing, если хотите пустить через туннель весь трафик iPhone.

## Windows: полный туннель

Режим Shadowsocks GUI на Windows — это системный прокси, а не полноценный VPN.
Для маршрутизации всего устройства установите AmneziaVPN на клиентскую машину с
Windows. По умолчанию используются эти вложенные в него исполняемые файлы:

```text
C:\Program Files\AmneziaVPN\cloak\ck-client.exe
C:\Program Files\AmneziaVPN\ss\ss-local.exe
C:\Program Files\AmneziaVPN\xray\tun2socks.exe
```

Отдельное GUI-приложение Shadowsocks для Windows в режиме полного туннеля не
нужно. Если какой-то бинарник лежит в другом месте, задайте `CK_BIN`, `SS_BIN`
или `TUN2SOCKS_BIN` с полным путём к файлу.

Из этого каталога сгенерируйте рантайм-файлы для Windows:

```powershell
.\vpn.cmd install
```

Затем запустите PowerShell с правами администратора из этого каталога и
выполните:

```powershell
.\vpn.cmd run
```

`run` запускает `ck-client`, `ss-local` и `tun2socks`, создаёт TUN-адаптер с
именем `sscloak`, добавляет через него разделённые маршруты по умолчанию и
восстанавливает маршруты по Ctrl-C. Команды Windows:

По умолчанию Windows использует `TUN_DNS_MODE=tunnel`: второй клиент Cloak несёт
UDP через серверный метод `ssudp`, а `ss-local -u` даёт ретрансляцию UDP по
SOCKS5. Поэтому DNS резолвится с VPN-сервера, а не из локальной сети. Режим
`physical` пускает DNS мимо туннеля через активный адаптер; `none` оставляет
TUN-адаптер без настроенных DNS-серверов.

```powershell
.\vpn.cmd install
.\vpn.cmd on
.\vpn.cmd off
.\vpn.cmd status
.\vpn.cmd restart
.\vpn.cmd run
```

Скрипт для Windows пишет сгенерированные рантайм-файлы в `config-windows/`.

## Linux: полный туннель

Установите AmneziaVPN на клиентскую машину с Linux. Используются вложенные в него
бинарники:

- `ck-client`, клиент Cloak
- `ss-local`, локальный клиент Shadowsocks
- `tun2socks`, для заворачивания TUN-интерфейса в локальный SOCKS-прокси

`./vpn.sh install` ищет в `PATH` эти команды:

```text
ck-client
ss-local
tun2socks
```

Если их там нет, установщик ищет исполняемые файлы в:

```text
/usr/local/bin
/usr/bin
/bin
/opt
```

Если какой-то бинарник установлен вне `PATH`, передайте явные пути. При типичной
установке AmneziaVPN это выглядит так:

```bash
CK_BIN=/opt/AmneziaVPN/client/bin/ck-client \
SS_BIN=/opt/AmneziaVPN/client/bin/ss-local \
TUN2SOCKS_BIN=/opt/AmneziaVPN/client/bin/tun2socks \
./vpn.sh install
```

Поменять каталоги запасного поиска:

```bash
BIN_SEARCH_DIRS=/opt:/srv/tools ./vpn.sh install
```

Из этого каталога установите сгенерированные рантайм-файлы, systemd-юниты и хук
системного сна:

```bash
./vpn.sh install
```

Сгенерированные юниты ссылаются на текущий каталог, поэтому если вы перенесёте
эту папку, выполните:

```bash
./vpn.sh install
```

заново с нового места. Установщик сохраняет найденные пути к бинарникам в
`config-linux/runtime.env`, а сгенерированные конфиги клиента — в
`config-linux/`.

Команды Linux:

```bash
./vpn.sh install
./vpn.sh on
./vpn.sh off
./vpn.sh restart
./vpn.sh status
./vpn.sh run
```

`./vpn.sh run` запускает VPN в переднем плане. Ctrl-C останавливает его и
восстанавливает маршруты.

## Файлы конфигурации

Секреты клиента лежат в одном файле:

```text
config-local/client.env
```

Сгенерированные рантайм-конфиги для десктопа:

```text
config-linux/ck-client.json
config-linux/ss-local.json
config-linux/runtime.env
config-windows/ck-client.json
config-windows/ss-local.json
config-windows/runtime.json
```

Не редактируйте сгенерированные рантайм-файлы напрямую. Меняйте
`config-local/client.env`, затем заново запускайте `./vpn.sh install`,
`./vpn.sh on` или `.\vpn.cmd install`.
