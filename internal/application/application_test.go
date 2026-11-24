package application

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testadmin"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

type testMedia struct{}

func (testMedia) Participants(context.Context, string) ([]room.Participant, error) {
	return []room.Participant{}, nil
}
func (testMedia) EnsureRoom(context.Context, string) error                { return nil }
func (testMedia) RemoveParticipant(context.Context, string, string) error { return nil }
func (testMedia) EndRoom(context.Context, string) error                   { return nil }

func testApplicationConfig(t *testing.T) config.Config {
	t.Helper()
	t.Setenv("CHIRP_DATABASE_PATH", filepath.Join(t.TempDir(), "chirp.db"))
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "https://chirp.youzifeile.cn")
	t.Setenv("LIVEKIT_API_KEY", "chirp")
	t.Setenv("LIVEKIT_API_SECRET", strings.Repeat("test-secret-", 4))
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := authorization.GenerateKeyFile(cfg.AuthorizationKeyFile); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestUnifiedRoutesShareStateAndKeepAuthenticationScoped(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cfg := testApplicationConfig(t)
	db, err := store.Open(ctx, cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	app, err := New(db, testMedia{}, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	app.Start(ctx)
	defer app.Close()
	mac := testclient.MustLatest(t, db, "macos")
	request := func(method, path, body, token string, cookie *http.Cookie, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, cfg.PublicOrigin+path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", cfg.PublicOrigin)
		testclient.SetHeaders(r, mac)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		if cookie != nil {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		app.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s: %d want %d: %s", method, path, w.Code, want, w.Body.String())
		}
		return w
	}
	for _, path := range []string{"/", "/register", "/device", "/assets/app.js", "/assets/theme.css"} {
		request("GET", path, "", "", nil, 200)
	}
	health := request("GET", "/healthz", "", "", nil, 200)
	if !strings.Contains(health.Body.String(), `"service":"chirp"`) {
		t.Fatal(health.Body.String())
	}
	manifest := request("GET", "/v1/client-config", "", "", nil, 200)
	var discovery struct {
		Protocol  int               `json:"protocol_version"`
		Endpoints map[string]string `json:"endpoints"`
	}
	if err := json.Unmarshal(manifest.Body.Bytes(), &discovery); err != nil || discovery.Protocol != 5 {
		t.Fatal(err, manifest.Body.String())
	}
	for _, endpoint := range discovery.Endpoints {
		if !strings.HasPrefix(endpoint, cfg.PublicOrigin+"/") {
			t.Fatal("cross-origin endpoint", endpoint)
		}
	}
	options := request("POST", "/api/auth/register/begin", `{"nickname":"Friend"}`, "", nil, 200)
	if !strings.Contains(options.Body.String(), `"id":"chirp.youzifeile.cn"`) {
		t.Fatal(options.Body.String())
	}
	request("GET", "/admin/api/overview", "", "", nil, 401)
	request("GET", "/admin/assets/app.js", "", "", nil, 401)
	cookie := testadmin.Session(t, db)
	request("GET", "/admin/", "", "", cookie, 200)
	asset := request("GET", "/admin/assets/app.js", "", "", cookie, 200)
	if !strings.Contains(asset.Body.String(), "/admin/api") {
		t.Fatal("admin asset collided with login asset")
	}
	request("GET", "/admin/api/overview", "", "", cookie, 200)
	request("POST", "/api/auth/logout", `{}`, "", cookie, 204)
	request("GET", "/admin/api/overview", "", "", cookie, 401)
	member, token, err := db.AddMember(ctx, "Voice member")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.JoinRoom(ctx, member, "friends", 1, 0); err != nil {
		t.Fatal(err)
	}
	request("GET", "/v1/me", "", token, nil, 200)
	request("GET", "/v1/group/rooms/friends/config", "", token, nil, 200)
	request("GET", "/v1/group/rooms/friends/config", "", "", cookie, 401)
	for _, path := range []string{"/internal/group/end", "/internal/group/remove"} {
		request("POST", path, `{}`, token, nil, 404)
	}
	request("GET", "/api/overview", "", "", nil, 404)
	request("GET", "/authorization/healthz", "", "", nil, 204)
	// Authorization does not inherit browser/Bearer authentication. It still
	// requires device signatures and returns challenge-bound signed snapshots.
	origin, err := identity.NormalizeOrigin(cfg.PublicOrigin)
	if err != nil {
		t.Fatal(err)
	}
	owner := testidentity.New("unified-authorization")
	event := authorization.Event{Origin: origin, Version: 1, Operation: "enroll", Signer: owner.Device}
	event.Signature = identity.Sign(owner.Key, event.Message())
	body, _ := json.Marshal(event)
	request("POST", "/authorization/v5/append", string(body), "", nil, 204)
	key, err := authorization.ReadKeyFile(cfg.AuthorizationKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	public := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	clear(key)
	checkSnapshot := func() {
		t.Helper()
		nonce := identity.Hash([]byte("unified snapshot request"))
		body, _ := json.Marshal(authorization.SnapshotRequest{Origin: origin, Nonce: nonce, Roots: []string{owner.Device.AccountKey}})
		response := request("POST", "/authorization/v5/snapshot", string(body), "", nil, 200)
		var envelope authorization.Envelope
		if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
			t.Fatal(err)
		}
		payload, err := base64.StdEncoding.DecodeString(envelope.Payload)
		if err != nil || !identity.Verify(public, envelope.Signature, authorization.SnapshotMessage(origin, nonce, payload)) {
			t.Fatal("application snapshot signature rejected", err)
		}
		var snapshot authorization.Snapshot
		if err := json.Unmarshal(payload, &snapshot); err != nil || len(snapshot.Accounts) != 1 || len(snapshot.Accounts[0].Records) != 1 || snapshot.Accounts[0].Records[0].Event.Hash() != event.Hash() {
			t.Fatal("authorization history was lost", err)
		}
	}
	checkSnapshot()
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	app, err = New(db, testMedia{}, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	checkSnapshot()
	if err := app.authorization.Close(); err != nil {
		t.Fatal(err)
	}
	request("GET", "/healthz", "", "", nil, 503)
	if err := os.Remove(cfg.AuthorizationKeyFile); err != nil {
		t.Fatal(err)
	}
	if unexpected, err := New(db, testMedia{}, cfg, slog.New(slog.NewTextHandler(io.Discard, nil))); err == nil {
		unexpected.Close()
		t.Fatal("application started without the existing signing key")
	}
	if _, err := os.Stat(cfg.AuthorizationKeyFile); !os.IsNotExist(err) {
		t.Fatal("missing signing key was recreated")
	}
}

func TestSelfServiceDeviceRevocationRequiresMatchingSignedHistory(t *testing.T) {
	ctx := t.Context()
	cfg := testApplicationConfig(t)
	db, err := store.Open(ctx, cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	app, err := New(db, testMedia{}, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()

	account := store.PasskeyAccount{ID: "revocation-account", Nickname: "DeviceOwner", CredentialID: []byte("fixture"), CredentialJSON: []byte("{}")}
	registration, err := db.RegisterPasskey(ctx, account)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ApproveRegistration(ctx, registration.RequestID); err != nil {
		t.Fatal(err)
	}
	activate := func(device testidentity.Client) store.ClientLogin {
		t.Helper()
		verifier := strings.Repeat("v", 43)
		digest := sha256.Sum256([]byte(verifier))
		request, err := db.BeginDeviceAuthorization(ctx, base64.RawURLEncoding.EncodeToString(digest[:]), store.ClientID)
		if err != nil {
			t.Fatal(err)
		}
		if err := db.ApproveDeviceAuthorization(ctx, request.RequestID, account, account.CredentialJSON); err != nil {
			t.Fatal(err)
		}
		client := testclient.MustLatest(t, db, "macos")
		login, err := db.PollDeviceAuthorization(ctx, request.RequestID, verifier, client, device.Login(store.ClientID, request.RequestID, verifier))
		if err != nil {
			t.Fatal(err)
		}
		return login
	}
	owner := testidentity.New("revocation-owner")
	target := testidentity.Child(owner, "revocation-target", false)
	spare := testidentity.Child(owner, "revocation-spare", false)
	activate(owner)
	activate(target)
	activate(spare)
	login := activate(owner)
	syncDevice := func(device testidentity.Client, want int) {
		t.Helper()
		public := device.Key.Public().(ed25519.PublicKey)
		path := "/v1/identity/devices/" + base64.RawURLEncoding.EncodeToString(public)
		r := httptest.NewRequest(http.MethodDelete, path, nil)
		r.Header.Set("Authorization", "Bearer "+login.Credential)
		w := httptest.NewRecorder()
		app.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("device revocation returned %d, want %d: %s", w.Code, want, w.Body.String())
		}
	}
	origin, err := identity.NormalizeOrigin(cfg.PublicOrigin)
	if err != nil {
		t.Fatal(err)
	}
	heads := map[string]authorization.Event{}
	appendEvent := func(signer testidentity.Client, operation, targetKey string) {
		t.Helper()
		root := signer.Device.AccountKey
		previous := heads[root]
		event := authorization.Event{Origin: origin, Version: previous.Version + 1, Operation: operation, Signer: signer.Device, TargetKey: targetKey}
		if previous.Version > 0 {
			event.PreviousHash = previous.Hash()
		}
		event.Signature = identity.Sign(signer.Key, event.Message())
		body, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		app.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/authorization/v5/append", bytes.NewReader(body)))
		if w.Code != http.StatusNoContent {
			t.Fatalf("authorization %s returned %d: %s", operation, w.Code, w.Body.String())
		}
		heads[root] = event
	}

	appendEvent(owner, "enroll", "")
	appendEvent(target, "enroll", "")
	syncDevice(target, http.StatusForbidden)
	// The same leaf key certified under another root has a separate history.
	other := testidentity.New("other-revocation-owner")
	appendEvent(other, "enroll", "")
	appendEvent(testidentity.Child(other, "revocation-target", false), "enroll", "")
	appendEvent(other, "revoke", target.Device.LeafKey())
	syncDevice(target, http.StatusForbidden)
	if records, err := db.Blacklist(ctx); err != nil || len(records) != 0 {
		t.Fatalf("blacklist changed before a matching signed revocation: %v, %v", records, err)
	}

	appendEvent(owner, "revoke", target.Device.LeafKey())
	syncDevice(spare, http.StatusForbidden)
	syncDevice(target, http.StatusNoContent)
	syncDevice(target, http.StatusNoContent)
	if err := app.authorization.Close(); err != nil {
		t.Fatal(err)
	}
	syncDevice(spare, http.StatusServiceUnavailable)
	records, err := db.Blacklist(ctx)
	if err != nil || len(records) != 1 || records[0].AccountKey != owner.Device.AccountKey || records[0].Subject != target.Device.LeafKey() {
		t.Fatalf("unexpected blacklist after sync: %v, %v", records, err)
	}
}
