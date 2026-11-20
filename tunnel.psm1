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

function Get-WindowsPidFile {
    param ([string]$SSH_CONFIG)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($SSH_CONFIG)
        $hash = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }

    return (Join-Path $PSScriptRoot "tunnel-$hash.pid")
}

function Get-WindowsSshProcess {
    param ([string]$SSH_CONFIG)

    $pidFile = Get-WindowsPidFile $SSH_CONFIG
    if (-not (Test-Path $pidFile)) {
        return $null
    }

    $pidData = (Get-Content -Path $pidFile -Raw).Trim() -split '\|'
    $processId = 0
    $startTimeTicks = 0L
    if ($pidData.Count -ne 2 -or
        -not [int]::TryParse($pidData[0], [ref]$processId) -or
        -not [long]::TryParse($pidData[1], [ref]$startTimeTicks)) {
        Remove-Item -Force $pidFile
        return $null
    }

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.ProcessName -ne "ssh") {
        Remove-Item -Force $pidFile
        return $null
    }

    if ($process.StartTime.ToUniversalTime().Ticks -ne $startTimeTicks) {
        Remove-Item -Force $pidFile
        return $null
    }

    return $process
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
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return ($null -ne (Get-WindowsSshProcess $SSH_CONFIG))
    }

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

    if (Test-TunnelRunning $SSH_CONFIG) {
        $Env:ALL_PROXY = "socks5h://127.0.0.1:$LOCAL_PORT"
        Write-Host "Proxy resumed: $Env:ALL_PROXY" -ForegroundColor Green
        return
    }

    Write-Host "[$Index] Starting tunnel: $SSH_CONFIG..." -ForegroundColor Green

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $ssh = Get-Command ssh -CommandType Application -ErrorAction Stop
        $pidFile = Get-WindowsPidFile $SSH_CONFIG
        $stdoutFile = "$pidFile.out"
        $stderrFile = "$pidFile.err"
        Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

        $process = Start-Process -FilePath $ssh.Source `
            -ArgumentList @("-N", "-D", $LOCAL_PORT, "-o", "ExitOnForwardFailure=yes", "`"$SSH_CONFIG`"") `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile
        $startTimeTicks = $process.StartTime.ToUniversalTime().Ticks
        Set-Content -Path $pidFile -Value "$($process.Id)|$startTimeTicks" -NoNewline

        Start-Sleep -Milliseconds 500
        if (Test-TunnelRunning $SSH_CONFIG) {
            Write-Host "[$Index] $SSH_CONFIG - Started successfully" -ForegroundColor Green
            $Env:ALL_PROXY = "socks5h://127.0.0.1:$LOCAL_PORT"
        } else {
            Write-Host "[$Index] $SSH_CONFIG - Failed to start" -ForegroundColor Red
            if (Test-Path $stderrFile) {
                Get-Content -Path $stderrFile -Tail 10
            }
            Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        }
        return
    }

    $CONTROL_SOCKET = Get-ControlSocket $SSH_CONFIG
    ssh -M -S "$CONTROL_SOCKET" -c aes128-ctr -C -D $LOCAL_PORT -fN $SSH_CONFIG

    if (Test-TunnelRunning $SSH_CONFIG) {
        Write-Host "[$Index] $SSH_CONFIG - Started successfully" -ForegroundColor Green
        $Env:ALL_PROXY = "socks5h://127.0.0.1:$LOCAL_PORT"
    } else {
        Write-Host "[$Index] $SSH_CONFIG - Failed to start" -ForegroundColor Red
    }
}

function Stop-Tunnel {
    param ([int]$Index)

    $tunnels = @(Get-TunnelList)
    $SSH_CONFIG = $tunnels[$Index]

    if (-not (Test-TunnelRunning $SSH_CONFIG)) {
        Write-Host "[$Index] $SSH_CONFIG - Not running" -ForegroundColor Yellow
        return
    }

    Write-Host "[$Index] Stopping tunnel: $SSH_CONFIG..." -ForegroundColor Green

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $process = Get-WindowsSshProcess $SSH_CONFIG
        if ($null -ne $process) {
            Stop-Process -Id $process.Id -Force
            if (-not $process.WaitForExit(5000)) {
                throw "SSH process $($process.Id) did not exit after being stopped"
            }
        }
        $pidFile = Get-WindowsPidFile $SSH_CONFIG
        foreach ($file in @($pidFile, "$pidFile.out", "$pidFile.err")) {
            if (Test-Path $file) {
                Remove-Item -Force $file
            }
        }
        Write-Host "[$Index] $SSH_CONFIG - Stopped" -ForegroundColor Green
        $Env:ALL_PROXY = $null
        return
    }

    $CONTROL_SOCKET = Get-ControlSocket $SSH_CONFIG
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
