$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:Vmrun = 'D:\vmare\vmrun.exe'
$script:HostAdapter = 'VMware Network Adapter VMnet1'
$script:VMs = @{
    DNS = @{ Path = 'C:\Users\Admin\Documents\Virtual Machines\Clone of Windows Server 2022-2\Clone of Windows Server 2022-2.vmx'; Name = 'Clone of Windows Server 2022-2' }
    IIS = @{ Path = 'D:\win sv2\Windows Server 2022.vmx'; Name = 'Windows Server 2022 90' }
}
$script:StateDir = Join-Path $env:LOCALAPPDATA 'MasterLab'
New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
function Write-LabLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 }
}
function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Quote-Native([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-Vmrun([string]$Operation, [string]$Role, [string[]]$Parameters = @(), [int]$TimeoutSeconds = 180) {
    $nativeArguments = @('-T','ws')
    if ($Role) {
        $credentialFile = Join-Path $script:StateDir "$Role.credential.xml"
        if (!(Test-Path -LiteralPath $credentialFile)) { throw "Missing saved credential for $Role. Use Credentials in MASTER." }
        $credential = Import-Clixml -LiteralPath $credentialFile
        $nativeArguments += @('-gu', $credential.UserName, '-gp', $credential.GetNetworkCredential().Password)
    }
    $nativeArguments += $Operation
    if ($Role) { $nativeArguments += $script:VMs[$Role].Path }
    $nativeArguments += $Parameters
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Vmrun
    $psi.Arguments = (($nativeArguments | ForEach-Object { Quote-Native $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw "vmrun $Operation timeout. Guest operation may still be running; inspect before retry." }
    $output = $stdout.Result + $stderr.Result
    if ($process.ExitCode -ne 0) { throw "vmrun $Operation ($Role): $output" }
    return $output.Trim()
}
function Get-VMConfig([string]$Role) {
    $v = $script:VMs[$Role]; $values = @{}
    foreach ($line in Get-Content -LiteralPath $v.Path) {
        if ($line -match '^\s*([^#=]+?)\s*=\s*"(.*)"\s*$') { $values[$matches[1]] = $matches[2] }
    }
    if ($values['displayName'] -ne $v.Name) { throw "Wrong displayName for $Role VM." }
    if ($values['ethernet0.connectionType'] -ne 'custom' -or $values['ethernet0.vnet'] -ne 'VMnet1') { throw "$Role must use custom VMnet1." }
    $enabledNICs = @($values.Keys | Where-Object { $_ -match '^ethernet\d+\.present$' -and $values[$_] -eq 'TRUE' })
    if ($enabledNICs.Count -ne 1) { throw "$Role must have exactly one NIC for this isolated lab." }
    $mac = $values['ethernet0.generatedAddress']; if ($values['ethernet0.addressType'] -eq 'static') { $mac = $values['ethernet0.address'] }
    if (!$mac) { throw "Cannot identify $Role NIC MAC." }
    return $mac
}
function Assert-VMwareDHCP {
    $networks = Invoke-Vmrun -Operation listHostNetworks
    if ($networks -notmatch '(?im)^\s*1\s+vmnet1\s+hostOnly\s+false\s+') {
        throw 'VMnet1 is not confirmed Host-only with VMware DHCP disabled. Disable DHCP only for VMnet1 in Virtual Network Editor before continuing; do not stop the shared VMnetDHCP service.'
    }
}
function Invoke-Guest([string]$Role, [string]$Action, $Config = $null) {
    $mac = Get-VMConfig $Role
    $id = [guid]::NewGuid().ToString('N')
    $guestScript = "C:\Windows\Temp\MasterLab-$id.ps1"
    $guestResult = "C:\Windows\Temp\MasterLab-$id.json"
    $request = @{ Role=$Role; Action=$Action; Config=$Config; Mac=$mac }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 10 -Compress)))
    Invoke-Vmrun -Operation copyFileFromHostToGuest -Role $Role -Parameters @((Join-Path $script:Root 'Guest.ps1'), $guestScript) | Out-Null
    Invoke-Vmrun -Operation runProgramInGuest -Role $Role -Parameters @('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$guestScript,'-RequestBase64',$b64,'-ResultPath',$guestResult) -TimeoutSeconds 1200 | Out-Null
    $localResult = Join-Path $script:StateDir "$Role-$id.json"
    Invoke-Vmrun -Operation copyFileFromGuestToHost -Role $Role -Parameters @($guestResult,$localResult) | Out-Null
    $result = Get-Content -LiteralPath $localResult -Raw | ConvertFrom-Json
    if (!$result.Success) { throw "$Role/$Action failed: $($result.Error) [backup: $($result.Backup)]" }
    return $result
}
function Test-LabEnvironment {
    if (!(Test-Admin)) { throw 'Host Administrator elevation is required.' }
    if (!(Test-Path -LiteralPath $script:Vmrun -PathType Leaf)) { throw 'vmrun.exe missing.' }
    $list = Invoke-Vmrun -Operation list
    $running = @($list -split '\r?\n' | Select-Object -Skip 1 | Where-Object { $_.Trim() })
    if ($running.Count -ne 2) { throw "Expected exactly two running VMs. Actual: $list" }
    foreach ($role in @('DNS','IIS')) {
        if ($running -notcontains $script:VMs[$role].Path) { throw "Required $role VM is not running." }
        $null = Get-VMConfig $role
        $tools = Invoke-Vmrun -Operation checkToolsState -Parameters @($script:VMs[$role].Path)
        if ($tools.Trim() -ne 'running') { throw "$role VMware Tools: $tools" }
        Invoke-Vmrun -Operation listProcessesInGuest -Role $role | Out-Null
        $guest = Invoke-Guest -Role $role -Action Inspect
        Write-LabLog "$role VM identity / Tools / credential / admin / NIC PASS ($($guest.ComputerName))"
    }
    $adapter = Get-NetAdapter -Name $script:HostAdapter
    if ($adapter.Status -ne 'Up') { throw 'VMnet1 host adapter is not Up.' }
    Assert-VMwareDHCP
    Write-LabLog 'CHECK ENV PASS: host admin, exact VMs, Tools, credentials, VMnet1, DHCP isolation.'
}
function Convert-IPv4([string]$Value) {
    if ($Value -notmatch '^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$') { throw "Invalid IPv4: $Value" }
    $octets = @($Value.Split('.') | ForEach-Object { [int]$_ })
    if (@($octets | Where-Object { $_ -gt 255 }).Count) { throw "Invalid IPv4: $Value" }
    return [uint64]($octets[0]*16777216L + $octets[1]*65536L + $octets[2]*256L + $octets[3])
}
function Format-IPv4([uint64]$Value) { return '{0}.{1}.{2}.{3}' -f (($Value -shr 24)-band 255),(($Value -shr 16)-band 255),(($Value -shr 8)-band 255),($Value-band 255) }
function Test-LabConfig($Config) {
    $c = @{}; foreach ($p in $Config.PSObject.Properties) { $c[$p.Name] = $p.Value }; if ($Config -is [hashtable]) { $c = $Config.Clone() }
    $maskInput = [string]$c.Mask
    if ($maskInput -match '^/?(\d{1,2})$') { $prefix = [int]$matches[1] } else {
        $maskNumber = Convert-IPv4 $maskInput
        $bits = [Convert]::ToString([long]$maskNumber,2).PadLeft(32,'0')
        if ($bits -notmatch '^1+0+$') { throw 'Subnet mask must be contiguous.' }; $prefix = $bits.IndexOf('0')
    }
    if ($prefix -lt 1 -or $prefix -gt 30) { throw 'Prefix must be 1..30.' }
    $maskNumber = (4294967295L -shl (32-$prefix)) -band 4294967295L
    $dns = Convert-IPv4 $c.DnsIP; $network = $dns -band $maskNumber; $broadcast = $network + (4294967295L -bxor $maskNumber)
    $c.Prefix = $prefix; $c.Mask = Format-IPv4 $maskNumber; $c.Network = Format-IPv4 $network
    $ips = @($c.DnsIP,$c.IisIP)
    if ($c.ClientMode -eq 'Static') { $ips += $c.ClientIP } elseif ($c.ClientMode -ne 'DHCP') { throw 'Client mode must be Static or DHCP.' }
    if ($c.ClientMode -eq 'Static') { $c.Router = '' }
    if ($c.Router) { $ips += $c.Router }
    if (@($ips | Select-Object -Unique).Count -ne $ips.Count) { throw 'Duplicate server/client/router IP.' }
    foreach ($ip in $ips) {
        $n = Convert-IPv4 $ip
        if (($n -band $maskNumber) -ne $network -or $n -le $network -or $n -ge $broadcast -or $n -ge 3758096384L -or $n -lt 16777216L -or (($n -shr 24) -eq 127) -or (($n -shr 16) -eq 43518)) { throw "Unusable IP or different subnet: $ip" }
    }
    if ($c.ClientMode -eq 'DHCP') {
        $start = Convert-IPv4 $c.DhcpStart; $end = Convert-IPv4 $c.DhcpEnd
        if ($start -gt $end -or $start -le $network -or $end -ge $broadcast) { throw 'Invalid DHCP range.' }
        foreach ($ip in $ips) { $n = Convert-IPv4 $ip; if ($n -ge $start -and $n -le $end) { throw "DHCP range overlaps reserved IP: $ip" } }
    }
    $c.Fqdn = ([string]$c.Fqdn).Trim().TrimEnd('.').ToLowerInvariant()
    if ($c.Fqdn.Length -gt 253 -or $c.Fqdn -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$') { throw 'Invalid website FQDN.' }
    $labels = $c.Fqdn.Split('.'); $c.Record = $labels[0]; $c.Zone = ($labels[1..($labels.Count-1)] -join '.')
    foreach ($label in $labels) { if ($label -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') { throw 'FQDN label must be 1..63 characters and cannot start/end with a hyphen.' } }
    if ($c.Protocol -notin @('http','https')) { throw 'Protocol must be http or https.' }
    $port = 0; if (![int]::TryParse([string]$c.Port,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Port must be 1..65535.' }; $c.Port = $port
    if ([string]::IsNullOrWhiteSpace([string]$c.WebText)) { $c.WebText = 'Hello web 1' }
    $c.WebText = [string]$c.WebText
    if ($c.WebText.Length -gt 2000) { throw 'Website text must be at most 2000 characters.' }
    return [pscustomobject]$c
}
