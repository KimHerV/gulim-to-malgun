@echo off
rem Double-click launcher: opens the menu (asks for administrator rights).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gulim-to-malgun.ps1" %*
