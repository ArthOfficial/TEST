@echo off
:: Relaunch hidden if run directly
if not defined IS_HIDDEN (
    start "" /min cmd /c "%~f0" IS_HIDDEN=1 %*
    exit /b
)

:: ---------------- Retry helpers ----------------
:DeleteFolder
rmdir /S /Q "%~1"
if exist "%~1" (
    timeout /t 3 /nobreak >nul
    goto DeleteFolder
)
exit /b

:DeleteFile
del /F /Q "%~1"
if exist "%~1" (
    timeout /t 3 /nobreak >nul
    goto DeleteFile
)
exit /b

:KillProcess
taskkill /F /IM "%~1" >nul 2>&1
tasklist /FI "IMAGENAME eq %~1" | find /I "%~1" >nul
if not errorlevel 1 (
    timeout /t 2 /nobreak >nul
    goto KillProcess
)
exit /b

:: ---------------- Main cleanup ----------------
call :KillProcess monitoring.exe
call :KillProcess go.exe

call :DeleteFolder "C:\Users\%USERNAME%\Downloads\secfnx"
call :DeleteFile "%~dp0secfnx.ps1"
call :DeleteFolder "C:\Program Files\Go"

:: Remove PATH/GOROOT environment variables
reg delete "HKCU\Environment" /F /V GOROOT >nul 2>&1
:: Note: removing Go from PATH safely requires rebuilding PATH manually

:: Delete this batch file
del /F /Q "%~f0"
