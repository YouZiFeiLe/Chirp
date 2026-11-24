// A loopback-only, disposable API fixture for Apple/Android/Go interoperability.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/passkeyhttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func registeredAccount(ctx context.Context, db *store.Store, name string) store.PasskeyAccount {
	account := store.PasskeyAccount{ID: must(store.NewPasskeyID()), Nickname: name, CredentialID: []byte(name), CredentialJSON: []byte("{}")}
	registration := must(db.RegisterPasskey(ctx, account))
	must(db.ApproveRegistration(ctx, registration.RequestID))
	return account
}

func approvedDeviceRequest(ctx context.Context, db *store.Store, account store.PasskeyAccount) (store.DeviceAuthorization, string) {
	verifier := base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat("x", 32)))
	digest := sha256.Sum256([]byte(verifier))
	request := must(db.BeginDeviceAuthorization(ctx, base64.RawURLEncoding.EncodeToString(digest[:]), store.AndroidClientID))
	if err := db.ApproveDeviceAuthorization(ctx, request.RequestID, account, account.CredentialJSON); err != nil {
		panic(err)
	}
	return request, verifier
}

// The fixture exercises admission, directory and group APIs without a running SFU.
type fixtureMedia struct{}

func (fixtureMedia) Participants(context.Context, string) ([]room.Participant, error) {
	return []room.Participant{}, nil
}
func (fixtureMedia) EnsureRoom(context.Context, string) error { return nil }

func fixtureLogin(ctx context.Context, db *store.Store, origin, name string) (store.ClientLogin, testidentity.Client) {
	request, verifier := approvedDeviceRequest(ctx, db, registeredAccount(ctx, db, name))
	client := must(testclient.Latest(ctx, db, store.AndroidClientPlatform))
	device := testidentity.New(name)
	setup := must(db.BeginIdentitySetup(ctx, request.RequestID, verifier, store.AndroidClientID, origin, client, true))
	nonce := must(db.BindIdentityChallenge(ctx, setup.Token, verifier, origin, client, device.Device))
	signature := identity.Sign(device.Key, identity.ActivationMessage(origin, setup.AccountID, store.AndroidClientID, setup.Token, verifier, nonce, device.Device))
	login := must(db.CompleteIdentitySetup(ctx, setup.Token, verifier, origin, signature, client, device.Device))
	return login, device
}

func roomClients(ctx context.Context, db *store.Store, origin, roomID string, names ...string) []map[string]any {
	clients := make([]map[string]any, 0, len(names))
	for _, name := range names {
		login, device := fixtureLogin(ctx, db, origin, name)
		a := must(db.JoinRoom(ctx, login.Member, roomID, 1, 0))
		clients = append(clients, map[string]any{"credential": login.Credential, "room_id": a.RoomID, "entry_id": a.EntryID, "identity": a.Identity(),
			"device": device.Device, "seed": base64.StdEncoding.EncodeToString(device.Key.Seed())})
	}
	return clients
}

func productionClient(login store.ClientLogin, device testidentity.Client, open, locked store.RoomConfig, password string) map[string]any {
	return map[string]any{
		"credential": login.Credential, "identity": login.Member.ParticipantIdentity(), "account_id": login.Member.ID,
		"name": login.Member.DisplayName, "device": device.Device, "seed": base64.StdEncoding.EncodeToString(device.Key.Seed()), "expires_at": login.ExpiresAt,
		"room_id": open.RoomID, "room_name": open.DisplayName, "locked_room_id": locked.RoomID,
		"locked_room_name": locked.DisplayName, "room_password": password,
	}
}

