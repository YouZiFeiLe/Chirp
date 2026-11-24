package passkeyhttp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func TestNativeLoginChecksCurrentPolicyWithoutRevokingExistingSessions(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Oliver")
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	ctx := context.Background()
	before := store.ClientIdentity{Platform: "macos", Version: "2026.11.21", Build: 22}
	after := store.ClientIdentity{Platform: "macos", Version: "2026.11.22", Build: 1}
	if _, err := f.db.UpdateClientVersionPolicy(ctx, store.ClientVersionPolicy{
		Platform: before.Platform, LatestVersion: before.Version, LatestBuild: before.Build, MinimumVersion: before.Version, MinimumBuild: before.Build,
	}); err != nil {
		t.Fatal(err)
	}
	account, err := f.db.PasskeyByCredential(ctx, a.id, a.handle)
	if err != nil {
		t.Fatal(err)
	}
	verifier := strings.Repeat("v", 43)
	digest := sha256.Sum256([]byte(verifier))
	authorization := store.ClientAuthorization{ClientID: store.ClientID, RedirectURI: store.ClientRedirectURI, State: strings.Repeat("s", 43), CodeChallenge: b64(digest[:]), CodeChallengeMethod: "S256"}
	code, err := f.db.CreateClientAuthorization(ctx, account, account.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	previous, err := f.db.ExchangeClientAuthorization(ctx, code, verifier, store.ClientID, store.ClientRedirectURI, before, testidentity.New("existing-login-fixture").Login(store.ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	code, err = f.db.CreateClientAuthorization(ctx, account, account.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	device, deviceVerifier := f.startDevice(t)
	f.approveDevice(t, a, device.RequestID, 200)
	f.request(t, f.admin, "PUT", "/api/client-versions/macos", map[string]any{"latest_version": after.Version, "latest_build": after.Build, "minimum_version": after.Version, "minimum_build": after.Build}, 200)
	native := func(path string, client *store.ClientIdentity, body any, want int) {
		t.Helper()
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("POST", testOrigin+path, bytes.NewReader(data))
		r.Header.Set("Content-Type", "application/json")
		if client != nil {
			testclient.SetHeaders(r, *client)
		}
		w := httptest.NewRecorder()
		f.http.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s client %v: %d %s", path, client, w.Code, w.Body.String())
		}
		if want == 403 && (!strings.Contains(w.Body.String(), "CLIENT_UPDATE_REQUIRED") || strings.Contains(w.Body.String(), `"credential"`)) {
			t.Fatal("rejection missing or leaked a login", w.Body.String())
		}
	}
	exchange := map[string]string{"code": code, "code_verifier": verifier, "client_id": store.ClientID, "redirect_uri": store.ClientRedirectURI}
	start := map[string]string{"client_id": store.ClientID, "code_challenge": authorization.CodeChallenge, "code_challenge_method": "S256"}
	proof := map[string]string{"request_id": device.RequestID, "code_verifier": deviceVerifier}
	native("/api/client/exchange", nil, exchange, 400)
	for _, build := range []int{before.Build, store.MaxClientBuild} {
		outdated := before
		outdated.Build = build
		native("/api/client/exchange", &outdated, exchange, 403)
		native("/api/client/device/start", &outdated, start, 403)
		native("/api/client/device/poll", &outdated, proof, 403)
	}
	api := httpapi.New(f.db, media{}, room.Issuer{}, "wss://rtc.example.test", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	r := httptest.NewRequest("GET", "/v1/me", nil)
	r.Header.Set("Authorization", "Bearer "+previous.Credential)
	w := httptest.NewRecorder()
	api.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal("policy update invalidated an existing login", w.Code)
	}
	native("/api/client/device/cancel", &before, proof, 204)
	// A numerically newer version can redeem the unconsumed code with a reset build.
	native("/api/client/exchange", &after, exchange, 200)
}
