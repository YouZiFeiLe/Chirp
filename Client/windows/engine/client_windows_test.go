package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	lk "github.com/livekit/server-sdk-go/v2"
	"golang.org/x/sys/windows"
	"image"
	"image/jpeg"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/passkeyhttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

var testAppCadence = flag.Bool("chirp-app-cadence", false, "run the native room fixture with the desktop tick and the server deployment rotation interval")

// go test runs from the package directory and puts its binary in a temporary
// folder. Resolve the same DLL produced by the application build in both cases.
func TestMain(m *testing.M) {
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			os.Exit(1)
		}
		dir = parent
	}
	if err := os.Chdir(dir); err != nil {
		os.Exit(1)
	}
	dll = sync.OnceValues(func() (*windows.DLL, error) {
		return windows.LoadDLL(filepath.Join(dir, ".build", "winui-native", "chirp_mls_native.dll"))
	})
	os.Exit(m.Run())
}

func requireNative(t *testing.T) {
	t.Helper()
	if _, err := dll(); err != nil {
		t.Skip("Build the Windows native libraries with scripts/Build-Native.ps1 -Test")
	}
}

const testRoster = "fixture-roster"

func (m *mediaSession) grant(group string, index byte, until int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.grantLocked(group, testRoster, index, until)
}

// Matches Apple MediaChecks/Tests/VoiceReplayTests.swift, including its HKDF
// material, clear Opus header, nonce byte order, GCM tag and key-index trailer.
func TestAppleVoiceFramesAndLease(t *testing.T) {
	first, err := hex.DecodeString("f80729397c4dee0b5ab5460cd7b160032eba070000000000000000000000070c00")
	ok(t, err)
	earlier, err := hex.DecodeString("f87c624d442c7488134062139d879cdcc467950000000000000000000000020c00")
	ok(t, err)
	material := make([]byte, 32)
	for i := range material {
		material[i] = byte(i)
	}
	alice, err := newSenderKey(material)
	ok(t, err)
	bob, err := newSenderKey(bytes.Repeat([]byte{42}, 32))
	ok(t, err)
	m := mediaSession{packets: map[string]uint64{}}
	m.stage("first", testRoster, 0, map[string]*senderKey{"alice": alice, "bob": bob})
	check := func(from string, packet []byte, audible bool) {
		t.Helper()
		p, until := m.openVoice(from, packet)
		if audible != bytes.Equal(p, []byte{0xf8, 0xff, 0xfe}) || audible != (until > ticks()) {
			t.Fatal("unexpected playout decision", from, audible)
		}
	}
	check("alice", first, false)
	m.grant("room", 0, ticks()+3000)
	broken := bytes.Clone(first)
	broken[5] ^= 1
	check("alice", broken, false)
	check("bob", first, false)
	check("alice", first, true)
	check("alice", first, false)
	check("alice", earlier, true)
	alias, err := newSenderKey(material)
	ok(t, err)
	m.stage("next", testRoster, 1, map[string]*senderKey{"alice": alias})
	first[len(first)-1] = 1
	check("alice", first, false)
	m.grant("room", 1, ticks()+3000)
	check("alice", first, false)
	m.pause()
	check("alice", earlier, false)
}

func ok(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
func TestRecoveryVectorAndWindowsVault(t *testing.T) {
	requireNative(t)
	file, err := os.ReadFile(filepath.Join("internal", "identity", "testdata", "recovery-v1.json"))
	ok(t, err)
	var fixture struct{ File, Password, Payload string }
	ok(t, json.Unmarshal(file, &fixture))
	n, err := newNative("recovery")
	ok(t, err)
	defer n.close()
	var result struct{ Payload string }
	ok(t, n.request(obj{"operation": "security", "security": obj{"action": "decrypt", "password": fixture.Password, "file": fixture.File}}, &result))
	if result.Payload != fixture.Payload {
		t.Fatal("public Apple recovery vector differs")
	}
	if n.request(obj{"operation": "security", "security": obj{"action": "decrypt", "password": "wrong password", "file": fixture.File}}, &result) == nil {
		t.Fatal("incorrect password accepted")
	}
	dir := t.TempDir()
	v, err := loadVault(dir)
	ok(t, err)
	root := ed25519.NewKeyFromSeed(random(32))
	d := issueKey(root)
	v.Accounts["test-service|member"] = &storedAccount{Active: d}
	ok(t, v.save())
	ciphertext, err := os.ReadFile(v.path)
	ok(t, err)
	if bytes.Contains(ciphertext, []byte(d.Device.AccountKey)) {
		t.Fatal("plaintext identity store")
	}
	reopened, err := loadVault(dir)
	ok(t, err)
	if !bytes.Equal(d.Seed, reopened.Accounts["test-service|member"].Active.Seed) {
		t.Fatal("device identity not retained")
	}
	e := engine{vault: reopened}
	_, err = e.handle(context.Background(), command{Op: "clearLocalData"})
	ok(t, err)
	fresh, err := loadVault(dir)
	ok(t, err)
	if len(fresh.Accounts) != 0 {
		t.Fatal("local identities survived explicit clear")
	}
}

func TestDirectoryHintAndCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	served := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture" || r.Header.Get("Accept") != "text/event-stream" {
			w.WriteHeader(401)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "event: state\ndata: {\"server_id\":\"fixture\",\"revision\":2}\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(served)
	}))
	defer server.Close()
	go watchDirectory(ctx, server.URL, "fixture", func(kind string, _ any) {
		if kind == "directoryChanged" {
			cancel()
		}
	})
	select {
	case <-served:
	case <-time.After(3 * time.Second):
		cancel()
		t.Fatal("directory feed failed to deliver and cancel")
	}
}

