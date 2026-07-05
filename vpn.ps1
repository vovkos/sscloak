param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'on', 'off', 'restart', 'status', 'run', 'debug', 'help')]
    [string]$Command = 'help'
)

$ErrorActionPreference = 'Stop'

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalDir = Join-Path $AppDir 'config-local'
$ClientEnv = Join-Path $LocalDir 'client.env'
$RuntimeDir = Join-Path $AppDir 'config-windows'
$RuntimeEnv = Join-Path $RuntimeDir 'runtime.json'
$CkConfig = Join-Path $RuntimeDir 'ck-client.json'
$SsConfig = Join-Path $RuntimeDir 'ss-local.json'
$StateFile = Join-Path $RuntimeDir 'state.json'
$LogDir = Join-Path $RuntimeDir 'logs'

function Write-Step {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    try {
        Ensure-Dirs
        Add-Content -LiteralPath (Join-Path $LogDir 'vpn-run.log') -Value $line -Encoding UTF8
    } catch {
        # Logging must never block VPN setup.
    }
}

function Show-Usage {
    @'
Usage: .\vpn.cmd <command>

Commands:
  install   Detect binaries and generate Windows runtime config
  on        Start full VPN in the background
  off       Stop VPN and restore routes
  restart   Stop, clean, and start again
  status    Show process, route, and public IP status
  run       Foreground mode: start VPN, Ctrl-C stops it
  debug     Check runtime inputs without changing routes
'@
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw "This command must be run from an elevated PowerShell window."
    }
}

function Ensure-Dirs {
    New-Item -ItemType Directory -Force -Path $RuntimeDir, $LogDir | Out-Null
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Value
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Read-ClientEnv {
    if (-not (Test-Path -LiteralPath $ClientEnv)) {
        throw "Missing $ClientEnv. Copy local\client.example.env to local\client.env and fill it in."
    }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $ClientEnv) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }

    foreach ($required in @('SS_HOST', 'SS_PORT', 'SS_METHOD', 'SS_PASSWORD', 'CK_UID', 'CK_PUBLIC_KEY')) {
        if (-not $values.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($values[$required])) {
            throw "Missing required value $required in $ClientEnv."
        }
    }

    $defaults = @{
        CK_SERVER_NAME = 'tile.openstreetmap.org'
        CK_BROWSER_SIG = 'chrome'
        CK_PROXY_METHOD = 'shadowsocks'
        CK_ENCRYPTION_METHOD = 'aes-gcm'
        CK_TRANSPORT = 'direct'
        CK_STREAM_TIMEOUT = '300'
        CK_NUM_CONN = '1'
        SS_LOCAL_SERVER = '127.0.0.1'
        SS_LOCAL_SERVER_PORT = '16789'
        SS_LOCAL_ADDRESS = '127.0.0.1'
        SS_LOCAL_PORT = '10810'
        SS_TIMEOUT = '60'
        TUN_NAME = 'sscloak'
        TUN_ADDR = '198.19.0.1'
        TUN_PREFIX = '15'
        TUN_DNS = '1.1.1.1,8.8.8.8'
    }

    foreach ($key in $defaults.Keys) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($values[$key])) {
            $values[$key] = $defaults[$key]
        }
    }

    $values
}

function Find-Binary {
    param(
        [string]$EnvName,
        [string[]]$Candidates
    )

    $configured = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (Test-Path -LiteralPath $configured) { return (Resolve-Path -LiteralPath $configured).Path }
        throw "$EnvName is set but does not exist: $configured"
    }

    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    throw "Could not find $EnvName. Set $EnvName to the executable path and run install again."
}

function Resolve-RemoteIp {
    param([string]$HostName)

    if ($HostName -match '^\d{1,3}(\.\d{1,3}){3}$') { return $HostName }
    $entry = [System.Net.Dns]::GetHostAddresses($HostName) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        Select-Object -First 1
    if (-not $entry) { throw "Could not resolve IPv4 address for $HostName." }
    $entry.IPAddressToString
}

