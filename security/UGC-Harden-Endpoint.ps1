<#
.SYNOPSIS
    UGC endpoint hardening against password-protected ZIP / WhatsApp / email malware.
    Works WITHOUT antivirus: blocks execution from download/temp folders (Software
    Restriction Policies), disables script engines, neutralises script/HTA file types,
    hides ISO/VHD mounting, enforces SmartScreen and browser download blocking.

.USAGE  (run as Administrator)
    powershell -ExecutionPolicy Bypass -File .\UGC-Harden-Endpoint.ps1
    powershell -ExecutionPolicy Bypass -File .\UGC-Harden-Endpoint.ps1 -BlockArchiveTools
    powershell -ExecutionPolicy Bypass -File .\UGC-Harden-Endpoint.ps1 -ExemptAdmins
    powershell -ExecutionPolicy Bypass -File .\UGC-Harden-Endpoint.ps1 -Undo

.SWITCHES
    -BlockArchiveTools  Also block 7-Zip / WinRAR GUIs (stops opening AES password ZIPs).
    -ExemptAdmins       Restrictions skip local administrators. Only useful if normal
                        users are NOT local admins; otherwise leave it off.
    -Undo               Roll back everything this script changed.

    Log + backups: C:\ProgramData\UGC\Hardening
#>
[CmdletBinding()]
param(
    [switch]$BlockArchiveTools,
    [switch]$ExemptAdmins,
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'
$Base   = 'C:\ProgramData\UGC\Hardening'
$Backup = Join-Path $Base 'backup'
$Log    = Join-Path $Base 'hardening.log'
New-Item -ItemType Directory -Path $Backup -Force | Out-Null

function Log([string]$m) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m
    Add-Content -Path $Log -Value $line
    Write-Output $line
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

# ---------------------------------------------------------------- helpers
function Set-Reg {
    param([string]$Path, [string]$Name, $Value,
          [ValidateSet('String','ExpandString','DWord','QWord','MultiString')][string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Remove-RegValue([string]$Path, [string]$Name) {
    if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
}
function Backup-Key([string]$RegPath, [string]$File) {
    # Backs up only the first time, so re-runs never overwrite the original state.
    $out = Join-Path $Backup $File
    if (-not (Test-Path $out)) { cmd /c "reg export `"$RegPath`" `"$out`" /y >nul 2>&1" | Out-Null }
}
function Restore-Key([string]$File) {
    $in = Join-Path $Backup $File
    if (Test-Path $in) { cmd /c "reg import `"$in`" >nul 2>&1" | Out-Null; return $true }
    return $false
}

# Runs a scriptblock against every user profile hive + the Default user (new logins).
function Invoke-ForEachUserHive([scriptblock]$Action) {
    $targets = @()
    Get-CimInstance Win32_UserProfile |
        Where-Object { -not $_.Special -and $_.LocalPath -like "$env:SystemDrive\Users\*" } |
        ForEach-Object { $targets += [pscustomobject]@{ Sid = $_.SID; Dat = (Join-Path $_.LocalPath 'NTUSER.DAT') } }
    $targets += [pscustomobject]@{ Sid = 'DefaultUser'; Dat = "$env:SystemDrive\Users\Default\NTUSER.DAT" }

    foreach ($t in $targets) {
        $loaded = "Registry::HKEY_USERS\$($t.Sid)"
        $tempHive = $null
        if (Test-Path $loaded) {
            $root = $loaded
        } elseif (Test-Path $t.Dat) {
            $tempHive = "UGC_$($t.Sid)"
            cmd /c "reg load `"HKU\$tempHive`" `"$($t.Dat)`" >nul 2>&1" | Out-Null
            if ($LASTEXITCODE -ne 0) { Log "  skipped profile $($t.Sid) (hive in use/unreadable)"; continue }
            $root = "Registry::HKEY_USERS\$tempHive"
        } else { continue }

        try { & $Action $root } catch { Log "  profile $($t.Sid): $($_.Exception.Message)" }

        if ($tempHive) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300
            cmd /c "reg unload `"HKU\$tempHive`" >nul 2>&1" | Out-Null
        }
    }
}

# ---------------------------------------------------------------- constants
$SRP          = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
$ScriptClasses = 'JSFile','JSEFile','VBSFile','VBEFile','WSFFile','htafile'
$MountClasses  = 'Windows.IsoFile','Windows.VhdFile'
$OfficeApps    = 'Word','Excel','PowerPoint'
$Notepad       = "`"$env:SystemRoot\System32\notepad.exe`" `"%1`""

# =================================================================== UNDO
if ($Undo) {
    Log '=== UNDO started ==='

    if (Test-Path $SRP) { Remove-Item $SRP -Recurse -Force }
    if (Restore-Key 'srp.reg') { Log 'SRP: original policy restored from backup' } else { Log 'SRP: removed' }

    Remove-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' 'Enabled'
    Remove-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Script Host\Settings' 'Enabled'
    Log 'Windows Script Host: re-enabled'

    foreach ($c in $ScriptClasses) { [void](Restore-Key "assoc_$c.reg") }
    Log 'Script file associations: restored'

    foreach ($k in $MountClasses) { Remove-RegValue "HKLM:\SOFTWARE\Classes\$k\shell\mount" 'ProgrammaticAccessOnly' }
    Log 'ISO/VHD mount: restored'

    Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'ShellSmartScreenLevel'
    foreach ($n in 'SmartScreenEnabled','PreventSmartScreenPromptOverrideForFiles','DownloadRestrictions') {
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' $n
    }
    Remove-RegValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'DownloadRestrictions'
    Log 'SmartScreen / browser policies: removed'

    Invoke-ForEachUserHive {
        param($r)
        Remove-RegValue "$r\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" 'SaveZoneInformation'
        foreach ($a in $OfficeApps) {
            Remove-RegValue "$r\Software\Policies\Microsoft\Office\16.0\$a\Security" 'blockcontentexecutionfrominternet'
        }
    }
    Log 'Per-user policies: removed (file extensions left visible)'
    Log '=== UNDO complete - reboot the PC ==='
    return
}

# =================================================================== APPLY
Log "=== APPLY started on $env:COMPUTERNAME (BlockArchiveTools=$BlockArchiveTools, ExemptAdmins=$ExemptAdmins) ==="

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Log 'WARNING: PC is domain-joined. A domain GPO that configures SRP will override these local SRP settings.'
}

# ---- 1. Disable Windows Script Host (wscript/cscript: .js .vbs .wsf)
Backup-Key 'HKLM\SOFTWARE\Microsoft\Windows Script Host\Settings' 'wsh.reg'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' 'Enabled' 0
Set-Reg 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Script Host\Settings' 'Enabled' 0
Log '1. Windows Script Host disabled'

# ---- 2. Script / HTA files open in Notepad instead of executing
foreach ($c in $ScriptClasses) {
    $p = "HKLM:\SOFTWARE\Classes\$c\Shell\Open\Command"
    Backup-Key "HKLM\SOFTWARE\Classes\$c\Shell\Open\Command" "assoc_$c.reg"
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    Set-Item -Path $p -Value $Notepad
}
Log '2. .js .jse .vbs .vbe .wsf .hta now open in Notepad'

# ---- 3. Hide "Mount" for ISO/IMG/VHD (common way to smuggle malware inside a ZIP)
foreach ($k in $MountClasses) {
    $p = "HKLM:\SOFTWARE\Classes\$k\shell\mount"
    if (Test-Path $p) { Set-Reg $p 'ProgrammaticAccessOnly' '' 'String' }
}
Log '3. ISO/VHD double-click mount hidden'

# ---- 4. SmartScreen (Explorer + Edge) and browser download protection
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'ShellSmartScreenLevel' 'Block' 'String'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'PreventSmartScreenPromptOverrideForFiles' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'DownloadRestrictions' 1     # block dangerous downloads
Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome'  'DownloadRestrictions' 1
Log '4. SmartScreen enforced; Edge/Chrome block dangerous downloads'

# ---- 5. Software Restriction Policies - nothing runs from download/temp folders
Backup-Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Safer' 'srp.reg'
if (Test-Path $SRP) { Remove-Item $SRP -Recurse -Force }    # rebuild cleanly every run

Set-Reg $SRP 'DefaultLevel'        0x40000            # Unrestricted by default
Set-Reg $SRP 'TransparentEnabled'  1                  # all files except DLLs
Set-Reg $SRP 'PolicyScope'         ([int][bool]$ExemptAdmins)   # 0 = everyone, 1 = skip admins
Set-Reg $SRP 'AuthenticodeEnabled' 0
Set-Reg $SRP 'ExecutableTypes' @(
    'ADE','ADP','BAS','BAT','CHM','CMD','COM','CPL','CRT','EXE','HLP','HTA','INF','INS','ISP',
    'LNK','MDB','MDE','MSC','MSI','MSP','MST','OCX','PCD','PIF','REG','SCR','SHS','URL','VB',
    'WSC','JS','JSE','VBS','VBE','WSF','WSH','PS1','ISO','IMG','VHD','VHDX') 'MultiString'

$script:RuleCount = 0
function Add-SrpRule([int]$Level, [string]$Path, [string]$Desc) {
    $k = "$SRP\$Level\Paths\{$([guid]::NewGuid())}"
    Set-Reg $k 'ItemData'    $Path 'ExpandString'
    Set-Reg $k 'SaferFlags'  0
    Set-Reg $k 'Description' $Desc 'String'
    $script:RuleCount++
}
$DISALLOWED = 0

# Whole folders: nothing executable may run from here (WhatsApp/browser downloads, ZIP extraction temp, Outlook temp)
foreach ($f in @(
    '%USERPROFILE%\Downloads',
    '%USERPROFILE%\AppData\Local\Temp',
    '%USERPROFILE%\AppData\Local\Microsoft\Windows\INetCache'
)) { Add-SrpRule $DISALLOWED $f 'UGC: block execution from download/temp folder' }

# Desktop & Documents (incl. OneDrive-redirected): block risky types only, so normal shortcuts keep working
$extFolders = '%USERPROFILE%\Desktop','%USERPROFILE%\Documents',
              '%OneDriveCommercial%\Desktop','%OneDriveCommercial%\Documents',
              '%OneDrive%\Desktop','%OneDrive%\Documents'
$riskyExt   = 'exe','com','scr','pif','bat','cmd','js','jse','vbs','vbe','wsf','hta','msi','ps1','cpl','iso','img','vhd'
foreach ($f in $extFolders) { foreach ($e in $riskyExt) {
    Add-SrpRule $DISALLOWED "$f\*.$e" "UGC: block .$e on Desktop/Documents"
} }

# mshta.exe - used by almost every HTA/LNK dropper
Add-SrpRule $DISALLOWED '%SystemRoot%\System32\mshta.exe' 'UGC: block mshta'
Add-SrpRule $DISALLOWED '%SystemRoot%\SysWOW64\mshta.exe' 'UGC: block mshta (32-bit)'

if ($BlockArchiveTools) {
    foreach ($a in @(
        '%ProgramFiles%\7-Zip\7zFM.exe', '%ProgramFiles%\7-Zip\7zG.exe',
        '%ProgramFiles(x86)%\7-Zip\7zFM.exe', '%ProgramFiles(x86)%\7-Zip\7zG.exe',
        '%ProgramFiles%\WinRAR\WinRAR.exe', '%ProgramFiles(x86)%\WinRAR\WinRAR.exe'
    )) { Add-SrpRule $DISALLOWED $a 'UGC: block archive tool' }
    Log '5b. 7-Zip / WinRAR blocked'
}
Log "5. Software Restriction Policy applied ($script:RuleCount rules, PolicyScope=$([int][bool]$ExemptAdmins))"

# ---- 6. Per-user settings (all existing profiles + Default user for new logins)
Invoke-ForEachUserHive {
    param($r)
    Set-Reg "$r\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt' 0
    Set-Reg "$r\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" 'SaveZoneInformation' 2  # keep "downloaded from internet" tag
    foreach ($a in $OfficeApps) {
        Set-Reg "$r\Software\Policies\Microsoft\Office\16.0\$a\Security" 'blockcontentexecutionfrominternet' 1
    }
}
Log '6. File extensions shown; Mark-of-the-Web kept; Office internet macros blocked (all users)'

Log '=== APPLY complete - REBOOT the PC for everything to take effect ==='
