<#
    Ihsan Tech Fix - Toolkit
    ------------------------
    A point-and-click menu of common Windows fixes.

    Launch (from any PowerShell window):
        irm https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/UGC-Toolkit.ps1 | iex

    Or run the file directly:
        powershell -ExecutionPolicy Bypass -File .\UGC-Toolkit.ps1

    The toolkit elevates itself to Administrator, shows every fix as a button,
    asks before anything that deletes or resets, and logs every action to
    C:\ProgramData\IhsanTechFix\toolkit.log
#>

# ---------------------------------------------------------------------------
# 1. SETTINGS
# ---------------------------------------------------------------------------
$ToolkitUrl = 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/UGC-Toolkit.ps1'
$ToolkitName    = 'Ihsan Tech Fix'
$ToolkitVersion = '2.3'
$LogDir  = Join-Path $env:ProgramData 'IhsanTechFix'

# Office printers for the one-click install cards. Add one line per printer.
#   Driver = the exact driver name inside the .inf file
#   Source = where to get the driver: a folder or .zip on the NAS, and/or a web
#            link to a .zip. The first one that works is used (NAS first = fast).
$PrinterCatalog = @(
    @{ Name   = 'Canon-Office'
       IP     = '10.10.10.189'
       Driver = 'Canon Generic Plus UFR II'     # from CNLB0MA64.INF, v3.20 (02/2025), 64-bit
       Source = @('\\10.10.10.209\UGC Public\IHSAN\Softwares\Drivers\Canon-Generic-Plus-UFRII',
                  'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/drivers/Canon-Generic-Plus-UFRII-v3.20-x64.zip') }
)
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
# PRELUDE - helper functions available inside every fix
#   Get-LoggedOnUser     : the person signed in to Windows (name, SID, profile
#                          folder, registry hive) - correct even when the toolkit
#                          runs under a separate admin account
#   Start-AsLoggedOnUser : opens a program in that person's session
# ---------------------------------------------------------------------------
$Prelude = @'
function Get-LoggedOnUser {
    $name = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $name) {
        $owner = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 |
                 Invoke-CimMethod -MethodName GetOwner
        if ($owner) { $name = "$($owner.Domain)\$($owner.User)" }
    }
    if (-not $name) { return $null }
    $sid  = (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $prof = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
    [pscustomobject]@{ Name = $name; Sid = $sid; ProfilePath = $prof; Hive = "Registry::HKEY_USERS\$sid" }
}

function Start-AsLoggedOnUser([string]$Program, [string]$Arguments = '') {
    $u = Get-LoggedOnUser
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not $u -or $u.Sid -eq $me) {
        if ($Arguments) { Start-Process $Program -ArgumentList $Arguments } else { Start-Process $Program }
        return
    }
    # Different account: launch through a one-time scheduled task in the user's session
    $task = 'IhsanTechFix_Launch'
    $action = if ($Arguments) { New-ScheduledTaskAction -Execute $Program -Argument $Arguments } else { New-ScheduledTaskAction -Execute $Program }
    $principal = New-ScheduledTaskPrincipal -UserId $u.Name -LogonType Interactive
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    Start-Sleep 3
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
}

