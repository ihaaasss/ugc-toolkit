# Turns Archive Guard off for 30 minutes so a file can be received; it switches back on by itself.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir  = Join-Path $env:ProgramData 'IhsanTechFix_scripts\security'
New-Item $dir -ItemType Directory -Force | Out-Null
$file = Join-Path $dir 'UGC-ArchiveGuard.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-ArchiveGuard.ps1' -OutFile $file
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -PauseMinutes 30
