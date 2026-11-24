package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/passkeyhttp"
)

// Opt-in, loopback-only UI fixture. It uses a disposable account and normal
// identity setup and activation routes. Its generated recovery file is public test data.
func TestLocalWinUIDesktop(t *testing.T) {
	dir := os.Getenv("CHIRP_UI_FIXTURE")
	if dir == "" {
		t.Skip("interactive WinUI verification")
	}
	rtc := "ws://127.0.0.1:1"
	if os.Getenv("CHIRP_LIVEKIT_SERVER") != "" {
		rtc = startSFU(t)
	}
	var f fixture
	if os.Getenv("CHIRP_UI_USE_BUNDLED_TRUST") == "1" {
		f = serviceWithAuthority(t, rtc, testBundledSigner(t))
	} else {
		f = service(t, rtc)
	}
	target, _ := f.mux.Handler(httptest.NewRequest("POST", "/v1/rooms/test/preflight", nil))
	f.mux.HandleFunc("POST /v1/rooms/{room}/preflight", func(w http.ResponseWriter, r *http.Request) {
		if _, err := os.Stat(filepath.Join(dir, "hold-preflight")); err == nil {
			select {
			case <-r.Context().Done():
				return
			case <-time.After(15 * time.Second):
			}
		}
		target.ServeHTTP(w, r)
	})
	account := f.account(t, "Desktop")
	e, _ := f.client(t)
	file := f.enroll(t, e, account, false)
	handler, err := passkeyhttp.New(f.db, config.PasskeyConfig{RPID: "localhost", Origins: []string{f.origin}}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ok(t, err)
	f.mux.HandleFunc("POST /api/client/device/poll", func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(io.LimitReader(r.Body, 4097))
		r.Body.Close()
		r.Body = io.NopCloser(bytes.NewReader(data))
		var p struct {
			ID string `json:"request_id"`
		}
		_ = json.Unmarshal(data, &p)
		_ = f.db.ApproveDeviceAuthorization(r.Context(), p.ID, account, account.CredentialJSON)
		handler.ServeHTTP(w, r)
	})
	ok(t, os.MkdirAll(dir, 0700))
	pin, err := json.Marshal(obj{"public_key": f.trust})
	ok(t, err)
	ok(t, os.WriteFile(filepath.Join(dir, "AuthorizationTrust.json"), pin, 0600))
	// An isolated test package may reuse the disposable enrolled device so that
	// UI tests can exercise active calls without an interactive recovery picker.
	vault, err := os.ReadFile(e.vault.path)
	ok(t, err)
	ok(t, os.WriteFile(filepath.Join(dir, "identities.v5"), vault, 0600))
	ok(t, os.WriteFile(filepath.Join(dir, "sample.chirpkey"), file, 0600))
	ok(t, os.WriteFile(filepath.Join(dir, "origin.txt"), []byte(f.origin), 0600))
	fmt.Println("UI fixture listening at", f.origin)
	replaced := false
	end := time.Now().Add(12 * time.Minute)
	for time.Now().Before(end) {
		if _, err := os.Stat(filepath.Join(dir, "stop")); err == nil {
			return
		}
		if _, err := os.Stat(filepath.Join(dir, "replace-login")); err == nil && !replaced {
			e.reset(f.ctx)
			if result := f.exchange(t, e, account, false); result["step"] != "signedIn" {
				t.Fatal("fixture could not replace the desktop login")
			}
			replaced = true
		}
		time.Sleep(200 * time.Millisecond)
	}
}