function Install-NetworkPrinter([string]$Name, [string]$IP, [string]$Driver, [string[]]$Source) {
    "Printer : $Name"
    "Address : $IP"
    if (-not (Test-Connection $IP -Count 2 -Quiet)) { "WARNING: $IP does not answer ping. Continuing anyway." }

    # 1. Driver
    if (Get-PrinterDriver -Name $Driver -ErrorAction SilentlyContinue) {
        "Driver  : '$Driver' already installed"
    } else {
        $work = $null
        foreach ($src in $Source) {
            if ($src -match '^https?://') {
                try {
                    $zip = Join-Path $env:TEMP "IhsanTechFix_driver.zip"
                    "Driver  : downloading from $src"
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $src -OutFile $zip -UseBasicParsing
                    $work = $zip; break
                } catch { "Driver  : download failed ($($_.Exception.Message))" }
            } elseif (Test-Path $src) {
                "Driver  : using $src"
                $work = $src; break
            } else { "Driver  : not reachable: $src" }
        }
        if (-not $work) { throw 'The driver could not be found in any source.' }
        if ($work -like '*.zip') {
            $dest = Join-Path $env:TEMP ("IhsanTechFix_drv_" + [guid]::NewGuid().ToString('N'))
            Expand-Archive -Path $work -DestinationPath $dest -Force
            $work = $dest
        }
        if (-not (Test-Path $work)) { throw "Driver folder not found: $work" }
        $inf = Get-ChildItem $work -Recurse -Filter *.inf |
               Where-Object { Select-String -Path $_.FullName -Pattern $Driver -SimpleMatch -Quiet } |
               Sort-Object { if ($_.FullName -match 'x64|amd64|64') { 0 } else { 1 } } | Select-Object -First 1
        if (-not $inf) { throw "No .inf file mentioning '$Driver' was found in $work" }
        "Driver  : installing from $($inf.FullName)"
        pnputil.exe /add-driver "$($inf.FullName)" /install | Out-Null
        Add-PrinterDriver -Name $Driver
        "Driver  : installed"
    }

    # 2. Port
    $port = "IP_$IP"
    if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $port -PrinterHostAddress $IP
        "Port    : $port created"
    } else { "Port    : $port already exists" }

    # 3. Printer
    if (Get-Printer -Name $Name -ErrorAction SilentlyContinue) {
        Set-Printer -Name $Name -DriverName $Driver -PortName $port
        "Printer : '$Name' updated to the correct driver and port"
    } else {
        Add-Printer -Name $Name -DriverName $Driver -PortName $port
        "Printer : '$Name' added"
    }
    "Done. '$Name' is ready to use."
}
'@
. ([scriptblock]::Create($Prelude))

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

    # ----- VPN (Tailscale) -----
    @{ Tab='Network'; Name='Install Tailscale VPN'; Mode='Window'; Icon=0xE705
       Help='Installs Tailscale and joins this PC to the company tailnet using an auth key (read from the NAS or typed in). No passwords are stored in this script.'
       Script={
           $exe = 'C:\Program Files\Tailscale\tailscale.exe'
           if (-not (Test-Path $exe)) {
               Write-Host 'Installing Tailscale...' -ForegroundColor Cyan
               winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements
               if (-not (Test-Path $exe)) {
                   Write-Host 'winget not available - downloading the MSI instead...' -ForegroundColor Yellow
                   $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
                   Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi -UseBasicParsing
                   Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn TS_UNATTENDEDMODE=always" -Wait
               }
           } else { Write-Host 'Tailscale is already installed.' -ForegroundColor Green }
           if (-not (Test-Path $exe)) { Write-Host 'Tailscale could not be installed.' -ForegroundColor Red; return }

           # Auth key: from the NAS file if present, otherwise ask
           $keyFile = '\\10.10.10.209\UGC Public\IHSAN\Softwares\Tailscale\authkey.txt'
           $key = $null
           if (Test-Path $keyFile) { $key = (Get-Content $keyFile -Raw).Trim(); Write-Host 'Using the auth key from the NAS.' -ForegroundColor Green }
           if (-not $key) {
               Write-Host "`nPaste the Tailscale auth key (tskey-auth-...), or press Enter to sign in through the browser instead:" -ForegroundColor Cyan
               $sec = Read-Host -AsSecureString
               $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
           }
           $hostName = ($env:COMPUTERNAME).ToLower()
           if ($key) {
               & $exe up --authkey $key --unattended --hostname $hostName --reset
           } else {
               Write-Host 'A browser window will open. Sign in with the company Tailscale account.' -ForegroundColor Yellow
               & $exe up --unattended --hostname $hostName --reset
           }
           Write-Host "`nStatus:" -ForegroundColor Cyan
           & $exe status
           Write-Host "`nThis PC's Tailscale IP: $(& $exe ip -4)" -ForegroundColor Green
       } }

    @{ Tab='Network'; Name='Tailscale status'; Mode='Inline'; Icon=0xE705
       Help='Shows whether this PC is connected to the tailnet, its Tailscale IP and the other devices.'
       Script={
           $exe = 'C:\Program Files\Tailscale\tailscale.exe'
           if (-not (Test-Path $exe)) { 'Tailscale is not installed. Use "Install Tailscale VPN".'; return }
           "Tailscale IP: $(& $exe ip -4)"
           & $exe status | Out-String -Width 200
       } }

    # ----- OUTLOOK & OFFICE -----
    # These act on the person signed in to Windows, even when the toolkit was
    # opened with a different admin account (see Get-LoggedOnUser in the prelude).
    @{ Tab='Outlook & Office'; Name='Rebuild Outlook profile'; Mode='Inline'; Confirm=$true
       Help='One-click fix for most Outlook problems: backs up the old profile, creates a fresh one and sets it as default. Outlook then sets up the mailbox automatically.'
       Script={
           $u = Get-LoggedOnUser
           if (-not $u) { 'No user is signed in to Windows.'; return }
           Get-Process outlook -ErrorAction SilentlyContinue | Stop-Process -Force
           Start-Sleep 3
           $base = "$($u.Hive)\Software\Microsoft\Office\16.0\Outlook"
           if (-not (Test-Path $base)) { New-Item $base -Force | Out-Null }
           $profiles = "$base\Profiles"
           if (-not (Test-Path $profiles)) { New-Item $profiles -Force | Out-Null }

           # 1. Back up the existing profiles
           $bk = Join-Path $env:ProgramData "IhsanTechFix\Backups"
           New-Item $bk -ItemType Directory -Force | Out-Null
           $bkFile = Join-Path $bk ("OutlookProfiles_{0}_{1}.reg" -f $u.Name.Split('\')[-1], (Get-Date -Format yyyyMMdd-HHmm))
           reg.exe export ("HKU\{0}\Software\Microsoft\Office\16.0\Outlook\Profiles" -f $u.Sid) $bkFile /y | Out-Null
           "Backup of old profile(s): $bkFile"
           $old = (Get-ItemProperty $base -Name DefaultProfile -ErrorAction SilentlyContinue).DefaultProfile
           if ($old) { "Old default profile: $old (kept, not deleted)" }

           # 2. Create a new empty profile and make it the default
           $new = "Outlook_" + (Get-Date -Format 'yyyyMMdd_HHmm')
           New-Item "$profiles\$new" -Force | Out-Null
           Set-ItemProperty $base -Name DefaultProfile -Value $new
           # Never ask which profile to use
           $setup = "$base\Setup"
           if (-not (Test-Path $setup)) { New-Item $setup -Force | Out-Null }
           Remove-ItemProperty $setup -Name First-Run -ErrorAction SilentlyContinue

           # 3. Let Outlook configure the Microsoft 365 mailbox by itself
           $ad = "$base\AutoDiscover"
           if (-not (Test-Path $ad)) { New-Item $ad -Force | Out-Null }
           Set-ItemProperty $ad -Name ZeroConfigExchange -Value 1 -Type DWord
           "New default profile: $new"

           # 4. Open Outlook for the user
           Start-AsLoggedOnUser 'outlook.exe'
           'Outlook is opening with the new profile. Sign in if asked; the mailbox downloads in the background.'
           'Old .ost cache files are not deleted. Use "Outlook cache (.ost) sizes" later to clean them up.'
       } }

    @{ Tab='Outlook & Office'; Name='Restore previous Outlook profile'; Mode='Inline'; Confirm=$true
       Help='Undo for the rebuild: switches the default back to the profile that was used before.'
       Script={
           $u = Get-LoggedOnUser
           $base = "$($u.Hive)\Software\Microsoft\Office\16.0\Outlook"
           $names = Get-ChildItem "$base\Profiles" -ErrorAction SilentlyContinue | ForEach-Object PSChildName
           $current = (Get-ItemProperty $base -Name DefaultProfile -ErrorAction SilentlyContinue).DefaultProfile
           $prev = $names | Where-Object { $_ -ne $current -and $_ -notlike 'Outlook_2*' } | Select-Object -First 1
           if (-not $prev) { $prev = $names | Where-Object { $_ -ne $current } | Sort-Object | Select-Object -Last 1 }
           if (-not $prev) { 'No other profile found.'; return }
           Get-Process outlook -ErrorAction SilentlyContinue | Stop-Process -Force
           Set-ItemProperty $base -Name DefaultProfile -Value $prev
           "Default profile switched from '$current' back to '$prev'."
           "All profiles: $($names -join ', ')"
       } }

    @{ Tab='Outlook & Office'; Name='Open Outlook in Safe Mode'; Mode='Inline'
       Help='Starts Outlook without add-ins. If it works in Safe Mode, a faulty add-in is the cause.'
       Script={ Get-Process outlook -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
                Start-AsLoggedOnUser 'outlook.exe' '/safe'; 'Outlook opened in Safe Mode.' } }

    @{ Tab='Outlook & Office'; Name='Reset Outlook navigation pane'; Mode='Inline'
       Help='Fixes Outlook crashing at start or a broken folder pane (outlook.exe /resetnavpane).'
       Script={ Get-Process outlook -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
                Start-AsLoggedOnUser 'outlook.exe' '/resetnavpane'; 'Navigation pane reset. Outlook is opening.' } }

    @{ Tab='Outlook & Office'; Name='Clear Outlook RoamCache'; Mode='Inline'; Confirm=$true
       Help='Closes Outlook and clears autocomplete and calendar cache. The mailbox is not touched.'
       Script={
           $u = Get-LoggedOnUser
           Get-Process outlook -ErrorAction SilentlyContinue | Stop-Process -Force
           Start-Sleep 2
           $p = "$($u.ProfilePath)\AppData\Local\Microsoft\Outlook\RoamCache"
           if (Test-Path $p) { Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue; "RoamCache cleared for $($u.Name)." }
           else { 'No RoamCache folder found.' }
       } }

    @{ Tab='Outlook & Office'; Name='Clear Teams cache'; Mode='Inline'; Confirm=$true
       Help='Closes Teams and clears the cache for classic and new Teams. Fixes sign-in and loading issues.'
       Script={
           $u = Get-LoggedOnUser
           Get-Process ms-teams, Teams -ErrorAction SilentlyContinue | Stop-Process -Force
           Start-Sleep 2
           $paths = "$($u.ProfilePath)\AppData\Roaming\Microsoft\Teams",
                    "$($u.ProfilePath)\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
           foreach ($p in $paths) { if (Test-Path $p) { Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue; "Cleared $p" } }
           'Done. Open Teams again.'
       } }

    @{ Tab='Outlook & Office'; Name='Office Quick Repair'; Mode='Inline'
       Help='Starts the Microsoft 365 Click-to-Run quick repair.'
       Script={
           $c2r = "$env:CommonProgramFiles\microsoft shared\ClickToRun\OfficeClickToRun.exe"
           if (Test-Path $c2r) {
               Start-Process $c2r -ArgumentList 'scenario=Repair platform=x64 culture=en-us RepairType=QuickRepair forceappshutdown=True DisplayLevel=True'
               'Office Quick Repair started.'
           } else { 'Microsoft 365 Click-to-Run not found.' }
       } }

    # ----- PRINTERS -----
    # One "Install" card per printer in $PrinterCatalog is added automatically below.
    @{ Tab='Printers'; Name='Fix stuck print queue'; Mode='Inline'; Confirm=$true
       Help='Stops the spooler, deletes stuck jobs, starts the spooler.'
       Script={
           Stop-Service Spooler -Force
           Remove-Item "$env:windir\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
           Start-Service Spooler
           'Print queue cleared and spooler restarted.'
       } }

    @{ Tab='Printers'; Name='List printers'; Mode='Inline'
       Help='Shows installed printers, ports, drivers and status.'
       Script={ Get-Printer | Select-Object Name, PortName, DriverName, PrinterStatus | Format-Table -AutoSize | Out-String -Width 200 } }

    @{ Tab='Printers'; Name='Remove offline printers'; Mode='Inline'; Confirm=$true
       Help='Deletes network printers that show Error or Offline (virtual printers like PDF are kept). Reinstall with the Install cards.'
       Script={
           $gone = Get-Printer | Where-Object {
               $_.Type -eq 'Local' -and $_.PortName -notmatch '^(PORTPROMPT|nul|FILE|AD_Port|Documents)' -and
               ($_.PrinterStatus -match 'Offline|Error') }
           if (-not $gone) { 'No offline or error printers found.'; return }
           foreach ($p in $gone) { Remove-Printer -Name $p.Name -ErrorAction SilentlyContinue; "Removed: $($p.Name) ($($p.PortName))" }
       } }

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

# One "Install" card for every printer in $PrinterCatalog
foreach ($pr in $PrinterCatalog) {
    $sources = (@($pr.Source) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $code = "Install-NetworkPrinter -Name '{0}' -IP '{1}' -Driver '{2}' -Source @({3})" -f $pr.Name, $pr.IP, $pr.Driver, $sources
    $Fixes += @{ Tab='Printers'; Name="Install $($pr.Name)"; Mode='Inline'; Icon=0xE749
                 Help="One-click install of $($pr.Name) at $($pr.IP): adds the $($pr.Driver) driver, the network port and the printer."
                 Script=[scriptblock]::Create($code) }
}

# ---------------------------------------------------------------------------
# 4. LOOK & FEEL
# ---------------------------------------------------------------------------
$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(17, 19, 26)
    Sidebar   = [System.Drawing.Color]::FromArgb(23, 26, 35)
    Panel     = [System.Drawing.Color]::FromArgb(28, 32, 43)
    Card      = [System.Drawing.Color]::FromArgb(34, 39, 52)
    CardHover = [System.Drawing.Color]::FromArgb(44, 51, 69)
    Accent    = [System.Drawing.Color]::FromArgb(56, 132, 255)
    Accent2   = [System.Drawing.Color]::FromArgb(0, 200, 170)
    Warn      = [System.Drawing.Color]::FromArgb(255, 159, 67)
    Text      = [System.Drawing.Color]::FromArgb(236, 239, 245)
    Muted     = [System.Drawing.Color]::FromArgb(140, 148, 166)
    Console   = [System.Drawing.Color]::FromArgb(12, 14, 19)
    Ok        = [System.Drawing.Color]::FromArgb(46, 204, 113)
    Err       = [System.Drawing.Color]::FromArgb(255, 99, 99)
}

# Icon font: Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on Windows 10
$IconFontName = 'Segoe MDL2 Assets'
$installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
if ($installed -contains 'Segoe Fluent Icons') { $IconFontName = 'Segoe Fluent Icons' }
function New-IconFont([float]$Size) { New-Object System.Drawing.Font($IconFontName, $Size) }
function New-UiFont([float]$Size, [string]$Style = 'Regular') {
    New-Object System.Drawing.Font('Segoe UI', $Size, [System.Drawing.FontStyle]$Style)
}

# Icons for each page and each fix (hex code points in the icon font)
$PageIcons = @{
    'Disk & Cleanup'    = 0xEDA2
    'System Repair'     = 0xE90F
    'Network'           = 0xE968
    'Outlook & Office'  = 0xE715
    'Printers'          = 0xE749
    'Info'              = 0xE946
}
$FixIcons = @{
    'Disk space summary'              = 0xEDA2
    'Largest folders in user profile' = 0xE8B7
    'Outlook cache (.ost) sizes'      = 0xE715
    'Clear temp files'                = 0xE74D
    'Empty Recycle Bin'               = 0xE74D
    'Windows Disk Cleanup (auto)'     = 0xE90F
    'Clean component store (WinSxS)'  = 0xE7B8
    'Turn off hibernation'            = 0xE7E8
    'Install / open WizTree'          = 0xE9D2
    'System File Checker (SFC)'       = 0xEA18
    'DISM repair image'               = 0xE90F
    'Check disk (online scan)'        = 0xE721
    'Reset Windows Update'            = 0xE895
    'Restart Explorer'                = 0xE72C
    'Group Policy update'             = 0xE713
    'Sync Windows time'               = 0xE823
    'IP configuration'                = 0xE968
    'Internet & DNS test'             = 0xE774
    'Flush DNS + renew IP'            = 0xE72C
    'Reset network stack'             = 0xE7BA
    'Saved Wi-Fi networks'            = 0xE701
    'Clear Teams cache'               = 0xE716
    'Rebuild Outlook profile'         = 0xE715
    'Restore previous Outlook profile'= 0xE7A7
    'Open Outlook in Safe Mode'       = 0xEA18
    'Reset Outlook navigation pane'   = 0xE72C
    'Clear Outlook RoamCache'         = 0xE74D
    'Remove offline printers'         = 0xE711
    'Office Quick Repair'             = 0xE90F
    'Fix stuck print queue'           = 0xE749
    'List printers'                   = 0xE8FD
    'Computer summary'                = 0xE7F4
    'Pending restart?'                = 0xE777
    'Last 10 updates'                 = 0xE896
    'Recent critical errors'          = 0xE7BA
}
function Get-Glyph([int]$Code) { [string][char]$Code }
$Dot  = [string][char]0x00B7   # middle dot
$Play = [string][char]0x25B6   # play arrow
$Tick = [string][char]0x2714   # check mark
$Cross= [string][char]0x2716   # cross

# ---------------------------------------------------------------------------
# 5. HELPERS
# ---------------------------------------------------------------------------
function Write-ToolkitLog([string]$Text) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$env:USERNAME] $Text" | Add-Content -Path $LogFile
}

