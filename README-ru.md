# VPN: Shadowsocks поверх Cloak

Русская версия [README.md](README.md).

Как поднять сервер на Ubuntu и настроить клиентов на iPhone, Windows и Linux.

На стороне сервера путь у всех клиентов один и тот же:

```text
транспорт Cloak на клиенте -> сервер Cloak -> сервер Shadowsocks -> интернет
```

## Как идёт трафик

iPhone с Shadowrocket:

```text
приложения на iPhone
  -> VPN-профиль iOS
  -> клиент Shadowsocks в Shadowrocket
  -> плагин Cloak в Shadowrocket
  -> сервер Cloak
  -> сервер Shadowsocks
  -> интернет
```

Windows, полный туннель:

```text
приложения Windows
  -> две половины default-маршрута
  -> TUN-адаптер tun2socks
  -> ss-local
  -> ck-client
  -> сервер Cloak
  -> сервер Shadowsocks
  -> интернет
```

Linux, полный туннель:

```text
приложения Linux
  -> маршруты в TUN
  -> tun2socks
  -> ss-local
  -> ck-client
  -> сервер Cloak
  -> сервер Shadowsocks
  -> интернет
```

## Сервер

Весь сервер — это два бинарника под systemd: `ck-server` из Cloak и `ssserver`
из shadowsocks-rust. Ни Xray, ни Docker, ни образы AmneziaVPN здесь намеренно не
используются.

### Установка скриптом

`install-sscloak-server.sh` проделывает всё, что описано ниже, на чистой Ubuntu
и в конце показывает QR-код для Shadowrocket:

```bash
scp install-sscloak-server.sh user@server:~/
ssh user@server 'bash ~/install-sscloak-server.sh'
```

Пароль sudo он спросит один раз. Дальше сам поставит бинарники, сгенерирует
ключи и пароль, создаст `/opt/sscloak-<порт>/`, включит systemd-юниты, откроет
порт в `ufw`, проверит туннель одноразовым локальным клиентом и положит рядом с
собой `shadowrocket-sscloak-<порт>.png` и `.txt` со ссылкой `ss://`.

Переменные окружения, все необязательные:

```bash
SS_HOST=vpn.example.com SS_PORT=443 bash install-sscloak-server.sh
OUT_DIR=/tmp bash install-sscloak-server.sh      # куда положить QR-код
REGENERATE=1 bash install-sscloak-server.sh      # новые ключи, старые клиенты отвалятся
SKIP_SELFTEST=1 bash install-sscloak-server.sh   # без проверки туннеля
CLOAK_VERSION=v2.12.0 SSRUST_VERSION=v1.24.0 bash install-sscloak-server.sh
```

Запускать повторно безопасно: если порт уже настроен, ключи остаются прежними,
перезаписываются только конфиги, юниты и QR-код. После самопроверки в
`/usr/local/bin` остаются `ck-client` и `sslocal` — если не хотите держать на
сервере лишнее, удалите.

Дальше в этом разделе — то же самое руками.

### Параметры сервера

Дальше по тексту встречаются такие имена:

```text
SS_HOST=<домен или IP сервера>
SS_PORT=<публичный порт Cloak, обычно 443>
SS_METHOD=chacha20-ietf-poly1305
SS_PASSWORD=<сгенерированный пароль Shadowsocks>
CK_UID=<сгенерированный UID Cloak>
CK_PUBLIC_KEY=<сгенерированный публичный ключ Cloak>
CK_SERVER_NAME=tile.openstreetmap.org
CK_BROWSER_SIG=chrome
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
```

Всё дальнейшее рассчитано на чистую Ubuntu, права root (`sudo -i`) и свободный
публичный TCP-порт.

### Бинарники

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

Для arm64 берите `ck-server-linux-arm64-v2.12.0` и
`shadowsocks-v1.24.0.aarch64-unknown-linux-gnu.tar.xz`. Эти же версии зашиты в
скрипт установки; с более свежими всё работает так же.

### Ключи и пароль

На сервере:

```bash
KEY_TEXT=$(ck-server -key | sed -r 's/\x1B\[[0-9;]*[mK]//g')
UID_TEXT=$(ck-server -uid | sed -r 's/\x1B\[[0-9;]*[mK]//g')

PUBLIC_KEY=$(printf '%s\n' "$KEY_TEXT" | awk -F': *' '/PUBLIC key/{print $2}' | awk '{print $1}')
PRIVATE_KEY=$(printf '%s\n' "$KEY_TEXT" | awk -F': *' '/PRIVATE key/{print $2}' | awk '{print $1}')
CK_UID=$(printf '%s\n' "$UID_TEXT" | awk -F': *' '/UID/{print $2}' | awk '{print $1}')
SS_PASSWORD=$(openssl rand -base64 32)
```

