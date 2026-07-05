# Shadowsocks over Cloak VPN Client

This directory contains a Linux client setup for routing traffic through:

```text
local apps -> tun2socks -> ss-local -> ck-client -> Cloak/Shadowsocks server
```

## Dependency

Install AmneziaVPN on the client machine. This setup uses the binaries bundled
with it:

- `ck-client`, the Cloak client
- `ss-local`, the Shadowsocks local client
- `tun2socks`, for routing the TUN interface into the local SOCKS proxy

If you provide compatible binaries another way, set explicit paths as shown
below.

## Binary Discovery

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

The installer stores the resolved binary paths in `config-linux/runtime.env`.

## Setup

Create the single local client values file:

```bash
cp config-local/client.example.env config-local/client.env
```

Edit `config-local/client.env` with your server host, Cloak UID/public key, and
Shadowsocks password. `./vpn.sh install` and `./vpn.sh on` generate the
runtime files in `config-linux/ck-client.json` and `config-linux/ss-local.json` from that
single source.

The real `config-local/client.env`, generated `config-linux/*.json` files, and
Shadowrocket import files under `config-local/` are ignored by git because they
contain credentials.

From this directory:

```bash
./vpn.sh install
```

This installs systemd units and a system sleep hook. The generated units point
at the current directory, so if you move this folder later, run:

```bash
./vpn.sh install
```

again from the new location.

## Commands

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

## Windows Full-Tunnel Setup

Windows Shadowsocks GUI mode is a system proxy, not a full VPN. For full-device
routing, install AmneziaVPN first and use it as the source for the required
Windows executables:

```text
C:\Program Files\AmneziaVPN\cloak\ck-client.exe
C:\Program Files\AmneziaVPN\ss\ss-local.exe
C:\Program Files\AmneziaVPN\xray\tun2socks.exe
```

The standalone Shadowsocks Windows GUI app is not required for full-tunnel mode.

Then use the PowerShell controller:

```powershell
.\vpn.cmd install
```

Then start an elevated PowerShell from this directory:

```powershell
.\vpn.cmd run
```

`run` starts `ck-client`, `ss-local`, and `tun2socks`, creates a TUN adapter
named `sscloak`, adds split default routes through it, and restores routes when
you press Ctrl-C. The background commands are:

```powershell
.\vpn.cmd on
.\vpn.cmd off
.\vpn.cmd status
.\vpn.cmd restart
```

The Windows script reads the same `config-local/client.env` file as the Linux script
and writes generated runtime files under `config-windows/`.

## iPhone Setup with Shadowrocket

Install Shadowrocket from the App Store. On iPhone, Shadowrocket connects
directly to the Cloak/Shadowsocks server, so it does not use AmneziaVPN,
`tun2socks`, or the local listener values from `config-local/client.env`.

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

## Config Files

Client secrets live in one file:

```text
config-local/client.env
```

Generated runtime config lives in:

```text
config-linux/ck-client.json
config-linux/ss-local.json
```

Do not edit the generated JSON files directly. Change `config-local/client.env`, then
run `./vpn.sh install` or `./vpn.sh on`.

## Server Setup

This setup uses:

```text
client -> Shadowsocks local -> Cloak client -> server Cloak endpoint -> Shadowsocks server -> internet
```

It intentionally does not use Xray.

### Server Values

Use these placeholders consistently:

```text
SS_HOST=<server hostname or IP>
SS_PORT=<public Cloak port, usually 8443>
SS_METHOD=chacha20-ietf-poly1305
SS_PASSWORD=<generated Shadowsocks password>
CK_UID=<generated Cloak UID>
CK_PUBLIC_KEY=<generated Cloak public key>
CK_SERVER_NAME=tile.openstreetmap.org
CK_BROWSER_SIG=chrome
CK_PROXY_METHOD=shadowsocks
CK_ENCRYPTION_METHOD=aes-gcm
```

The server examples below assume:

- Docker is installed on the server.
- The image `amnezia-openvpn-cloak` is available.
- The selected public TCP port is free.

That image is used because it contains `ck-server` and `ssserver`.

Check:

```bash
docker run --rm --entrypoint sh amnezia-openvpn-cloak -c 'command -v ck-server; command -v ssserver'
```

### Generate Credentials

Run on the server:

```bash
KEY_TEXT=$(docker run --rm --entrypoint ck-server amnezia-openvpn-cloak -key | sed -r 's/\x1B\[[0-9;]*[mK]//g')
UID_TEXT=$(docker run --rm --entrypoint ck-server amnezia-openvpn-cloak -uid | sed -r 's/\x1B\[[0-9;]*[mK]//g')

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
SS_PORT="8443"

install -d -m 700 /opt/sscloak-8443

cat >/opt/sscloak-8443/ck-config.json <<EOF
{
  "ProxyBook": {
    "shadowsocks": ["tcp", "127.0.0.1:6789"]
  },
  "BypassUID": ["$CK_UID"],
  "BindAddr": [":$SS_PORT"],
  "RedirAddr": "tile.openstreetmap.org",
  "PrivateKey": "$PRIVATE_KEY",
  "AdminUID": "$CK_UID",
  "DatabasePath": "/opt/sscloak/userinfo.db",
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
  "mode": "tcp_only"
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
EOF

chmod 600 /opt/sscloak-8443/*.json /opt/sscloak-8443/client.env
```

### Start Server Container

```bash
docker rm -f sscloak-8443 >/dev/null 2>&1 || true

docker run -d \
  --name sscloak-8443 \
  --restart unless-stopped \
  -p "$SS_PORT:$SS_PORT/tcp" \
  -v /opt/sscloak-8443:/opt/sscloak \
  --entrypoint sh \
  amnezia-openvpn-cloak \
  -c "ssserver -c /opt/sscloak/ss-config.json & exec ck-server -c /opt/sscloak/ck-config.json"
```

The bind mount is intentionally writable because Cloak writes `userinfo.db`.

### Check Server

```bash
docker ps --filter name=sscloak-8443 --format '{{.Names}} {{.Status}} {{.Ports}}'
docker logs --tail 80 sscloak-8443
ss -lntup | grep ":$SS_PORT"
```

Expected:

```text
sscloak-8443 Up ... 0.0.0.0:<SS_PORT>-><SS_PORT>/tcp
shadowsocks tcp server listening on 127.0.0.1:6789
Listening on :<SS_PORT>
```

Use `/opt/sscloak-8443/client.env` to fill in `config-local/client.env`.

