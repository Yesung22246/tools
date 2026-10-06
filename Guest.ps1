param([Parameter(Mandatory=$true)][string]$RequestBase64,[Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RequestBase64)) | ConvertFrom-Json
$c = $request.Config; $backup = $null
function Save-Backup {
    $path = 'C:\ProgramData\MasterLab\Backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    @(Get-NetIPAddress -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) | Export-Clixml "$path\addresses.xml"
    Get-NetIPInterface -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 | Export-Clixml "$path\interface.xml"
    Get-DnsClientServerAddress -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 | Export-Clixml "$path\dns.xml"
    Get-NetRoute -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 | Export-Clixml "$path\routes.xml"
    & netsh.exe advfirewall export "$path\firewall.wfw" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Firewall backup failed.' }
    if (Test-Path 'C:\LABWEB') { Copy-Item 'C:\LABWEB' "$path\LABWEB" -Recurse }
    if (Test-Path 'C:\Windows\System32\inetsrv\config\applicationHost.config') { Copy-Item 'C:\Windows\System32\inetsrv\config\applicationHost.config' "$path\applicationHost.config" }
    if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
        Get-DnsServerZone | Export-Clixml "$path\zones.xml"
        if ($c -and (Get-DnsServerZone -Name $c.Zone -ErrorAction SilentlyContinue)) { Get-DnsServerResourceRecord -ZoneName $c.Zone | Export-Clixml "$path\zone-records.xml"; & dnscmd.exe localhost /ZoneExport $c.Zone ("MasterLab-" + (Split-Path $path -Leaf) + '.dns') | Out-Null }
    }
    if ((Get-Service DHCPServer -ErrorAction SilentlyContinue).Status -eq 'Running') { Export-DhcpServer -File "$path\dhcp.xml" -Leases -Force }
    if (Test-Path 'C:\ProgramData\MasterLab\state.json') { Copy-Item 'C:\ProgramData\MasterLab\state.json' "$path\state.json" }
    return $path
}
function Set-LabAddress([string]$IP) {
    Set-NetIPInterface -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
    Get-NetRoute -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    Get-NetIPAddress -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne $IP -or $_.PrefixLength -ne $c.Prefix } | Remove-NetIPAddress -Confirm:$false
    if (!(Get-NetIPAddress -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $IP -and $_.PrefixLength -eq $c.Prefix })) { New-NetIPAddress -InterfaceIndex $script:nic.ifIndex -IPAddress $IP -PrefixLength $c.Prefix | Out-Null }
    Set-DnsClientServerAddress -InterfaceIndex $script:nic.ifIndex -ServerAddresses $c.DnsIP
    for ($i=0;$i -lt 15;$i++) { $a = Get-NetIPAddress -InterfaceIndex $script:nic.ifIndex -IPAddress $IP; if ($a.AddressState -eq 'Duplicate') { throw "Duplicate network IP: $IP" }; if ($a.AddressState -eq 'Preferred') { return }; Start-Sleep 1 }
    throw "IP did not become Preferred: $IP"
}
function Ensure-Roles {
    $names = @('Web-Server','Web-Mgmt-Tools'); if ($request.Role -eq 'DNS') { $names = @('DNS','DHCP') }
    $missing = @(Get-WindowsFeature -Name $names | Where-Object { !$_.Installed } | Select-Object -ExpandProperty Name)
    if ($missing.Count) { $installed = Install-WindowsFeature -Name $missing -IncludeManagementTools; if (!$installed.Success) { throw 'Windows role installation failed; local component source may be needed.' }; if ($installed.RestartNeeded -eq 'Yes') { throw 'Role installation requires a guest restart. Restart is not performed automatically.' } }
}
function Ensure-Firewall([string]$Name,[string]$Protocol,[int]$Port) {
    Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $Name -DisplayName $Name -Direction Inbound -Action Allow -Protocol $Protocol -LocalPort $Port -Profile Any -InterfaceAlias $script:nic.Name | Out-Null
}
function Remove-StaleCertificates([string]$KeepThumbprint) {
    $history = @(Get-ChildItem 'C:\ProgramData\MasterLab\Backups' -Filter 'state.json' -Recurse -ErrorAction SilentlyContinue)
    $liveBindings = @(Get-WebBinding -Protocol https)
    foreach ($file in $history) {
        $s = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if (!$s.Thumbprint -or $s.Thumbprint -eq $KeepThumbprint) { continue }
        $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $s.Thumbprint) -ErrorAction SilentlyContinue
        if (!$cert -or $cert.FriendlyName -notlike 'MasterLab *') { continue }
        $endpoint = '{0}:{1}:' -f $s.Config.IisIP,$s.Config.Port
        if (@($liveBindings | Where-Object { $_.bindingInformation -eq $endpoint }).Count) { continue }
        $sslPath = 'IIS:\SslBindings\' + $s.Config.IisIP + '!' + $s.Config.Port
        if (Test-Path $sslPath) {
            $ssl = Get-Item $sslPath
            if ($ssl.Thumbprint -eq $s.Thumbprint) { Remove-Item $sslPath -Force }
        }
        if (@(Get-ChildItem IIS:\SslBindings | Where-Object { $_.Thumbprint -eq $s.Thumbprint }).Count) { continue }
        Export-Certificate -Cert $cert -FilePath (Join-Path $backup ($s.Thumbprint + '.cer')) -Force | Out-Null
        foreach ($store in @('My','Root')) { $certPath = "Cert:\LocalMachine\$store\" + $s.Thumbprint; if (Test-Path $certPath) { Remove-Item -LiteralPath $certPath -Force } }
    }
}
try {
    $p = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Guest credential must run with administrator privileges.' }
    $script:nic = @(Get-NetAdapter | Where-Object { ($_.MacAddress -replace '[:-]','') -eq ($request.Mac -replace '[:-]','') })
    if ($script:nic.Count -ne 1 -or $script:nic[0].Status -ne 'Up') { throw 'Cannot identify the connected VMnet1 guest adapter.' }; $script:nic = $script:nic[0]
    $result = @{ Success=$true; ComputerName=$env:COMPUTERNAME; Role=$request.Role; Action=$request.Action; Adapter=$script:nic.Name }
    if ($request.Action -eq 'Inspect') {
        $result.Addresses = @(Get-NetIPAddress -InterfaceIndex $script:nic.ifIndex -AddressFamily IPv4 | Select-Object IPAddress,PrefixLength)
        $result.DomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
        if (Test-Path 'C:\ProgramData\MasterLab\state.json') {
            $result.LabState = Get-Content 'C:\ProgramData\MasterLab\state.json' -Raw | ConvertFrom-Json
            if ($request.Role -eq 'DNS' -and (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) { $result.Scopes=@(Get-DhcpServerv4Scope | Select-Object ScopeId,Name,State,StartRange,EndRange) }
            if ($request.Role -eq 'IIS' -and (Get-WindowsFeature Web-Server).Installed) {
                Import-Module WebAdministration
                $result.WebBindings=@(Get-WebBinding -Name web1 | Select-Object protocol,bindingInformation,sslFlags)
                $result.SslBindings=@(Get-ChildItem IIS:\SslBindings | Select-Object IPAddress,Port,Thumbprint)
                $result.LabCertificates=@(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -like 'MasterLab *' } | Select-Object Subject,Thumbprint,NotAfter)
            }
        }
    } elseif ($request.Action -in @('Prep','Configure')) {
        $backup = Save-Backup; $result.Backup = $backup
        Ensure-Roles
        if ($request.Action -eq 'Configure') {
            $stateFile = 'C:\ProgramData\MasterLab\state.json'; $old = $null
            if (Test-Path $stateFile) { $old = Get-Content $stateFile -Raw | ConvertFrom-Json }
            if ($request.Role -eq 'DNS') {
                Set-LabAddress $c.DnsIP
                Set-Service DNS -StartupType Automatic; Start-Service DNS
                if (!(Get-DnsServerZone -Name $c.Zone -ErrorAction SilentlyContinue)) { Add-DnsServerPrimaryZone -Name $c.Zone -ZoneFile ($c.Zone + '.dns') -DynamicUpdate None }
                $records = @(Get-DnsServerResourceRecord -ZoneName $c.Zone -Name $c.Record -ErrorAction SilentlyContinue)
                if (@($records | Where-Object { $_.RecordType -eq 'CNAME' }).Count) { throw 'The requested A record conflicts with an existing CNAME; preserved for manual review.' }
                $records | Where-Object { $_.RecordType -eq 'A' } | ForEach-Object { Remove-DnsServerResourceRecord -ZoneName $c.Zone -InputObject $_ -Force }
                Add-DnsServerResourceRecordA -ZoneName $c.Zone -Name $c.Record -IPv4Address $c.IisIP -TimeToLive (New-TimeSpan -Minutes 1)
                Ensure-Firewall 'MasterLab-DNS-UDP' UDP 53; Ensure-Firewall 'MasterLab-DNS-TCP' TCP 53
                Restart-Service DNS
                $dnsReady=$false
                for ($attempt=0;$attempt -lt 12;$attempt++) {
                    try { $answer=@(Resolve-DnsName -Name $c.Fqdn -Server $c.DnsIP -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress); if ($answer -contains $c.IisIP) { $dnsReady=$true; break } } catch {}
                    Start-Sleep 1
                }
                if (!$dnsReady) { throw 'DNS service did not answer correctly on the new IP.' }
                Set-Service DHCPServer -StartupType Automatic; Start-Service DHCPServer
                if ($old -and $old.Scope) { $previous = Get-DhcpServerv4Scope -ScopeId $old.Scope -ErrorAction SilentlyContinue; if ($previous -and $previous.Name -eq 'MasterLab') { Set-DhcpServerv4Scope -ScopeId $old.Scope -State InActive } }
                if ($c.ClientMode -eq 'DHCP') {
                    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw 'Domain joined DHCP server needs explicit AD authorization; this tool expects a standalone lab server.' }
                    Set-DhcpServerv4Binding -InterfaceAlias $script:nic.Name -BindingState $true
                    $otherScopes = @(Get-DhcpServerv4Scope | Where-Object { $_.State -eq 'Active' -and $_.Name -ne 'MasterLab' })
                    if ($otherScopes.Count) { throw 'An unmanaged active DHCP scope exists. Preserved; resolve its conflict first.' }
                    $existing = Get-DhcpServerv4Scope -ScopeId $c.Network -ErrorAction SilentlyContinue
                    if ($existing) {
                        if ($existing.Name -ne 'MasterLab') { throw 'Requested scope is owned by another configuration.' }
                        if ([string]$existing.StartRange -ne $c.DhcpStart -or [string]$existing.EndRange -ne $c.DhcpEnd -or [string]$existing.SubnetMask -ne $c.Mask) { Remove-DhcpServerv4Scope -ScopeId $c.Network -Force; $existing=$null }
                    }
                    if (!$existing) { Add-DhcpServerv4Scope -Name 'MasterLab' -StartRange $c.DhcpStart -EndRange $c.DhcpEnd -SubnetMask $c.Mask -State InActive -LeaseDuration (New-TimeSpan -Hours 1) }
                    # DNS was verified above. Force avoids DHCP's unrelated DNS validation heuristic.
                    Set-DhcpServerv4OptionValue -ScopeId $c.Network -DnsServer $c.DnsIP -DnsDomain $c.Zone -Force
                    if ($c.Router) { Set-DhcpServerv4OptionValue -ScopeId $c.Network -Router $c.Router } else { if (Get-DhcpServerv4OptionValue -ScopeId $c.Network -OptionId 3 -ErrorAction SilentlyContinue) { Remove-DhcpServerv4OptionValue -ScopeId $c.Network -OptionId 3 } }
                    Ensure-Firewall 'MasterLab-DHCP' UDP 67
                    Set-DhcpServerv4Scope -ScopeId $c.Network -State Active
                    Restart-Service DHCPServer
                    $result.Scope = $c.Network
                }
                Clear-DnsServerCache -Force
                $resolved = @(Resolve-DnsName -Name $c.Fqdn -Server $c.DnsIP -Type A -DnsOnly | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
                if ($resolved -notcontains $c.IisIP) { throw 'DNS server self-test failed.' }
                $result.DnsAnswer = $resolved
            } else {
                Set-LabAddress $c.IisIP
                Import-Module WebAdministration
                if (Get-Website -Name 'web1' -ErrorAction SilentlyContinue) { Remove-Website -Name 'web1' }
                foreach ($site in Get-Website) { foreach ($binding in $site.Bindings.Collection) { if ($binding.bindingInformation -match (':' + $c.Port + ':') -and $binding.bindingInformation -match '^\*:') { throw "Port conflicts with existing website $($site.Name)." } } }
                New-Item -ItemType Directory -Path 'C:\LABWEB' -Force | Out-Null
                $marker = 'MasterLab ' + $c.Fqdn + ' ' + $c.IisIP + ':' + $c.Port
                $webText = [string]$c.WebText
                if ([string]::IsNullOrWhiteSpace($webText)) { $webText = 'Hello web 1' }
                $encodedText = [Net.WebUtility]::HtmlEncode($webText)
                $html = '<!doctype html><html><head><meta charset="utf-8"><title>web1</title></head><body><!-- ' + $marker + ' -->' + $encodedText + '</body></html>'
                Set-Content -LiteralPath 'C:\LABWEB\index.html' -Value $html -Encoding UTF8
                & icacls.exe 'C:\LABWEB' /grant '*S-1-5-32-568:(OI)(CI)RX' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Cannot grant IIS read permission.' }
                if ($c.Protocol -eq 'http') { New-Website -Name 'web1' -PhysicalPath 'C:\LABWEB' -IPAddress $c.IisIP -Port $c.Port | Out-Null } else {
                    $cert=$null
                    if ($old -and $old.Thumbprint -and $old.Config.Fqdn -eq $c.Fqdn -and $old.Config.IisIP -eq $c.IisIP) { $cert=Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $old.Thumbprint) -ErrorAction SilentlyContinue; if ($cert -and $cert.NotAfter -lt (Get-Date).AddDays(1)) { $cert=$null } }
                    if (!$cert) { $cert = New-SelfSignedCertificate -Type Custom -Subject ('CN=' + $c.Fqdn) -FriendlyName ('MasterLab ' + $c.Fqdn) -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -KeyUsage DigitalSignature,KeyEncipherment -NotAfter (Get-Date).AddYears(1) -TextExtension @(('2.5.29.17={text}DNS=' + $c.Fqdn + '&IPAddress=' + $c.IisIP),'2.5.29.37={text}1.3.6.1.5.5.7.3.1') }
                    New-Website -Name 'web1' -PhysicalPath 'C:\LABWEB' -IPAddress $c.IisIP -Port $c.Port -Ssl | Out-Null
                    $binding = Get-WebBinding -Name 'web1' -Protocol https
                    $binding.AddSslCertificate($cert.Thumbprint,'My')
                    Export-Certificate -Cert $cert -FilePath 'C:\ProgramData\MasterLab\lab.cer' -Force | Out-Null
                    Import-Certificate -FilePath 'C:\ProgramData\MasterLab\lab.cer' -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
                    $result.Thumbprint = $cert.Thumbprint
                    $result.SAN = ($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }).Format($false)
                }
                Ensure-Firewall 'MasterLab-Web' TCP $c.Port
                Set-Service W3SVC -StartupType Automatic; Start-Service W3SVC; Start-Website -Name 'web1'
                $uri = '{0}://{1}:{2}/' -f $c.Protocol,$c.IisIP,$c.Port
                $handler = New-Object System.Net.WebClient; $handler.Proxy = $null
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $page = $handler.DownloadString($uri)
                if (!$page.Contains($marker) -or !$page.Contains($encodedText)) { throw 'IIS local content check failed.' }
                $result.LocalHttp = 200; $result.Marker = $marker
                Remove-StaleCertificates $result.Thumbprint
            }
            @{ Config=$c; Scope=$result.Scope; Thumbprint=$result.Thumbprint; Backup=$backup } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }
    } else { throw 'Unknown guest action.' }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    @{ Success=$false; Error=($_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber); Backup=$backup } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
