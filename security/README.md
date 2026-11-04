# Security - password-protected ZIP / WhatsApp malware protection

Two scripts that stop "invoice" malware sent as password-protected ZIP/RAR files over WhatsApp or email. They work **without antivirus**. Run both on every PC, as Administrator.

| Script | What it does |
|---|---|
| `UGC-ArchiveGuard.ps1` | Hidden SYSTEM task that **quarantines** archives the moment they land: any archive downloaded from WhatsApp (WhatsApp Web **and** the WhatsApp Desktop app's own download folder), and any **password-protected** archive from anywhere. Normal ZIP/RAR files keep working. |
| `UGC-Harden-Endpoint.ps1` | If anything slips through, **nothing inside can run**: blocks execution from Downloads/Temp/Outlook temp and the WhatsApp Desktop download folder (Software Restriction Policies), blocks risky file types on Desktop/Documents, disables Windows Script Host, opens `.js/.vbs/.hta` in Notepad, blocks `mshta`, hides ISO/VHD mount, enforces SmartScreen, shows file extensions, blocks Office internet macros. |

## Install from GitHub (PowerShell as Administrator)

```powershell
# 1. Archive Guard (quarantine)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-ArchiveGuard.ps1))) -Install

# 2. Endpoint hardening, then reboot
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/security/UGC-Harden-Endpoint.ps1)))
```

From a local copy or the NAS:

```powershell
powershell -ExecutionPolicy Bypass -File .\UGC-ArchiveGuard.ps1 -Install
powershell -ExecutionPolicy Bypass -File .\UGC-Harden-Endpoint.ps1
```

## Options

| Command | Effect |
|---|---|
| `UGC-ArchiveGuard.ps1 -Install -BlockAllWhatsAppArchives $false` | Only quarantine password-protected archives |
| `UGC-ArchiveGuard.ps1 -Uninstall` | Remove the guard (quarantine folder is kept) |
| `UGC-Harden-Endpoint.ps1 -BlockArchiveTools` | Also block 7-Zip/WinRAR (breaks **all** RAR/7z opening - Finance PCs only) |
| `UGC-Harden-Endpoint.ps1 -ExemptAdmins` | Skip restrictions for local admins (only if users are not admins) |
| `UGC-Harden-Endpoint.ps1 -Undo` | Roll back hardening, then reboot |

## Where things are

- Quarantine: `C:\ProgramData\UGC\ArchiveGuard\Quarantine\<user>\` (Admins only). To release a genuine file, remove the timestamp prefix and `.blocked` ending, after confirming with the sender **by phone**.
- Logs: `C:\ProgramData\UGC\ArchiveGuard\guard.log` and `C:\ProgramData\UGC\Hardening\hardening.log`
- Hardening backups (used by `-Undo`): `C:\ProgramData\UGC\Hardening\backup\`

## Test after install

1. Create a ZIP with password `1234` in Downloads - it disappears within ~10 s and a popup appears.
2. As a normal user, copy `C:\Windows\System32\notepad.exe` into Downloads and double-click - "blocked by group policy".
3. Double-click a `test.js` on the Desktop - opens in Notepad.

Install **7-Zip** on all PCs: Archive Guard uses it to detect passwords in ZIP, RAR and 7z.

To run your own installers once hardening is on, run them from `C:\IT\` or straight from the NAS share - Downloads and Temp are blocked for everyone, admins included.
