<#
    UGC IT Quick-Fix Toolkit
    ------------------------
    A point-and-click menu of common Windows fixes for UGC workstations.

    Launch (from any PowerShell window):
        irm https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/UGC-Toolkit.ps1 | iex

    Or run the file directly:
        powershell -ExecutionPolicy Bypass -File .\UGC-Toolkit.ps1

    The toolkit elevates itself to Administrator, shows every fix as a button,
    asks before anything that deletes or resets, and logs every action to
    C:\ProgramData\UGC-Toolkit\toolkit.log
#>

# ---------------------------------------------------------------------------
# 1. SETTINGS - change this to the raw URL of this file once it is hosted
# ---------------------------------------------------------------------------
$ToolkitUrl = 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/UGC-Toolkit.ps1'
$ToolkitVersion = '1.0'
$LogDir  = Join-Path $env:ProgramData 'UGC-Toolkit'
$LogFile = Join-Path $LogDir 'toolkit.log'

# ---------------------------------------------------------------------------
# 2. SELF-ELEVATION - relaunch as Administrator if needed
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-EncodedCommand([string]$Script) {
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

if (-not (Test-IsAdmin)) {
    if ($PSCommandPath) {
        # Started from a saved file: relaunch the same file
        $relaunch = "& '$PSCommandPath'"
    } else {
        # Started with irm | iex: download and run again
        $relaunch = "irm '$ToolkitUrl' | iex"
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', (ConvertTo-EncodedCommand $relaunch))
    return
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# 3. THE FIXES
#    Mode 'Inline'  = runs in the background, output appears in the log box
#    Mode 'Window'  = opens its own PowerShell window (for long tasks such as
#                     SFC or DISM, so you can watch the progress)
#    Confirm        = asks Yes/No first (anything that deletes or resets)
#    To add a fix, copy one block and change it - nothing else needs editing.
# ---------------------------------------------------------------------------
$Fixes = @(

    # ----- DISK & CLEANUP -----
    @{ Tab='Disk & Cleanup'; Name='Disk space summary'; Mode='Inline'
       Help='Shows used and free space on every drive.'
       Script={
           Get-PSDrive -PSProvider FileSystem | Where-Object Used -ne $null |
             Select-Object Name,
               @{n='Used (GB)';e={[math]::Round($_.Used/1GB,1)}},
               @{n='Free (GB)';e={[math]::Round($_.Free/1GB,1)}},
               @{n='Free %';e={ if (($_.Used+$_.Free) -gt 0) {[math]::Round(100*$_.Free/($_.Used+$_.Free))} }} |
             Format-Table -AutoSize | Out-String
       } }

    @{ Tab='Disk & Cleanup'; Name='Largest folders in user profile'; Mode='Inline'
       Help='Lists the 15 biggest folders under C:\Users (takes a minute).'
       Script={
           Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
             Get-ChildItem -Directory -Force -ErrorAction SilentlyContinue |
             ForEach-Object {
                 $s = (Get-ChildItem $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                       Measure-Object Length -Sum).Sum
                 [pscustomobject]@{ Folder=$_.FullName; GB=[math]::Round($s/1GB,2) }
             } | Sort-Object GB -Descending | Select-Object -First 15 |
             Format-Table -AutoSize | Out-String -Width 200
       } }

    @{ Tab='Disk & Cleanup'; Name='Outlook cache (.ost) sizes'; Mode='Inline'
       Help='Shows every Outlook offline cache file for all users and its size.'
       Script={
           $files = Get-ChildItem 'C:\Users\*\AppData\Local\Microsoft\Outlook\*.ost' -Force -ErrorAction SilentlyContinue
           if (-not $files) { 'No .ost files found.' } else {
               $files | Sort-Object Length -Descending |
                 Select-Object FullName, @{n='GB';e={[math]::Round($_.Length/1GB,2)}}, LastWriteTime |
                 Format-Table -AutoSize | Out-String -Width 220
           }
       } }

    @{ Tab='Disk & Cleanup'; Name='Clear temp files'; Mode='Inline'; Confirm=$true
       Help='Deletes files in Windows\Temp and every user Temp folder. Files in use are skipped.'
       Script={
           $before = (Get-PSDrive C).Free
           $paths = @("$env:windir\Temp\*") + (Get-ChildItem 'C:\Users\*\AppData\Local\Temp' -Directory -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName '*' })
           foreach ($p in $paths) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
           "Freed {0:N2} GB" -f (((Get-PSDrive C).Free - $before)/1GB)
       } }

    @{ Tab='Disk & Cleanup'; Name='Empty Recycle Bin'; Mode='Inline'; Confirm=$true
       Help='Permanently empties the Recycle Bin on all drives.'
       Script={ Clear-RecycleBin -Force -ErrorAction SilentlyContinue; 'Recycle Bin emptied.' } }

    @{ Tab='Disk & Cleanup'; Name='Windows Disk Cleanup (auto)'; Mode='Window'
       Help='Runs Disk Cleanup on C: with all safe categories, including old Windows Update files.'
       Script={ cleanmgr.exe /d C /VERYLOWDISK } }

    @{ Tab='Disk & Cleanup'; Name='Clean component store (WinSxS)'; Mode='Window'; Confirm=$true
       Help='DISM StartComponentCleanup. Removes superseded update files. Takes 5-20 minutes.'
       Script={ Dism.exe /Online /Cleanup-Image /StartComponentCleanup } }

    @{ Tab='Disk & Cleanup'; Name='Turn off hibernation'; Mode='Inline'; Confirm=$true
       Help='Deletes hiberfil.sys (usually the size of RAM). Disables hibernate and Fast Startup.'
       Script={ powercfg.exe /h off; 'Hibernation disabled. hiberfil.sys removed.' } }

    @{ Tab='Disk & Cleanup'; Name='Install / open WizTree'; Mode='Inline'
       Help='Opens WizTree to see exactly what uses the disk. Installs it with winget if missing.'
       Script={
           $exe = 'C:\Program Files\WizTree\WizTree64.exe'
           if (-not (Test-Path $exe)) {
               winget install --id AntibodySoftware.WizTree -e --silent --accept-package-agreements --accept-source-agreements | Out-String
           }
           if (Test-Path $exe) { Start-Process $exe; 'WizTree opened.' } else { 'WizTree could not be installed.' }
       } }

    # ----- SYSTEM REPAIR -----
    @{ Tab='System Repair'; Name='System File Checker (SFC)'; Mode='Window'
       Help='sfc /scannow - checks and repairs Windows system files. 10-20 minutes.'
       Script={ sfc.exe /scannow } }

    @{ Tab='System Repair'; Name='DISM repair image'; Mode='Window'
       Help='DISM /RestoreHealth - repairs the Windows image. Run before SFC if SFC fails.'
       Script={ Dism.exe /Online /Cleanup-Image /RestoreHealth } }

    @{ Tab='System Repair'; Name='Check disk (online scan)'; Mode='Window'
       Help='chkdsk C: /scan - scans for file system errors without a reboot.'
       Script={ chkdsk.exe C: /scan } }

    @{ Tab='System Repair'; Name='Reset Windows Update'; Mode='Window'; Confirm=$true
       Help='Stops update services, renames SoftwareDistribution and catroot2, restarts services.'
       Script={
           $svc = 'wuauserv','bits','cryptsvc','msiserver'
           Stop-Service $svc -Force -ErrorAction SilentlyContinue
           $stamp = Get-Date -Format 'yyyyMMddHHmm'
           Rename-Item "$env:windir\SoftwareDistribution" "SoftwareDistribution.old$stamp" -ErrorAction SilentlyContinue
           Rename-Item "$env:windir\System32\catroot2" "catroot2.old$stamp" -ErrorAction SilentlyContinue
           Start-Service $svc -ErrorAction SilentlyContinue
           'Windows Update components reset. Run Windows Update again.'
       } }

    @{ Tab='System Repair'; Name='Restart Explorer'; Mode='Inline'
       Help='Fixes a frozen taskbar, Start menu or desktop.'
       Script={ Stop-Process -Name explorer -Force; Start-Sleep 2
                if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
                'Explorer restarted.' } }

    @{ Tab='System Repair'; Name='Group Policy update'; Mode='Window'
       Help='gpupdate /force - applies the latest policies.'
       Script={ gpupdate.exe /force } }

    @{ Tab='System Repair'; Name='Sync Windows time'; Mode='Inline'
       Help='Forces a time sync. Wrong time breaks sign-in, Outlook and certificates.'
       Script={ Start-Service w32time -ErrorAction SilentlyContinue
                w32tm.exe /resync /force | Out-String } }

    # ----- NETWORK -----
    @{ Tab='Network'; Name='IP configuration'; Mode='Inline'
       Help='Shows adapters, IP addresses, gateway and DNS servers.'
       Script={ Get-NetIPConfiguration | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer | Out-String } }

    @{ Tab='Network'; Name='Internet & DNS test'; Mode='Inline'
       Help='Tests the gateway, internet, DNS and Microsoft 365 reachability.'
       Script={
           $gw = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1).IPv4DefaultGateway.NextHop
           $tests = [ordered]@{
               "Gateway ($gw)"          = { Test-Connection $gw -Count 2 -Quiet }
               'Internet (8.8.8.8)'     = { Test-Connection 8.8.8.8 -Count 2 -Quiet }
               'DNS (google.com)'       = { [bool](Resolve-DnsName google.com -ErrorAction SilentlyContinue) }
               'Microsoft 365 (443)'    = { (Test-NetConnection outlook.office365.com -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded }
           }
           foreach ($k in $tests.Keys) { '{0,-25} {1}' -f $k, $(if (& $tests[$k]) {'OK'} else {'FAILED'}) }
       } }

    @{ Tab='Network'; Name='Flush DNS + renew IP'; Mode='Window'; Confirm=$true
       Help='ipconfig /flushdns, /release, /renew. The network drops for a few seconds.'
       Script={ ipconfig.exe /flushdns; ipconfig.exe /release; ipconfig.exe /renew; ipconfig.exe /registerdns } }

    @{ Tab='Network'; Name='Reset network stack'; Mode='Window'; Confirm=$true
       Help='netsh winsock reset + int ip reset. Fixes deep network faults. Needs a restart.'
       Script={ netsh.exe winsock reset; netsh.exe int ip reset; ipconfig.exe /flushdns
                Write-Host "`nRestart the computer to finish." -ForegroundColor Yellow } }

    @{ Tab='Network'; Name='Saved Wi-Fi networks'; Mode='Inline'
       Help='Lists Wi-Fi profiles saved on this computer.'
       Script={ netsh.exe wlan show profiles | Out-String } }

    # ----- OFFICE & PRINTERS -----
    @{ Tab='Office & Printers'; Name='Clear Teams cache'; Mode='Inline'; Confirm=$true
       Help='Closes Teams and clears the cache for classic and new Teams (current user). Fixes sign-in and loading issues.'
       Script={
           Get-Process ms-teams, Teams -ErrorAction SilentlyContinue | Stop-Process -Force
           Start-Sleep 2
           $u = $env:USERPROFILE
           $paths = "$env:APPDATA\Microsoft\Teams",
                    "$u\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
           foreach ($p in $paths) { if (Test-Path $p) { Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue; "Cleared $p" } }
           'Done. Open Teams again.'
       } }

    @{ Tab='Office & Printers'; Name='Repair Outlook profile cache'; Mode='Inline'; Confirm=$true
       Help='Closes Outlook and clears RoamCache (autocomplete and calendar cache). The mailbox is not touched.'
       Script={
           Get-Process outlook -ErrorAction SilentlyContinue | Stop-Process -Force
           Start-Sleep 2
           $p = "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache"
           if (Test-Path $p) { Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue; 'RoamCache cleared. Open Outlook again.' }
           else { 'No RoamCache folder found.' }
       } }

    @{ Tab='Office & Printers'; Name='Office Quick Repair'; Mode='Inline'
       Help='Starts the Microsoft 365 Click-to-Run quick repair.'
       Script={
           $c2r = "$env:CommonProgramFiles\microsoft shared\ClickToRun\OfficeClickToRun.exe"
           if (Test-Path $c2r) {
               Start-Process $c2r -ArgumentList 'scenario=Repair platform=x64 culture=en-us RepairType=QuickRepair forceappshutdown=True DisplayLevel=True'
               'Office Quick Repair started.'
           } else { 'Microsoft 365 Click-to-Run not found.' }
       } }

    @{ Tab='Office & Printers'; Name='Fix stuck print queue'; Mode='Inline'; Confirm=$true
       Help='Stops the spooler, deletes stuck jobs, starts the spooler.'
       Script={
           Stop-Service Spooler -Force
           Remove-Item "$env:windir\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
           Start-Service Spooler
           'Print queue cleared and spooler restarted.'
       } }

    @{ Tab='Office & Printers'; Name='List printers'; Mode='Inline'
       Help='Shows installed printers, ports and status.'
       Script={ Get-Printer | Select-Object Name, PortName, DriverName, PrinterStatus | Format-Table -AutoSize | Out-String -Width 200 } }

    # ----- INFO -----
    @{ Tab='Info'; Name='Computer summary'; Mode='Inline'
       Help='Name, user, model, serial, OS, CPU, RAM, uptime and IP. Useful for asset records.'
       Script={
           $cs  = Get-CimInstance Win32_ComputerSystem
           $os  = Get-CimInstance Win32_OperatingSystem
           $bio = Get-CimInstance Win32_BIOS
           $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
           $ip  = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' }).IPAddress -join ', '
           $info = [ordered]@{
               'Computer name' = $env:COMPUTERNAME
               'Logged-in user'= $cs.UserName
               'Manufacturer'  = $cs.Manufacturer
               'Model'         = $cs.Model
               'Serial number' = $bio.SerialNumber
               'Windows'       = "$($os.Caption) ($($os.Version))"
               'CPU'           = $cpu.Name
               'RAM (GB)'      = [math]::Round($cs.TotalPhysicalMemory/1GB)
               'Uptime'        = ((Get-Date) - $os.LastBootUpTime).ToString('d\d\ h\h\ m\m')
               'IP address(es)'= $ip
           }
           $info.GetEnumerator() | ForEach-Object { '{0,-16}: {1}' -f $_.Key, $_.Value }
       } }

    @{ Tab='Info'; Name='Pending restart?'; Mode='Inline'
       Help='Checks whether Windows is waiting for a restart.'
       Script={
           $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
           if ($keys | Where-Object { Test-Path $_ }) { 'YES - a restart is pending.' } else { 'No restart pending.' }
       } }

    @{ Tab='Info'; Name='Last 10 updates'; Mode='Inline'
       Help='Shows the most recently installed Windows updates.'
       Script={ Get-HotFix | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue |
                  Select-Object -First 10 HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String } }

    @{ Tab='Info'; Name='Recent critical errors'; Mode='Inline'
       Help='Last 15 critical/error events from the System log (24 hours).'
       Script={ Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-1)} -MaxEvents 15 -ErrorAction SilentlyContinue |
                  Select-Object TimeCreated, ProviderName, Id, @{n='Message';e={($_.Message -split "`n")[0]}} |
                  Format-Table -AutoSize -Wrap | Out-String -Width 220 } }
)

