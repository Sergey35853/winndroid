@echo off
setlocal
set "APP=%~dp0Winoid.ps1"
if not exist "%APP%" (
    echo Winoid.ps1 was not found next to this launcher.
    pause
    exit /b 1
)
if not exist "%~dp0Winoid.vbs" (
    echo Winoid.vbs was not found next to this launcher.
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
start "" wscript.exe //B "%~dp0Winoid.vbs" %*
exit /b 0