function Add-Output([string]$Text, [System.Drawing.Color]$Color = $C.Text) {
    $box = $script:OutputBox
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $Color
    $box.AppendText($Text.TrimEnd() + "`r`n")
    $box.ScrollToCaret()
}

$script:RunningJobs = @{}

function Update-Status {
    if ($script:RunningJobs.Count) {
        $script:StatusLabel.Text = 'Running: ' + ($script:RunningJobs.Values -join ', ')
        $script:Busy.Visible = $true
    } else {
        $script:StatusLabel.Text = "Ready  $Dot  Click a card to run it  $Dot  Orange cards ask before changing anything"
        $script:Busy.Visible = $false
    }
}

function Invoke-Fix($Fix) {
    if ($Fix.Confirm) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$($Fix.Help)`n`nRun '$($Fix.Name)' now?", $ToolkitName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Write-ToolkitLog "RUN  $($Fix.Name)"
    Add-Output "`r`n$Play $($Fix.Name)   [$(Get-Date -Format 'HH:mm:ss')]" $C.Accent

    if ($Fix.Mode -eq 'Window') {
        $body  = $Prelude + "`n" + $Fix.Script.ToString() +
                 "`nWrite-Host `"`n--- Finished. You can close this window. ---`" -ForegroundColor Green"
        $title = "`$Host.UI.RawUI.WindowTitle = '$ToolkitName - $($Fix.Name)'`n"
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', (ConvertTo-EncodedCommand ($title + $body)))
        Add-Output '  Opened in a separate window so you can follow the progress.' $C.Muted
    } else {
        $job = Start-Job -ScriptBlock $Fix.Script -InitializationScript ([scriptblock]::Create($Prelude))
        $script:RunningJobs[$job.Id] = $Fix.Name
        Update-Status
    }
}

