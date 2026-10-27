# tunnel.psm1

$LOCAL_PORT = "1080"

function Get-ControlSocket {
    param ([string]$SSH_CONFIG)

    $parts = $SSH_CONFIG -split '@'
    if ($parts.Length -ne 2) {
        throw "Invalid SSH config format: $SSH_CONFIG"
    }
    $user = $parts[0]
    $server = $parts[1]

    return (Join-Path $PSScriptRoot "control-tunnel-$user@$server")
}

function Add-Tunnel {
    param([string]$SSH_CONFIG)

    $file = Join-Path $PSScriptRoot "server.txt"
    if (-not ($SSH_CONFIG -match "@" )) {
        Write-Host "Invalid format, use user@host" -ForegroundColor Red
        return
    }
    Add-Content -Path $file -Value $SSH_CONFIG
    Write-Host "Added tunnel: $SSH_CONFIG" -ForegroundColor Green
}

function Get-TunnelList {
    $file = Join-Path $PSScriptRoot "server.txt"
    if (-not (Test-Path $file)) {
        New-Item -ItemType File -Path $file | Out-Null
    }
    Get-Content $file | Where-Object { $_ -match "@" }
}

function Test-TunnelRunning {
    param ([string]$SSH_CONFIG)
    $CONTROL_SOCKET = Get-ControlSocket $SSH_CONFIG
    return (Test-Path $CONTROL_SOCKET)
}

function Get-ActiveTunnelIndex {
    $tunnels = @(Get-TunnelList)
    for ($i = 0; $i -lt $tunnels.Count; $i++) {
        if (Test-TunnelRunning $tunnels[$i]) {
            return $i
        }
    }
    return -1
}

function Start-Tunnel {
    param ([int]$Index)

    $tunnels = @(Get-TunnelList)
    $SSH_CONFIG = $tunnels[$Index]
    $CONTROL_SOCKET = Get-ControlSocket $SSH_CONFIG

    if (Test-TunnelRunning $SSH_CONFIG) {
        $Env:ALL_PROXY = "socks5://127.0.0.1:$LOCAL_PORT"
        Write-Host "Proxy resumed: $Env:ALL_PROXY" -ForegroundColor Green
        return
    }

    Write-Host "[$Index] Starting tunnel: $SSH_CONFIG..." -ForegroundColor Green

    ssh -M -S "$CONTROL_SOCKET" -c aes128-ctr -C -D $LOCAL_PORT -fN $SSH_CONFIG

    if (Test-TunnelRunning $SSH_CONFIG) {
        Write-Host "[$Index] $SSH_CONFIG - Started successfully" -ForegroundColor Green
        $Env:ALL_PROXY = "socks5://127.0.0.1:$LOCAL_PORT"
    } else {
        Write-Host "[$Index] $SSH_CONFIG - Failed to start" -ForegroundColor Red
    }
}

function Stop-Tunnel {
    param ([int]$Index)

    $tunnels = @(Get-TunnelList)
    $SSH_CONFIG = $tunnels[$Index]
    $CONTROL_SOCKET = Get-ControlSocket $SSH_CONFIG

    if (-not (Test-TunnelRunning $SSH_CONFIG)) {
        Write-Host "[$Index] $SSH_CONFIG - Not running" -ForegroundColor Yellow
        return
    }

    Write-Host "[$Index] Stopping tunnel: $SSH_CONFIG..." -ForegroundColor Green

    if (Test-Path $CONTROL_SOCKET) {
        & ssh -S "$CONTROL_SOCKET" -O exit 2>$null
    }

    pkill -f "ssh.*-D $LOCAL_PORT" 2>$null

    if (Test-Path $CONTROL_SOCKET) {
        Remove-Item -Force $CONTROL_SOCKET 2>$null
    }

    Write-Host "[$Index] $SSH_CONFIG - Stopped" -ForegroundColor Green
    $Env:ALL_PROXY = $null
}

function Show-TunnelList {
    $tunnels = @(Get-TunnelList)
    Write-Host "Available tunnels:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $tunnels.Count; $i++) {
        $SSH_CONFIG = $tunnels[$i]
        $running = Test-TunnelRunning $SSH_CONFIG
        $status = if ($running) { "[Running]" } else { "" }
        Write-Host "  [$i] $SSH_CONFIG $status" -ForegroundColor $(if ($running) { "Green" } else { "White" })
    }
    Write-Host ""
}

function Show-Status {
    $tunnels = @(Get-TunnelList)
    $activeIndex = Get-ActiveTunnelIndex
    if ($activeIndex -ne -1) {
        Write-Host "Active: [$activeIndex] $($tunnels[$activeIndex])" -ForegroundColor Green
        Write-Host "Port: $LOCAL_PORT" -ForegroundColor Green
        Write-Host "Proxy: $Env:ALL_PROXY" -ForegroundColor $(if ($null -eq $Env:ALL_PROXY) { "Red" } else { "Green" })
    } else {
        Write-Host "No tunnel is running" -ForegroundColor Gray
    }
}

function tunnel {
    param(
        [string]$Action = "",
        [string]$Arg = ""
    )

    if ($Action -eq "") {
        Write-Host "SSH SOCKS5 Tunnel Management Tool" -ForegroundColor White
        Write-Host ""
        Show-Status
        Write-Host ""
        Write-Host "Usage:" -ForegroundColor White
        Write-Host "  add             Add a new tunnel" -ForegroundColor Magenta
        Write-Host "  start           Start or resume a tunnel" -ForegroundColor Green
        Write-Host "  stop            Stop current tunnel" -ForegroundColor Yellow
        Write-Host "  status          Check tunnel status" -ForegroundColor DarkCyan
        Write-Host ""
        return
    }

    switch ($Action.ToLower()) {
        "add" {
            if ($Arg) {
                Add-Tunnel $Arg
            } else {
                Write-Host "Usage: tunnel add user@host" -ForegroundColor Yellow
            }
        }

        "start" {
            $tunnels = @(Get-TunnelList)
            Show-TunnelList
            $input = Read-Host "Select tunnel number (0-$($tunnels.Count - 1))"

            if ($input -match '^\d+$') {
                $index = [int]$input
                if ($index -ge 0 -and $index -lt $tunnels.Count) {
                    $activeIndex = Get-ActiveTunnelIndex
                    if ($activeIndex -ne -1 -and $activeIndex -ne $index) {
                        Stop-Tunnel $activeIndex
                    }
                    Start-Tunnel $index
                } else {
                    Write-Host "Invalid index: $input" -ForegroundColor Red
                }
            } else {
                Write-Host "Invalid input: $input" -ForegroundColor Red
            }
        }

        "stop" {
            $activeIndex = Get-ActiveTunnelIndex
            if ($activeIndex -ne -1) {
                Stop-Tunnel $activeIndex
            } else {
                Write-Host "No tunnel is currently running" -ForegroundColor Yellow
            }
        }

        default {
            Write-Host "Unknown command: $Action" -ForegroundColor Red
            Write-Host "Use: add | start | stop" -ForegroundColor Yellow
        }
    }
}

Export-ModuleMember -Function tunnel
