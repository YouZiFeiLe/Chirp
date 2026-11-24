package main

import (
	"bufio"
	"bytes"
	"cmp"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// Opt-in process-to-process timing. Use the same fixture and command stream
// with either release binary; neither binary needs benchmark instrumentation.
var startupProtocol = flag.String("chirp-startup-protocol", "", "Windows protocol executable for the joining client")
var startupPeer = flag.String("chirp-startup-peer", "", "optional different executable for the client already in the room")
var startupRepeats = flag.Int("chirp-startup-repeats", 3, "number of previously verified rejoins")
var startupHTTPDelay = flag.Duration("chirp-startup-http-delay", 0, "added response time per control HTTP request")

type startupFrame struct {
	ID           uint64
	Event, Error string
	Data         json.RawMessage
	at           time.Time
}

type startupState struct {
	Entry, Identity, Group, Status, Sender, URL, Step string
	Ready                                             bool
	Packet                                            []byte
	Peers                                             []struct{ ID string }
	Verification                                      struct {
		ID, Step string
		Decimals []int
	}
}

func (m startupFrame) state() startupState {
	var state startupState
	_ = json.Unmarshal(m.Data, &state)
	return state
}

type startupClient struct {
	pid   int
	input *json.Encoder
	out   chan startupFrame
	read  []startupFrame
	seq   uint64
}

type startupDevice struct {
	enrolled *engine
	account  store.PasskeyAccount
}

func enrollStartupDevice(t *testing.T, f fixture, name string) startupDevice {
	t.Helper()
	enrolled, _ := f.client(t)
	account := f.account(t, name)
	f.enroll(t, enrolled, account, false)
	return startupDevice{enrolled: enrolled, account: account}
}

func startProtocol(t *testing.T, f fixture, executable string, device startupDevice) *startupClient {
	t.Helper()
	client := launchProtocol(t, f, executable, device)
	client.login(t, f, device.account)
	return client
}

func launchProtocol(t *testing.T, f fixture, executable string, device startupDevice) *startupClient {
	t.Helper()
	dir := t.TempDir()
	for source, filename := range map[string]string{executable: "Chirp.Protocol.exe", filepath.Join(".build", "winui-native", "chirp_mls_native.dll"): "chirp_mls_native.dll"} {
		data, err := os.ReadFile(source)
		ok(t, err)
		ok(t, os.WriteFile(filepath.Join(dir, filename), data, 0700))
	}
	pin, err := json.Marshal(obj{"public_key": f.trust})
	ok(t, err)
	ok(t, os.WriteFile(filepath.Join(dir, "AuthorizationTrust.json"), pin, 0600))
	cmd := exec.CommandContext(t.Context(), filepath.Join(dir, "Chirp.Protocol.exe"), "-loopback", "-data", filepath.Dir(device.enrolled.vault.path))
	input, err := cmd.StdinPipe()
	ok(t, err)
	output, err := cmd.StdoutPipe()
	ok(t, err)
	ok(t, cmd.Start())
	t.Cleanup(func() { _ = input.Close(); _ = cmd.Wait() })
	client := &startupClient{pid: cmd.Process.Pid, input: json.NewEncoder(input), out: make(chan startupFrame, 256)}
	go func() {
		defer close(client.out)
		decoder := json.NewDecoder(bufio.NewReader(output))
		for {
			var frame startupFrame
			if decoder.Decode(&frame) != nil {
				return
			}
			frame.at = time.Now()
			select {
			case client.out <- frame:
			case <-t.Context().Done():
				return
			}
		}
	}()
	return client
}

func (client *startupClient) login(t *testing.T, f fixture, account store.PasskeyAccount) {
	t.Helper()
	client.call(t, "discover", args{Address: f.origin})
	authURL, err := url.Parse(client.call(t, "browser", args{}).state().URL)
	ok(t, err)
	q := authURL.Query()
	auth := store.ClientAuthorization{ClientID: q.Get("client_id"), RedirectURI: q.Get("redirect_uri"), State: q.Get("state"), CodeChallenge: q.Get("code_challenge"), CodeChallengeMethod: q.Get("code_challenge_method")}
	code, err := f.db.CreateClientAuthorization(f.ctx, account, account.CredentialJSON, auth)
	ok(t, err)
	if client.call(t, "exchange", args{URL: store.WindowsClientRedirectURI + "?state=" + auth.State + "&code=" + code}).state().Step != "signedIn" {
		t.Fatal("disposable device did not sign in")
	}
}

func (p *startupClient) wait(t *testing.T, since time.Time, label string, match func(startupFrame) bool) startupFrame {
	t.Helper()
	for _, m := range p.read {
		if !m.at.Before(since) && match(m) {
			return m
		}
	}
	timeout := time.NewTimer(30 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case <-timeout.C:
			t.Fatalf("timed out waiting for %s", label)
		case m, open := <-p.out:
			if !open {
				t.Fatalf("protocol exited while waiting for %s", label)
			}
			if m.Event == "roomError" || m.Event == "fatal" || m.Event == "signedOut" {
				t.Fatalf("%s: %s", m.Event, m.Data)
			}
			p.read = append(p.read, m)
			if !m.at.Before(since) && match(m) {
				return m
			}
		}
	}
}