# Builds one clickable card: icon, title and a one-line description
function New-FixCard($Fix) {
    $isRisky = [bool]$Fix.Confirm
    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object System.Drawing.Size(262, 92)
    $card.Margin = New-Object System.Windows.Forms.Padding(8)
    $card.BackColor = $C.Card
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Tag = $Fix

    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Dock = 'Left'; $stripe.Width = 4
    $stripe.BackColor = if ($isRisky) { $C.Warn } else { $C.Accent }

    $icon = New-Object System.Windows.Forms.Label
    $icon.Text = Get-Glyph $(if ($Fix.Icon) { $Fix.Icon } elseif ($FixIcons[$Fix.Name]) { $FixIcons[$Fix.Name] } else { 0xE90F })
    $icon.Font = New-IconFont 20
    $icon.ForeColor = if ($isRisky) { $C.Warn } else { $C.Accent }
    $icon.Location = New-Object System.Drawing.Point(16, 14)
    $icon.Size = New-Object System.Drawing.Size(36, 36)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Fix.Name
    $title.Font = New-UiFont 10.5 'Bold'
    $title.ForeColor = $C.Text
    $title.Location = New-Object System.Drawing.Point(58, 12)
    $title.Size = New-Object System.Drawing.Size(196, 22)
    $title.AutoEllipsis = $true

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $Fix.Help
    $desc.Font = New-UiFont 8.5
    $desc.ForeColor = $C.Muted
    $desc.Location = New-Object System.Drawing.Point(58, 36)
    $desc.Size = New-Object System.Drawing.Size(196, 48)
    $desc.AutoEllipsis = $true

    $badge = New-Object System.Windows.Forms.Label
    $badge.Font = New-UiFont 7.5 'Bold'
    $badge.AutoSize = $true
    $badge.Location = New-Object System.Drawing.Point(16, 66)
    if ($isRisky)              { $badge.Text = 'CONFIRM'; $badge.ForeColor = $C.Warn }
    elseif ($Fix.Mode -eq 'Window') { $badge.Text = 'WINDOW';  $badge.ForeColor = $C.Accent2 }
    else                       { $badge.Text = '';        }

    $card.Controls.AddRange(@($badge, $desc, $title, $icon, $stripe))
    $script:Tips.SetToolTip($card, $Fix.Help)

    $enter = { $p = if ($this -is [System.Windows.Forms.Panel] -and $this.Tag) { $this } else { $this.Parent }; $p.BackColor = $C.CardHover }
    $leave = { $p = if ($this -is [System.Windows.Forms.Panel] -and $this.Tag) { $this } else { $this.Parent }; $p.BackColor = $C.Card }
    $click = { $p = if ($this -is [System.Windows.Forms.Panel] -and $this.Tag) { $this } else { $this.Parent }; Invoke-Fix $p.Tag }
    foreach ($ctl in @($card, $icon, $title, $desc, $badge)) {
        $ctl.Add_MouseEnter($enter); $ctl.Add_MouseLeave($leave); $ctl.Add_Click($click)
        if ($ctl -ne $card) { $ctl.Cursor = [System.Windows.Forms.Cursors]::Hand }
    }
    return $card
}

