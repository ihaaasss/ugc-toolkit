<#
.SYNOPSIS
    UGC Archive Guard - quarantines dangerous archives the moment they land on a PC.

    Blocks (moves to a locked quarantine folder that users cannot open):
      1. ANY archive downloaded from WhatsApp Web / WhatsApp (zip, rar, 7z, iso, img ...)
      2. ANY password-protected archive, from any source (WhatsApp Desktop, email,
         USB copy, browser) - this is the malware trick, legit files rarely need it.

    Normal, non-password ZIP/RAR files from email, suppliers, NAS etc. keep working.

    Watches every user's Downloads, Desktop, Documents (incl. OneDrive Desktop/Documents)
    AND the WhatsApp Desktop app's own folders, where chat downloads are stored
    (AppData\Local\Packages\*WhatsApp*  and  AppData\Roaming\WhatsApp).
    Runs as a hidden SYSTEM scheduled task at startup - no window, users can't stop it.

.USAGE (as Administrator)
    powershell -ExecutionPolicy Bypass -File .\UGC-ArchiveGuard.ps1 -Install
    powershell -ExecutionPolicy Bypass -File .\UGC-ArchiveGuard.ps1 -Uninstall
    powershell -ExecutionPolicy Bypass -File .\UGC-ArchiveGuard.ps1 -PauseMinutes 30

    Quarantine : C:\ProgramData\UGC\ArchiveGuard\Quarantine\<username>\   (Admins/SYSTEM only)
    Log        : C:\ProgramData\UGC\ArchiveGuard\guard.log
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Run,
    [switch]$OnlyPasswordProtected,   # don't block normal archives from WhatsApp, only password-protected ones
    [int]$PauseMinutes = 0,           # temporarily stop the guard; it switches itself back on
    [int]$PollSeconds = 5
)

$GuardHome = 'C:\ProgramData\UGC\ArchiveGuard'
$Quar      = Join-Path $GuardHome 'Quarantine'
$LogFile   = Join-Path $GuardHome 'guard.log'
$Installed = Join-Path $GuardHome 'ArchiveGuard.ps1'
$TaskName  = 'UGC Archive Guard'
$SourceUrl = 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-ArchiveGuard.ps1'

function Log([string]$m) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m
    try { Add-Content -Path $LogFile -Value $line } catch {}
    Write-Output $line
}
function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }
}
function Stop-Guard {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ArchiveGuard.ps1*-Run*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
}

# ================================================================ INSTALL
if ($Install) {
    Assert-Admin
    New-Item -ItemType Directory -Path $Quar -Force | Out-Null
    # Quarantine: only SYSTEM + Administrators (SIDs, so it works on any Windows language)
    cmd /c "icacls `"$Quar`" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F >nul" | Out-Null

    if ($PSCommandPath) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $Installed -Force
    } else {
        # Run straight from GitHub (irm | iex) - no local file, so fetch the script itself
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $SourceUrl -OutFile $Installed
    }
    cmd /c "icacls `"$Installed`" /inheritance:r /grant:r *S-1-5-18:F *S-1-5-32-544:F *S-1-5-32-545:RX >nul" | Out-Null

    Stop-Guard
    # Switches only - a [bool] value can't be passed through powershell.exe -File
    $modeArg = if ($OnlyPasswordProtected) { ' -OnlyPasswordProtected' } else { '' }
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Installed`" -Run$modeArg"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
                 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Quarantines WhatsApp and password-protected archives (UGC IT)' -Force | Out-Null
    $startedAt = (Get-Date).AddSeconds(-2)
    Start-ScheduledTask -TaskName $TaskName
    Log "Installed on $env:COMPUTERNAME (OnlyPasswordProtected=$OnlyPasswordProtected) - checking it starts..."

    # Self-check: the guard writes 'Guard started' within a few seconds if it is really running
    $ok = $false
    for ($i = 0; $i -lt 15 -and -not $ok; $i++) {
        Start-Sleep -Seconds 1
        $ok = [bool](Get-Content $LogFile -Tail 20 -ErrorAction SilentlyContinue | Where-Object {
            $_ -match '^(\S+ \S+)\s+Guard started' -and ([datetime]$Matches[1] -ge $startedAt) })
    }
    $state = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
    if ($ok) { Log "OK - Archive Guard is running (task state: $state)" }
    else     { Log "WARNING - Archive Guard did not report in (task state: $state). Run: Start-ScheduledTask '$TaskName' and check this log." }
    return
}

# ================================================================ PAUSE
if ($PauseMinutes -gt 0) {
    Assert-Admin
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { throw 'Archive Guard is not installed on this PC.' }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Stop-Guard
    $resumeAt  = (Get-Date).AddMinutes($PauseMinutes)
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -WindowStyle Hidden -Command Start-ScheduledTask -TaskName '$TaskName'"
    $trigger   = New-ScheduledTaskTrigger -Once -At $resumeAt
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "$TaskName - Resume" -Action $action -Trigger $trigger -Principal $principal `
        -Description 'Turns UGC Archive Guard back on after a pause' -Force | Out-Null
    Log ("PAUSED by {0} for {1} min - resumes automatically at {2:HH:mm} (or on reboot)" -f $env:USERNAME, $PauseMinutes, $resumeAt)
    return
}

