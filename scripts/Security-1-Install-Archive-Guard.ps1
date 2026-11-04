# Quarantines WhatsApp and password-protected ZIP/RAR files as soon as they land on this PC.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir  = Join-Path $env:ProgramData 'IhsanTechFix_scripts\security'
New-Item $dir -ItemType Directory -Force | Out-Null
$file = Join-Path $dir 'UGC-ArchiveGuard.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-ArchiveGuard.ps1' -OutFile $file
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -Install