# ---------------------------------------------------------------------------
# 6. THE WINDOW
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "$ToolkitName - Toolkit  v$ToolkitVersion"
$form.Size = New-Object System.Drawing.Size(1180, 820)
$form.MinimumSize = New-Object System.Drawing.Size(980, 680)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = New-UiFont 9.5
$script:Tips = New-Object System.Windows.Forms.ToolTip
$Tips.AutoPopDelay = 15000

# ----- Header -----
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 86
$header.Add_Paint({
    param($s, $e)
    $rect = $s.ClientRectangle
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect, [System.Drawing.Color]::FromArgb(30, 64, 175), [System.Drawing.Color]::FromArgb(13, 148, 136), 0.0)
    $e.Graphics.FillRectangle($brush, $rect)
    $brush.Dispose()
})

$logo = New-Object System.Windows.Forms.Label
$logo.Text = Get-Glyph 0xE90F
$logo.Font = New-IconFont 26
$logo.ForeColor = [System.Drawing.Color]::White
$logo.BackColor = [System.Drawing.Color]::Transparent
$logo.Location = New-Object System.Drawing.Point(22, 22)
$logo.Size = New-Object System.Drawing.Size(48, 44)

$appTitle = New-Object System.Windows.Forms.Label
$appTitle.Text = $ToolkitName
$appTitle.Font = New-UiFont 20 'Bold'
$appTitle.ForeColor = [System.Drawing.Color]::White
$appTitle.BackColor = [System.Drawing.Color]::Transparent
$appTitle.AutoSize = $true
$appTitle.Location = New-Object System.Drawing.Point(74, 12)