Проверьте, что ничего не пустое:

```bash
printf 'PUBLIC_KEY=%s\nPRIVATE_KEY=%s\nCK_UID=%s\nSS_PASSWORD=%s\n' "$PUBLIC_KEY" "$PRIVATE_KEY" "$CK_UID" "$SS_PASSWORD"
```

### Конфиги

Подставьте свой хост и порт и создайте файлы:

```bash
SS_HOST="your.server.example"
SS_PORT="443"

install -d -m 700 /opt/sscloak-443

cat >/opt/sscloak-443/ck-config.json <<EOF
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
  "DatabasePath": "/opt/sscloak-443/userinfo.db",
  "StreamTimeout": 300
}
EOF

cat >/opt/sscloak-443/ss-config.json <<EOF
{
  "server": "127.0.0.1",
  "server_port": 6789,
  "method": "chacha20-ietf-poly1305",
  "password": "$SS_PASSWORD",
  "timeout": 60,
  "mode": "tcp_and_udp"
}
EOF

cat >/opt/sscloak-443/client.env <<EOF
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

chmod 600 /opt/sscloak-443/*.json /opt/sscloak-443/client.env
```

Строка `ssudp` и режим `tcp_and_udp` пускают через туннель UDP — без них не
работает `TUN_DNS_MODE=tunnel`, который на Windows включён по умолчанию. Если
UDP не нужен, уберите `ssudp` и поставьте `"mode": "tcp_only"`.

### Запуск под systemd

```bash
cat >/etc/systemd/system/sscloak-ss-443.service <<'EOF'
[Unit]
Description=Shadowsocks server for sscloak-443
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /opt/sscloak-443/ss-config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/sscloak-ck-443.service <<'EOF'
[Unit]
Description=Cloak server for sscloak-443
After=sscloak-ss-443.service
Requires=sscloak-ss-443.service

[Service]
ExecStart=/usr/local/bin/ck-server -c /opt/sscloak-443/ck-config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sscloak-ss-443.service sscloak-ck-443.service
```

Оба юнита работают от root: Cloak пишет `userinfo.db` в `/opt/sscloak-443`.

### Открыть порт

```bash
ufw allow 443/tcp
```

Cloak слушает только TCP — UDP едет внутри той же TCP-сессии. Если у провайдера
есть свой фаервол (DigitalOcean, Hetzner, AWS), откройте порт и там.

### Проверка

```bash
systemctl --no-pager status sscloak-ss-443 sscloak-ck-443
ss -lntup | grep -E ":$SS_PORT|:6789"
journalctl -u sscloak-ck-443 -n 30 --no-pager
```

Должно быть примерно так:

```text
active (running)  # оба юнита
shadowsocks tcp server listening on 127.0.0.1:6789
Listening on :<SS_PORT>
```

Это показывает только то, что процессы слушают порты. Весь путь целиком
проверяется единственным способом — подключением клиента.
`install-sscloak-server.sh` делает это сам: поднимает одноразовые `ck-client` и
`sslocal`, нацеленные на `127.0.0.1:$SS_PORT`, и запрашивает через полученный
SOCKS-порт `ifconfig.me`. Вручную то же самое — это Linux-клиент из раздела ниже
и `./vpn.sh status`.

## Данные для клиентов

Всё, что нужно клиентам, сервер складывает в `/opt/sscloak-443/client.env`.
Локально эти данные живут в одном файле:

```bash
cp config-local/client.example.env config-local/client.env
```

Впишите туда адрес сервера, UID и публичный ключ Cloak, пароль Shadowsocks. Из
этого файла читают и Linux-, и Windows-скрипты. На iPhone те же значения либо
вводятся в Shadowrocket руками, либо приезжают с QR-кодом, который сделал
серверный скрипт.

Ни настоящий `config-local/client.env`, ни сгенерированные конфиги для
десктопа, ни файлы импорта для Shadowrocket в git не попадают — в них секреты.

## iPhone: Shadowrocket

Поставьте Shadowrocket из App Store. К серверу Cloak/Shadowsocks он ходит
напрямую, поэтому ни AmneziaVPN, ни `tun2socks`, ни настройки локальных
слушателей из `config-local/client.env` ему не нужны.

Быстрее всего — QR-код от `install-sscloak-server.sh`: вкладка Servers -> «+» ->
иконка сканера -> отсканировать `shadowrocket-sscloak-<порт>.png`. Ниже то же
самое руками.

Добавьте новый сервер типа Shadowsocks:

```text
Type: Shadowsocks
Address: SS_HOST
Port: SS_PORT
Method: SS_METHOD
Password: SS_PASSWORD
Plugin: cloak
```