function Write-Configs {
    Ensure-Dirs
    $env = Read-ClientEnv
    $remoteIp = Resolve-RemoteIp $env.SS_HOST

    $ck = [ordered]@{
        BrowserSig = $env.CK_BROWSER_SIG
        EncryptionMethod = $env.CK_ENCRYPTION_METHOD
        NumConn = [int]$env.CK_NUM_CONN
        ProxyMethod = $env.CK_PROXY_METHOD
        PublicKey = $env.CK_PUBLIC_KEY
        RemoteHost = $env.SS_HOST
        RemotePort = "$($env.SS_PORT)"
        ServerName = $env.CK_SERVER_NAME
        StreamTimeout = [int]$env.CK_STREAM_TIMEOUT
        Transport = $env.CK_TRANSPORT
        UID = $env.CK_UID
    }

    $ss = [ordered]@{
        server = $env.SS_LOCAL_SERVER
        server_port = [int]$env.SS_LOCAL_SERVER_PORT
        local_address = $env.SS_LOCAL_ADDRESS
        local_port = [int]$env.SS_LOCAL_PORT
        method = $env.SS_METHOD
        password = $env.SS_PASSWORD
        timeout = [int]$env.SS_TIMEOUT
    }

    $runtime = [ordered]@{
        CK_BIN = Find-Binary 'CK_BIN' @(
            'C:\Program Files\AmneziaVPN\cloak\ck-client.exe',
            'C:\Vpn\cloak\ck-client.exe',
            'ck-client.exe'
        )
        SS_BIN = Find-Binary 'SS_BIN' @(
            'C:\Program Files\AmneziaVPN\ss\ss-local.exe',
            'ss-local.exe'
        )
        TUN2SOCKS_BIN = Find-Binary 'TUN2SOCKS_BIN' @(
            'C:\Program Files\AmneziaVPN\xray\tun2socks.exe',
            'tun2socks.exe'
        )
        REMOTE_HOST = $env.SS_HOST
        REMOTE_IP = $remoteIp
        REMOTE_PORT = [int]$env.SS_PORT
        CK_LISTEN_PORT = [int]$env.SS_LOCAL_SERVER_PORT
        SOCKS_HOST = $env.SS_LOCAL_ADDRESS
        SOCKS_PORT = [int]$env.SS_LOCAL_PORT
        TUN_NAME = $env.TUN_NAME
        TUN_ADDR = $env.TUN_ADDR
        TUN_PREFIX = [int]$env.TUN_PREFIX
        TUN_DNS = @($env.TUN_DNS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    Write-Utf8NoBom -Path $CkConfig -Value (($ck | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Write-Utf8NoBom -Path $SsConfig -Value (($ss | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Write-Utf8NoBom -Path $RuntimeEnv -Value (($runtime | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    $runtime
}

function Read-Runtime {
    if (-not (Test-Path -LiteralPath $RuntimeEnv)) {
        Write-Configs | Out-Null
    }
    Get-Content -Raw -LiteralPath $RuntimeEnv | ConvertFrom-Json
}

function Get-ProcessByPathAndArgs {
    param([string]$Name, [string]$Path, [string]$ArgLike)
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq $Name -and
        $_.ExecutablePath -eq $Path -and
        $_.CommandLine -like $ArgLike
    }
}

function Stop-ProcessByPathAndArgs {
    param([string]$Name, [string]$Path, [string]$ArgLike)
    Get-ProcessByPathAndArgs -Name $Name -Path $Path -ArgLike $ArgLike |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-ShadowsocksGuiIfUsingPort {
    param([int]$Port)
    Write-Step "Checking whether Shadowsocks GUI is using 127.0.0.1:$Port"
    $listeners = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'Shadowsocks') {
            Stop-Process -Id $proc.Id -Force
        }
    }
}

function Stop-LocalPortOwner {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        if ($listener.OwningProcess -eq 0 -or $listener.OwningProcess -eq $PID) { continue }
        $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Step "Stopping stale listener on 127.0.0.1:$Port owned by $($proc.ProcessName) PID $($proc.Id)"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    for ($i = 0; $i -lt 20; $i++) {
        $stillListening = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $stillListening) { return }
        Start-Sleep -Milliseconds 250
    }
}

function Start-LocalProxy {
    param($Runtime)

    Stop-ShadowsocksGuiIfUsingPort -Port $Runtime.SOCKS_PORT
    Stop-LocalPortOwner -Port $Runtime.CK_LISTEN_PORT
    Stop-LocalPortOwner -Port $Runtime.SOCKS_PORT

    Write-Step "Starting Cloak listener on 127.0.0.1:$($Runtime.CK_LISTEN_PORT)"
    $ckExisting = Get-ProcessByPathAndArgs -Name 'ck-client.exe' -Path $Runtime.CK_BIN -ArgLike "*$CkConfig*"
    if (-not $ckExisting) {
        Remove-Item (Join-Path $LogDir 'ck-client.out.log'), (Join-Path $LogDir 'ck-client.err.log') -ErrorAction SilentlyContinue
        Start-Process -FilePath $Runtime.CK_BIN `
            -ArgumentList @('-c', $CkConfig, '-l', "$($Runtime.CK_LISTEN_PORT)") `
            -WorkingDirectory (Split-Path -Parent $Runtime.CK_BIN) `
            -RedirectStandardOutput (Join-Path $LogDir 'ck-client.out.log') `
            -RedirectStandardError (Join-Path $LogDir 'ck-client.err.log') `
            -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 2
    }

    $ckRunning = Get-ProcessByPathAndArgs -Name 'ck-client.exe' -Path $Runtime.CK_BIN -ArgLike "*$CkConfig*"
    if (-not $ckRunning) {
        $ckLog = Join-Path $LogDir 'ck-client.err.log'
        $tail = if (Test-Path -LiteralPath $ckLog) { (Get-Content -Tail 20 -LiteralPath $ckLog) -join [Environment]::NewLine } else { '' }
        throw "ck-client did not stay running. $tail"
    }

    Write-Step "Starting ss-local SOCKS listener on 127.0.0.1:$($Runtime.SOCKS_PORT)"
    $ssExisting = Get-ProcessByPathAndArgs -Name 'ss-local.exe' -Path $Runtime.SS_BIN -ArgLike "*$SsConfig*"
    if (-not $ssExisting) {
        Remove-Item (Join-Path $LogDir 'ss-local.out.log'), (Join-Path $LogDir 'ss-local.err.log') -ErrorAction SilentlyContinue
        Start-Process -FilePath $Runtime.SS_BIN `
            -ArgumentList @('-c', $SsConfig) `
            -WorkingDirectory (Split-Path -Parent $Runtime.SS_BIN) `
            -RedirectStandardOutput (Join-Path $LogDir 'ss-local.out.log') `
            -RedirectStandardError (Join-Path $LogDir 'ss-local.err.log') `
            -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 2
    }

    $ssRunning = Get-ProcessByPathAndArgs -Name 'ss-local.exe' -Path $Runtime.SS_BIN -ArgLike "*$SsConfig*"
    if (-not $ssRunning) {
        $ssLog = Join-Path $LogDir 'ss-local.err.log'
        $tail = if (Test-Path -LiteralPath $ssLog) { (Get-Content -Tail 20 -LiteralPath $ssLog) -join [Environment]::NewLine } else { '' }
        throw "ss-local did not stay running. $tail"
    }

    $listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Runtime.SOCKS_PORT -State Listen -ErrorAction SilentlyContinue
    if (-not $listener) {
        throw "ss-local did not start on 127.0.0.1:$($Runtime.SOCKS_PORT). Check $LogDir."
    }
}

function Get-PhysicalDefaultRoute {
    param($Runtime)
    Write-Step "Finding physical default route"
    $excluded = @($Runtime.TUN_NAME, 'Loopback Pseudo-Interface 1')
    $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Where-Object { $excluded -notcontains $_.InterfaceAlias -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceMetric
    $route = $routes | Select-Object -First 1
    if (-not $route) { throw "Could not find a physical IPv4 default route." }
    $route
}

function Save-State {
    param($Runtime, $Route)
    Write-Step "Saving route state"
    $state = [ordered]@{
        CreatedAt = (Get-Date).ToString('o')
        DefaultIfIndex = [int]$Route.ifIndex
        DefaultInterfaceAlias = $Route.InterfaceAlias
        DefaultNextHop = $Route.NextHop
        RemoteIp = $Runtime.REMOTE_IP
        TunName = $Runtime.TUN_NAME
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Start-Tun2Socks {
    param($Runtime)
    Write-Step "Starting tun2socks on TUN adapter $($Runtime.TUN_NAME)"
    $existing = Get-ProcessByPathAndArgs -Name (Split-Path -Leaf $Runtime.TUN2SOCKS_BIN) -Path $Runtime.TUN2SOCKS_BIN -ArgLike "*$($Runtime.TUN_NAME)*"
    if ($existing) { return }

    Start-Process -FilePath $Runtime.TUN2SOCKS_BIN `
        -ArgumentList @(
            '-device', "tun://$($Runtime.TUN_NAME)",
            '-proxy', "socks5://$($Runtime.SOCKS_HOST):$($Runtime.SOCKS_PORT)",
            '-loglevel', 'info'
        ) `
        -WorkingDirectory (Split-Path -Parent $Runtime.TUN2SOCKS_BIN) `
        -RedirectStandardOutput (Join-Path $LogDir 'tun2socks.out.log') `
        -RedirectStandardError (Join-Path $LogDir 'tun2socks.err.log') `
        -WindowStyle Hidden | Out-Null
}

function Wait-TunAdapter {
    param($Runtime)
    Write-Step "Waiting for TUN adapter $($Runtime.TUN_NAME)"
    for ($i = 0; $i -lt 30; $i++) {
        $adapter = Get-NetAdapter -Name $Runtime.TUN_NAME -ErrorAction SilentlyContinue
        if ($adapter) { return $adapter }
        Start-Sleep -Milliseconds 500
    }
    throw "TUN adapter $($Runtime.TUN_NAME) did not appear. Check tun2socks logs in $LogDir."
}

function Set-TunRoutes {
    param($Runtime)

    $route = Get-PhysicalDefaultRoute -Runtime $Runtime
    Save-State -Runtime $Runtime -Route $route

    Write-Step "Adding bypass route for $($Runtime.REMOTE_IP) via $($route.NextHop)"
    New-NetRoute -DestinationPrefix "$($Runtime.REMOTE_IP)/32" -InterfaceIndex $route.ifIndex -NextHop $route.NextHop -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Out-Null

    Start-Tun2Socks -Runtime $Runtime
    $adapter = Wait-TunAdapter -Runtime $Runtime

    Write-Step "Configuring adapter $($adapter.Name) ($($adapter.ifIndex))"
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -InterfaceMetric 1 | Out-Null

    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Runtime.TUN_ADDR -PrefixLength $Runtime.TUN_PREFIX -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Out-Null

    if ($Runtime.TUN_DNS.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Runtime.TUN_DNS -ErrorAction SilentlyContinue
    }

    foreach ($prefix in @('0.0.0.0/1', '128.0.0.0/1')) {
        Write-Step "Adding full-tunnel route $prefix through $($adapter.Name)"
        Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -ne $adapter.ifIndex } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $adapter.ifIndex -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Out-Null
    }
}

function Stop-Vpn {
    $runtime = Read-Runtime
    Write-Step "Stopping sscloak VPN components"
    $state = $null
    if (Test-Path -LiteralPath $StateFile) {
        $state = Get-Content -Raw -LiteralPath $StateFile | ConvertFrom-Json
    }

    Stop-ProcessByPathAndArgs -Name (Split-Path -Leaf $runtime.TUN2SOCKS_BIN) -Path $runtime.TUN2SOCKS_BIN -ArgLike "*$($runtime.TUN_NAME)*"
    Stop-LocalPortOwner -Port $runtime.CK_LISTEN_PORT
    Stop-LocalPortOwner -Port $runtime.SOCKS_PORT

    $adapter = Get-NetAdapter -Name $runtime.TUN_NAME -ErrorAction SilentlyContinue
    if ($adapter) {
        foreach ($prefix in @('0.0.0.0/1', '128.0.0.0/1')) {
            Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex } |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }

    if ($state -and $state.RemoteIp) {
        Get-NetRoute -DestinationPrefix "$($state.RemoteIp)/32" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq [int]$state.DefaultIfIndex -and $_.NextHop -eq $state.DefaultNextHop } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }

    Stop-ProcessByPathAndArgs -Name 'ss-local.exe' -Path $runtime.SS_BIN -ArgLike "*$SsConfig*"
    Stop-ProcessByPathAndArgs -Name 'ck-client.exe' -Path $runtime.CK_BIN -ArgLike "*$CkConfig*"

    Remove-Item -LiteralPath $StateFile -ErrorAction SilentlyContinue
}

function Remove-LegacyRuntimeDir {
    $legacy = Join-Path $AppDir 'sscloak-windows'
    if (Test-Path -LiteralPath $legacy) {
        Write-Step "Removing legacy runtime directory $legacy"
        Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-Vpn {
    Require-Admin
    Write-Step "Generating Windows runtime config"
    $runtime = Write-Configs
    Write-Step "Cleaning stale Windows VPN state"
    Stop-Vpn
    Write-Step "Starting local proxy chain"
    Start-LocalProxy -Runtime $runtime
    Write-Step "Configuring full-tunnel routes"
    Set-TunRoutes -Runtime $runtime
    Write-Step "Full-tunnel setup completed"
}

function Show-Status {
    $runtime = Read-Runtime
    Write-Host "Runtime: $RuntimeDir"
    Write-Host "Remote: $($runtime.REMOTE_HOST) / $($runtime.REMOTE_IP):$($runtime.REMOTE_PORT)"
    Write-Host ''
    Write-Host 'Processes:'
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -like "*$RuntimeDir*" -or
            $_.CommandLine -like "*$($runtime.TUN_NAME)*" -or
            $_.Name -eq 'Shadowsocks.exe'
        } |
        Select-Object ProcessId, Name, ExecutablePath, CommandLine |
        Format-Table -AutoSize

    Write-Host ''
    Write-Host 'Routes:'
    Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DestinationPrefix -in @('0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1', "$($runtime.REMOTE_IP)/32")
        } |
        Sort-Object DestinationPrefix, RouteMetric, InterfaceMetric |
        Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric, InterfaceMetric |
        Format-Table -AutoSize

    Write-Host ''
    Write-Host 'Public IP through current route:'
    curl.exe --ssl-no-revoke --connect-timeout 8 --max-time 15 https://ifconfig.me/ip
}

switch ($Command) {
    'install' {
        Write-Step "Install starting"
        $runtime = Write-Configs
        Write-Host "Windows runtime written to $RuntimeDir"
        Write-Host "ck-client: $($runtime.CK_BIN)"
        Write-Host "ss-local: $($runtime.SS_BIN)"
        Write-Host "tun2socks: $($runtime.TUN2SOCKS_BIN)"
        Write-Host "Run full VPN from elevated PowerShell: .\vpn.cmd run"
    }
    'on' {
        Write-Step "On starting"
        Start-Vpn
        Show-Status
    }
    'off' {
        Write-Step "Off starting"
        Require-Admin
        Stop-Vpn
        Remove-LegacyRuntimeDir
        Write-Host 'sscloak VPN stopped.'
    }
    'restart' {
        Write-Step "Restart starting"
        Require-Admin
        Stop-Vpn
        Start-Vpn
        Show-Status
    }
    'status' {
        Write-Step "Status starting"
        Show-Status
    }
    'debug' {
        Write-Step "Debug starting"
        $runtime = Write-Configs
        Write-Host "Admin: $(Test-Admin)"
        Write-Host "Runtime: $RuntimeDir"
        Write-Host "ck-client: $($runtime.CK_BIN)"
        Write-Host "ss-local: $($runtime.SS_BIN)"
        Write-Host "tun2socks: $($runtime.TUN2SOCKS_BIN)"
        Write-Host "Remote: $($runtime.REMOTE_HOST) / $($runtime.REMOTE_IP):$($runtime.REMOTE_PORT)"
        Write-Host "SOCKS: $($runtime.SOCKS_HOST):$($runtime.SOCKS_PORT)"
        Write-Host "TUN: $($runtime.TUN_NAME) $($runtime.TUN_ADDR)/$($runtime.TUN_PREFIX)"
    }
    'run' {
        Write-Step "Run command entered"
        Require-Admin
        try {
            Write-Step "Run mode starting"
            Start-Vpn
            Show-Status
            Write-Host ''
            Write-Host 'VPN is running. Press Ctrl-C to stop and restore routes.'
            while ($true) {
                Start-Sleep -Seconds 5
            }
        }
        finally {
            Stop-Vpn
            Write-Host 'sscloak VPN stopped.'
        }
    }
    default {
        Show-Usage
    }
}
