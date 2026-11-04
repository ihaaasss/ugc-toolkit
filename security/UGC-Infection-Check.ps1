<#
.SYNOPSIS
    UGC Infection Check - READ-ONLY triage of a PC that may have opened a malicious file.
    Changes nothing. Collects the usual footprints of WhatsApp/ZIP "invoice" malware
    (info-stealers / remote-access tools) into one report and flags suspicious items with !!.

    Checks:
      1. Recently created/changed executables & scripts in user folders, AppData, Temp, ProgramData, Public
      2. Auto-start entries: Run/RunOnce (all users), Startup folders, Winlogon
      3. Scheduled tasks and services that point to user-writable folders or script hosts
      4. Running processes outside Windows/Program Files, unsigned, or with suspicious command lines
      5. Network connections owned by those processes
      6. Defender status and recent detections, local administrators
      7. Remote-access / screen-sharing tools (AnyDesk, ScreenConnect, NetSupport, RustDesk ...)
      8. Which programs used the webcam, microphone or screen capture, and when

.USAGE (as Administrator)
    powershell -ExecutionPolicy Bypass -File .\UGC-Infection-Check.ps1            # last 14 days
    powershell -ExecutionPolicy Bypass -File .\UGC-Infection-Check.ps1 -Days 30

    Report: C:\ProgramData\UGC\Triage\<PC>_<date>.txt  (also opened in Notepad)
#>
param([int]$Days = 14)

$ErrorActionPreference = 'SilentlyContinue'
$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }

$OutDir = 'C:\ProgramData\UGC\Triage'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$Report = Join-Path $OutDir ('{0}_{1:yyyyMMdd-HHmm}.txt' -f $env:COMPUTERNAME, (Get-Date))
$Since  = (Get-Date).AddDays(-$Days)
$script:Flags = 0

function W([string]$t = '') { Add-Content -Path $Report -Value $t; Write-Host $t }
$script:Findings = @()
$script:Top = @()
function Flag([string]$t, [string]$Kind = 'Info', [string]$Target = '', [string]$File = '', [switch]$High) {
    $script:Flags++
    if ($High) { W "  !!! $t"; $script:Top += $t } else { W "  !! $t" }
    # Machine-readable copy for UGC-Infection-Cleanup.ps1
    $script:Findings += [pscustomobject]@{ Severity = $(if ($High) { 'HIGH' } else { 'check' }); Kind = $Kind
                                           Detail = (($t -replace '\s+', ' ').Trim()); Target = $Target; File = $File }
}
function Head([string]$t)   { W ''; W ('=' * 90); W "  $t"; W ('=' * 90) }

# Folders a normal program never runs from
$UserWritable = '\\Users\\[^\\]+\\(AppData|Downloads|Desktop|Documents|Music|Pictures|Videos)\\|\\Temp\\|\\ProgramData\\|\\Users\\Public\\|\\Windows\\Temp\\'
$ScriptHosts  = 'mshta|wscript|cscript|rundll32|regsvr32|powershell|pwsh|cmd\.exe|certutil|bitsadmin|msiexec'
# Known-good tool/app folders that would otherwise flood the report
$Noise        = '\\node_modules\\|\\npm-cache\\|\\Mozilla\\Firefox\\|\\OpenAI\\Codex\\|\\Claude-Data\\|\\IhsanTechFix|\\\.vscode\\|\\pip\\|\\Python\d*\\|' +
                '\\Windows Defender\\|\\DriverStore\\|\\Microsoft\\WindowsApps\\|\\NVIDIA|\\JetBrains\\|\\Docker|\\Package Cache\\|\\\.?venv\\|\\site-packages\\'