# ================================================================ UNINSTALL
if ($Uninstall) {
    Assert-Admin
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Guard
    Log "Uninstalled from $env:COMPUTERNAME (quarantine folder kept: $Quar)"
    return
}

if (-not $Run) { Write-Output 'Use -Install or -Uninstall.'; return }

# ================================================================ GUARD LOOP (runs as SYSTEM)
$ArchiveExt = '.zip','.rar','.7z','.tar','.gz','.tgz','.bz2','.xz','.cab','.arj','.lzh','.ace','.z',
              '.iso','.img','.vhd','.vhdx'
$MaxTestBytes = 500MB

$SevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") |
            Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$UnRar    = @("$env:ProgramFiles\WinRAR\UnRAR.exe", "${env:ProgramFiles(x86)}\WinRAR\UnRAR.exe") |
            Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$MsgExe   = "$env:SystemRoot\System32\msg.exe"

Log "Guard started (7-Zip: $([bool]$SevenZip), UnRAR: $([bool]$UnRar), OnlyPasswordProtected=$OnlyPasswordProtected)"

function Get-WatchFolders {
    $skip = 'Public','Default','Default User','All Users'
    foreach ($u in Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        if ($skip -contains $u.Name) { continue }
        foreach ($sub in 'Downloads','Desktop','Documents') {
            $p = Join-Path $u.FullName $sub
            if (Test-Path $p) { [pscustomobject]@{ User = $u.Name; Path = $p } }
        }
        foreach ($od in Get-ChildItem $u.FullName -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue) {
            foreach ($sub in 'Desktop','Documents') {
                $p = Join-Path $od.FullName $sub
                if (Test-Path $p) { [pscustomobject]@{ User = $u.Name; Path = $p } }
            }
        }
    }
}

function Test-FileReady([IO.FileInfo]$f) {
    if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 3) { return $false }      # still being written
    try { $s = [IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $s.Close(); return $true }
    catch { return $false }                                                          # locked
}

function Test-FromWhatsApp([string]$path) {
    try {
        $z = Get-Content -LiteralPath $path -Stream Zone.Identifier -ErrorAction Stop
        return (($z -join ' ') -match 'whatsapp')
    } catch { return $false }
}

function Test-Encrypted([IO.FileInfo]$f) {
    $ext = $f.Extension.ToLower()
    if ($f.Length -gt $MaxTestBytes) { return $false }

    if ($SevenZip) {
        # Wrong dummy password: unencrypted archives still test OK (exit 0/1), encrypted ones fail (exit 2)
        $p = Start-Process -FilePath $SevenZip -WindowStyle Hidden -Wait -PassThru `
             -ArgumentList @('t', '-pUGC_NoSuchPassword_9x', '-y', '-bso0', '-bse0', '-bsp0', "`"$($f.FullName)`"")
        return ($p.ExitCode -ge 2)
    }
    if ($ext -eq '.zip') {
        # ZIP local header: signature PK\3\4, general-purpose flag bit 0 = encrypted
        $buf = New-Object byte[] 8
        $s = [IO.File]::OpenRead($f.FullName); [void]$s.Read($buf, 0, 8); $s.Close()
        if ([BitConverter]::ToUInt32($buf, 0) -eq 0x04034b50) { return (($buf[6] -band 1) -eq 1) }
        return $false
    }
    if ($ext -eq '.rar' -and $UnRar) {
        # -p- = never ask for password; encrypted archive returns non-zero
        $p = Start-Process -FilePath $UnRar -WindowStyle Hidden -Wait -PassThru `
             -ArgumentList @('t', '-p-', '-y', '-idq', "`"$($f.FullName)`"")
        return ($p.ExitCode -ne 0)
    }
    return $false
}

