$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Host.ps1')
$script:LogPath=Join-Path $PSScriptRoot 'logs\offline.log'
$statusPath=Join-Path $PSScriptRoot 'logs\offline-status.json'
$state=@{Success=$false;Complete=$false;Restored=$false}
$state | ConvertTo-Json | Set-Content $statusPath -Encoding UTF8
$restore=@()
try {
    if (!(Test-Admin)) { throw 'Administrator required.' }
    $c=Get-Content (Join-Path $script:StateDir 'last-config.json') -Raw | ConvertFrom-Json
    $restore=@(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })
    # The finally block restores exactly the adapters that were Up before this test.
    foreach ($a in $restore) { Write-LabLog "Temporarily disabling physical uplink: $($a.Name)"; Disable-NetAdapter -Name $a.Name -Confirm:$false }
    if (@(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }).Count) { throw 'A physical uplink is still active.' }
    $internetRoutes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Status -eq 'Up' })
    $internetRoutes6=@(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue | Where-Object { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Status -eq 'Up' })
    if ($internetRoutes.Count -or $internetRoutes6.Count) { throw 'An active default route remains; offline state not proven.' }
    $state.DisabledAdapters=@($restore.Name)
    $state.Web=@(Test-ClientLab $c)
    $state.Success=$true
    Write-LabLog 'OFFLINE PASS: physical uplinks off, no active default IPv4 route, DNS and both real web requests passed over VMnet1.'
} catch { $state.Error=$_.Exception.Message; Write-LabLog ('OFFLINE FAIL: ' + $state.Error) }
finally {
    $restoreErrors=@()
    foreach ($a in $restore) { try { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop } catch { $restoreErrors += $_.Exception.Message } }
    $state.Restored=($restoreErrors.Count -eq 0); $state.RestoreErrors=$restoreErrors; $state.Complete=$true
    $state | ConvertTo-Json -Depth 10 | Set-Content $statusPath -Encoding UTF8
}