# Malware loves Windows-sounding names in user folders (e.g. AppData\Local\Updates\WindowsService.exe)
$FakeName     = '^(windows|microsoft|svchost|system|winlogon|lsass|csrss|explorer|services?|update[rs]?|runtime|host|chrome|msedge|defender|security)[^\\]*\.exe$'
$FakeFolder   = '\\AppData\\(Local|Roaming)\\(Updates?|Windows|Microsoft Windows|System|Service[s]?)\\'
$HotFolders   = '\\(Downloads|Desktop|Documents|Temp|Public|Start Menu)\\'
$BadCmd       = '-enc|-encodedcommand|-w(indowstyle)?\s+h(idden)?|frombase64string|downloadstring|downloadfile|invoke-expression|\biex\b|http[s]?://|\.hta|\.js\b|\.vbs\b|javascript:'

function Get-SigStatus([string]$path) {
    if ($path -match '\\Microsoft\\WindowsApps\\') { return 'store app' }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 'missing' }
    $s = Get-AuthenticodeSignature -LiteralPath $path
    if ($s.Status -eq 'Valid') { return "signed: $($s.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1')" }
    return "UNSIGNED ($($s.Status))"
}
function Test-HighRisk([string]$exe) {
    # Program in a user-writable folder that is unsigned, or pretends to be part of Windows
    if (-not $exe -or $exe -notmatch $UserWritable -or $exe -match $Noise) { return $false }
    $sig = Get-SigStatus $exe
    if ($sig -like 'signed:*') { return $false }          # validly signed by a publisher
    if ((Split-Path $exe -Leaf) -match $FakeName -or $exe -match $FakeFolder) { return $true }
    return ($sig -like 'UNSIGNED*')
}
function Get-ExePath([string]$cmd) {
    if (-not $cmd) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
    if ($c -match '^"([^"]+)"') { return $Matches[1] }
    if ($c -match '^(.+?\.(exe|com|bat|cmd|vbs|js|hta|ps1|dll|scr))(\s|,|$)') { return $Matches[1] }
    return ($c -split '\s')[0]
}

W "UGC INFECTION CHECK  -  $env:COMPUTERNAME  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
W "Run by: $env:USERNAME    Looking back: $Days days (since $($Since.ToString('yyyy-MM-dd')))"
$os = Get-CimInstance Win32_OperatingSystem
W "OS: $($os.Caption) build $($os.BuildNumber)    Last boot: $($os.LastBootUpTime)"

