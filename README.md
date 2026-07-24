# TunnelManager

PowerShell SSH tunnel manager.

## Quick Start

```bash
git clone https://github.com/lixinyang123/TunnelManager.git

mv TunnelManager tunnel
cd tunnel

$modulePath = (Get-Location).Path
Write-Output "Import-Module `\"$modulePath`\"" | Out-File -FilePath $PROFILE -Append
```
