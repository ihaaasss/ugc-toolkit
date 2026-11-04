# Rolls back all hardening changes on this PC. Reboot after.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir  = Join-Path $env:ProgramData 'IhsanTechFix_scripts\security'
New-Item $dir -ItemType Directory -Force | Out-Null
$file = Join-Path $dir 'UGC-Harden-Endpoint.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-Harden-Endpoint.ps1' -OutFile $file
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -Undo