# ------------------------------------------------------------------ 1. recent files
Head "1. RECENT EXECUTABLES / SCRIPTS / ARCHIVES IN USER-WRITABLE FOLDERS (since $($Since.ToString('yyyy-MM-dd')))"
$riskyExt = '.exe','.dll','.scr','.com','.pif','.cpl','.msi','.js','.jse','.vbs','.vbe','.wsf','.hta','.bat','.cmd','.ps1','.lnk','.iso','.img','.vhd'
$arcExt   = '.zip','.rar','.7z','.cab'
$roots = @()
foreach ($u in Get-ChildItem 'C:\Users' -Directory -Force | Where-Object { $_.Name -notin 'Default','Default User','All Users' }) {
    $roots += 'Downloads','Desktop','Documents','AppData\Roaming','AppData\Local\Temp' |
              ForEach-Object { Join-Path $u.FullName $_ }
    $roots += Get-ChildItem (Join-Path $u.FullName 'AppData\Local') -Directory -Force |
              Where-Object { $_.Name -notin 'Microsoft','Packages','Google','Mozilla','Programs','D3DSCache','NVIDIA','Temp' } |
              Select-Object -ExpandProperty FullName
    $roots += Get-ChildItem (Join-Path $u.FullName 'AppData\Local\Packages') -Directory -Filter '*WhatsApp*' -Force |
              Select-Object -ExpandProperty FullName
}
$roots += 'C:\ProgramData','C:\Users\Public','C:\Windows\Temp'
$found = foreach ($r in ($roots | Where-Object { Test-Path $_ } | Sort-Object -Unique)) {
    Get-ChildItem -LiteralPath $r -File -Recurse -Force |
        Where-Object { $_.LastWriteTime -ge $Since -and (($riskyExt + $arcExt) -contains $_.Extension.ToLower()) -and
                       $_.FullName -notmatch '\\ProgramData\\(Microsoft|Package Cache|UGC|IhsanTechFix|regid|Microsoft OneDrive)' -and
                       $_.FullName -notmatch $Noise }
}
$found = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 300
if (-not $found) { W '  (none)' }
foreach ($f in $found) {
    $line = '{0:yyyy-MM-dd HH:mm}  {1,9:N0} KB  {2}' -f $f.LastWriteTime, ($f.Length / 1KB), $f.FullName
    $ext  = $f.Extension.ToLower()
    if ($arcExt -contains $ext) { W "     $line" ; continue }
    if ($ext -in '.exe','.dll','.scr','.com','.cpl','.msi') {
        $sig = Get-SigStatus $f.FullName
        $hi  = ($ext -ne '.dll') -and (Test-HighRisk $f.FullName)
        if ($hi) { Flag "$line   [$sig]" 'File' $f.FullName $f.FullName -High }
        elseif ($sig -like 'UNSIGNED*') { Flag "$line   [$sig]" 'File' $f.FullName $f.FullName }
        else { W "     $line   [$sig]" }
    } elseif ($ext -eq '.lnk') {
        $t = (New-Object -ComObject WScript.Shell).CreateShortcut($f.FullName)
        $tl = "$($t.TargetPath) $($t.Arguments)"
        if ($tl -match $ScriptHosts -and $tl -match $BadCmd) { Flag "$line   -> $tl" 'File' $f.FullName $f.FullName }
    } else {
        # Scripts: apps ship thousands of .js/.ps1 - only flag them where users drop files,
        # and always flag the types normal apps never use (.vbs/.hta/.wsf/.jse)
        if ($ext -in '.vbs','.vbe','.jse','.wsf','.hta') { Flag $line 'File' $f.FullName $f.FullName -High }
        elseif ($f.FullName -match $HotFolders)       { Flag $line 'File' $f.FullName $f.FullName }
    }
}