# ---------------------------------------------------------------------------
# 4. HELPERS
# ---------------------------------------------------------------------------
function Write-ToolkitLog([string]$Text) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$env:USERNAME] $Text" | Add-Content -Path $LogFile
}

function Add-Output([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro) {
    $script:OutputBox.SelectionStart  = $script:OutputBox.TextLength
    $script:OutputBox.SelectionColor  = $Color
    $script:OutputBox.AppendText($Text.TrimEnd() + "`r`n")
    $script:OutputBox.ScrollToCaret()
}

$script:RunningJobs = @{}

function Invoke-Fix($Fix) {
    if ($Fix.Confirm) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$($Fix.Help)`n`nRun '$($Fix.Name)' now?", 'Confirm',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Write-ToolkitLog "RUN  $($Fix.Name)"
    Add-Output "`r`n>>> $($Fix.Name)" ([System.Drawing.Color]::DeepSkyBlue)

    if ($Fix.Mode -eq 'Window') {
        $body = $Fix.Script.ToString() +
                "`nWrite-Host `"`n--- Finished. You can close this window. ---`" -ForegroundColor Green"
        $title = "`$Host.UI.RawUI.WindowTitle = 'UGC Toolkit - $($Fix.Name)'`n"
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', (ConvertTo-EncodedCommand ($title + $body)))
        Add-Output 'Opened in a separate window.' ([System.Drawing.Color]::Silver)
    } else {
        $job = Start-Job -ScriptBlock $Fix.Script
        $script:RunningJobs[$job.Id] = $Fix.Name
        $script:StatusLabel.Text = "Running: $($Fix.Name)..."
    }
}

# ---------------------------------------------------------------------------
# 5. THE WINDOW
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "UGC IT Quick-Fix Toolkit v$ToolkitVersion   |   $env:COMPUTERNAME"
$form.Size = New-Object System.Drawing.Size(980, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 34, 40)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Top'
$tabs.Height = 330

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 15000

foreach ($tabName in ($Fixes | ForEach-Object { $_.Tab } | Select-Object -Unique)) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $tabName
    $page.BackColor = [System.Drawing.Color]::FromArgb(40, 43, 50)

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'
    $panel.AutoScroll = $true
    $panel.Padding = New-Object System.Windows.Forms.Padding(10)

    foreach ($fix in ($Fixes | Where-Object { $_.Tab -eq $tabName })) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $fix.Name + $(if ($fix.Confirm) { '  *' } else { '' })
        $btn.Size = New-Object System.Drawing.Size(220, 56)
        $btn.Margin = New-Object System.Windows.Forms.Padding(6)
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 110, 160)
        $btn.BackColor = if ($fix.Confirm) { [System.Drawing.Color]::FromArgb(75, 55, 45) } else { [System.Drawing.Color]::FromArgb(45, 60, 85) }
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.Tag = $fix
        $btn.Add_Click({ Invoke-Fix $this.Tag })
        $tooltip.SetToolTip($btn, $fix.Help)
        $panel.Controls.Add($btn)
    }
    $page.Controls.Add($panel)
    $tabs.TabPages.Add($page)
}

