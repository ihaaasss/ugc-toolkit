# After Security 7: tick the flagged items to kill and remove them. Files are quarantined, every change is backed up.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir  = Join-Path $env:ProgramData 'IhsanTechFix_scripts\security'
New-Item $dir -ItemType Directory -Force | Out-Null
$file = Join-Path $dir 'UGC-Infection-Cleanup.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-Infection-Cleanup.ps1' -OutFile $file
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file
