$ErrorActionPreference='Stop'
try { & (Join-Path $PSScriptRoot 'Master.ps1') -Elevated } catch { $_ | Format-List * -Force | Out-File (Join-Path $PSScriptRoot 'logs\gui-error.txt'); exit 1 }
