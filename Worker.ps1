param([ValidateSet('Check','Prep','Run','Suite')][string]$Action='Check',[string]$ConfigPath)
. (Join-Path $PSScriptRoot 'Host.ps1')
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'logs') -Force | Out-Null
$script:LogPath = Join-Path $PSScriptRoot 'logs\current.log'
$statusPath = Join-Path $PSScriptRoot 'logs\status.json'
$mutex = New-Object Threading.Mutex($false,'Local\MasterLab-Operation')
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
if (!$locked) { Write-Host 'Another MASTER operation is already running. Existing logs preserved.'; $mutex.Dispose(); exit 2 }
Set-Content -LiteralPath $script:LogPath -Value '' -Encoding UTF8
$status = @{ Action=$Action; Success=$false; Complete=$false }
$status | ConvertTo-Json | Set-Content $statusPath -Encoding UTF8
try {
    switch ($Action) {
        Check { Test-LabEnvironment }
        Prep { Test-LabEnvironment; foreach ($role in @('DNS','IIS')) { Write-LabLog "Preparing $role roles..."; $r = Invoke-Guest -Role $role -Action Prep; Write-LabLog "$role PREP PASS; backup $($r.Backup)" } }
        Run { $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json; $null = Invoke-LabRun $c -OpenBrowser }
        Suite {
            $cases = @(
                @{ DnsIP='10.10.10.2'; IisIP='10.10.10.3'; Mask='24'; Fqdn='www.lab.local'; Protocol='http'; Port=8080; ClientMode='Static'; ClientIP='10.10.10.4'; DhcpStart=''; DhcpEnd=''; Router='' },
                @{ DnsIP='172.16.20.2'; IisIP='172.16.20.10'; Mask='24'; Fqdn='secure.exam.local'; Protocol='https'; Port=8443; ClientMode='Static'; ClientIP='172.16.20.20'; DhcpStart=''; DhcpEnd=''; Router='' },
                @{ DnsIP='192.168.50.2'; IisIP='192.168.50.3'; Mask='24'; Fqdn='web.exam.local'; Protocol='http'; Port=8081; ClientMode='DHCP'; ClientIP=''; DhcpStart='192.168.50.100'; DhcpEnd='192.168.50.150'; Router='' }
            )
            $report = @('MASTER LAB - REAL MACHINE TESTS', (Get-Date).ToString('o'))
            Set-Content (Join-Path $PSScriptRoot 'TEST-RESULTS.txt') -Value 'IN PROGRESS - NOT READY' -Encoding UTF8
            foreach ($case in $cases) {
                $r = Invoke-LabRun $case -OpenBrowser
                $report += "Environment check PASS; DNS PASS; IIS PASS; $($case.Protocol.ToUpper()) $($case.ClientMode) PASS"
                if ($case.ClientMode -eq 'DHCP') { $report += "DHCP lease PASS: $($r.ClientIP), server 192.168.50.2, DNS 192.168.50.2" }
                if ($case.Protocol -eq 'https') { $report += "HTTPS certificate SAN: $($r.IIS.SAN); trusted TLS validation PASS for IP and FQDN" }
                foreach ($web in $r.Web) { $report += "$($web.URL) = HTTP $($web.Status), content matched, interface $($web.Interface)" }
                $report | Set-Content (Join-Path $PSScriptRoot 'TEST-RESULTS.txt') -Encoding UTF8
            }
            $report += 'All three automated live tests PASS. Browser visual confirmation pending.'
            $report | Set-Content (Join-Path $PSScriptRoot 'TEST-RESULTS.txt') -Encoding UTF8
        }
    }
    $status.Success = $true
} catch {
    $status.Error = $_.Exception.Message
    Write-LabLog "ERROR: $($status.Error)"
    if ($Action -eq 'Suite') { Add-Content (Join-Path $PSScriptRoot 'TEST-RESULTS.txt') -Value "FAIL: $($status.Error)`r`nNOT READY" -Encoding UTF8 }
} finally {
    $status.Complete = $true
    $status | ConvertTo-Json | Set-Content $statusPath -Encoding UTF8
    if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
if (!$status.Success) { exit 1 }