type mediaDirectory struct{}

func (mediaDirectory) Participants(context.Context, string) ([]room.Participant, error) {
	return []room.Participant{}, nil
}
func (mediaDirectory) EnsureRoom(context.Context, string) error { return nil }

type fixture struct {
	db            *store.Store
	origin, trust string
	ctx           context.Context
	mux           *http.ServeMux
}
type notice struct {
	name string
	data any
}

func service(t *testing.T, rtc string) fixture {
	t.Helper()
	_, signer, err := ed25519.GenerateKey(nil)
	ok(t, err)
	return serviceWithAuthority(t, rtc, signer)
}

func serviceWithAuthority(t *testing.T, rtc string, sign ed25519.PrivateKey) fixture {
	return serviceWithHTTP(t, rtc, sign, func(h http.Handler) http.Handler { return h })
}

func serviceWithHTTP(t *testing.T, rtc string, sign ed25519.PrivateKey, wrap func(http.Handler) http.Handler) fixture {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	mux := http.NewServeMux()
	web := httptest.NewServer(wrap(mux))
	origin := strings.Replace(web.URL, "127.0.0.1", "localhost", 1)
	dir := t.TempDir()
	db, err := store.Open(ctx, filepath.Join(dir, "test.db"))
	ok(t, err)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	pk := sign.Public().(ed25519.PublicKey)
	auth, err := authorization.Open(filepath.Join(dir, "auth.db"), origin, sign)
	ok(t, err)
	policy := group.DefaultPolicy()
	policy.Rotation = 8 * time.Second
	if *testAppCadence {
		policy.Rotation = 60 * time.Second
	}
	sfu := group.New(db, policy, logger, origin)
	go sfu.Monitor(ctx)
	passkey, err := passkeyhttp.New(db, config.PasskeyConfig{RPID: "localhost", Origins: []string{origin}}, logger)
	ok(t, err)
	files, err := httpapi.NewAttachmentStorage(db, filepath.Join(dir, "attachments"))
	ok(t, err)
	api := httpapi.NewWithAttachments(db, mediaDirectory{}, room.Issuer{APIKey: "chirp-test", APISecret: strings.Repeat("sample-", 8), TTL: 2 * time.Minute}, rtc, origin, logger, config.DefaultClientEndpoints(origin), files, auth.DeviceRevoked)
	mux.Handle("/v1/", api)
	mux.Handle("/v1/group/", sfu)
	mux.Handle("/api/", passkey)
	mux.Handle("/authorization/", http.StripPrefix("/authorization", auth.Handler()))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"service":"chirp","status":"ok"}`)
	})
	t.Cleanup(func() { cancel(); web.Close(); files.Close(); auth.Close(); db.Close() })
	return fixture{db, origin, b64(pk), ctx, mux}
}
func (f fixture) account(t *testing.T, name string) store.PasskeyAccount {
	t.Helper()
	id, err := store.NewPasskeyID()
	ok(t, err)
	a := store.PasskeyAccount{ID: id, Nickname: name, CredentialID: random(16), CredentialJSON: []byte(`{"fixture":true}`)}
	req, err := f.db.RegisterPasskey(f.ctx, a)
	ok(t, err)
	_, err = f.db.ApproveRegistration(f.ctx, req.RequestID)
	ok(t, err)
	return a
}
func (f fixture) client(t *testing.T) (*engine, chan notice) {
	t.Helper()
	v, err := loadVault(t.TempDir())
	ok(t, err)
	events := make(chan notice, 512)
	e := &engine{vault: v, cache: t.TempDir(), trustKey: f.trust, local: true, notify: func(name string, data any) {
		select {
		case events <- notice{name, data}:
		default:
		}
	}}
	_, err = e.handle(f.ctx, command{Op: "discover", Args: args{Address: f.origin}})
	ok(t, err)
	t.Cleanup(func() { e.reset(f.ctx) })
	return e, events
}
func (f fixture) exchange(t *testing.T, e *engine, a store.PasskeyAccount, phone bool) obj {
	t.Helper()
	result, err := e.begin(f.ctx, phone)
	ok(t, err)
	callback := ""
	if phone {
		pending, err := e.exchange(f.ctx, "")
		ok(t, err)
		if pending["step"] != "waiting" {
			t.Fatal(pending["step"])
		}
		ok(t, f.db.ApproveDeviceAuthorization(f.ctx, e.flow.requestID, a, a.CredentialJSON))
	} else {
		u, err := url.Parse(result["url"].(string))
		ok(t, err)
		q := u.Query()
		auth := store.ClientAuthorization{ClientID: q.Get("client_id"), RedirectURI: q.Get("redirect_uri"), State: q.Get("state"), CodeChallenge: q.Get("code_challenge"), CodeChallengeMethod: q.Get("code_challenge_method")}
		code, err := f.db.CreateClientAuthorization(f.ctx, a, a.CredentialJSON, auth)
		ok(t, err)
		if _, err = e.exchange(f.ctx, store.WindowsClientRedirectURI+"?state=stale&code="+code); err == nil {
			t.Fatal("unbound callback accepted")
		}
		callback = store.WindowsClientRedirectURI + "?state=" + auth.State + "&code=" + code
	}
	result, err = e.exchange(f.ctx, callback)
	ok(t, err)
	return result
}

const password = "A public test recovery password"

func (f fixture) enroll(t *testing.T, e *engine, a store.PasskeyAccount, phone bool) []byte {
	t.Helper()
	if f.exchange(t, e, a, phone)["step"] != "backup" {
		t.Fatal("new account skipped recovery")
	}
	b, err := e.backup(password)
	ok(t, err)
	if _, err = e.backup("A different recovery password"); err == nil {
		t.Fatal("unconfirmed recovery export was overwritten")
	}
	file := b["file"].([]byte)
	continued := f.exchange(t, e, a, phone)
	if continued["step"] != "resumeBackup" || !bytes.Equal(file, continued["file"].([]byte)) {
		t.Fatal("interrupted recovery did not retain the original root and encrypted export")
	}
	signed, err := e.recover(f.ctx, file, password, true)
	ok(t, err)
	if signed["step"] != "signedIn" {
		t.Fatal("backup confirmation did not activate")
	}
	_, err = e.handle(f.ctx, command{Op: "state"})
	ok(t, err)
	_, err = e.handle(f.ctx, command{Op: "friends"})
	ok(t, err)
	return file
}
func TestWindowsIdentitySetupRecoveryAndPairing(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	a := f.account(t, "River")
	one, _ := f.client(t)
	backup := f.enroll(t, one, a, false)
	two, _ := f.client(t)
	if f.exchange(t, two, a, true)["step"] != "recover" {
		t.Fatal("missing existing account")
	}
	signed, err := two.recover(f.ctx, backup, password, false)
	ok(t, err)
	if signed["step"] != "signedIn" {
		t.Fatal("recovery failed")
	}
	three, _ := f.client(t)
	if f.exchange(t, three, a, false)["step"] != "recover" {
		t.Fatal("missing existing account")
	}
	start, err := three.devicePair(f.ctx, "pairNew", args{})
	ok(t, err)
	_, err = two.devicePair(f.ctx, "pairOld", args{Code: start.(obj)["code"].(string)})
	ok(t, err)
	_, err = three.devicePair(f.ctx, "pairPoll", args{})
	ok(t, err)
	_, err = two.devicePair(f.ctx, "pairPoll", args{})
	ok(t, err)
	digits := three.pairing.digits
	if len(digits) != 3 {
		t.Fatal("missing SAS digits")
	}
	code := fmt.Sprintf("%04d%04d%04d", digits[0], digits[1], digits[2])
	if _, err = two.devicePair(f.ctx, "pairConfirm", args{Code: "0000"}); err == nil {
		t.Fatal("incorrect SAS accepted")
	}
	_, err = three.devicePair(f.ctx, "pairConfirm", args{})
	ok(t, err)
	_, err = two.devicePair(f.ctx, "pairConfirm", args{Code: code, Enabled: true})
	ok(t, err)
	last, err := three.devicePair(f.ctx, "pairPoll", args{})
	ok(t, err)
	if last.(obj)["step"] != "signedIn" {
		t.Fatal("paired device failed to sign in")
	}
	_, err = three.handle(f.ctx, command{Op: "devices"})
	ok(t, err)
	_, err = three.handle(f.ctx, command{Op: "revoke", Args: args{Key: one.account.Active.Device.LeafKey()}})
	ok(t, err)
}
func startSFU(t *testing.T) string {
	t.Helper()
	return startSFUAt(t, net.IPv4(127, 0, 0, 1))
}

func startSFUAt(t *testing.T, ip net.IP) string {
	t.Helper()
	exe := os.Getenv("CHIRP_LIVEKIT_SERVER")
	if exe == "" {
		matches, _ := filepath.Glob(".build/windows-tools/livekit-*/livekit-server.exe")
		if len(matches) > 0 {
			exe = matches[len(matches)-1]
		}
	}
	if exe == "" {
		t.Skip("Set CHIRP_LIVEKIT_SERVER to the pinned LiveKit server to run the two-client media check")
	}
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	ok(t, err)
	port := tcp.Addr().(*net.TCPAddr).Port
	tcp.Close()
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	ok(t, err)
	mediaPort := udp.LocalAddr().(*net.UDPAddr).Port
	udp.Close()
	interfaces := ""
	if !ip.IsLoopback() {
		interfaces = fmt.Sprintf("  ips:\n    includes: [%s/32]\n", ip)
	}
	config := fmt.Sprintf("port: %d\nbind_addresses: [127.0.0.1]\nkeys:\n  chirp-test: %s\nrtc:\n%s  node_ip: %s\n  udp_port: %d\n  tcp_port: 0\n  use_external_ip: false\n  enable_loopback_candidate: true\nturn:\n  enabled: false\n", port, strings.Repeat("sample-", 8), interfaces, ip, mediaPort)
	path := filepath.Join(t.TempDir(), "livekit.yaml")
	ok(t, os.WriteFile(path, []byte(config), 0600))
	var logs bytes.Buffer
	cmd := exec.Command(exe, "--config", path)
	cmd.Stdout = &logs
	cmd.Stderr = &logs
	ok(t, cmd.Start())
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if t.Failed() {
			s := logs.String()
			if len(s) > 3500 {
				s = s[len(s)-3500:]
			}
			t.Log(s)
		}
	})
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for i := 0; i < 80; i++ {
		c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			c.Close()
			return "ws://" + addr
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("SFU did not start")
	return ""
}
func TestThreePartyVerificationBusy(t *testing.T) {
	requireNative(t)
	if _, ok := any(lk.NewRoom(nil)).(channels); !ok {
		t.Skip("Run Build-Native.ps1 -Test for the pinned LiveKit media build")
	}
	f := service(t, startSFU(t))
	var clients []*engine
	for _, name := range []string{"Alice", "Bob", "Carol"} {
		e, _ := f.client(t)
		f.enroll(t, e, f.account(t, name), false)
		clients = append(clients, e)
	}
	for _, e := range clients {
		ok(t, e.joinRoom(f.ctx, store.DefaultRoomID, ""))
	}
	for _, e := range clients {
		ok(t, e.fetchSnapshot(f.ctx, e.room, e.room.action("snapshot")))
		ok(t, e.refreshAuth(f.ctx, e.roomRoots(), true))
		ok(t, e.signals(f.ctx, e.room))
		if len(e.room.snap.Members) != 3 {
			t.Fatal("all three devices must be present before sending invitations")
		}
	}
	poll := func(participants ...*engine) {
		t.Helper()
		for _, e := range participants {
			ok(t, e.signals(f.ctx, e.room))
		}
	}
	act := func(e, peer *engine, action, id string) string {
		t.Helper()
		ok(t, e.verify(f.ctx, action, peer.room.join.Identity, id))
		return e.room.verification.ID
	}
	expect := func(e, peer *engine, id, step string) {
		t.Helper()
		v := e.room.verification
		if v == nil || v.ID != id || v.Peer != peer.room.join.Identity || v.Step != step {
			t.Fatalf("%s expected %s with %s on invitation %s, got %+v", e.session.Member.Name, step, peer.session.Member.Name, id, v)
		}
	}
	busyReply := func(sender, recipient *engine, id string) {
		t.Helper()
		ok(t, sender.signal(f.ctx, sender.room, sender.room.peer(recipient.room.join.Identity), "sas",
			obj{"transaction": id, "message": `{"kind":"Busy"}`}))
	}

	a, b, c := clients[0], clients[1], clients[2]
	if a.room.join.Identity > b.room.join.Identity {
		a, b = b, a
	}
	// Two invitations can be queued before B polls its inbox.
	first := act(a, b, "start", "")
	second := act(c, b, "start", "")
	poll(b, c)
	expect(b, a, first, "incoming")
	expect(c, b, second, "peerBusy")
	act(b, a, "cancel", first)
	poll(a)
	expect(a, b, first, "peerCancelled")

	// A and B invite each other before either receives the other's request.
	ab := act(a, b, "start", "")
	act(b, a, "start", "")
	poll(b, a)
	expect(a, b, ab, "sent")
	expect(b, a, ab, "incoming")

	ca := act(c, a, "start", "")
	busyReply(b, c, ca)
	poll(c)
	expect(c, a, ca, "sent") // Only the invited peer can answer.
	poll(a, c)
	expect(c, a, ca, "peerBusy")
	expect(a, b, ab, "sent")
	expect(b, a, ab, "incoming")
	if !c.canRetryVerification(c.room) {
		t.Fatal("busy invitation should be retryable")
	}

	act(b, a, "accept", ab)
	poll(a, b, a, b)
	expect(a, b, ab, "compare")
	expect(b, a, ab, "compare")
	codes := slices.Clone(a.room.verification.Decimals)
	act(a, b, "confirm", ab)
	cb := act(c, b, "start", "") // C can choose another member directly from the busy result.
	poll(b, c)
	expect(c, b, cb, "peerBusy")
	expect(a, b, ab, "confirmed")
	expect(b, a, ab, "compare")
	if len(codes) != 3 || !slices.Equal(codes, a.room.verification.Decimals) || !slices.Equal(codes, b.room.verification.Decimals) {
		t.Fatal("a third-party invitation changed the comparison codes")
	}
	if c.trusted(*c.room.peer(a.room.join.Identity)) || c.trusted(*c.room.peer(b.room.join.Identity)) {
		t.Fatal("a busy reply granted device trust")
	}
	act(b, a, "confirm", ab)
	poll(a, b)
	expect(a, b, ab, "completed")
	expect(b, a, ab, "completed")

	retry := act(c, b, "retry", cb)
	if retry == cb {
		t.Fatal("retry reused the busy invitation")
	}
	busyReply(b, c, cb)
	poll(c)
	expect(c, b, retry, "sent")
	poll(b)
	expect(b, c, retry, "incoming")
	act(b, c, "accept", retry)
	poll(c, b, c, b)
	busyReply(b, c, retry)
	poll(c)
	expect(c, b, retry, "compare") // A busy reply cannot end an accepted exchange.
	act(c, b, "confirm", retry)
	act(b, c, "confirm", retry)
	poll(b, c)
	expect(c, b, retry, "completed")
	expect(b, c, retry, "completed")
}

func TestNativeTwoPartyRoom(t *testing.T) {
	requireNative(t)
	if _, ok := any(lk.NewRoom(nil)).(channels); !ok {
		t.Skip("Run Build-Native.ps1 -Test for the pinned LiveKit media build")
	}
	f := service(t, startSFU(t))
	left, sentEvents := f.client(t)
	right, events := f.client(t)
	f.enroll(t, left, f.account(t, "North"), false)
	f.enroll(t, right, f.account(t, "South"), true)
	ok(t, left.joinRoom(f.ctx, store.DefaultRoomID, ""))
	setListening := func(e *engine, entry string, enabled bool) {
		t.Helper()
		_, err := e.handle(f.ctx, command{Op: "setListening", Args: args{Entry: entry, Enabled: enabled}})
		ok(t, err)
	}
	setListening(left, left.room.join.Identity, true)
	ok(t, right.joinRoom(f.ctx, store.DefaultRoomID, ""))
	// The newcomer changed the generation after the host read its admission.
	// Let a stale round write actually reach the server before consuming the hint.
	oldGeneration := left.room.snap.Generation
	err := left.advance(f.ctx, left.room, &left.room.current, left.room.snap.Members, left.room.snap.Phase, "", "", 0)
	if err == nil || err.Error() != "GROUP_CHANGED" {
		t.Fatalf("stale initial round returned %v", err)
	}
	ok(t, left.resyncRound(f.ctx, left.room, err))
	if left.room.snap.Generation <= oldGeneration || len(left.room.snap.Members) != 2 || left.room.current.ack || left.room.media.ready() {
		t.Fatal("resynchronization retained the obsolete round or granted early media")
	}
	stagedBeforeSwitch := false
	interval, timeout := 60*time.Millisecond, 18*time.Second
	if *testAppCadence {
		interval, timeout = 900*time.Millisecond, 95*time.Second
	}
	drive := func(until func() bool) {
		t.Helper()
		limit := time.Now().Add(timeout)
		for !until() {
			if time.Now().After(limit) {
				t.Fatalf("room timed out, left %s (%s), right %s (%s)", left.room.status, left.room.snap.Phase, right.room.status, right.room.snap.Phase)
			}
			ok(t, left.tickRoom(f.ctx))
			ok(t, right.tickRoom(f.ctx))
			for _, r := range []*activeRoom{left.room, right.room} {
				if r.candidate.ack && !r.candidate.activated {
					r.media.mu.Lock()
					staged := r.media.slots[r.candidate.epoch%2].group == r.candidate.group
					r.media.mu.Unlock()
					if !staged {
						t.Fatal("candidate was acknowledged before media installation")
					}
					stagedBeforeSwitch = true
				}
			}
			time.Sleep(interval)
		}
	}
	drive(func() bool { return left.room.status == "verify" && right.room.status == "verify" })
	peer := right.room.join.Identity
	showsAudio := func(viewer *engine, entry string, mic bool, listening any) bool {
		for _, person := range viewer.roomView().(obj)["peers"].([]obj) {
			if person["id"] == entry {
				return person["mic"] == mic && person["listening"] == listening
			}
		}
		return false
	}
	drive(func() bool {
		return showsAudio(right, left.room.join.Identity, false, true) && showsAudio(left, peer, false, nil)
	})
	setListening(right, peer, false)
	setListening(right, left.room.join.Identity, true) // A late toggle from a different entry.
	drive(func() bool {
		remote := left.room.media.room.GetParticipantByIdentity(peer)
		return remote != nil && remote.Attributes()["chirp.listening"] == "false" &&
			showsAudio(left, peer, false, false) && showsAudio(right, peer, false, false)
	})
	ok(t, left.verify(f.ctx, "start", peer, ""))
	drive(func() bool { return right.room.verification != nil && right.room.verification.Step == "incoming" })
	cancelledID := right.room.verification.ID
	ok(t, right.verify(f.ctx, "cancel", left.room.join.Identity, cancelledID))
	drive(func() bool { return left.room.verification != nil && left.room.verification.Step == "peerCancelled" })
	ok(t, right.verify(f.ctx, "dismiss", left.room.join.Identity, cancelledID))
	ok(t, left.verify(f.ctx, "retry", peer, cancelledID))
	drive(func() bool { return right.room.verification != nil && right.room.verification.Step == "incoming" })
	id := right.room.verification.ID
	if id == cancelledID || left.verify(f.ctx, "confirm", peer, cancelledID) == nil {
		t.Fatal("restarting verification reused an ended transaction")
	}
	ok(t, right.verify(f.ctx, "accept", left.room.join.Identity, id))
	drive(func() bool {
		return len(left.room.verification.Decimals) == 3 && len(right.room.verification.Decimals) == 3
	})
	if fmt.Sprint(left.room.verification.Decimals) != fmt.Sprint(right.room.verification.Decimals) {
		t.Fatal("SAS mismatch")
	}
	ok(t, left.verify(f.ctx, "confirm", peer, id))
	if v := left.room.verification; v.Step != "confirmed" || len(v.Decimals) != 3 {
		t.Fatal("confirmation hid the device comparison numbers")
	}
	ok(t, right.verify(f.ctx, "confirm", left.room.join.Identity, id))
	drive(func() bool { return left.room.media.ready() && right.room.media.ready() })
	if left.room.verification.Step != "completed" || right.room.verification.Step != "completed" {
		t.Fatal("mutual trust did not retain a completed verification")
	}
	if len(left.room.media.room.LocalParticipant.TrackPublications()) != 0 || len(right.room.media.room.LocalParticipant.TrackPublications()) != 0 {
		t.Fatal("joining a room published a microphone before the user enabled it")
	}
	checkTrustStatementArrivalOrder(t, f, left, right)
	dataSent := false
	drive(func() bool {
		if !dataSent {
			dataSent = left.room.media.send("both microphones off", nil) == nil
		}
		for len(events) > 0 {
			event := <-events
			if event.name == "chat" && event.data.(chatMessage).Text == "both microphones off" {
				return true
			}
		}
		return false
	})
	checkSlowRoomCommand(t, f, left, right)
	checkQueuedRTCWrite(t, left.room.media)
	drive(func() bool { return left.room.media.ready() && right.room.media.ready() })
	sent := false
	gotText, gotVoice := false, false
	ok(t, left.room.media.mute(false))
	setListening(left, left.room.join.Identity, false)
	drive(func() bool { return showsAudio(right, left.room.join.Identity, true, false) })
	setListening(left, left.room.join.Identity, true)
	drive(func() bool { return showsAudio(right, left.room.join.Identity, true, true) })
	ok(t, left.room.media.mute(true))
	drive(func() bool { return showsAudio(right, left.room.join.Identity, false, true) })
	ok(t, left.room.media.mute(false))
	audio := []byte{0xf8, 0xff, 0xfe}
	drive(func() bool {
		if !sent {
			sent = left.room.media.send("native transport", nil) == nil
		}
		left.room.media.capture(groupID(left.room.snap), audio, nil)
		for len(events) > 0 {
			e := <-events
			if e.name == "chat" && e.data.(chatMessage).Text == "native transport" {
				gotText = true
			}
			if e.name == "chat" && e.data.(chatMessage).Text == "stale queued payload" {
				t.Fatal("unauthorized queued packet reached the other client")
			}
			if e.name == "audio" && e.data.(obj)["entry"] == right.room.join.Identity && bytes.Equal(e.data.(obj)["packet"].([]byte), audio) {
				gotVoice = true
			}
		}
		return gotText && gotVoice
	})
	drive(func() bool {
		left.room.media.capture(groupID(left.room.snap), audio, nil)
		diagnostic := right.room.media.peerDiagnostic(left.room.join.Identity)
		jitter, _ := diagnostic["jitterMs"].(*float64)
		loss, _ := diagnostic["packetsLost"].(*int32)
		return diagnostic["encryption"] == "verified" && jitter != nil && loss != nil
	})
	pixels := image.NewRGBA(image.Rect(0, 0, 1500, 1200))
	copy(pixels.Pix, random(len(pixels.Pix)))
	var jpg, thumb bytes.Buffer
	ok(t, jpeg.Encode(&jpg, pixels, &jpeg.Options{Quality: 96}))
	ok(t, jpeg.Encode(&thumb, pixels.SubImage(image.Rect(0, 0, 48, 48)), nil))
	payload := jpg.Bytes()
	if len(payload) < fileChunk {
		t.Fatal("fixture must cross a network chunk boundary")
	}
	source := filepath.Join(t.TempDir(), "sample.jpg")
	ok(t, os.WriteFile(source, payload, 0600))
	scope := left.fileScope.Load()
	result, err := left.handle(f.ctx, command{Op: "upload", Args: args{Entry: scope.entry, Revision: scope.revision, Group: groupID(left.room.snap), Path: source, File: thumb.Bytes()}})
	ok(t, err)
	fileID := result.(obj)["id"].(string)
	dest := filepath.Join(t.TempDir(), "received.jpg")
	begun, exporting := false, false
	drive(func() bool {
		for len(sentEvents) > 0 {
			event := <-sentEvents
			if event.name == "transfer" && event.data.(obj)["error"] != nil {
				t.Fatal(event.data.(obj)["error"])
			}
		}
		for len(events) > 0 {
			event := <-events
			switch event.name {
			case "chat":
				d := event.data.(chatMessage).Attachment
				if d != nil && d.Info.ID == fileID && !begun {
					if !bytes.Equal(openReferenceThumbnail(t, *d), thumb.Bytes()) {
						t.Fatal("Mac-format reference could not read the outgoing thumbnail")
					}
					if bytes.Equal(d.Thumbnail, thumb.Bytes()) {
						t.Fatal("plaintext thumbnail on wire")
					}
					right.acceptChat(chatDelivery{event.data.(chatMessage), right.fileScope.Load()}, func(name string, value any) {
						if name != "chat" || !bytes.Equal(value.(obj)["thumbnail"].([]byte), thumb.Bytes()) {
							t.Fatal("received thumbnail differs")
						}
					})
					begun = true
				}
			case "transfer":
				data := event.data.(obj)
				if data["error"] != nil {
					t.Fatal(data["error"])
				}
				if data["done"] == true && !exporting {
					s := right.fileScope.Load()
					a := args{Entry: s.entry, Revision: s.revision, ID: fileID, Path: dest}
					preview, err := right.handle(f.ctx, command{Op: "previewFile", Args: a})
					ok(t, err)
					if !bytes.Equal(preview.(obj)["file"].([]byte), payload) {
						t.Fatal("in-memory preview differs")
					}
					allowed, err := right.handle(f.ctx, command{Op: "prepareExport", Args: a})
					ok(t, err)
					if allowed.(obj)["entry"] != a.Entry || allowed.(obj)["revision"] != a.Revision {
						t.Fatal("folder picker received a stale authorization")
					}
					_, err = right.handle(f.ctx, command{Op: "download", Args: a})
					ok(t, err)
					exporting = true
				}
			}
		}
		_, statErr := os.Stat(dest)
		return exporting && statErr == nil
	})
	received, err := os.ReadFile(dest)
	ok(t, err)
	if !bytes.Equal(received, payload) {
		t.Fatal("exported file differs")
	}
	drive(func() bool {
		return left.room.epoch > 0 && right.room.epoch == left.room.epoch && left.room.media.ready() && right.room.media.ready()
	})
	if !stagedBeforeSwitch {
		t.Fatal("no staged confirmation observed")
	}
	sent = false
	drive(func() bool {
		if !sent {
			sent = right.room.media.send("after rotation", nil) == nil
		}
		for len(sentEvents) > 0 {
			event := <-sentEvents
			if event.name == "chat" && event.data.(chatMessage).Text == "after rotation" {
				return true
			}
		}
		return false
	})
	// Close this client's actual signalling connection. Both peers must
	// regain a new secure generation while retaining their admission and mute intent.
	beforeReconnect := left.room.snap.Generation
	originalEntry := left.room.join.Identity
	left.room.media.room.Simulate(lk.SimulateSignalReconnect)
	drive(func() bool {
		return left.room.snap.Generation > beforeReconnect && left.room.snap.Generation == right.room.snap.Generation && left.room.media.ready() && right.room.media.ready()
	})
	left.room.media.mu.Lock()
	mutedAfterReconnect := left.room.media.muted
	left.room.media.mu.Unlock()
	if left.room.join.Identity != originalEntry || mutedAfterReconnect {
		t.Fatal("ordinary reconnect lost admission or microphone intent")
	}
	// A membership change replaces the group's generation and requires trust
	// in the new peer. Previously received, verified local copies still belong
	// to the original admissions, even while the new group is awaiting trust.
	originalGroup := groupID(right.room.snap)
	oldSenderKey, err := right.room.n.key(left.room.join.Identity, false)
	ok(t, err)
	defer clear(oldSenderKey)
	ok(t, left.verify(f.ctx, "start", peer, ""))
	drive(func() bool { return right.room.verification != nil && right.room.verification.Step == "incoming" })
	beforeRosterChange := right.room.verification.ID
	third, _ := f.client(t)
	f.enroll(t, third, f.account(t, "East"), false)
	ok(t, third.joinRoom(f.ctx, store.DefaultRoomID, ""))
	drive(func() bool { return groupID(right.room.snap) != originalGroup && len(right.room.snap.Members) == 3 })
	for _, reader := range []*engine{left, right} {
		if key, err := reader.room.n.key(left.room.join.Identity, false); err == nil {
			clear(key)
			t.Fatal("old MLS sender key remained exportable while the new roster awaited trust")
		}
		v := reader.room.verification
		if v == nil || v.ID != beforeRosterChange || v.Step != "roomChanged" {
			t.Fatal("membership change did not end the pending verification with its visible reason", v)
		}
		scope := reader.fileScope.Load()
		target := filepath.Join(t.TempDir(), "after-roster.jpg")
		a := args{ID: fileID, Path: target, Entry: scope.entry, Revision: scope.revision}
		_, err = reader.handle(f.ctx, command{Op: "download", Args: a})
		ok(t, err)
		drive(func() bool { _, err := os.Stat(target); return err == nil })
		content, err := os.ReadFile(target)
		ok(t, err)
		if !bytes.Equal(content, payload) {
			t.Fatal("cached export after roster change differs")
		}
		_, err = reader.handle(f.ctx, command{Op: "clearCache", Args: a})
		ok(t, err)
		if _, err = reader.handle(f.ctx, command{Op: "previewFile", Args: a}); err == nil {
			t.Fatal("cleared cache admitted previous dialog")
		}
	}
	left.room.media.pause()
	if left.room.media.ready() || left.room.media.send("expired", nil) == nil {
		t.Fatal("paused lease accepted content")
	}
	right.leaveRoom(f.ctx)
	third.leaveRoom(f.ctx)
	for deadline := time.Now().Add(timeout); len(left.room.snap.Members) != 1 || !left.room.media.ready(); {
		if time.Now().After(deadline) {
			t.Fatal("remaining member did not establish a fresh MLS group")
		}
		ok(t, left.tickRoom(f.ctx))
		time.Sleep(interval)
	}
	freshKey, err := left.room.n.key(left.room.join.Identity, false)
	ok(t, err)
	defer clear(freshKey)
	if bytes.Equal(freshKey, oldSenderKey) {
		t.Fatal("remaining member resumed with the sender key held by the departed peer")
	}
	left.room.media.mu.Lock()
	muted := left.room.media.muted
	left.room.media.mu.Unlock()
	if !muted {
		t.Fatal("membership change reopened the microphone")
	}
}