$appSub = New-Object System.Windows.Forms.Label
$appSub.Text = "TOOLKIT  $Dot  v$ToolkitVersion  $Dot  Quick fixes for Windows workstations"
$appSub.Font = New-UiFont 9
$appSub.ForeColor = [System.Drawing.Color]::FromArgb(210, 225, 255)
$appSub.BackColor = [System.Drawing.Color]::Transparent
$appSub.AutoSize = $true
$appSub.Location = New-Object System.Drawing.Point(78, 52)

# Machine info on the right of the header
$os   = Get-CimInstance Win32_OperatingSystem
$cDrv = Get-PSDrive C
$freePct = [math]::Round(100 * $cDrv.Free / ($cDrv.Used + $cDrv.Free))
$sysInfo = New-Object System.Windows.Forms.Label
$sysInfo.Text = "$env:COMPUTERNAME   $Dot   $env:USERNAME`n" +
                ($os.Caption -replace 'Microsoft ', '') + "   $Dot   C: $([math]::Round($cDrv.Free/1GB,1)) GB free ($freePct%)"
$sysInfo.Font = New-UiFont 9
$sysInfo.ForeColor = [System.Drawing.Color]::White
$sysInfo.BackColor = [System.Drawing.Color]::Transparent
$sysInfo.TextAlign = 'MiddleRight'
$sysInfo.Dock = 'Right'
$sysInfo.Width = 420
$sysInfo.Padding = New-Object System.Windows.Forms.Padding(0, 0, 22, 0)
$header.Controls.AddRange(@($sysInfo, $appSub, $appTitle, $logo))

# ----- Sidebar -----
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = 'Left'; $sidebar.Width = 210
$sidebar.BackColor = $C.Sidebar
$sidebar.Padding = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)