// Only the exact public example documented in docs/authorization-keys.md may
// stand in for the real authority when exercising the shipped Activity trust.
func publicDemoKey() ed25519.PrivateKey {
	const path = "deploy/authorization-key.default"
	const knownSHA256 = "d09284eeec9ca2ab8491472fbc9ed997297ba419765b6e566859968fd8d89831"
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != 44 {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	encoded, err := io.ReadAll(io.LimitReader(file, 45))
	defer clear(encoded)
	digest := sha256.Sum256(encoded)
	if err != nil || hex.EncodeToString(digest[:]) != knownSHA256 {
		return nil
	}
	seed := make([]byte, ed25519.SeedSize+1)
	defer clear(seed)
	length, err := base64.StdEncoding.Strict().Decode(seed, encoded)
	if err != nil || length != ed25519.SeedSize {
		return nil
	}
	key := ed25519.NewKeyFromSeed(seed[:length])
	trust, err := os.ReadFile("Client/apple/Shared/Resources/AuthorizationTrust.json")
	var pinned struct {
		PublicKey string `json:"public_key"`
	}
	if err != nil || json.Unmarshal(trust, &pinned) != nil || pinned.PublicKey != base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)) {
		clear(key)
		return nil
	}
	return key
}

func main() {
	root, err := os.MkdirTemp("", "chirp-attachments-fixture-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(root)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	db, err := store.Open(ctx, filepath.Join(root, "test.db"))
	if err != nil {
		panic(err)
	}
	defer db.Close()
	files, err := httpapi.NewAttachmentStorage(db, filepath.Join(root, "ciphertext"))
	if err != nil {
		panic(err)
	}
	defer files.Close()
	server := httptest.NewUnstartedServer(nil)
	defer server.Close()
	_, port, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		panic(err)
	}
	origin := "http://localhost:" + port
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	mediaPort := os.Getenv("CHIRP_FIXTURE_LIVEKIT_PORT")
	var private ed25519.PrivateKey
	var flowSkip string
	if mediaPort != "" {
		private = publicDemoKey()
		if private == nil {
			flowSkip = "The repository's public demo authorization key or bundled trust was changed or is unavailable."
			mediaPort = ""
		}
	}
	if private == nil {
		_, private, err = ed25519.GenerateKey(rand.Reader)
		if err != nil {
			panic(err)
		}
	}
	defer clear(private)
	public := private.Public().(ed25519.PublicKey)
	authority := must(authorization.Open(filepath.Join(root, "authorization.db"), origin, private))
	defer authority.Close()
	snapshots := http.StripPrefix("/authorization", authority.Handler())
	passkeys := must(passkeyhttp.New(db, config.PasskeyConfig{RPID: "localhost", Origins: []string{origin}}, logger))
	clients := roomClients(ctx, db, origin, store.DefaultRoomID, "sender", "recipient", "late")
	departureRoom := must(db.CreateRoom(ctx, "Departure"))
	departureClients := roomClients(ctx, db, origin, departureRoom.RoomID, "resident", "remaining", "departing")
	go func() {
		admissions := append(clients, departureClients...)
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				for _, client := range admissions {
					_ = db.TouchAdmission(ctx, client["room_id"].(string), client["identity"].(string))
				}
			}
		}
	}()
	go files.Monitor(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)))
	issuer := room.Issuer{APIKey: "fixture", APISecret: strings.Repeat("s", 32), TTL: 5 * time.Minute}
	var media room.Backend = fixtureMedia{}
	signaling := "wss://unused.example"
	var flow, peer map[string]any
	var comparison *peerSAS
	var comparisonKey [32]byte
	if mediaPort != "" {
		port := must(strconv.Atoi(mediaPort))
		issuer.APISecret = os.Getenv("CHIRP_FIXTURE_LIVEKIT_SECRET")
		if port < 1 || port > 65535 || len(issuer.APISecret) < 32 {
			panic("invalid local fixture media configuration")
		}
		media = room.New("http://127.0.0.1:"+strconv.Itoa(port), issuer.APIKey, issuer.APISecret)
		signaling = "ws://localhost:" + strconv.Itoa(port)
		open := must(db.CreateRoom(ctx, "Flow Room"))
		locked := must(db.CreateRoom(ctx, "Flow Password Room"))
		password := "Chirp fixture 2026"
		must(db.SetRoomPassword(ctx, locked.RoomID, password))
		ownerLogin, ownerDevice := fixtureLogin(ctx, db, origin, "FlowOwner")
		peerLogin, peerDevice := fixtureLogin(ctx, db, origin, "FlowPeer")
		flow = productionClient(ownerLogin, ownerDevice, open, locked, password)
		peer = productionClient(peerLogin, peerDevice, open, locked, password)
		comparison = &peerSAS{credentials: map[string]string{"sender": ownerLogin.Credential, "receiver": peerLogin.Credential}, commitments: map[string]string{}}
		must(rand.Read(comparisonKey[:]))
	}
	h := httpapi.NewWithAttachments(db, media, issuer, signaling, origin, logger, config.DefaultClientEndpoints(origin), files, authority.DeviceRevoked)
	policy := group.DefaultPolicy()
	policy.Rotation = 5 * time.Second
	groups := group.New(db, policy, logger, origin)
	go groups.Monitor(ctx)
	account := registeredAccount(ctx, db, "identityprobe")
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if comparison != nil && r.URL.Path == "/test/peer-sas" {
			comparison.ServeHTTP(w, r)
			return
		}
		// The disposable fixture supplies the result of a successful passkey assertion.
		// Clients still perform their normal callback parsing, PKCE exchange, and activation.
		if r.Method == http.MethodPost && r.URL.Path == "/test/native-authorization" {
			var auth store.ClientAuthorization
			if json.NewDecoder(io.LimitReader(r.Body, 2048)).Decode(&auth) != nil || auth.ClientID != store.AndroidClientID || !auth.Valid() {
				http.Error(w, "invalid fixture authorization", http.StatusBadRequest)
				return
			}
			code, err := db.CreateClientAuthorization(r.Context(), account, account.CredentialJSON, auth)
			if err != nil {
				http.Error(w, "fixture authorization failed", http.StatusInternalServerError)
				return
			}
			httpresponse.JSON(w, http.StatusOK, map[string]string{"callback": auth.RedirectURI + "?state=" + auth.State + "&code=" + code})
			return
		}
		if r.URL.Path == "/healthz" {
			httpresponse.Health(db, "chirp")(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/authorization/") {
			snapshots.ServeHTTP(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/client/") {
			passkeys.ServeHTTP(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/group/") {
			groups.ServeHTTP(w, r)
			return
		}
		h.ServeHTTP(w, r)
	})
	faults := &faultTransport{next: api, plans: map[string]*faultPlan{}, requests: map[string][]int{}}
	server.Config.Handler = faults
	server.Start()
	probe, verifier := approvedDeviceRequest(ctx, db, account)
	paired, _ := approvedDeviceRequest(ctx, db, account)
	recovery, _ := approvedDeviceRequest(ctx, db, account)
	result := map[string]any{"url": origin, "clients": clients, "departure_clients": departureClients, "authorization_key": base64.StdEncoding.EncodeToString(public),
		"setup_request": probe.RequestID, "pairing_request": paired.RequestID, "recovery_request": recovery.RequestID, "setup_verifier": verifier}
	if flow != nil {
		result["production_flow"] = flow
		result["production_peer"] = peer
		result["peer_comparison_key"] = base64.StdEncoding.EncodeToString(comparisonKey[:])
		clear(comparisonKey[:])
	} else if flowSkip != "" {
		result["production_flow_skipped"] = flowSkip
	}
	if err = json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
	<-ctx.Done()
}

