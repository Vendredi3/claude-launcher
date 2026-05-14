@echo off
REM Lance le launcher AVEC la console PowerShell visible (utile en cas d'erreur).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClaudeLauncher.ps1"
pause