$script:OutputBox = New-Object System.Windows.Forms.RichTextBox
$OutputBox.Dock = 'Fill'
$OutputBox.ReadOnly = $true
$OutputBox.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 20)
$OutputBox.ForeColor = [System.Drawing.Color]::Gainsboro
$OutputBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$OutputBox.WordWrap = $false

$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'
$bottom.Height = 34
$bottom.BackColor = [System.Drawing.Color]::FromArgb(28, 30, 36)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.ForeColor = [System.Drawing.Color]::Silver
$StatusLabel.AutoSize = $true
$StatusLabel.Location = New-Object System.Drawing.Point(10, 9)
$StatusLabel.Text = 'Ready. Hover a button for details.  * = asks for confirmation.'

$clearBtn = New-Object System.Windows.Forms.Button
$clearBtn.Text = 'Clear output'
$clearBtn.Size = New-Object System.Drawing.Size(100, 26)
$clearBtn.Anchor = 'Right, Top'
$clearBtn.Location = New-Object System.Drawing.Point(740, 4)
$clearBtn.FlatStyle = 'Flat'; $clearBtn.ForeColor = [System.Drawing.Color]::White
$clearBtn.Add_Click({ $script:OutputBox.Clear() })

$logBtn = New-Object System.Windows.Forms.Button
$logBtn.Text = 'Open log'
$logBtn.Size = New-Object System.Drawing.Size(100, 26)
$logBtn.Anchor = 'Right, Top'
$logBtn.Location = New-Object System.Drawing.Point(850, 4)
$logBtn.FlatStyle = 'Flat'; $logBtn.ForeColor = [System.Drawing.Color]::White
$logBtn.Add_Click({ if (Test-Path $LogFile) { notepad.exe $LogFile } })