И заполните параметры плагина Cloak:

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

Значения — те же, что в `config-local/client.env`. А вот это нужно только
десктопным клиентам, в Shadowrocket такого не вводят:

```text
SS_LOCAL_SERVER
SS_LOCAL_SERVER_PORT
SS_LOCAL_ADDRESS
SS_LOCAL_PORT
TUN_*
```

Сохраните сервер, выберите его в списке и включите VPN. Чтобы через туннель шёл
весь трафик телефона, включите Global Routing.

## Windows: полный туннель

Shadowsocks GUI на Windows работает системным прокси, а не VPN. Чтобы завернуть
в туннель всю машину, поставьте AmneziaVPN — по умолчанию берутся вложенные в
него программы:

```text
C:\Program Files\AmneziaVPN\cloak\ck-client.exe
C:\Program Files\AmneziaVPN\ss\ss-local.exe
C:\Program Files\AmneziaVPN\xray\tun2socks.exe
```

Отдельное GUI-приложение Shadowsocks при этом не нужно. Если что-то лежит в
другом месте, укажите полный путь через `CK_BIN`, `SS_BIN` или `TUN2SOCKS_BIN`.

Из этого каталога соберите файлы для Windows:

```powershell
.\vpn.cmd install
```

Затем откройте PowerShell от администратора в этом же каталоге и запустите:

```powershell
.\vpn.cmd run
```

`run` поднимает `ck-client`, `ss-local` и `tun2socks`, создаёт TUN-адаптер с
именем `sscloak`, заворачивает в него маршруты по умолчанию, а по Ctrl-C
возвращает маршруты на место.

По умолчанию на Windows стоит `TUN_DNS_MODE=tunnel`: второй экземпляр `ck-client`
тащит UDP через серверный `ssudp`, а `ss-local -u` работает UDP-релеем для
SOCKS5. За счёт этого DNS резолвится на VPN-сервере, а не в локальной сети.
Режим `physical` пускает DNS мимо туннеля, через активный адаптер; `none`
оставляет TUN-адаптер вообще без DNS-серверов.

Команды:

```powershell
.\vpn.cmd install
.\vpn.cmd on
.\vpn.cmd off
.\vpn.cmd status
.\vpn.cmd restart
.\vpn.cmd run
```

Сгенерированные файлы Windows-скрипт складывает в `config-windows/`.

## Linux: полный туннель

Поставьте AmneziaVPN на клиентскую машину — берутся вложенные в него бинарники:

- `ck-client` — клиент Cloak
- `ss-local` — локальный клиент Shadowsocks
- `tun2socks` — заворачивает TUN-интерфейс в локальный SOCKS-прокси

`./vpn.sh install` ищет в `PATH` такие команды:

```text
ck-client
ss-local
tun2socks
```

Если в `PATH` их нет, установщик просматривает каталоги:

```text
/usr/local/bin
/usr/bin
/bin
/opt
```

Если бинарник лежит где-то ещё, передайте путь явно. Для типичной установки
AmneziaVPN это выглядит так:

```bash
CK_BIN=/opt/AmneziaVPN/client/bin/ck-client \
SS_BIN=/opt/AmneziaVPN/client/bin/ss-local \
TUN2SOCKS_BIN=/opt/AmneziaVPN/client/bin/tun2socks \
./vpn.sh install
```

Сменить каталоги запасного поиска:

```bash
BIN_SEARCH_DIRS=/opt:/srv/tools ./vpn.sh install
```

Из этого каталога поставьте сгенерированные конфиги, systemd-юниты и хук
системного сна:

```bash
./vpn.sh install
```

В юнитах прописан путь к текущему каталогу, поэтому после переноса папки
`./vpn.sh install` нужно запустить заново, уже с нового места. Найденные пути к
бинарникам установщик сохраняет в `config-linux/runtime.env`, туда же, в
`config-linux/`, кладёт сгенерированные конфиги клиента.

Команды:

```bash
./vpn.sh install
./vpn.sh on
./vpn.sh off
./vpn.sh restart
./vpn.sh status
./vpn.sh run
```

`./vpn.sh run` держит VPN на переднем плане: Ctrl-C останавливает его и
возвращает маршруты на место.

## Файлы конфигурации

Секреты клиента — в одном файле:

```text
config-local/client.env
```

Конфиги, которые генерируются на десктопе автоматически:

```text
config-linux/ck-client.json
config-linux/ss-local.json
config-linux/runtime.env
config-windows/ck-client.json
config-windows/ss-local.json
config-windows/runtime.json
```

Руками их править не надо: меняйте `config-local/client.env` и заново
запускайте `./vpn.sh install`, `./vpn.sh on` или `.\vpn.cmd install`.
