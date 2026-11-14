@echo off
setlocal
set "APP=%~dp0Winndroid.ps1"
if not exist "%APP%" (
    echo Winndroid.ps1 was not found next to this launcher.
    pause
    exit /b 1
)
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 is required.
    echo Install it from https://aka.ms/powershell and run this file again.
    pause
    exit /b 1
)
start "" pwsh.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP%"
exit /b 0