func (p *startupClient) call(t *testing.T, op string, a args) startupFrame {
	t.Helper()
	p.seq++
	start := time.Now()
	ok(t, p.input.Encode(command{ID: p.seq, Op: op, Args: a}))
	reply := p.wait(t, start, op, func(m startupFrame) bool { return m.ID == p.seq })
	if reply.Error != "" {
		t.Fatalf("%s: %s", op, reply.Error)
	}
	return reply
}

func (p *startupClient) room(t *testing.T, since time.Time, label string, match func(startupState) bool) startupFrame {
	t.Helper()
	return p.wait(t, since, label, func(m startupFrame) bool { return m.Event == "room" && match(m.state()) })
}

func (p *startupClient) join(t *testing.T) startupFrame {
	t.Helper()
	start := time.Now()
	p.call(t, "join", args{ID: store.DefaultRoomID, Key: "latency"})
	return p.wait(t, start, "joined", func(m startupFrame) bool { return m.Event == "joined" })
}

func later(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// Wait for every client to recognize the entrant in the same secure generation.
func waitForStartupGroup(t *testing.T, since time.Time, clients []*startupClient, entrant string) (time.Time, string) {
	t.Helper()
	readyForEntrant := func(s startupState) bool {
		if !s.Ready || s.Group == "" || len(s.Peers) != len(clients) {
			return false
		}
		for _, peer := range s.Peers {
			if peer.ID == entrant {
				return true
			}
		}
		return false
	}
	var ready time.Time
	var group string
	for _, client := range clients {
		frame := client.room(t, since, "whole group secure", readyForEntrant)
		current := frame.state().Group
		if group != "" && current != group {
			t.Fatal("different secure generations")
		}
		ready, group = later(ready, frame.at), current
	}
	return ready, group
}

// Pump the same 20 ms voiced Opus frame used by the desktop decoder test.
// Stop the clock on an exact decrypted payload from this admission.
func firstVoice(t *testing.T, talker, listener *startupClient, sender, receiver, group string) (published, received time.Time) {
	t.Helper()
	published = talker.call(t, "mute", args{Entry: sender, Group: group}).at
	talker.call(t, "room", args{})
	packet, err := hex.DecodeString("28822e38f043dbaec91bf391756b9e04f658daa09409930b46f83cbbe22968267e636b99ddb9babf93d938e0d564fbc0")
	ok(t, err)
	voice := command{Op: "voice", Args: args{Group: group, Packet: packet}}
	ok(t, talker.input.Encode(voice))
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	timeout := time.NewTimer(10 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case <-tick.C:
			ok(t, talker.input.Encode(voice))
		case <-timeout.C:
			t.Fatal("peer did not decrypt the voice frame")
		case m, open := <-listener.out:
			if !open {
				t.Fatal(io.ErrUnexpectedEOF)
			}
			if m.Event != "audio" {
				continue
			}
			s := m.state()
			if s.Entry == receiver && s.Sender == sender && s.Group == group && bytes.Equal(s.Packet, packet) {
				return published, m.at
			}
		}
	}
}

func startupService(t *testing.T, rtc string, signer ed25519.PrivateKey, requests *atomic.Int64) fixture {
	t.Helper()
	return serviceWithHTTP(t, rtc, signer, func(h http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requests.Add(1)
			if *startupHTTPDelay > 0 {
				select {
				case <-time.After(*startupHTTPDelay):
				case <-r.Context().Done():
					return
				}
			}
			h.ServeHTTP(w, r)
		})
	})
}

