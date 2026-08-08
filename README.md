# Shadowsocks over Cloak VPN

Setup notes and scripts for the Ubuntu server and for the iPhone, Windows, and
Linux clients.

All clients ultimately use the same server-side path:

```text
client Cloak transport -> Cloak server -> Shadowsocks server -> Internet
```

## Traffic Paths

iPhone with Shadowrocket:

```text
iPhone apps
  -> iOS VPN profile
  -> Shadowrocket Shadowsocks client
  -> Shadowrocket Cloak plugin
  -> Cloak server
  -> Shadowsocks server
  -> Internet
```

Windows full-tunnel mode:

```text
Windows apps
  -> split default routes
  -> tun2socks TUN adapter
  -> ss-local
  -> ck-client
  -> Cloak server
  -> Shadowsocks server
  -> Internet
```

Linux full-tunnel mode:

```text
Linux apps
  -> TUN routes
  -> tun2socks
  -> ss-local
  -> ck-client
  -> Cloak server
  -> Shadowsocks server
  -> Internet
```

## Server Setup

The server is two static binaries under systemd: `ck-server` from Cloak and
`ssserver` from shadowsocks-rust. It intentionally does not use Xray, Docker, or
the AmneziaVPN container images.

### Automated Install

`install-sscloak-server.sh` does everything in this section on a clean Ubuntu
host and prints a Shadowrocket QR code at the end:

```bash
scp install-sscloak-server.sh user@server:~/
ssh user@server 'bash ~/install-sscloak-server.sh'
```

It asks for the sudo password once, installs the binaries, generates
credentials, writes `/opt/sscloak-<port>/`, enables the systemd units, opens the
port in `ufw`, verifies the tunnel with a throwaway local client, and drops
`shadowrocket-sscloak-<port>.png` plus a `.txt` with the `ss://` link next to
itself.

Optional environment variables:

```bash
SS_HOST=vpn.example.com SS_PORT=443 bash install-sscloak-server.sh
OUT_DIR=/tmp bash install-sscloak-server.sh      # where to write the QR code
REGENERATE=1 bash install-sscloak-server.sh      # new keys, drops existing clients
SKIP_SELFTEST=1 bash install-sscloak-server.sh   # skip the tunnel check
CLOAK_VERSION=v2.12.0 SSRUST_VERSION=v1.24.0 bash install-sscloak-server.sh
```

Rerunning is safe: an already-configured port keeps its keys by default and only
its configs, units, and QR code are rewritten. The self-test leaves `ck-client`
and `sslocal` in `/usr/local/bin`; remove them if you want the server host
clean.

The rest of this section is the same install by hand.

### Server Values

Use these placeholders consistently:

```text
SS_HOST=<server hostname or IP>
SS_PORT=<public Cloak port, usually 443>
SS_METHOD=chacha20-ietf-poly1305
SS_PASSWORD=<generated Shadowsocks password>
CK_UID=<generated Cloak UID>
CK_PUBLIC_KEY=<generated Cloak public key>
CK_SERVER_NAME=tile.openstreetmap.org
CK_BROWSER_SIG=chrome
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
```

The manual steps below assume a clean Ubuntu host, root (`sudo -i`), and a free
public TCP port.

### Install Server Binaries

```bash
apt update && apt install -y curl xz-utils openssl qrencode

# Cloak server
curl -fsSL -o /usr/local/bin/ck-server \
  https://github.com/cbeuw/Cloak/releases/download/v2.12.0/ck-server-linux-amd64-v2.12.0
chmod +x /usr/local/bin/ck-server

# Shadowsocks server, from shadowsocks-rust
curl -fsSL -o /tmp/ss.tar.xz \
  https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.24.0/shadowsocks-v1.24.0.x86_64-unknown-linux-gnu.tar.xz
tar -xJf /tmp/ss.tar.xz -C /usr/local/bin ssserver
chmod +x /usr/local/bin/ssserver
```

On arm64 use `ck-server-linux-arm64-v2.12.0` and
`shadowsocks-v1.24.0.aarch64-unknown-linux-gnu.tar.xz`. These are the versions
the install script pins; newer releases work the same way.