# ------------------------------------------------------------------ 2. autoruns
Head '2. AUTO-START ENTRIES (Run / RunOnce / Startup folders / Winlogon)'
$runKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')
foreach ($sid in Get-ChildItem 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }) {
    $runKeys += "Registry::HKEY_USERS\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run"
    $runKeys += "Registry::HKEY_USERS\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\RunOnce"
}
foreach ($k in $runKeys) {
    $props = Get-ItemProperty -Path $k
    if (-not $props) { continue }
    foreach ($pr in $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
        $cmd  = [string]$pr.Value
        $exe  = Get-ExePath $cmd
        $line = "$($k -replace 'Registry::','')  |  $($pr.Name) = $cmd"
        $sig  = Get-SigStatus $exe
        if (($cmd -match $ScriptHosts -and $cmd -match $BadCmd) -or (Test-HighRisk $exe)) {
            Flag "$line   [$sig]" 'RunValue' "$k|$($pr.Name)" $exe -High
        } elseif ($sig -like 'UNSIGNED*') { Flag "$line   [$sig]" 'RunValue' "$k|$($pr.Name)" $exe }
        elseif ($exe -match $UserWritable) { W "  ?  $line   [$sig]" }
        else { W "     $line" }
    }
}
$startupDirs = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp') +
               (Get-ChildItem 'C:\Users' -Directory -Force | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' })
foreach ($d in $startupDirs | Where-Object { Test-Path $_ }) {
    foreach ($f in Get-ChildItem $d -File -Force | Where-Object { $_.Name -ne 'desktop.ini' }) {
        $line = "Startup folder: $($f.FullName)  ($($f.LastWriteTime.ToString('yyyy-MM-dd')))"
        if ($f.Extension -match '\.(js|jse|vbs|vbe|wsf|hta)$') { Flag $line 'File' $f.FullName $f.FullName -High; continue }
        if ($f.Extension -match '\.(bat|cmd|ps1|exe)$') { Flag $line 'File' $f.FullName $f.FullName; continue }
        if ($f.Extension -eq '.lnk') {
            $t = (New-Object -ComObject WScript.Shell).CreateShortcut($f.FullName)
            $tl = "$($t.TargetPath) $($t.Arguments)"
            if (($tl -match $ScriptHosts -and $tl -match $BadCmd) -or (Test-HighRisk $t.TargetPath)) {
                Flag "$line  ->  $tl" 'File' $f.FullName $f.FullName -High; continue
            }
            W "     $line  ->  $($t.TargetPath)"; continue
        }
        W "     $line"
    }
}
$wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if ($wl.Shell -and $wl.Shell -ne 'explorer.exe') { Flag "Winlogon Shell = $($wl.Shell)" }
if ($wl.Userinit -and $wl.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { Flag "Winlogon Userinit = $($wl.Userinit)" }

# ------------------------------------------------------------------ 3. tasks & services
Head '3. SCHEDULED TASKS AND SERVICES POINTING TO UNUSUAL LOCATIONS'
foreach ($t in Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
    foreach ($a in $t.Actions) {
        $cmd = "$($a.Execute) $($a.Arguments)".Trim()
        if (-not $cmd) { continue }
        if ($t.TaskName -like 'UGC Archive Guard*' -or $t.TaskName -like 'IhsanTechFix*') { continue }
        $exe  = Get-ExePath $a.Execute
        $line = "Task $($t.TaskPath)$($t.TaskName)  ->  $cmd   [$(Get-SigStatus $exe)]"
        if (($cmd -match $ScriptHosts -and $cmd -match $BadCmd) -or (Test-HighRisk $exe)) {
            Flag $line 'Task' "$($t.TaskPath)|$($t.TaskName)" $exe -High
        } elseif ($exe -match $UserWritable -and $exe -notmatch $Noise) { W "  ?  $line" }
        elseif ($t.Date -and ([datetime]$t.Date) -ge $Since) { W "  ?  (new) $line" }
    }
}
foreach ($s in Get-CimInstance Win32_Service) {
    $path = [string]$s.PathName; $exe = Get-ExePath $path
    if ($exe -match $Noise) { continue }
    $line = "Service $($s.Name) [$($s.State)/$($s.StartMode)]  ->  $path   [$(Get-SigStatus $exe)]"
    if (($path -match $ScriptHosts -and $path -match $BadCmd) -or (Test-HighRisk $exe)) { Flag $line 'Service' $s.Name $exe -High }
    elseif ($exe -match $UserWritable) { W "  ?  $line" }
}

# ------------------------------------------------------------------ 4. processes
Head '4. RUNNING PROCESSES OUTSIDE WINDOWS / PROGRAM FILES, UNSIGNED, OR WITH SUSPICIOUS COMMAND LINES'
$suspectPids = @()
foreach ($pr in Get-CimInstance Win32_Process) {
    $path = [string]$pr.ExecutablePath; $cl = [string]$pr.CommandLine
    if (-not $path) { continue }
    $standard = $path -match '^C:\\(Windows|Program Files|Program Files \(x86\))\\'
    if ($cl -match '-e(nc|ncodedcommand)?\s+([A-Za-z0-9+/=]{16,})') {
        try { $cl += "   [decoded: " + (([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[2]))) -replace '\s+', ' ').Substring(0, [Math]::Min(150, ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[2]))).Length)) + "]" } catch {}
    }
    if ($cl -match 'IhsanTechFix|Trouble Ticket|\\UGC\\ArchiveGuard|UGC-Infection|UGC-Harden|UGC-Release') { continue }   # our own UGC tools
    $badLine  = ($pr.Name -match $ScriptHosts -and $cl -match $BadCmd)
    if ($standard -and -not $badLine) { continue }
    $sig = Get-SigStatus $path
    $owner = (Invoke-CimMethod -InputObject $pr -MethodName GetOwner).User
    $line = "PID $($pr.ProcessId) [$owner] $path   [$sig]"
    if ($badLine -or (Test-HighRisk $path)) {
        Flag "$line`n       cmd: $cl" 'Process' $pr.ProcessId $path -High; $suspectPids += $pr.ProcessId
    } elseif ($path -match $UserWritable) {
        W "  ?  $line"; $suspectPids += $pr.ProcessId
    }
}

