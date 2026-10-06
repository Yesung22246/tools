. (Join-Path $PSScriptRoot 'Common.ps1')
function Backup-Host {
    $dir = Join-Path $script:Root ('backups\host-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $adapter = Get-NetAdapter -Name $script:HostAdapter
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Export-Clixml "$dir\addresses.xml"
    Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Export-Clixml "$dir\interface.xml"
    Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Export-Clixml "$dir\dns.xml"
    Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Export-Clixml "$dir\routes.xml"
    Copy-Item -LiteralPath 'C:\ProgramData\VMware\vmnetdhcp.conf' -Destination "$dir\vmnetdhcp.conf"
    return $dir
}
function Restore-HostNetwork([string]$BackupPath) {
    $adapter = Get-NetAdapter -Name $script:HostAdapter
    $originalInterface = Import-Clixml "$BackupPath\interface.xml"
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    if ([string]$originalInterface.Dhcp -eq 'Enabled' -or [int]$originalInterface.Dhcp -eq 1) {
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled
    } else {
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
        foreach ($a in Import-Clixml "$BackupPath\addresses.xml") { if ($a.IPAddress -notlike '169.254.*') { New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $a.IPAddress -PrefixLength $a.PrefixLength | Out-Null } }
    }
    $dns = (Import-Clixml "$BackupPath\dns.xml").ServerAddresses
    if (@($dns).Count) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns } else { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses }
    foreach ($route in Import-Clixml "$BackupPath\routes.xml") { if ($route.DestinationPrefix -eq '0.0.0.0/0') { New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix $route.DestinationPrefix -NextHop $route.NextHop -RouteMetric $route.RouteMetric | Out-Null } }
}
function Set-HostClient($c) {
    $adapter = Get-NetAdapter -Name $script:HostAdapter
    # Change only the isolated VMware host adapter, leaving Wi-Fi and other NICs intact.
    Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    if ($c.ClientMode -eq 'Static') {
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne $c.ClientIP -or $_.PrefixLength -ne $c.Prefix } | Remove-NetIPAddress -Confirm:$false
        if (!(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $c.ClientIP -and $_.PrefixLength -eq $c.Prefix })) { New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $c.ClientIP -PrefixLength $c.Prefix | Out-Null }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $c.DnsIP
    } else {
        Assert-VMwareDHCP
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled
        & ipconfig.exe /renew $script:HostAdapter | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'DHCP renew failed.' }
    }
    for ($i=0;$i -lt 30;$i++) {
        $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
        if ($addresses.Count -eq 1) { break }; Start-Sleep 1
    }
    if ($addresses.Count -ne 1) { throw 'Client does not have exactly one usable IPv4 address.' }
    if ($c.ClientMode -eq 'DHCP') {
        $client = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex }
        $n = Convert-IPv4 $addresses[0].IPAddress
        if (!$client.DHCPEnabled -or $client.DHCPServer -ne $c.DnsIP -or $n -lt (Convert-IPv4 $c.DhcpStart) -or $n -gt (Convert-IPv4 $c.DhcpEnd)) { throw "Wrong DHCP lease/server: $($addresses[0].IPAddress), server $($client.DHCPServer)" }
        Write-LabLog "DHCP PASS: client $($addresses[0].IPAddress), Windows DHCP server $($client.DHCPServer)"
    } elseif ($addresses[0].IPAddress -ne $c.ClientIP) { throw 'Static client IP mismatch.' }
    $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
    if ($dnsServers.Count -ne 1 -or $dnsServers[0] -ne $c.DnsIP) { throw "Client DNS does not equal $($c.DnsIP)." }
    Write-LabLog "Client IP / DNS option PASS: $($addresses[0].IPAddress), DNS $($dnsServers -join ',')"
    return $addresses[0].IPAddress
}
function Test-ClientLab($c) {
    Clear-DnsClientCache
    $direct = @(Resolve-DnsName -Name $c.Fqdn -Server $c.DnsIP -Type A -DnsOnly -NoHostsFile | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
    $normal = @(Resolve-DnsName -Name $c.Fqdn -Type A -DnsOnly -NoHostsFile | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
    if ($direct -notcontains $c.IisIP -or $normal -notcontains $c.IisIP) { throw 'Client DNS query failed.' }
    Write-LabLog "DNS PASS: $($c.Fqdn) -> $($c.IisIP), explicit DNS VM and normal resolver, hosts file excluded."
    $labAdapter=Get-NetAdapter -Name $script:HostAdapter
    $clientAddresses=@(Get-NetIPAddress -InterfaceIndex $labAdapter.ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
    if ($clientAddresses.Count -ne 1) { throw 'VMnet1 must have exactly one preferred client IPv4 address.' }
    $evidence = @()
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($target in @($c.IisIP,$c.Fqdn)) {
        if ($target -match '^\d{1,3}(?:\.\d{1,3}){3}$') { $destination=[Net.IPAddress]::Parse($target) }
        else {
            $resolvedTarget=@(Resolve-DnsName -Name $target -Server $c.DnsIP -Type A -DnsOnly -NoHostsFile | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
            if ($resolvedTarget -notcontains $c.IisIP) { throw "TCP target resolved to an unexpected IP: $target" }
            $destination=[Net.IPAddress]::Parse($c.IisIP)
        }
        $tcpClient=New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetwork)
        try {
            $connect=$tcpClient.BeginConnect($destination,[int]$c.Port,$null,$null)
            if (!$connect.AsyncWaitHandle.WaitOne(3000)) { throw "TCP timeout after 3 seconds: ${target}:$($c.Port)" }
            $tcpClient.EndConnect($connect)
            $remoteAddress=$tcpClient.Client.RemoteEndPoint.Address.ToString()
            $sourceAddress=$tcpClient.Client.LocalEndPoint.Address.ToString()
        } finally { if ($connect) { $connect.AsyncWaitHandle.Close() }; $tcpClient.Close() }
        if ($remoteAddress -ne $c.IisIP) { throw "TCP connected to the wrong destination: $target -> $remoteAddress" }
        if ($sourceAddress -ne $clientAddresses[0].IPAddress) { throw "TCP used the wrong client adapter/address: $sourceAddress" }
        Write-LabLog "TCP PASS: ${target}:$($c.Port) connected to $remoteAddress from $sourceAddress on VMnet1 (3-second timeout, no ping wait)."
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(25)
        $url = '{0}://{1}:{2}/' -f $c.Protocol,$target,$c.Port
        try {
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $marker = 'MasterLab ' + $c.Fqdn + ' ' + $c.IisIP + ':' + $c.Port
            $expectedText = [string]$c.WebText
            if ([string]::IsNullOrWhiteSpace($expectedText)) { $expectedText = 'Hello web 1' }
            if ([int]$response.StatusCode -ne 200 -or !$body.Contains($marker) -or !$body.Contains([Net.WebUtility]::HtmlEncode($expectedText))) { throw "Wrong HTTP status or page content for $url" }
            Write-LabLog "$url = HTTP 200 PASS (normal TLS validation, no proxy)."
            $evidence += @{ URL=$url; Status=200; ContentMatched=$true; Interface=$script:HostAdapter; RemoteAddress=$remoteAddress; SourceAddress=$sourceAddress }
        } finally { $client.Dispose(); $handler.Dispose() }
    }
    return $evidence
}
function Invoke-LabRun($Config,[switch]$OpenBrowser) {
    $c = Test-LabConfig $Config
    $labStart=Convert-IPv4 $c.Network; $labEnd=$labStart + [math]::Pow(2,32-$c.Prefix)-1
    foreach ($a in Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -ne $script:HostAdapter -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }) {
        $mask=(4294967295L -shl (32-$a.PrefixLength)) -band 4294967295L
        $start=(Convert-IPv4 $a.IPAddress) -band $mask; $end=$start+[math]::Pow(2,32-$a.PrefixLength)-1
        if ($labStart -le $end -and $labEnd -ge $start) { throw "LAB subnet overlaps host adapter $($a.InterfaceAlias) ($($a.IPAddress)/$($a.PrefixLength)). No configuration changed." }
    }
    Test-LabEnvironment
    $backup = Backup-Host
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'results') -Force | Out-Null
    $resultFile = Join-Path $script:Root "results\run-$stamp.json"
    $evidence = @{ Success=$false; Time=(Get-Date).ToString('o'); Config=$c; HostBackup=$backup }
    try {
        Write-LabLog 'Configuring DNS + DHCP VM...'
        $dnsResult = Invoke-Guest -Role DNS -Action Configure -Config $c
        $evidence.DNS = $dnsResult
        Write-LabLog 'Configuring IIS VM...'
        $iisResult = Invoke-Guest -Role IIS -Action Configure -Config $c
        $evidence.IIS = $iisResult
        if ($c.Protocol -eq 'https') {
            $certPath = Join-Path $script:Root "results\lab-$stamp.cer"
            Invoke-Vmrun -Operation copyFileFromGuestToHost -Role IIS -Parameters @('C:\ProgramData\MasterLab\lab.cer',$certPath) | Out-Null
            $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
            if ($cert.Thumbprint -ne $iisResult.Thumbprint) { throw 'Certificate thumbprint mismatch.' }
            Import-Certificate -FilePath $certPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
            Write-LabLog "Lab certificate trusted: $($cert.Thumbprint); SAN $($iisResult.SAN)"
        }
        $evidence.ClientIP = Set-HostClient $c
        $evidence.Web = @(Test-ClientLab $c)
        # Remove only certificates whose creation/import is recorded in this tool's own evidence.
        $keepThumbprint=$iisResult.Thumbprint
        foreach ($priorFile in Get-ChildItem (Join-Path $script:Root 'results') -Filter 'run-*.json') {
            $prior=Get-Content -LiteralPath $priorFile.FullName -Raw | ConvertFrom-Json
            $thumb=$prior.IIS.Thumbprint
            if ($thumb -and $thumb -ne $keepThumbprint) {
                $trustedPath='Cert:\LocalMachine\Root\' + $thumb
                if (Test-Path $trustedPath) { Export-Certificate -Cert (Get-Item $trustedPath) -FilePath (Join-Path $backup ($thumb + '.cer')) -Force | Out-Null; Remove-Item -LiteralPath $trustedPath -Force }
            }
        }
        $c | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:StateDir 'last-config.json') -Encoding UTF8
        $evidence.Success = $true
        Write-LabLog "RUN ALL PASS: $($c.Protocol), $($c.ClientMode), $($c.Fqdn):$($c.Port)"
        if ($OpenBrowser) { Start-Process ('{0}://{1}:{2}/' -f $c.Protocol,$c.Fqdn,$c.Port) | Out-Null }
    } catch {
        $evidence.Error = $_.Exception.Message
        Write-LabLog "FAIL: $($evidence.Error). Restoring previous host VMnet1 configuration. Guest backups retained."
        try { Restore-HostNetwork $backup; $evidence.HostRollback = 'PASS' } catch { $evidence.HostRollback = $_.Exception.Message }
        throw
    } finally { $evidence | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $resultFile -Encoding UTF8 }
    return $evidence
}
