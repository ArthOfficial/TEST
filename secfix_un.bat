@echo off
:: ---------------- Retry delete helper ----------------
:DeleteFolder
rmdir /S /Q "%~1"
if exist "%~1" (
    timeout /t 3 /nobreak >nul
    goto DeleteFolder
)

:DeleteFile
del /F /Q "%~1"
if exist "%~1" (
    timeout /t 3 /nobreak >nul
    goto DeleteFile
)

:: Close monitoring processes
taskkill /F /IM monitoring.exe >nul 2>&1
taskkill /F /IM go.exe >nul 2>&1

:: Delete secfnx folder (with retry)
call :DeleteFolder "C:\Users\%USERNAME%\Downloads\secfnx"

:: Delete PS1 script (with retry)
call :DeleteFile "%~dp0secfnx.ps1"

:: Delete Go installation (with retry)
call :DeleteFolder "C:\Program Files\Go"

:: Delete this batch file
del /F /Q "%~f0"