# ----- Page area (cards) -----
$pageHost = New-Object System.Windows.Forms.Panel
$pageHost.Dock = 'Fill'
$pageHost.BackColor = $C.Bg
$pageHost.Padding = New-Object System.Windows.Forms.Padding(18, 12, 12, 6)

$pageTitle = New-Object System.Windows.Forms.Label
$pageTitle.Dock = 'Top'; $pageTitle.Height = 40
$pageTitle.Font = New-UiFont 15 'Bold'
$pageTitle.ForeColor = $C.Text

$pages = @{}
$navButtons = @()
$tabNames = $Fixes | ForEach-Object { $_.Tab } | Select-Object -Unique

function Show-Page([string]$Name) {
    foreach ($k in $pages.Keys) { $pages[$k].Visible = ($k -eq $Name) }
    $count = @($Fixes | Where-Object { $_.Tab -eq $Name }).Count
    $pageTitle.Text = "$Name  ($count)"
    foreach ($b in $script:NavButtons) {
        $active = ($b.Tag -eq $Name)
        $b.BackColor = if ($active) { $C.Panel } else { $C.Sidebar }
        $b.Controls[0].Visible = $active                                     # accent marker
        $b.Controls[2].ForeColor = if ($active) { $C.Text } else { $C.Muted } # label
        $b.Controls[2].Font = if ($active) { New-UiFont 10.5 'Bold' } else { New-UiFont 10.5 }
    }
}

foreach ($tabName in $tabNames) {
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.AutoScroll = $true
    $flow.BackColor = $C.Bg
    $flow.Visible = $false
    foreach ($fix in ($Fixes | Where-Object { $_.Tab -eq $tabName })) { $flow.Controls.Add((New-FixCard $fix)) }
    $pages[$tabName] = $flow
    $pageHost.Controls.Add($flow)
}
$pageHost.Controls.Add($pageTitle)

# Navigation buttons (added in reverse because Dock=Top stacks upwards)
$script:NavButtons = @()
$reversedTabs = @($tabNames); [array]::Reverse($reversedTabs)
foreach ($tabName in $reversedTabs) {
    $nav = New-Object System.Windows.Forms.Button
    $nav.Tag = $tabName
    $nav.Dock = 'Top'; $nav.Height = 48
    $nav.FlatStyle = 'Flat'
    $nav.FlatAppearance.BorderSize = 0
    $nav.FlatAppearance.MouseOverBackColor = $C.Panel
    $nav.TextAlign = 'MiddleLeft'
    $nav.Font = New-UiFont 10.5
    $nav.Cursor = [System.Windows.Forms.Cursors]::Hand

    # Icon and label are drawn with child labels so the icon uses the icon font
    $navIcon = New-Object System.Windows.Forms.Label
    $navIcon.Text = Get-Glyph $PageIcons[$tabName]
    $navIcon.Font = New-IconFont 13
    $navIcon.ForeColor = $C.Accent
    $navIcon.BackColor = [System.Drawing.Color]::Transparent
    $navIcon.Location = New-Object System.Drawing.Point(24, 14)
    $navIcon.Size = New-Object System.Drawing.Size(26, 22)
    $navLabel = New-Object System.Windows.Forms.Label
    $navLabel.Text = $tabName
    $navLabel.Font = New-UiFont 10.5
    $navLabel.BackColor = [System.Drawing.Color]::Transparent
    $navLabel.ForeColor = $C.Text
    $navLabel.Location = New-Object System.Drawing.Point(58, 13)
    $navLabel.AutoSize = $true

    $marker = New-Object System.Windows.Forms.Panel
    $marker.Dock = 'Left'; $marker.Width = 4
    $marker.BackColor = $C.Accent
    $marker.Visible = $false
    $nav.Controls.Add($marker)          # Controls[0] = active marker
    $nav.Controls.Add($navIcon)
    $nav.Controls.Add($navLabel)

    $go = { $b = if ($this -is [System.Windows.Forms.Button]) { $this } else { $this.Parent }; Show-Page $b.Tag }
    $nav.Add_Click($go); $navIcon.Add_Click($go); $navLabel.Add_Click($go)
    $navIcon.Cursor = [System.Windows.Forms.Cursors]::Hand
    $navLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $sidebar.Controls.Add($nav)
    $script:NavButtons += $nav
}

$sideFooter = New-Object System.Windows.Forms.Label
$sideFooter.Dock = 'Bottom'; $sideFooter.Height = 54
$sideFooter.Text = "Built by Ihsan`nLog: ProgramData\IhsanTechFix"
$sideFooter.Font = New-UiFont 8
$sideFooter.ForeColor = $C.Muted
$sideFooter.Padding = New-Object System.Windows.Forms.Padding(22, 0, 0, 10)
$sideFooter.TextAlign = 'BottomLeft'
$sidebar.Controls.Add($sideFooter)

# ----- Output console -----
$outPanel = New-Object System.Windows.Forms.Panel
$outPanel.Dock = 'Bottom'; $outPanel.Height = 270
$outPanel.BackColor = $C.Panel
$outPanel.Padding = New-Object System.Windows.Forms.Padding(14, 0, 14, 12)

