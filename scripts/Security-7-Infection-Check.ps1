# Read-only check of a PC that may have opened a malicious file - opens a report of suspicious items (!!).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir  = Join-Path $env:ProgramData 'IhsanTechFix_scripts\security'
New-Item $dir -ItemType Directory -Force | Out-Null
$file = Join-Path $dir 'UGC-Infection-Check.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-Infection-Check.ps1' -OutFile $file
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file
