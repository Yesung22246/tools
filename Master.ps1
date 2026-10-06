param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (!(Test-Admin)) {
    try { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "' + $PSCommandPath + '" -Elevated') -WorkingDirectory $PSScriptRoot | Out-Null } catch { Write-Host 'Windows UAC approval is needed to configure VMnet1.'; Read-Host 'Press Enter' }
    exit
}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$guiMutex=New-Object Threading.Mutex($false,'Local\MasterLab-GUI')
$guiLock=$false
try { $guiLock=$guiMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $guiLock=$true }
if (!$guiLock) { [Windows.Forms.MessageBox]::Show('MASTER LAB is already open. Use the existing window.','MASTER LAB') | Out-Null; $guiMutex.Dispose(); exit }
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text='MASTER LAB - DNS/DHCP + IIS'; $form.Size=New-Object Drawing.Size(910,780); $form.StartPosition='CenterScreen'
$form.MinimumSize=$form.Size
$font=New-Object Drawing.Font('Segoe UI',10); $form.Font=$font
$title=New-Object Windows.Forms.Label; $title.Text='ONE INPUT  >  RUN ALL'; $title.Location=New-Object Drawing.Point(24,18); $title.Size=New-Object Drawing.Size(800,30); $title.Font=New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold); $form.Controls.Add($title)
$roles=New-Object Windows.Forms.Label; $roles.Text='Clone of Windows Server 2022-2 = DNS/DHCP   |   Windows Server 2022 90 = IIS'; $roles.Location=New-Object Drawing.Point(24,58); $roles.Size=New-Object Drawing.Size(850,25); $form.Controls.Add($roles)
$fields=@{}
$spec=@(
    @('DnsIP','DNS / DHCP IP','10.10.10.2'),@('IisIP','IIS IP','10.10.10.3'),@('Mask','Mask or prefix','24'),@('Fqdn','Website FQDN','www.lab.local'),@('Protocol','Protocol','http'),@('Port','Port','8080'),@('ClientMode','Client mode','Static'),@('ClientIP','Static client IP','10.10.10.4'),@('DhcpStart','DHCP start','192.168.50.100'),@('DhcpEnd','DHCP end','192.168.50.150'),@('Router','DHCP router (optional)',''),@('WebText','Website text','Hello web 1')
)
for ($i=0;$i -lt $spec.Count;$i++) {
    $col=$i%2; $row=[math]::Floor($i/2); $x=24+$col*430; $y=100+$row*43
    $label=New-Object Windows.Forms.Label; $label.Text=$spec[$i][1]; $label.Location=[Drawing.Point]::new([int]$x,[int]($y+4)); $label.Size=New-Object Drawing.Size(155,27); $form.Controls.Add($label)
    if ($spec[$i][0] -in @('Protocol','ClientMode')) {
        $control=New-Object Windows.Forms.ComboBox; $control.DropDownStyle='DropDownList'
        if ($spec[$i][0] -eq 'Protocol') { $control.Items.AddRange(@('http','https')) } else { $control.Items.AddRange(@('Static','DHCP')) }
        $control.SelectedItem=$spec[$i][2]
    } else { $control=New-Object Windows.Forms.TextBox; $control.Text=$spec[$i][2] }
    $control.Location=New-Object Drawing.Point(($x+160),$y); $control.Size=New-Object Drawing.Size(225,28); $form.Controls.Add($control); $fields[$spec[$i][0]]=$control
}
$buttons=@{}
$names=@('Credentials','CHECK ENV','PREP BOTH VMs','RUN ALL')
for ($i=0;$i -lt $names.Count;$i++) { $b=New-Object Windows.Forms.Button; $b.Text=$names[$i]; $b.Location=New-Object Drawing.Point((24+$i*212),370); $b.Size=New-Object Drawing.Size(200,42); $form.Controls.Add($b); $buttons[$names[$i]]=$b }
$buttons['RUN ALL'].Enabled=$false; $buttons['PREP BOTH VMs'].Enabled=$false
$log=New-Object Windows.Forms.TextBox; $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.Location=New-Object Drawing.Point(24,435); $log.Size=New-Object Drawing.Size(842,280); $log.Anchor='Top,Bottom,Left,Right'; $log.Font=New-Object Drawing.Font('Consolas',10); $form.Controls.Add($log)
$script:activeProcess=$null; $script:checked=$false; $script:activeAction=''
function Start-UIWorker([string]$Action) {
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Worker.ps1') + '" -Action ' + $Action
    if ($Action -eq 'Run') {
        $config=@{}; foreach ($key in $fields.Keys) { $config[$key]=$fields[$key].Text.Trim() }
        $validated=Test-LabConfig $config
        $configPath=Join-Path $script:StateDir 'input.json'; $validated | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
        $arguments += ' -ConfigPath "' + $configPath + '"'
    }
    $script:activeAction=$Action
    $script:activeProcess=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru -WorkingDirectory $PSScriptRoot
    foreach ($b in $buttons.Values) { $b.Enabled=$false }
}
$buttons['Credentials'].Add_Click({
    foreach ($role in @('DNS','IIS')) {
        $cred=Get-Credential -UserName 'Administrator' -Message "Administrator account for $role VM (saved with Windows DPAPI)"
        if (!$cred) { return }
        $cred | Export-Clixml -LiteralPath (Join-Path $script:StateDir "$role.credential.xml")
    }
    $script:checked=$false; $buttons['RUN ALL'].Enabled=$false; $buttons['PREP BOTH VMs'].Enabled=$false; $log.Text='Credentials saved. Run CHECK ENV.'
})
$buttons['CHECK ENV'].Add_Click({ try { Start-UIWorker Check } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'CHECK ENV') } })
$buttons['PREP BOTH VMs'].Add_Click({ try { Start-UIWorker Prep } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'PREP') } })
$buttons['RUN ALL'].Add_Click({ try { Start-UIWorker Run } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Input error') } })
$fields.ClientMode.Add_SelectedIndexChanged({ $dhcp=$fields.ClientMode.Text -eq 'DHCP'; $fields.ClientIP.Enabled=!$dhcp; $fields.DhcpStart.Enabled=$dhcp; $fields.DhcpEnd.Enabled=$dhcp; $fields.Router.Enabled=$dhcp })
$lastConfigPath=Join-Path $script:StateDir 'last-config.json'
if (Test-Path $lastConfigPath) { try { $lastConfig=Get-Content $lastConfigPath -Raw | ConvertFrom-Json; foreach ($key in $fields.Keys) { if ($null -ne $lastConfig.$key) { $fields[$key].Text=[string]$lastConfig.$key } } } catch {} }
$dhcp=$fields.ClientMode.Text -eq 'DHCP'; $fields.ClientIP.Enabled=!$dhcp; $fields.DhcpStart.Enabled=$dhcp; $fields.DhcpEnd.Enabled=$dhcp; $fields.Router.Enabled=$dhcp
$timer=New-Object Windows.Forms.Timer; $timer.Interval=800
$timer.Add_Tick({
    if ($script:activeProcess) {
        $path=Join-Path $PSScriptRoot 'logs\current.log'; if (Test-Path $path) { try { $log.Text=Get-Content $path -Raw; $log.SelectionStart=$log.TextLength; $log.ScrollToCaret() } catch {} }
        if ($script:activeProcess.HasExited) {
            $statusPath=Join-Path $PSScriptRoot 'logs\status.json'; $s=$null
            try { $s=Get-Content $statusPath -Raw | ConvertFrom-Json } catch {}
            if ($script:activeAction -eq 'Check') { $script:checked=($script:activeProcess.ExitCode -eq 0 -and $null -ne $s -and $s.Action -eq 'Check' -and $s.Success -and $s.Complete) }
            if ($script:activeProcess.ExitCode -eq 2) { $log.AppendText("`r`nAnother MASTER operation is already running. Wait for it to finish.") }
            $buttons['Credentials'].Enabled=$true; $buttons['CHECK ENV'].Enabled=$true; $buttons['PREP BOTH VMs'].Enabled=$script:checked; $buttons['RUN ALL'].Enabled=$script:checked
            $script:activeProcess.Dispose(); $script:activeProcess=$null
        }
    }
})
$form.Add_FormClosing({ param($sender,$eventArgs) if ($script:activeProcess -and !$script:activeProcess.HasExited) { $eventArgs.Cancel=$true; [Windows.Forms.MessageBox]::Show('An operation is running. Wait for its result before closing.','MASTER LAB') | Out-Null } })
$form.Add_Shown({
    New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'logs') -Force | Out-Null
    @{ Event='GUI Shown'; Title=$form.Text; Fields=$fields.Count; Buttons=$buttons.Count; RunInitiallyDisabled=(!$buttons['RUN ALL'].Enabled); Time=(Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'logs\gui-status.json') -Encoding UTF8
    $form.Activate()
})
$timer.Start(); $form.Show(); [Windows.Forms.Application]::Run($form); $timer.Stop(); $timer.Dispose(); $guiMutex.ReleaseMutex(); $guiMutex.Dispose()
