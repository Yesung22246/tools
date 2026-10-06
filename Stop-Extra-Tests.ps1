$ErrorActionPreference='Stop'
$targets=@(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*-File "D:\codex t3\Finalize-Tests.ps1"*' -and $_.ProcessId -ne $PID })
foreach ($target in $targets) { Stop-Process -Id $target.ProcessId -ErrorAction Stop }
@{StoppedFinalizers=@($targets.ProcessId);Time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content 'D:\codex t3\logs\extra-tests-stopped.json' -Encoding UTF8
