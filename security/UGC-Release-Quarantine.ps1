<#
.SYNOPSIS
    Release files that UGC Archive Guard quarantined.

    Shows every quarantined file on this PC in a pick-list. The ones you select are copied,
    with their original name, to  C:\Users\<user>\IT-Released\  for the user they were
    taken from. Archive Guard does not watch that folder, so the file stays there.
    The quarantined copy is kept (delete it from the quarantine folder when done).

    Only release a file after confirming with the sender BY PHONE - not on WhatsApp,
    their account may be the hacked one.

.USAGE (as Administrator)
    powershell -ExecutionPolicy Bypass -File .\UGC-Release-Quarantine.ps1
#>
$ErrorActionPreference = 'Stop'
$Quar    = 'C:\ProgramData\UGC\ArchiveGuard\Quarantine'
$LogFile = 'C:\ProgramData\UGC\ArchiveGuard\guard.log'

$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }

$items = @(Get-ChildItem $Quar -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
        User         = $_.Directory.Name
        File         = (($_.Name -replace '^\d{8}-\d{6}_', '') -replace '\.blocked$', '')
        Quarantined  = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        'Size (KB)'  = [math]::Round($_.Length / 1KB, 1)
        Path         = $_.FullName
    }
} | Sort-Object Quarantined -Descending)

if (-not $items) { Write-Host 'Quarantine is empty - nothing to release.' -ForegroundColor Green; return }

# Pick-list window; falls back to a numbered list if the grid isn't available
$picked = $null
try {
    $picked = $items | Out-GridView -Title 'Select file(s) to RELEASE (Ctrl+click for several), then OK' -PassThru
} catch {
    Write-Host ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ("[{0}] {1,-12} {2}  ({3})" -f ($i + 1), $items[$i].User, $items[$i].File, $items[$i].Quarantined)
    }
    $ans = Read-Host "`nNumbers to release, comma-separated (blank = cancel)"
    if ($ans) { $picked = $ans -split ',' | ForEach-Object { $items[[int]$_.Trim() - 1] } }
}
if (-not $picked) { Write-Host 'Nothing selected.' -ForegroundColor Yellow; return }

foreach ($it in @($picked)) {
    $userDir = "C:\Users\$($it.User)"
    if (-not (Test-Path $userDir)) { Write-Host "No profile folder for '$($it.User)' - skipped $($it.File)" -ForegroundColor Red; continue }
    $destDir = Join-Path $userDir 'IT-Released'
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $dest = Join-Path $destDir $it.File
    if (Test-Path $dest) {
        $dest = Join-Path $destDir ('{0}_{1:HHmmss}{2}' -f [IO.Path]::GetFileNameWithoutExtension($it.File), (Get-Date), [IO.Path]::GetExtension($it.File))
    }
    Copy-Item -LiteralPath $it.Path -Destination $dest
    # Let the user own it like any of their files
    cmd /c "icacls `"$destDir`" /grant `"$($it.User)`":(OI)(CI)M /T >nul 2>&1" | Out-Null
    Add-Content $LogFile ('{0:yyyy-MM-dd HH:mm:ss}  RELEASED by {1}: {2} -> {3}' -f (Get-Date), $env:USERNAME, $it.Path, $dest)
    Write-Host "Released: $($it.File)  ->  $dest" -ForegroundColor Green
}
Write-Host "`nTell the user: the file is in the 'IT-Released' folder in their user folder (C:\Users\<name>\IT-Released)."
