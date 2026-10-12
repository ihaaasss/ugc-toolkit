# Ihsan Tech Fix - Toolkit

A point-and-click menu of common Windows fixes for Windows workstations: disk cleanup, system repair, network, Office/Teams, printers and system info.

## Run it

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/UGC-Toolkit.ps1 | iex
```

It elevates itself to Administrator. Orange cards ask for confirmation before deleting or resetting anything. Every action is logged to `C:\ProgramData\IhsanTechFix\toolkit.log`.

Offline: copy `UGC-Toolkit.ps1` and `Run-Toolkit.cmd` to a USB stick or share and double-click `Run-Toolkit.cmd`.

## Add a fix

Copy any `@{ Tab=...; Name=...; Help=...; Mode=...; Script={...} }` block in `$Fixes`, edit it, commit and push. A new `Tab` value creates a new tab.

A fix that needs details from you can add an `Inputs=@( @{ Key='Name'; Label='Full name'; Required=$true } )` list. The toolkit shows a form first and the answers reach the script as `$In.Name`, `$In.Title`, etc. (see **Create email signature** on the Outlook & Office tab).

## Email signature

**Outlook & Office > Create email signature** asks for the company (Ultraction or Powerful Plus), name, designation, mobile (and optionally email), then installs that company's signature with its banner from `assets/` (`UGC-signature-banner.jpg` / `PPC-signature-banner.jpg`) into the signed-in user's Outlook and makes it the default for new mails and replies. Classic Outlook only.

**Outlook & Office > Delete email signature** lists the signed-in user's Outlook signatures as a tick-list. Ticked ones are removed (moved to `C:\ProgramData\IhsanTechFix\Backups\Signatures_<user>_<date>`), and if one was the default for new mails or replies, that default is cleared.

## Downloads tab

Put files (usually `.zip`) in the repo's `downloads` folder. Each one shows up as a button on the **Downloads** page. One click saves it to the signed-in user's Downloads folder, extracts `.zip` files into a folder of the same name and opens it in Explorer. Files over 100 MB can't go on GitHub.

## Turn Defender protection off / on (System Repair)

For installs that get falsely blocked. **Turn off Defender protection** disables the settings Windows lets a script change — real-time protection, cloud-delivered protection, sample submission and controlled-folder access — and **leaves them off**. It first saves the previous state. **Turn on Defender protection** restores that exact saved state (or secure defaults) and runs a quick scan. Tamper Protection and Smart App Control are never touched (Windows blocks scripts from changing those); if Tamper Protection is on, the off card says so and does nothing. For permanently managing Defender across the fleet, use Intune/GPO instead.

## Network diagnostics

The Network tab includes **Ping a host**, **Trace route (tracert)**, **Test a TCP port**, **Listening ports on this PC**, **Scan a host (nmap)** and **Discover devices on the LAN (nmap)**. The nmap cards install nmap via winget (`Insecure.Nmap`) on first use. Host/IP inputs are validated so they can't inject extra command-line options. Only scan machines and networks you are responsible for.