// Each device commits once, out of band, before approving its locally displayed SAS.
// Only the disposable fixture receives the keyed commitments.
type peerSAS struct {
	mu          sync.Mutex
	credentials map[string]string
	commitments map[string]string
	mismatch    bool
}

func (p *peerSAS) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Role       string `json:"role"`
		Commitment string `json:"commitment"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	credential, validRole := p.credentials[body.Role]
	_, err := hex.DecodeString(body.Commitment)
	if !validRole || len(body.Commitment) != 64 || err != nil || strings.ToLower(body.Commitment) != body.Commitment {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+credential)) != 1 {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if previous, seen := p.commitments[body.Role]; seen && previous != body.Commitment {
		p.mismatch = true
	}
	p.commitments[body.Role] = body.Commitment
	switch {
	case p.mismatch:
		w.WriteHeader(http.StatusConflict)
	case len(p.commitments) == 1:
		w.WriteHeader(http.StatusAccepted)
	case p.commitments["sender"] != p.commitments["receiver"]:
		p.mismatch = true
		w.WriteHeader(http.StatusConflict)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// Faults exist only in this disposable loopback fixture. They never enter the
// production handler. A lost ACK happens after the real DB/file commit.
type faultPlan struct {
	Method    string `json:"method"`
	Path      string `json:"path"`
	Kind      string `json:"kind"`
	Remaining int    `json:"remaining"`
}
type faultTransport struct {
	next     http.Handler
	mu       sync.Mutex
	plans    map[string]*faultPlan
	requests map[string][]int
}

func (f *faultTransport) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/test/fault" && r.Method == "POST" {
		var p faultPlan
		if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&p) != nil || p.Remaining < 0 || p.Remaining > 20 || !strings.HasPrefix(p.Path, "/v1/rooms/") {
			http.Error(w, "invalid fixture plan", 400)
			return
		}
		f.mu.Lock()
		f.plans[p.Method+" "+p.Path] = &p
		f.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if r.URL.Path == "/test/requests" && r.Method == "GET" {
		f.mu.Lock()
		defer f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(f.requests)
		return
	}
	key := r.Method + " " + r.URL.Path
	f.mu.Lock()
	p := f.plans[key]
	kind := ""
	if p != nil && p.Remaining > 0 {
		p.Remaining--
		kind = p.Kind
	}
	if strings.Contains(r.URL.Path, "/chunks/") {
		f.requests[key] = append(f.requests[key], int(r.ContentLength))
	}
	f.mu.Unlock()
	switch kind {
	case "bad_prefix":
		captured := httptest.NewRecorder()
		f.next.ServeHTTP(captured, r)
		var body map[string]any
		if captured.Code == 200 && json.Unmarshal(captured.Body.Bytes(), &body) == nil {
			if hashes, ok := body["chunk_sha256"].([]any); ok && len(hashes) > 0 {
				hashes[0] = strings.Repeat("0", 64)
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(body)
			return
		}
		w.WriteHeader(captured.Code)
		_, _ = w.Write(captured.Body.Bytes())
		return
	case "busy":
		w.Header().Set("Retry-After", "1")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(429)
		_, _ = io.WriteString(w, `{"error":{"code":"ATTACHMENT_BUSY"}}`)
		return
	case "unavailable":
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(503)
		_, _ = io.WriteString(w, `{"error":{"code":"ATTACHMENTS_UNAVAILABLE"}}`)
		return
	case "lost_ack":
		captured := httptest.NewRecorder()
		f.next.ServeHTTP(captured, r)
		if captured.Code >= 200 && captured.Code < 300 {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				_ = conn.Close()
			}
			return
		}
		for name, values := range captured.Header() {
			w.Header()[name] = values
		}
		w.WriteHeader(captured.Code)
		_, _ = w.Write(captured.Body.Bytes())
		return
	case "torn_download":
		captured := httptest.NewRecorder()
		f.next.ServeHTTP(captured, r)
		for name, values := range captured.Header() {
			w.Header()[name] = values
		}
		w.WriteHeader(captured.Code)
		if captured.Code == 200 {
			_, _ = w.Write(captured.Body.Bytes()[:captured.Body.Len()/2])
			w.(http.Flusher).Flush()
			conn, _, err := w.(http.Hijacker).Hijack()
			if err == nil {
				_ = conn.Close()
			}
			return
		}
		_, _ = w.Write(captured.Body.Bytes())
		return
	}
	f.next.ServeHTTP(w, r)
}
