<#
.SYNOPSIS
    UGC Infection Cleanup - removes what UGC-Infection-Check.ps1 flagged, ONLY the items you tick.

    Run UGC-Infection-Check.ps1 first. This script opens its latest findings in a pick-list.
    For every item you select it:
      Process   -> kills it, then quarantines its .exe (if it lives in a user-writable folder)
      Task      -> exports the task to a backup .xml, then deletes it
      Service   -> stops it, disables it, backs up its config, deletes it, quarantines its .exe
      RunValue  -> backs up the registry key (.reg), removes the auto-start value, quarantines its .exe
      File      -> moves it into quarantine (never deleted)
      Uninstall -> runs the program's own uninstaller (remote-access tools)

    Nothing is deleted outright: files go to C:\ProgramData\UGC\Cleanup\<date>\quarantine\ and
    every task/service/registry change is backed up next to it. Everything is logged.

    Afterwards: REBOOT, run UGC-Infection-Check.ps1 again - it should come back clean.
    A PC that had a remote-access tool should still be reinstalled when possible.

.USAGE (as Administrator)
    powershell -ExecutionPolicy Bypass -File .\UGC-Infection-Cleanup.ps1
    powershell -ExecutionPolicy Bypass -File .\UGC-Infection-Cleanup.ps1 -Findings C:\ProgramData\UGC\Triage\PC_20261104-1230.json
#>
param([string]$Findings)

$ErrorActionPreference = 'Stop'
$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }

$Triage = 'C:\ProgramData\UGC\Triage'
if (-not $Findings) {
    $Findings = Get-ChildItem $Triage -Filter '*.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Findings -or -not (Test-Path $Findings)) {
    throw 'No findings file. Run Security 7 (UGC-Infection-Check.ps1) on this PC first.'
}
$age = (Get-Date) - (Get-Item $Findings).LastWriteTime
Write-Host "Using findings: $Findings  (made $([int]$age.TotalMinutes) min ago)" -ForegroundColor Cyan
if ($age.TotalHours -gt 2) { Write-Host 'WARNING: findings are over 2 hours old - consider running Security 7 again first.' -ForegroundColor Yellow }

$items = @(Get-Content $Findings -Raw | ConvertFrom-Json) | Where-Object { $_.Kind -and $_.Kind -ne 'Info' }
if (-not $items) { Write-Host 'Nothing removable in the findings (only informational items). Done.' -ForegroundColor Green; return }

$picked = $items | Select-Object Kind, Detail, Target, File |
          Out-GridView -Title 'Tick what to REMOVE (Ctrl/Shift+click), then OK. Leave anything you recognise as legitimate.' -PassThru
if (-not $picked) { Write-Host 'Nothing selected - no changes made.' -ForegroundColor Yellow; return }

Write-Host "`nSelected $(@($picked).Count) item(s):" -ForegroundColor Cyan
$picked | ForEach-Object { Write-Host "  [$($_.Kind)] $($_.Detail)" }
if ((Read-Host "`nType YES to remove them") -ne 'YES') { Write-Host 'Cancelled - no changes made.'; return }