$bottom.Controls.AddRange(@($StatusLabel, $clearBtn, $logBtn))
$form.Controls.Add($OutputBox)
$form.Controls.Add($bottom)
$form.Controls.Add($tabs)

# Collect results from background jobs without freezing the window
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    foreach ($id in @($script:RunningJobs.Keys)) {
        $job = Get-Job -Id $id -ErrorAction SilentlyContinue
        if ($job -and $job.State -ne 'Running') {
            $name = $script:RunningJobs[$id]
            $out  = Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable errs 2>&1 | Out-String -Width 220
            if ($out.Trim()) { Add-Output $out }
            if ($errs) { Add-Output ($errs | Out-String) ([System.Drawing.Color]::IndianRed) }
            $state = if ($job.State -eq 'Completed') { 'DONE' } else { $job.State.ToString().ToUpper() }
            Add-Output "<<< $name : $state" ([System.Drawing.Color]::MediumSeaGreen)
            Write-ToolkitLog "$state $name"
            Remove-Job $job -Force
            $script:RunningJobs.Remove($id)
        }
    }
    $script:StatusLabel.Text = if ($script:RunningJobs.Count) {
        "Running: " + ($script:RunningJobs.Values -join ', ')
    } else { 'Ready. Hover a button for details.  * = asks for confirmation.' }
})
$timer.Start()

Add-Output "UGC IT Quick-Fix Toolkit v$ToolkitVersion - running as Administrator on $env:COMPUTERNAME" ([System.Drawing.Color]::DeepSkyBlue)
Add-Output "Log file: $LogFile" ([System.Drawing.Color]::Silver)
Write-ToolkitLog 'Toolkit opened'

[void]$form.ShowDialog()
$timer.Stop()
Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
