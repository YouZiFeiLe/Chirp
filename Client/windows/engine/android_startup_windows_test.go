//go:build integration

package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// The Android Activity drives admission and its own real microphone. Windows stays in the room.
func TestAndroidJoinsWindowsRoom(t *testing.T) {
	serial := os.Getenv("CHIRP_STARTUP_ANDROID")
	if serial == "" || *startupProtocol == "" {
		t.Skip("requires the Android timing instrument and the Windows protocol executable")
	}
	ip := net.ParseIP(os.Getenv("CHIRP_STARTUP_MEDIA_IP")).To4()
	if ip == nil || ip.IsLoopback() {
		t.Fatal("CHIRP_STARTUP_MEDIA_IP must name a host IPv4 interface reachable from the emulator")
	}
	rtc := startSFUAt(t, ip)
	var requests atomic.Int64
	f := startupService(t, rtc, testBundledSigner(t), &requests)
	android := enrollStartupDevice(t, f, "Android").enrolled
	host := startProtocol(t, f, *startupProtocol, enrollStartupDevice(t, f, "Windows"))
	hostID := host.join(t).state().Identity

	// Compare independently generated commitments. Both peers wait for a match before confirming.
	key := random(32)
	var want atomic.Pointer[string]
	matched := make(chan struct{}, 1)
	f.mux.HandleFunc("POST /test/peer-sas", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Role, Commitment string }
		if r.Header.Get("Authorization") != "Bearer "+android.session.Credential ||
			json.NewDecoder(http.MaxBytesReader(w, r.Body, 256)).Decode(&in) != nil || in.Role != "sender" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch expected := want.Load(); {
		case expected == nil:
			w.WriteHeader(http.StatusAccepted)
		case !hmac.Equal([]byte(in.Commitment), []byte(*expected)):
			w.WriteHeader(http.StatusConflict)
		default:
			select {
			case matched <- struct{}{}:
			default:
			}
			w.WriteHeader(http.StatusNoContent)
		}
	})
	config, err := f.db.Room(f.ctx, store.DefaultRoomID)
	ok(t, err)
	device := android.account.Active
	payload, err := json.Marshal(obj{"url": f.origin, "authorization_key": f.trust, "peer_comparison_key": b64(key),
		"production_flow": obj{"seed": b64(device.Seed), "device": device.Device, "credential": android.session.Credential,
			"identity": android.session.Identity, "name": "Android", "expires_at": android.session.Expires,
			"account_id": android.session.Member.ID, "room_name": config.DisplayName}})
	ok(t, err)
	adb := func(args ...string) {
		t.Helper()
		out, err := exec.CommandContext(t.Context(), "adb", append([]string{"-s", serial}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("adb %s: %s", args[0], out)
		}
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	ok(t, err)
	defer listener.Close()
	port := strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	for _, endpoint := range []string{f.origin, rtc, "tcp://localhost:" + port} {
		u, err := url.Parse(endpoint)
		ok(t, err)
		spec := "tcp:" + u.Port()
		adb("reverse", "--no-rebind", spec, spec)
		defer adb("reverse", "--remove", spec)
	}
	name := fmt.Sprintf("room-startup-%s.json", port)
	file := filepath.Join(t.TempDir(), name)
	ok(t, os.WriteFile(file, payload, 0600))
	const remote = "/sdcard/Android/data/cn.youzifeile.chirp.android/files/"
	adb("shell", "mkdir", "-p", remote)
	adb("push", file, remote+name)
	defer adb("shell", "rm", "-f", remote+name)
	ctx, stop := context.WithCancel(t.Context())
	defer stop()
	cmd := exec.CommandContext(ctx, "adb", "-s", serial, "shell", "am", "instrument", "-w", "-r",
		"-e", "class", "cn.youzifeile.chirp.ui.RoomStartupLatencyTest", "-e", "attachment_fixture", name,
		"-e", "peer_role", "sender", "-e", "timing_port", port, "-e", "startup_repeats", strconv.Itoa(*startupRepeats),
		"cn.youzifeile.chirp.android.test/androidx.test.runner.AndroidJUnitRunner")
	result := make(chan string, 1)
	go func() { output, _ := cmd.CombinedOutput(); result <- string(output) }()
	ok(t, listener.SetDeadline(time.Now().Add(time.Minute)))
	socket, err := listener.Accept()
	ok(t, err)
	defer socket.Close()
	read := bufio.NewScanner(socket)
	epoch := time.Now()
	send := func(line string) { _, err := fmt.Fprintln(socket, line); ok(t, err) }
	send("hello")
	var since time.Time
	for round := 0; round <= *startupRepeats; round++ {
		ok(t, socket.SetDeadline(time.Now().Add(90*time.Second)))
		for range 5 {
			if !read.Scan() || read.Text() != "clock" {
				t.Fatal("lost Android clock exchange", read.Err())
			}
			send(strconv.FormatInt(time.Since(epoch).Milliseconds(), 10))
		}
		host.room(t, since, "Windows alone", func(s startupState) bool { return s.Ready && len(s.Peers) == 1 })
		join := time.Now()
		send("solo")
		var confirmed int64
		if round == 0 {
			invite := host.room(t, join, "Android invitation", func(s startupState) bool { return s.Verification.Step == "incoming" })
			state := invite.state()
			var guest string
			for _, p := range state.Peers {
				if p.ID != hostID {
					guest = p.ID
				}
			}
			id := state.Verification.ID
			host.call(t, "verify", args{Action: "accept", ID: id, Peer: guest})
			codes := host.room(t, join, "Windows safety numbers", func(s startupState) bool {
				return s.Verification.ID == id && s.Verification.Step == "compare" && len(s.Verification.Decimals) == 3
			}).state().Verification.Decimals
			mac := hmac.New(sha256.New, key)
			fmt.Fprintf(mac, "%s/%d,%d,%d", id, codes[0], codes[1], codes[2])
			digest := hex.EncodeToString(mac.Sum(nil))
			want.Store(&digest)
			select {
			case <-matched:
			case <-time.After(35 * time.Second):
				t.Fatal("devices did not match their safety numbers")
			}
			confirmed = time.Since(epoch).Milliseconds()
			host.call(t, "verify", args{Action: "confirm", ID: id, Peer: guest})
		}
		ready := host.room(t, join, "Windows secured both devices", func(s startupState) bool {
			return s.Ready && s.Group != "" && len(s.Peers) == 2
		})
		state := ready.state()
		send(fmt.Sprintf("%d %d", confirmed, ready.at.Sub(epoch).Milliseconds()))
		audio := host.wait(t, ready.at, "authenticated Android microphone", func(m startupFrame) bool {
			if m.Event != "audio" {
				return false
			}
			s := m.state()
			return s.Entry == hostID && s.Sender != hostID && s.Group == state.Group && len(s.Packet) > 0 &&
				(s.Sender == state.Peers[0].ID || s.Sender == state.Peers[1].ID)
		})
		since = audio.at
		send(strconv.FormatInt(audio.at.Sub(epoch).Milliseconds(), 10))
	}
	if !read.Scan() || read.Text() != "done" {
		t.Fatal("Android did not complete all joins")
	}
	select {
	case log := <-result:
		if !strings.Contains(log, "OK (1 test)") || strings.Count(log, "ROOM_STARTUP round=") != *startupRepeats+1 {
			t.Fatal(log)
		}
		for line := range strings.Lines(log) {
			if _, row, found := strings.Cut(line, "ROOM_STARTUP "); found {
				t.Log(strings.TrimSpace(row))
			}
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Android instrument did not finish")
	}
}