# ------------------------------------------------------------------ 5. network
Head '5. INTERNET CONNECTIONS FROM THOSE PROCESSES'
$conns = Get-NetTCPConnection -State Established | Where-Object {
    $_.RemoteAddress -notmatch '^(127\.|::1|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' }
$hits = $conns | Where-Object { $suspectPids -contains $_.OwningProcess }
if (-not $hits) { W '  (none from flagged processes)' }
foreach ($c in $hits) {
    $pn = (Get-Process -Id $c.OwningProcess).ProcessName
    Flag "$pn (PID $($c.OwningProcess)) -> $($c.RemoteAddress):$($c.RemotePort)" 'Process' $c.OwningProcess ((Get-Process -Id $c.OwningProcess).Path)
}

# ------------------------------------------------------------------ 6. defender & accounts
Head '6. DEFENDER AND LOCAL ADMINISTRATORS'
$mp = Get-MpComputerStatus
if ($mp) {
    W "  Defender real-time: $($mp.RealTimeProtectionEnabled)   Signatures: $($mp.AntivirusSignatureLastUpdated)   Last quick scan: $($mp.QuickScanEndTime)"
    if (-not $mp.RealTimeProtectionEnabled) { Flag 'Defender real-time protection is OFF' }
    foreach ($d in Get-MpThreatDetection | Where-Object { $_.InitialDetectionTime -ge $Since }) {
        $name = (Get-MpThreat -ThreatID $d.ThreatID).ThreatName
        Flag "Defender detection $($d.InitialDetectionTime): $name  ->  $($d.Resources -join '; ')"
    }
} else { W '  Defender not available (another antivirus or disabled)' }
W '  Local Administrators:'
Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { W "     $($_.Name)  ($($_.ObjectClass))" }
foreach ($lu in Get-LocalUser | Where-Object { $_.Enabled }) {
    if ($lu.PasswordLastSet -and $lu.PasswordLastSet -ge $Since) { W "  ?  Local user '$($lu.Name)' password set $($lu.PasswordLastSet) (new account?)" }
}

# ------------------------------------------------------------------ 7. remote access tools
Head '7. REMOTE-ACCESS / SCREEN-SHARING TOOLS (often installed silently by attackers)'
$rat = 'anydesk|teamviewer|screenconnect|connectwise|rustdesk|netsupport|client32|atera|splashtop|ultraviewer|ultravnc|tightvnc|realvnc|winvnc|' +
       'ammyy|supremo|radmin|logmein|simplehelp|meshagent|tacticalrmm|remoteutilities|rutserv|rfusclient|zohoassist|getscreen|dwagent|aeroadmin|hoptodesk|parsec'
$ratHits = @()
foreach ($pr in Get-CimInstance Win32_Process | Where-Object { "$($_.Name) $($_.ExecutablePath)" -match $rat }) {
    $ratHits += @{ T = "RUNNING  $($pr.Name)  (PID $($pr.ProcessId))  $($pr.ExecutablePath)   [$(Get-SigStatus $pr.ExecutablePath)]"; K = 'Process'; G = "$($pr.ProcessId)"; F = $pr.ExecutablePath }
}
foreach ($s in Get-CimInstance Win32_Service | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $rat }) {
    $ratHits += @{ T = "SERVICE  $($s.DisplayName) [$($s.State)/$($s.StartMode)]  $($s.PathName)"; K = 'Service'; G = $s.Name; F = (Get-ExePath $s.PathName) }
}
$uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach ($sid in Get-ChildItem 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }) {
    $uninst += "Registry::HKEY_USERS\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
}
foreach ($app in Get-ItemProperty $uninst | Where-Object { $_.DisplayName -match $rat }) {
    $un = if ($app.QuietUninstallString) { $app.QuietUninstallString } else { $app.UninstallString }
    $ratHits += @{ T = "INSTALLED  $($app.DisplayName) $($app.DisplayVersion)  (install date: $($app.InstallDate))"; K = 'Uninstall'; G = "$un"; F = '' }
}
foreach ($u in Get-ChildItem 'C:\Users' -Directory -Force) {
    foreach ($f in Get-ChildItem (Join-Path $u.FullName 'Downloads'),(Join-Path $u.FullName 'AppData') -Recurse -File -Force -Include *.exe |
                   Where-Object { $_.Name -match $rat }) {
        $ratHits += @{ T = "FILE  $($f.FullName)  ($($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"; K = 'File'; G = $f.FullName; F = $f.FullName }
    }
}
if ($ratHits) {
    $done = @{}
    foreach ($h in $ratHits) { if ($done[$h.T]) { continue }; $done[$h.T] = 1; Flag $h.T $h.K $h.G $h.F }
    W '     -> If IT did not install these, remove them and treat the PC as compromised.'
} else { W '  (none found)' }

