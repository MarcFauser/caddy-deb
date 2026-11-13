@echo off
rem Starts Update-Caddy.ps1 next to this file; arguments are passed on, see the script.
rem For a scheduled task call pwsh with the .ps1 directly: this file pauses when started
rem with cmd /c, which is how the Task Scheduler starts a .cmd.
setlocal

set "PS1=%~dp0Update-Caddy.ps1"

if not exist "%PS1%" (
    echo ERROR: Update-Caddy.ps1 not found next to this launcher.
    echo Expected: "%PS1%"
    exit /b 2
)

where pwsh >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh^) was not found on the PATH.
    exit /b 3
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (
    echo.
    pause
)

exit /b %RC%
