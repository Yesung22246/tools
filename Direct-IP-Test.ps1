param([ValidateSet('Direct','Domain')][string]$Stage='Direct')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Host.ps1')
$script:LogPath=Join-Path $PSScriptRoot ('logs\direct-' + $Stage.ToLowerInvariant() + '.log')
$statusFile=Join-Path $PSScriptRoot ('logs\direct-' + $Stage.ToLowerInvariant() + '-status.json')
$status=@{Stage=$Stage;Complete=$false;Success=$false}
$status | ConvertTo-Json | Set-Content $statusFile -Encoding UTF8
$c=Test-LabConfig @{DnsIP='10.10.10.2';IisIP='10.10.10.3';ClientIP='10.10.10.4';Mask='24';Fqdn='www.lab.local';Protocol='http';Port=8080;ClientMode='Static';Router=''}
try {
    if ($Stage -eq 'Direct') {
        $running=@(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*Worker.ps1" -Action Suite*' -and $_.ProcessId -ne $PID })
        foreach ($p in $running) { $proc=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue; if ($proc -and !$proc.WaitForExit(600000)) { throw 'Existing suite is still running; no reconfiguration performed.' } }
        Test-LabEnvironment
        $status.HostBackup=Backup-Host
        $status.DnsSetup=Invoke-Guest -Role DNS -Action Configure -Config $c
        $status.IisSetup=Invoke-Guest -Role IIS -Action Configure -Config $c
        $status.ClientIP=Set-HostClient $c
        Write-LabLog 'STEP 1: Test-NetConnection 10.10.10.3 -Port 8080'
        $tcp=Test-NetConnection 10.10.10.3 -Port 8080 -WarningAction SilentlyContinue
        $status.TCP=@{Success=$tcp.TcpTestSucceeded;RemoteAddress=[string]$tcp.RemoteAddress;Port=$tcp.RemotePort;Interface=$tcp.InterfaceAlias;SourceAddress=[string]$tcp.SourceAddress}
        if (!$tcp.TcpTestSucceeded -or [string]$tcp.RemoteAddress -ne '10.10.10.3' -or $tcp.InterfaceAlias -ne $script:HostAdapter) { throw 'DIRECT IP TCP FAIL' }
        Write-LabLog 'DIRECT IP TCP PASS: RemoteAddress=10.10.10.3; RemotePort=8080; VMnet1.'
        $target='10.10.10.3'; $label='DIRECT IP'
    } else {
        Write-LabLog 'STEP 4: Domain DNS and HTTP (after direct-IP browser verification).'
        Clear-DnsClientCache
        $answers=@(Resolve-DnsName www.lab.local -Server 10.10.10.2 -Type A -DnsOnly -NoHostsFile | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
        if ($answers -notcontains '10.10.10.3') { throw 'DOMAIN DNS FAIL' }
        $status.DNS=@{Success=$true;Server='10.10.10.2';Name='www.lab.local';Answers=$answers}
        Write-LabLog 'DOMAIN DNS PASS: www.lab.local -> 10.10.10.3 from DNS VM 10.10.10.2.'
        $target='www.lab.local'; $label='DOMAIN'
    }
    $url='http://' + $target + ':8080/'
    $bodyPath=Join-Path $PSScriptRoot ('results\' + $Stage.ToLowerInvariant() + '-body.html')
    $headersPath=Join-Path $PSScriptRoot ('results\' + $Stage.ToLowerInvariant() + '-headers.txt')
    $verbosePath=Join-Path $PSScriptRoot ('results\' + $Stage.ToLowerInvariant() + '-curl-verbose.txt')
    Write-LabLog ('REQUEST: curl.exe --noproxy "*" -v ' + $url)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=(Get-Command curl.exe).Source
    $nativeArguments=@('--noproxy','*','-v','--max-time','25','-D',$headersPath,'-o',$bodyPath,'-w','%{http_code}|%{remote_ip}|%{url_effective}',$url)
    $psi.Arguments=(($nativeArguments | ForEach-Object { Quote-Native $_ }) -join ' ')
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($psi); $out=$process.StandardOutput.ReadToEndAsync(); $err=$process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(40000)) { $process.Kill(); throw 'curl timeout.' }
    $stderr=$err.Result; $stdout=$out.Result
    $stderr | Set-Content $verbosePath -Encoding UTF8
    $metrics=$stdout.Trim().Split('|')
    if ($process.ExitCode -ne 0 -or $metrics.Count -ne 3 -or $metrics[0] -ne '200' -or $metrics[1] -ne '10.10.10.3' -or $metrics[2] -ne $url) { throw ('Unexpected real curl request result: ' + $stdout + ' ' + $stderr) }
    $body=Get-Content $bodyPath -Raw
    if (!$body.Contains([Net.WebUtility]::HtmlEncode($c.WebText)) -or !$body.Contains('MasterLab www.lab.local 10.10.10.3:8080')) { throw 'Response is not the expected web1 content.' }
    $status.HTTP=@{RequestedURL=$url;EffectiveURL=$metrics[2];RemoteIP=$metrics[1];StatusCode=[int]$metrics[0];Web1ContentMatched=$true;VerboseEvidence=$verbosePath;Headers=$headersPath}
    Write-LabLog "$label HTTP PASS: URL=$url; remote_ip=10.10.10.3; HTTP=200; web1 content matched."
    if ($Stage -eq 'Domain') {
        $iis=Invoke-Guest -Role IIS -Action Inspect
        $bindings=@($iis.WebBindings | Where-Object { $_.protocol -eq 'http' -and $_.bindingInformation -eq '10.10.10.3:8080:' })
        if ($bindings.Count -ne 1) { throw 'IIS lacks exactly one direct IP binding with an empty host header.' }
        $status.Binding=@{Protocol='http';IP='10.10.10.3';Port=8080;HostName='';Raw='10.10.10.3:8080:';Success=$true}
        Write-LabLog 'IIS BINDING PASS: http / 10.10.10.3 / 8080 / empty Host name.'
    }
    $status.Success=$true
} catch { $status.Error=$_.Exception.Message; Write-LabLog ('FAIL: ' + $status.Error) }
finally { $status.Complete=$true; $status | ConvertTo-Json -Depth 15 | Set-Content $statusFile -Encoding UTF8 }