### Generate Credentials

Run on the server:

```bash
KEY_TEXT=$(ck-server -key | sed -r 's/\x1B\[[0-9;]*[mK]//g')
UID_TEXT=$(ck-server -uid | sed -r 's/\x1B\[[0-9;]*[mK]//g')

PUBLIC_KEY=$(printf '%s\n' "$KEY_TEXT" | awk -F': *' '/PUBLIC key/{print $2}' | awk '{print $1}')
PRIVATE_KEY=$(printf '%s\n' "$KEY_TEXT" | awk -F': *' '/PRIVATE key/{print $2}' | awk '{print $1}')
CK_UID=$(printf '%s\n' "$UID_TEXT" | awk -F': *' '/UID/{print $2}' | awk '{print $1}')
SS_PASSWORD=$(openssl rand -base64 32)
```

Verify none are empty:

```bash
printf 'PUBLIC_KEY=%s\nPRIVATE_KEY=%s\nCK_UID=%s\nSS_PASSWORD=%s\n' "$PUBLIC_KEY" "$PRIVATE_KEY" "$CK_UID" "$SS_PASSWORD"
```

### Create Server Configs

Set your public host and port, then create the server config files:

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

The `ssudp` entry and `tcp_and_udp` carry UDP through the tunnel, which is what
the Windows client's default `TUN_DNS_MODE=tunnel` needs. For a TCP-only server,
drop the `ssudp` line and use `"mode": "tcp_only"`.

### Run Under systemd

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

Both units run as root because Cloak writes `userinfo.db` into
`/opt/sscloak-443`.

### Open The Port

```bash
ufw allow 443/tcp
```

Cloak listens on TCP only; UDP rides inside the same TCP session. If the
provider has its own firewall (DigitalOcean, Hetzner, AWS), open the port there
too.

### Check Server

```bash
systemctl --no-pager status sscloak-ss-443 sscloak-ck-443
ss -lntup | grep -E ":$SS_PORT|:6789"
journalctl -u sscloak-ck-443 -n 30 --no-pager
```

Expected:

```text
active (running)  # both units
shadowsocks tcp server listening on 127.0.0.1:6789
Listening on :<SS_PORT>
```

Those checks only prove the processes are listening. To prove the whole path,
connect a client: `install-sscloak-server.sh` does this automatically by running
a throwaway `ck-client` + `sslocal` against `127.0.0.1:$SS_PORT` and curling
`ifconfig.me` through the resulting SOCKS port, and the same check by hand is the
Linux client below plus `./vpn.sh status`.

## Client Values

`/opt/sscloak-443/client.env` on the server holds everything the clients need.
Copy it into the single local client values file:

```bash
cp config-local/client.example.env config-local/client.env
```

Edit `config-local/client.env` with your server host, Cloak UID/public key, and
Shadowsocks password. Linux and Windows scripts read this same file. iPhone
setup uses the same values entered manually in Shadowrocket, or imported from
the QR code the server install script produced.

The real `config-local/client.env`, generated desktop runtime files, and
Shadowrocket import files under `config-local/` are ignored by git because they
contain credentials.

## iPhone Setup with Shadowrocket

Install Shadowrocket from the App Store. On iPhone, Shadowrocket connects
directly to the Cloak/Shadowsocks server, so it does not use AmneziaVPN,
`tun2socks`, or the local listener values from `config-local/client.env`.

The quickest path is the QR code from `install-sscloak-server.sh`: Servers tab ->
`+` -> the scanner icon -> scan `shadowrocket-sscloak-<port>.png`. The manual
equivalent follows.

Add a new Shadowsocks server in Shadowrocket with these values:

```text
Type: Shadowsocks
Address: SS_HOST
Port: SS_PORT
Method: SS_METHOD
Password: SS_PASSWORD
Plugin: cloak
```

Configure the Cloak plugin with the matching Cloak values:

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

Use the same values that are in `config-local/client.env`. The local listener
settings below are desktop-only and should not be entered in Shadowrocket:

```text
SS_LOCAL_SERVER
SS_LOCAL_SERVER_PORT
SS_LOCAL_ADDRESS
SS_LOCAL_PORT
TUN_*
```

After saving the server, select it in Shadowrocket and enable the VPN switch.
Use Global Routing if you want all iPhone traffic through the tunnel.

## Windows Full-Tunnel Setup

Windows Shadowsocks GUI mode is a system proxy, not a full VPN. For full-device
routing, install AmneziaVPN on the Windows client machine. This setup uses
these bundled executables by default:

```text
C:\Program Files\AmneziaVPN\cloak\ck-client.exe
C:\Program Files\AmneziaVPN\ss\ss-local.exe
C:\Program Files\AmneziaVPN\xray\tun2socks.exe
```

The standalone Shadowsocks Windows GUI app is not required for full-tunnel mode.
If any binary is installed somewhere else, set `CK_BIN`, `SS_BIN`, or
`TUN2SOCKS_BIN` to the full executable path.

From this directory, generate Windows runtime files:

```powershell
.\vpn.cmd install
```

Then start an elevated PowerShell from this directory and run:

```powershell
.\vpn.cmd run
```

`run` starts `ck-client`, `ss-local`, and `tun2socks`, creates a TUN adapter
named `sscloak`, adds split default routes through it, and restores routes when
you press Ctrl-C. Windows commands:

By default, Windows uses `TUN_DNS_MODE=tunnel`: a second Cloak client carries
UDP through the server's `ssudp` method, and `ss-local -u` provides
SOCKS5 UDP relay. DNS therefore resolves from the VPN server rather than the
local network. `physical` bypasses the tunnel through the active adapter;
`none` leaves the TUN adapter without configured DNS servers.

```powershell
.\vpn.cmd install
.\vpn.cmd on
.\vpn.cmd off
.\vpn.cmd status
.\vpn.cmd restart
.\vpn.cmd run
```

The Windows script writes generated runtime files under `config-windows/`.

## Linux Full-Tunnel Setup

Install AmneziaVPN on the Linux client machine. This setup uses the binaries
bundled with it:

- `ck-client`, the Cloak client
- `ss-local`, the Shadowsocks local client
- `tun2socks`, for routing the TUN interface into the local SOCKS proxy

`./vpn.sh install` looks for these command names in `PATH`:

```text
ck-client
ss-local
tun2socks
```

If they are not in `PATH`, the installer searches executable files under:

```text
/usr/local/bin
/usr/bin
/bin
/opt
```

If any binary is installed somewhere outside `PATH`, pass explicit paths. With a
typical AmneziaVPN install this may look like:

```bash
CK_BIN=/opt/AmneziaVPN/client/bin/ck-client \
SS_BIN=/opt/AmneziaVPN/client/bin/ss-local \
TUN2SOCKS_BIN=/opt/AmneziaVPN/client/bin/tun2socks \
./vpn.sh install
```

To change the fallback search roots:

```bash
BIN_SEARCH_DIRS=/opt:/srv/tools ./vpn.sh install
```

From this directory, install the generated runtime files, systemd units, and
system sleep hook:

```bash
./vpn.sh install
```

The generated units point at the current directory, so if you move this folder
later, run:

```bash
./vpn.sh install
```

again from the new location. The installer stores resolved binary paths in
`config-linux/runtime.env` and generated client configs in `config-linux/`.

Linux commands:

```bash
./vpn.sh install
./vpn.sh on
./vpn.sh off
./vpn.sh restart
./vpn.sh status
./vpn.sh run
```

`./vpn.sh run` starts the VPN in foreground mode. Press Ctrl-C to stop it and
restore routes.

## Config Files

Client secrets live in one file:

```text
config-local/client.env
```

Generated desktop runtime config lives in:

```text
config-linux/ck-client.json
config-linux/ss-local.json
config-linux/runtime.env
config-windows/ck-client.json
config-windows/ss-local.json
config-windows/runtime.json
```

Do not edit the generated runtime files directly. Change
`config-local/client.env`, then rerun `./vpn.sh install`, `./vpn.sh on`, or
`.\vpn.cmd install`.
