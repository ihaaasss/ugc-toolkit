# My Scripts

Every `.bat`, `.cmd` or `.ps1` file in this folder automatically appears as a button
on the **My Scripts** page of Ihsan Tech Fix.

- Button name = file name (`-` and `_` become spaces): `Shutdown_PC.bat` → **Shutdown PC**
- Button description = the first comment line in the file (`REM ...`, `:: ...` or `# ...`)
- Every My Scripts button asks for confirmation before it runs
- Scripts run as Administrator in their own window

Example `Shutdown_PC.bat`:

```bat
@echo off
REM Shuts down this PC in 60 seconds
shutdown /s /t 60 /c "Shutdown started from Ihsan Tech Fix"
```
