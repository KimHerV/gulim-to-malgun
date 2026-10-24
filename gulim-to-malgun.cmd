@echo off
rem Double-click launcher: opens the menu (asks for administrator rights).
rem PowerShell by full path, so no powershell.exe in this folder or on PATH can stand in for it.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0gulim-to-malgun.ps1" %*
if errorlevel 1 pause
