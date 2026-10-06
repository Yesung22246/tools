$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$statusPath=Join-Path $root 'logs\finalize-status.json'
$status=@{Complete=$false;Success=$false;Stage='Waiting for final suite'}
function Save-Status { $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding UTF8 }
Save-Status
try {
    $suiteProcesses=@(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*Worker.ps1" -Action Suite*' -and $_.ProcessId -ne $PID })
    foreach ($p in $suiteProcesses) { $process=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue; if ($process -and !$process.WaitForExit(1200000)) { throw 'Suite timed out; no further actions taken.' } }
    $suite=Get-Content (Join-Path $root 'logs\status.json') -Raw | ConvertFrom-Json
    if (!$suite.Success -or !$suite.Complete -or $suite.Action -ne 'Suite') { throw ('Final suite not PASS: ' + $suite.Error) }
    Copy-Item (Join-Path $root 'logs\current.log') (Join-Path $root 'logs\final-suite.log') -Force
    $status.Stage='PREP verification'; Save-Status
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Worker.ps1') -Action Prep
    if ($LASTEXITCODE -ne 0) { throw 'PREP verification failed.' }
    Copy-Item (Join-Path $root 'logs\current.log') (Join-Path $root 'logs\prep.log') -Force
    $status.Stage='Repeat DHCP configuration'; Save-Status
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Worker.ps1') -Action Run -ConfigPath (Join-Path $root 'dhcp-test.json')
    if ($LASTEXITCODE -ne 0) { throw 'Repeated DHCP configuration failed.' }
    Copy-Item (Join-Path $root 'logs\current.log') (Join-Path $root 'logs\dhcp-rerun.log') -Force
    $status.Stage='Offline test (physical uplinks temporarily disabled)'; Save-Status
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Offline-Test.ps1')
    $offline=Get-Content (Join-Path $root 'logs\offline-status.json') -Raw | ConvertFrom-Json
    if (!$offline.Success -or !$offline.Restored) { throw ('Offline test or uplink restoration failed: ' + $offline.Error + ' ' + ($offline.RestoreErrors -join '; ')) }
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Audit.ps1') | Set-Content (Join-Path $root 'logs\audit.txt') -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Code/input audit failed.' }
    Add-Content (Join-Path $root 'TEST-RESULTS.txt') -Encoding UTF8 -Value @('PREP BOTH VMs PASS','Repeated DHCP RUN ALL PASS','Offline DNS / IP+PORT / DOMAIN+PORT PASS with physical uplinks disabled; uplinks restored.','GUI Shown event PASS: 11 fields, 4 buttons, RUN ALL initially disabled.','Browser launched, but visual browser inspection was blocked by computer-use support for the installed Windows browser.','NOT READY: browser visual confirmation and end-to-end GUI button interaction remain unverified.')
    $status.Stage='Automated tests complete; browser visual inspection unavailable'; $status.Success=$true
} catch {
    $status.Error=$_.Exception.Message
    Add-Content (Join-Path $root 'TEST-RESULTS.txt') -Encoding UTF8 -Value ('FINAL VERIFICATION FAIL: ' + $status.Error + "`r`nNOT READY")
} finally { $status.Complete=$true; Save-Status }
