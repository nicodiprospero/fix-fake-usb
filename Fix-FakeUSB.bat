@echo off
rem Double-click me. Keep Fix-FakeUSB.ps1 in the same folder.
title Fix fake USB stick
set "PS1="
for %%F in ("%~dp0Fix-FakeUSB*.ps1") do set "PS1=%%~fF"
if not defined PS1 (
  echo Fix-FakeUSB.ps1 was not found next to this file. Put both files in the same folder.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 pause