func verifyStartupPeers(t *testing.T, start time.Time, guest, host *startupClient, guestEntry, hostEntry string) {
	t.Helper()
	verification := func(s startupState) bool { return len(s.Peers) == 2 && s.Status == "verify" && !s.Ready }
	hostPrompt := host.room(t, start, "host verification prompt", verification)
	guestPrompt := guest.room(t, start, "guest verification prompt", verification)
	requested := time.Now()
	guest.call(t, "verify", args{Action: "start", Peer: hostEntry})
	invite := host.room(t, requested, "SAS invitation", func(s startupState) bool { return s.Verification.Step == "incoming" })
	id := invite.state().Verification.ID
	host.call(t, "verify", args{Action: "accept", Peer: guestEntry, ID: id})
	numbers := func(s startupState) bool {
		return s.Verification.ID == id && s.Verification.Step == "compare" && len(s.Verification.Decimals) == 3
	}
	a := host.room(t, requested, "host safety code", numbers)
	b := guest.room(t, requested, "guest safety code", numbers)
	if !slices.Equal(a.state().Verification.Decimals, b.state().Verification.Decimals) {
		t.Fatal("safety codes differ")
	}
	host.call(t, "verify", args{Action: "confirm", Peer: guestEntry, ID: id})
	confirmed := time.Now()
	guest.call(t, "verify", args{Action: "confirm", Peer: hostEntry, ID: id})
	t.Logf("SAS prompt_ms=%d codes_ms=%d last_confirm_ms=%d", later(hostPrompt.at, guestPrompt.at).Sub(start).Milliseconds(), later(a.at, b.at).Sub(requested).Milliseconds(), confirmed.Sub(start).Milliseconds())
}

func TestRoomStartupLatency(t *testing.T) {
	if *startupProtocol == "" {
		t.Skip("opt-in Windows process-to-process latency measurement")
	}
	requireNative(t)
	_, signer, err := ed25519.GenerateKey(nil)
	ok(t, err)
	var requests atomic.Int64
	f := startupService(t, startSFU(t), signer, &requests)
	host := startProtocol(t, f, cmp.Or(*startupPeer, *startupProtocol), enrollStartupDevice(t, f, "Listener"))
	guest := startProtocol(t, f, *startupProtocol, enrollStartupDevice(t, f, "Talker"))
	hostEntry := host.join(t).state().Identity
	alone := func(s startupState) bool { return s.Ready && len(s.Peers) == 1 }
	host.room(t, time.Time{}, "single member ready", alone)
	for i := 0; i <= *startupRepeats; i++ {
		start := time.Now()
		initialRequests := requests.Load()
		join := guest.join(t)
		guestEntry := join.state().Identity
		if i == 0 {
			verifyStartupPeers(t, start, guest, host, guestEntry, hostEntry)
		}
		ready, group := waitForStartupGroup(t, start, []*startupClient{host, guest}, guestEntry)
		count := requests.Load() - initialRequests
		unmute := time.Now()
		published, voice := firstVoice(t, guest, host, guestEntry, hostEntry, group)
		t.Logf("STARTUP iteration=%d joined_ms=%d ready_ms=%d voice_ms=%d unmute_ms=%d publish_ms=%d http_to_ready=%d", i, join.at.Sub(start).Milliseconds(), ready.Sub(start).Milliseconds(), voice.Sub(start).Milliseconds(), voice.Sub(unmute).Milliseconds(), published.Sub(unmute).Milliseconds(), count)
		leave := time.Now()
		guest.call(t, "leave", args{})
		if i < *startupRepeats {
			host.room(t, leave, "single member restored", alone)
		}
	}
}

func TestFourPartyRoomStartupLatency(t *testing.T) {
	if *startupProtocol == "" {
		t.Skip("opt-in Windows four-party latency measurement")
	}
	requireNative(t)
	f := service(t, startSFU(t))
	var devices []startupDevice
	for _, name := range []string{"North", "South", "East", "West"} {
		devices = append(devices, enrollStartupDevice(t, f, name))
	}
	for i, device := range devices {
		for j, peer := range devices {
			if i != j {
				p := peer.enrolled.session
				ok(t, device.enrolled.social(f.ctx, "trust", p.Member.ID, p.Device.AccountKey, p.Device.LeafKey(), p.Member.Name))
			}
		}
	}
	var residents []*startupClient
	for _, device := range devices[:3] {
		residents = append(residents, startProtocol(t, f, cmp.Or(*startupPeer, *startupProtocol), device))
	}
	guest := startProtocol(t, f, *startupProtocol, devices[3])
	members := append(slices.Clone(residents), guest)
	var hostEntry string
	for i, client := range residents {
		start := time.Now()
		entry := client.join(t).state().Identity
		if i == 0 {
			hostEntry = entry
		}
		waitForStartupGroup(t, start, residents[:i+1], entry)
	}
	for i := range *startupRepeats {
		start := time.Now()
		join := guest.join(t)
		guestEntry := join.state().Identity
		ready, group := waitForStartupGroup(t, start, members, guestEntry)
		_, voice := firstVoice(t, guest, residents[0], guestEntry, hostEntry, group)
		t.Logf("FOUR sample=%d joined_ms=%d ready_ms=%d voice_ms=%d", i, join.at.Sub(start).Milliseconds(), ready.Sub(start).Milliseconds(), voice.Sub(start).Milliseconds())
		leave := time.Now()
		guest.call(t, "leave", args{})
		if i+1 < *startupRepeats {
			waitForStartupGroup(t, leave, residents, hostEntry)
		}
	}
}