function Invoke-Quarantine([IO.FileInfo]$f, [string]$user, [string]$reason) {
    $dest = Join-Path $Quar $user
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $target = Join-Path $dest ('{0:yyyyMMdd-HHmmss}_{1}.blocked' -f (Get-Date), $f.Name)
    Move-Item -LiteralPath $f.FullName -Destination $target -Force
    Log "QUARANTINED [$user] $($f.FullName)  ->  $target  | $reason"
    if (Test-Path $MsgExe) {
        $text = "IT Security: the file '$($f.Name)' was blocked ($reason). " +
                "If you need this file for work, contact IT."
        Start-Process -FilePath $MsgExe -ArgumentList @('*', '/TIME:120', "`"$text`"") -WindowStyle Hidden
    }
}

# WhatsApp Desktop keeps downloaded files inside its own app folder, not in Downloads:
#   Store app : C:\Users\<user>\AppData\Local\Packages\*WhatsApp*\
#   Old app   : C:\Users\<user>\AppData\Roaming\WhatsApp\
# These are deep folders full of media, so they are watched with change notifications
# instead of being re-listed every few seconds.
function Get-WhatsAppFolders {
    $skip = 'Public','Default','Default User','All Users'
    foreach ($u in Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        if ($skip -contains $u.Name) { continue }
        $pk = Join-Path $u.FullName 'AppData\Local\Packages'
        foreach ($d in Get-ChildItem $pk -Directory -Filter '*WhatsApp*' -ErrorAction SilentlyContinue) {
            [pscustomobject]@{ User = $u.Name; Path = $d.FullName }
        }
        $old = Join-Path $u.FullName 'AppData\Roaming\WhatsApp'
        if (Test-Path $old) { [pscustomobject]@{ User = $u.Name; Path = $old } }
    }
}

$seen     = @{}
$pending  = @{}   # path -> @{ User; WA } for files reported by the WhatsApp watchers
$watchers = @{}   # folder path -> FileSystemWatcher

# Returns $true once the file has been dealt with, $false if it should be retried later
function Test-AndQuarantine([IO.FileInfo]$f, [string]$user, [bool]$inWhatsAppFolder) {
    # Skip OneDrive cloud-only placeholders (reading them would trigger a download)
    if (([int]$f.Attributes -band 0x400000) -or ($f.Attributes -band [IO.FileAttributes]::Offline)) { return $true }
    $key = '{0}|{1}|{2}' -f $f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks
    if ($seen.ContainsKey($key)) { return $true }
    if (-not (Test-FileReady $f)) { return $false }
    $seen[$key] = $true
    try {
        if ((-not $OnlyPasswordProtected) -and ($inWhatsAppFolder -or (Test-FromWhatsApp $f.FullName))) {
            Invoke-Quarantine $f $user 'archive received from WhatsApp'
        } elseif (Test-Encrypted $f) {
            Invoke-Quarantine $f $user 'password-protected archive'
        }
    } catch { Log "ERROR on $($f.FullName): $($_.Exception.Message)" }
    return $true
}

function Update-WhatsAppWatchers {
    foreach ($wa in Get-WhatsAppFolders) {
        if ($watchers.ContainsKey($wa.Path)) { continue }
        try {
            $fsw = New-Object IO.FileSystemWatcher $wa.Path
            $fsw.IncludeSubdirectories = $true
            $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
            $fsw.InternalBufferSize = 65536
            $n = $watchers.Count
            foreach ($evt in 'Created','Renamed','Changed') {
                Register-ObjectEvent -InputObject $fsw -EventName $evt -SourceIdentifier "UGCWA_${n}_$evt" -MessageData $wa.User | Out-Null
            }
            $fsw.EnableRaisingEvents = $true
            $watchers[$wa.Path] = $fsw
            Log "Watching WhatsApp folder [$($wa.User)] $($wa.Path)"

            # One-time sweep for archives already sitting in the folder
            Get-ChildItem -LiteralPath $wa.Path -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $ArchiveExt -contains $_.Extension.ToLower() } |
                ForEach-Object { $pending[$_.FullName] = $wa.User }
        } catch { Log "Could not watch $($wa.Path): $($_.Exception.Message)" }
    }
}

$loop = 0
while ($true) {
    try {
        # Re-check for new WhatsApp installs / new user profiles about once a minute
        if (($loop % [Math]::Max(1, [int](60 / $PollSeconds))) -eq 0) { Update-WhatsAppWatchers }
        $loop++

        # 1. Downloads / Desktop / Documents (incl. OneDrive) - quick listing
        foreach ($w in Get-WatchFolders) {
            Get-ChildItem -LiteralPath $w.Path -File -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                Where-Object { $ArchiveExt -contains $_.Extension.ToLower() } |
                ForEach-Object { [void](Test-AndQuarantine $_ $w.User $false) }
        }

        # 2. WhatsApp Desktop folders - collect change notifications
        foreach ($e in @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like 'UGCWA_*' })) {
            $p = $e.SourceEventArgs.FullPath
            if ($p -and ($ArchiveExt -contains [IO.Path]::GetExtension($p).ToLower())) { $pending[$p] = $e.MessageData }
            Remove-Event -EventIdentifier $e.EventIdentifier
        }
        foreach ($p in @($pending.Keys)) {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $pending.Remove($p); continue }
            if (Test-AndQuarantine (Get-Item -LiteralPath $p -Force) $pending[$p] $true) { $pending.Remove($p) }
        }

        if ($seen.Count -gt 5000) { $seen.Clear() }
    } catch { Log "Loop error: $($_.Exception.Message)" }
    Start-Sleep -Seconds $PollSeconds
}
