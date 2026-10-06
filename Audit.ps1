$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$base=@{DnsIP='10.10.10.2';IisIP='10.10.10.3';Mask='24';Fqdn='www.lab.local';Protocol='http';Port='8080';ClientMode='Static';ClientIP='10.10.10.4';Router=''}
$valid=Test-LabConfig $base
if ($valid.Network -ne '10.10.10.0' -or $valid.Mask -ne '255.255.255.0') { throw 'Subnet calculation failed.' }
$invalidCases=@(
    @{DnsIP='999.1.1.1'},@{DnsIP='010.10.10.2'},@{IisIP='10.10.10.2'},@{ClientIP='10.10.10.0'},@{ClientIP='10.10.10.255'},@{ClientIP='10.10.11.4'},@{Mask='255.0.255.0'},@{Mask='31'},@{Port='0'},@{Port='65536'},@{Fqdn='a;whoami.lab.local'},@{ClientMode='DHCP';DhcpStart='10.10.10.3';DhcpEnd='10.10.10.200'},@{ClientMode='DHCP';DhcpStart='10.10.10.200';DhcpEnd='10.10.10.100'}
)
foreach ($change in $invalidCases) {
    $case=$base.Clone(); foreach ($key in $change.Keys) { $case[$key]=$change[$key] }
    $rejected=$false; try { $null=Test-LabConfig $case } catch { $rejected=$true }
    if (!$rejected) { throw ('Expected input rejection: ' + ($change | ConvertTo-Json -Compress)) }
}
foreach ($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    $tokens=$null; $errors=$null; [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw ($file.Name + ': ' + ($errors.Message -join '; ')) }
}
'PASS: Windows PowerShell syntax; subnet; malformed/duplicate/network/broadcast/outside-subnet IP; invalid mask/port/FQDN; DHCP overlap/order.'