$outBar = New-Object System.Windows.Forms.Panel
$outBar.Dock = 'Top'; $outBar.Height = 42

$outTitle = New-Object System.Windows.Forms.Label
$outTitle.Text = 'Output'
$outTitle.Font = New-UiFont 11 'Bold'
$outTitle.ForeColor = $C.Text
$outTitle.AutoSize = $true
$outTitle.Location = New-Object System.Drawing.Point(0, 11)

function New-SmallButton([string]$Text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size(96, 28)
    $b.Anchor = 'Top, Right'
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 68, 88)
    $b.FlatAppearance.MouseOverBackColor = $C.CardHover
    $b.BackColor = $C.Card
    $b.ForeColor = $C.Text
    $b.Font = New-UiFont 9
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
$copyBtn  = New-SmallButton 'Copy'
$clearBtn = New-SmallButton 'Clear'
$logBtn   = New-SmallButton 'Open log'
$outBar.Add_Resize({
    $w = $outBar.ClientSize.Width
    $logBtn.Location   = New-Object System.Drawing.Point(($w - 96), 7)
    $clearBtn.Location = New-Object System.Drawing.Point(($w - 200), 7)
    $copyBtn.Location  = New-Object System.Drawing.Point(($w - 304), 7)
})
$copyBtn.Add_Click({ if ($script:OutputBox.TextLength) { [System.Windows.Forms.Clipboard]::SetText($script:OutputBox.Text); $script:StatusLabel.Text = 'Output copied to clipboard.' } })
$clearBtn.Add_Click({ $script:OutputBox.Clear() })
$logBtn.Add_Click({ if (Test-Path $LogFile) { notepad.exe $LogFile } })
$outBar.Controls.AddRange(@($outTitle, $copyBtn, $clearBtn, $logBtn))

$script:OutputBox = New-Object System.Windows.Forms.RichTextBox
$OutputBox.Dock = 'Fill'
$OutputBox.ReadOnly = $true
$OutputBox.BorderStyle = 'None'
$OutputBox.BackColor = $C.Console
$OutputBox.ForeColor = $C.Text
$OutputBox.Font = New-Object System.Drawing.Font('Cascadia Mono', 9.5)
if ($OutputBox.Font.Name -ne 'Cascadia Mono') { $OutputBox.Font = New-Object System.Drawing.Font('Consolas', 9.5) }
$OutputBox.WordWrap = $false

$outPanel.Controls.Add($OutputBox)
$outPanel.Controls.Add($outBar)

# ----- Status bar -----
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 30
$statusBar.BackColor = $C.Sidebar

$script:StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.Dock = 'Fill'
$StatusLabel.TextAlign = 'MiddleLeft'
$StatusLabel.Padding = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$StatusLabel.ForeColor = $C.Muted
$StatusLabel.Font = New-UiFont 9

$script:Busy = New-Object System.Windows.Forms.ProgressBar
$Busy.Style = 'Marquee'
$Busy.MarqueeAnimationSpeed = 30
$Busy.Dock = 'Right'; $Busy.Width = 160
$Busy.Visible = $false
$statusBar.Controls.Add($StatusLabel)
$statusBar.Controls.Add($Busy)

# Dock order: header, status bar, sidebar, output, then the page area fills the rest
$form.Controls.Add($pageHost)
$form.Controls.Add($outPanel)
$form.Controls.Add($sidebar)
$form.Controls.Add($statusBar)
$form.Controls.Add($header)

# Collect results from background jobs without freezing the window
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    foreach ($id in @($script:RunningJobs.Keys)) {
        $job = Get-Job -Id $id -ErrorAction SilentlyContinue
        if ($job -and $job.State -ne 'Running') {
            $name = $script:RunningJobs[$id]
            $out  = Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable errs 2>&1 | Out-String -Width 220
            if ($out.Trim()) { Add-Output $out }
            if ($errs) { Add-Output ($errs | Out-String) $C.Err }
            if ($job.State -eq 'Completed') {
                Add-Output "$Tick $name finished" $C.Ok; Write-ToolkitLog "DONE $name"
            } else {
                Add-Output "$Cross $name $($job.State)" $C.Err; Write-ToolkitLog "$($job.State) $name"
            }
            Remove-Job $job -Force
            $script:RunningJobs.Remove($id)
            Update-Status
        }
    }
})

$form.Add_Shown({
    Show-Page @($tabNames)[0]
    $w = $outBar.ClientSize.Width
    $logBtn.Location   = New-Object System.Drawing.Point(($w - 96), 7)
    $clearBtn.Location = New-Object System.Drawing.Point(($w - 200), 7)
    $copyBtn.Location  = New-Object System.Drawing.Point(($w - 304), 7)
    Update-Status
    Add-Output "$ToolkitName - Toolkit v$ToolkitVersion  $Dot  running as Administrator on $env:COMPUTERNAME" $C.Accent2
    Add-Output "Log file: $LogFile" $C.Muted
    $timer.Start()
})
Write-ToolkitLog 'Toolkit opened'

[void]$form.ShowDialog()
$timer.Stop()
Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
