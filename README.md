# TunnelManager

Cross-platform PowerShell SSH tunnel manager for Windows and Linux.

## Quick Start

```bash
git clone https://github.com/lixinyang123/TunnelManager.git

mv TunnelManager tunnel
cd tunnel

$modulePath = (Get-Location).Path
Write-Output "Import-Module `\"$modulePath`\"" | Out-File -FilePath $PROFILE -Append
```

On Windows, tunnels are started as background SSH processes and tracked by PID, avoiding OpenSSH control sockets. On Linux, SSH ControlMaster is used.