$Work = Join-Path 'C:\ProgramData\UGC\Cleanup' ('{0}_{1:yyyyMMdd-HHmmss}' -f $env:COMPUTERNAME, (Get-Date))
$QDir = Join-Path $Work 'quarantine'
New-Item -ItemType Directory -Path $QDir -Force | Out-Null
cmd /c "icacls `"$Work`" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F >nul" | Out-Null
$Log = Join-Path $Work 'cleanup.log'
function L([string]$m, [string]$c = 'Gray') { Add-Content $Log ('{0:HH:mm:ss}  {1}' -f (Get-Date), $m); Write-Host $m -ForegroundColor $c }

$UserWritable = '\\Users\\[^\\]+\\|\\Temp\\|\\ProgramData\\|\\Users\\Public\\|\\Windows\\Temp\\'
$quarantined  = @{}

function Stop-ByPath([string]$path) {
    if (-not $path) { return }
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $path } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; L "  killed PID $($_.ProcessId) ($($_.Name))" 'Yellow' }
}
function Move-ToQuarantine([string]$path, [switch]$OnlyIfUserWritable) {
    if (-not $path) { return }
    $path = [Environment]::ExpandEnvironmentVariables($path.Trim('"'))
    if ($quarantined[$path] -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ($OnlyIfUserWritable -and $path -notmatch $UserWritable) { L "  kept $path (not in a user folder - check it manually)" 'DarkYellow'; return }
    Stop-ByPath $path
    $dest = Join-Path $QDir (($path -replace '[:\\]', '_') + '.quarantined')
    try {
        Move-Item -LiteralPath $path -Destination $dest -Force
        $quarantined[$path] = $true
        L "  quarantined $path" 'Green'
    } catch {
        # Locked: schedule the delete for the next reboot instead
        L "  could not move $path now ($($_.Exception.Message)) - will be removed at reboot" 'Yellow'
        Copy-Item -LiteralPath $path -Destination $dest -Force -ErrorAction SilentlyContinue
        $sig = @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@
        if (-not ('UGC.Native' -as [type])) { Add-Type -MemberDefinition $sig -Name Native -Namespace UGC }
        [void][UGC.Native]::MoveFileEx($path, $null, 4)   # MOVEFILE_DELAY_UNTIL_REBOOT
    }
}

# Process first, so nothing respawns what we remove next
$order = @{ Process = 1; Service = 2; Task = 3; RunValue = 4; Uninstall = 5; File = 6 }
foreach ($it in @($picked) | Sort-Object { $order[$_.Kind] }) {
    L "`n[$($it.Kind)] $($it.Detail)" 'Cyan'
    try {
        switch ($it.Kind) {
            'Process' {
                # PIDs get reused: only kill it if it is still the same program
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$it.Target)"
                if ($proc -and (-not $it.File -or $proc.ExecutablePath -ieq $it.File)) {
                    Stop-Process -Id ([int]$it.Target) -Force -ErrorAction SilentlyContinue
                    L "  killed PID $($it.Target) ($($proc.Name))" 'Yellow'
                } else { L "  PID $($it.Target) is no longer that program - killing by path instead" }
                Stop-ByPath $it.File
                Move-ToQuarantine $it.File -OnlyIfUserWritable
            }
            'Service' {
                $name = $it.Target
                cmd /c "sc.exe qc `"$name`" > `"$Work\service_$name.txt`" 2>&1" | Out-Null
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
                cmd /c "sc.exe delete `"$name`" >nul 2>&1" | Out-Null
                L "  service $name stopped, disabled and deleted (config saved)" 'Green'
                Move-ToQuarantine $it.File -OnlyIfUserWritable
            }
            'Task' {
                $tp, $tn = $it.Target -split '\|', 2
                $xml = Export-ScheduledTask -TaskPath $tp -TaskName $tn
                Set-Content -Path (Join-Path $Work ("task_" + ($tn -replace '[^\w-]', '_') + '.xml')) -Value $xml
                Unregister-ScheduledTask -TaskPath $tp -TaskName $tn -Confirm:$false
                L "  task $tp$tn deleted (backup .xml saved)" 'Green'
                Move-ToQuarantine $it.File -OnlyIfUserWritable
            }
            'RunValue' {
                $key, $val = $it.Target -split '\|', 2
                $regPath = ($key -replace '^Registry::', '') -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
                cmd /c "reg export `"$regPath`" `"$Work\run_$(Get-Random).reg`" /y >nul 2>&1" | Out-Null
                Remove-ItemProperty -Path $key -Name $val
                L "  removed auto-start '$val' from $regPath (backup .reg saved)" 'Green'
                Move-ToQuarantine $it.File -OnlyIfUserWritable
            }
            'Uninstall' {
                if (-not $it.Target) { L '  no uninstaller registered - remove it from Settings > Apps' 'Yellow'; break }
                L "  running uninstaller: $($it.Target)" 'Yellow'
                Start-Process cmd.exe -ArgumentList "/c `"$($it.Target)`"" -Wait
                L '  uninstaller finished (check it really is gone in Settings > Apps)' 'Green'
            }
            'File' { Move-ToQuarantine $it.File }
        }
    } catch { L "  FAILED: $($_.Exception.Message)" 'Red' }
}

L "`nDone. Backups and quarantined files: $Work" 'Cyan'
L 'NEXT: reboot, then run Security 7 again. It should come back clean.' 'Cyan'
L 'If a remote-access tool was on this PC, still plan to reinstall Windows and change all passwords used on it.' 'Cyan'