# ------------------------------------------------------------------ 8. webcam / microphone / screen use
Head '8. PROGRAMS THAT USED THE WEBCAM / MICROPHONE / SCREEN CAPTURE (Windows privacy log)'
W '  Windows records the last time each desktop program used these. Anything you do not recognise = !!'
$known = '\\(Microsoft|Windows|Program Files|Program Files \(x86\))\\|teams|zoom|webex|skype|chrome|msedge|firefox|whatsapp|obs'
foreach ($sid in Get-ChildItem 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }) {
    $user = try { (New-Object Security.Principal.SecurityIdentifier $sid.PSChildName).Translate([Security.Principal.NTAccount]).Value } catch { $sid.PSChildName }
    foreach ($cap in 'webcam','microphone','graphicsCaptureProgrammatic','graphicsCaptureWithoutBorder') {
        $base = "Registry::HKEY_USERS\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$cap\NonPackaged"
        foreach ($k in Get-ChildItem $base) {
            $v = Get-ItemProperty $k.PSPath
            if (-not $v.LastUsedTimeStart) { continue }
            $when = [datetime]::FromFileTime([int64]$v.LastUsedTimeStart)
            $app  = $k.PSChildName -replace '#', '\'
            $line = '{0,-12} last used {1:yyyy-MM-dd HH:mm}  by  {2}   ({3})' -f $cap, $when, $app, $user
            if ($app -match $UserWritable -or ($app -notmatch $known -and $when -ge $Since)) { Flag $line 'File' $app $app } else { W "     $line" }
        }
    }
}

# ------------------------------------------------------------------ summary
Head 'SUMMARY'
if ($script:Top) {
    W "  TOP SUSPECTS ($(@($script:Top).Count)) - look at these first (marked !!! above):"
    $script:Top | ForEach-Object { W "   >> $_" }
    W ''
}
if ($script:Flags -eq 0) {
    W '  No obvious footprints found. This does NOT prove the PC is clean - also run a full/offline scan.'
} else {
    W "  $($script:Flags) item(s) flagged with !!  - review each one. A flagged file in AppData/Temp that"
    W '  starts with Windows or talks to the internet = treat the PC as INFECTED (see the response steps).'
}
W ''
W "Report saved: $Report"
# Put the top suspects at the very top of the report as well
$topBlock = @('#' * 90, '  TOP SUSPECTS - start here (details below, marked !!!)', '#' * 90)
$topBlock += $(if ($script:Top) { $script:Top | ForEach-Object { "   >> $_" } } else { '   (none - no high-risk items found)' })
$topBlock += ''
Set-Content -Path $Report -Value ($topBlock + (Get-Content $Report))
$Json = $Report -replace '\.txt$', '.json'
ConvertTo-Json -InputObject @($script:Findings) -Depth 3 | Set-Content -Path $Json -Encoding UTF8
W "Findings for Security 8 Cleanup: $Json"
Start-Process notepad.exe $Report
