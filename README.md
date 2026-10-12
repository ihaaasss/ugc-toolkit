# UGC IT Quick-Fix Toolkit

A point-and-click menu of common Windows fixes for UGC workstations: disk cleanup, system repair, network, Office/Teams, printers and system info.

## Run it

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/ihaaasss/ugc-toolkit/main/UGC-Toolkit.ps1 | iex
```

It elevates itself to Administrator. Buttons marked `*` ask for confirmation before deleting or resetting anything. Every action is logged to `C:\ProgramData\UGC-Toolkit\toolkit.log`.

Offline: copy `UGC-Toolkit.ps1` and `Run-Toolkit.cmd` to a USB stick or share and double-click `Run-Toolkit.cmd`.

## Add a fix

Copy any `@{ Tab=...; Name=...; Help=...; Mode=...; Script={...} }` block in `$Fixes`, edit it, commit and push. A new `Tab` value creates a new tab.
