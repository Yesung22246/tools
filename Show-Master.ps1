$ErrorActionPreference='Stop'
# Reopen only the hidden GUI instance created by this implementation's diagnostic launch.
$old = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*-File "D:\codex t3\Check-GUI.ps1"*' -and $_.ProcessId -ne $PID }
foreach ($p in $old) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue }
try { & (Join-Path $PSScriptRoot 'Master.ps1') -Elevated } catch { $_ | Format-List * -Force | Out-File (Join-Path $PSScriptRoot 'logs\gui-error-latest.txt'); exit 1 }
