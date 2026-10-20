@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ValheimSaveManager.ps1" -Console
if errorlevel 1 pause
