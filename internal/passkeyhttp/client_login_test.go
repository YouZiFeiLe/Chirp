package passkeyhttp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func (media) EnsureRoom(context.Context, string) error { return nil }

func TestNativePasskeyExchangeAndSingleLogin(t *testing.T) {
	t.Run("ios", func(t *testing.T) { testNativeExchange(t, "ios", "windows") })
	t.Run("android", func(t *testing.T) { testNativeExchange(t, "android", "windows") })
	t.Run("macos", func(t *testing.T) { testNativeExchange(t, "macos", "windows") })
	t.Run("windows", func(t *testing.T) { testNativeExchange(t, "windows", "macos") })
}

type nativeTestTarget struct {
	client                store.ClientIdentity
	clientID, redirectURI string
	requestResumption     bool
}

func (f *fixture) nativeTarget(t *testing.T, platform string) nativeTestTarget {
	t.Helper()
	client := testclient.MustLatest(t, f.db, platform)
	switch platform {
	case store.WindowsClientPlatform:
		return nativeTestTarget{client, store.WindowsClientID, store.WindowsClientRedirectURI, false}
	case store.AndroidClientPlatform:
		return nativeTestTarget{client, store.AndroidClientID, store.AndroidClientRedirectURI, false}
	default:
		return nativeTestTarget{client, store.ClientID, store.ClientRedirectURI, false}
	}
}

func testNativeExchange(t *testing.T, platform, otherPlatform string) {
	t.Helper()
	f := newFixture(t)
	target, other := f.nativeTarget(t, platform), f.nativeTarget(t, otherPlatform)
	a, receipt := f.register(t, "Oliver")
	verifier := strings.Repeat("v", 43)
	digest := sha256.Sum256([]byte(verifier))
	client := store.ClientAuthorization{ClientID: target.clientID, RedirectURI: target.redirectURI, State: strings.Repeat("s", 43), CodeChallenge: b64(digest[:]), CodeChallengeMethod: "S256"}
	code := func(want int) string {
		t.Helper()
		begin := f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]any{"client": client}, 200)
		options := decodeJSON[struct{ PublicKey struct{ Challenge string } }](t, begin)
		finished := f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, options.PublicKey.Challenge, testOrigin, "localhost", 0x05), want)
		if want != 200 {
			return ""
		}
		result := decodeJSON[map[string]string](t, finished)
		if len(result) != 1 || strings.Contains(finished.Body.String(), "credential") {
			t.Fatal("web redirect leaked a credential")
		}
		callback, err := url.Parse(result["redirect_url"])
		redirect, _, _ := strings.Cut(result["redirect_url"], "?")
		if err != nil || redirect != target.redirectURI || len(callback.Query()) != 2 || callback.Query().Get("state") != client.State {
			t.Fatal("invalid callback")
		}
		return callback.Query().Get("code")
	}
	code(403)
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	api := httpapi.New(f.db, media{}, room.Issuer{}, "wss://rtc.test.local", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	firstCode := code(200)
	checkHandoff := func(value string, want bool) {
		t.Helper()
		body := map[string]string{"code": value}
		if target.clientID != store.WindowsClientID {
			f.request(t, f.http, "POST", "/api/auth/login/windows-handoff", body, 400)
			return
		}
		response := f.request(t, f.http, "POST", "/api/auth/login/windows-handoff", body, 200)
		status := decodeJSON[map[string]bool](t, response)
		received, ok := status["received"]
		if len(status) != 1 || !ok || received != want {
			t.Fatalf("Windows handoff status = %v, want received=%t", status, want)
		}
	}
	// Native token requests carry neither a website Origin nor browser cookies.
	exchange := func(value, secret string, redeem nativeTestTarget, want int) *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"code": value, "code_verifier": secret, "client_id": redeem.clientID, "redirect_uri": redeem.redirectURI})
		r := httptest.NewRequest("POST", testOrigin+"/api/client/exchange", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		testclient.SetHeaders(r, redeem.client)
		w := httptest.NewRecorder()
		f.http.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("exchange got %d want %d", w.Code, want)
		}
		if want == 200 {
			checkHandoff(value, true)
			return f.finishIdentitySetup(t, w, secret, redeem, testidentity.New("existing-login-fixture"))
		}
		return w
	}
	exchange(firstCode, strings.Repeat("x", 43), target, 400)
	// A valid verifier cannot redeem the code against another registered client.
	exchange(firstCode, verifier, other, 400)
	mismatched := other
	mismatched.clientID, mismatched.redirectURI = target.clientID, target.redirectURI
	exchange(firstCode, verifier, mismatched, 400)
	checkHandoff(firstCode, false)
	f.restart(t)
	target.requestResumption = true
	firstResponse := exchange(firstCode, verifier, target, 200)
	one := decodeJSON[store.ClientLogin](t, firstResponse)
	activated, err := time.Parse(time.RFC3339, one.Member.LastLoginAt)
	if err != nil || one.Credential == "" || one.ExpiresAt != activated.Add(20*time.Hour).Unix() {
		t.Fatal("missing native credential metadata")
	}
	exchange(firstCode, verifier, target, 400)
	requestAPI := func(credential, method, path string, want int) {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		r.Header.Set("Authorization", "Bearer "+credential)
		w := httptest.NewRecorder()
		api.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("API got %d want %d", w.Code, want)
		}
	}
	// Rebuild the handler after a database restart.
	api = httpapi.New(f.db, media{}, room.Issuer{}, "wss://rtc.test.local", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	requestAPI(one.Credential, "GET", "/v1/session", 200)
	original := one
	if !strings.HasPrefix(one.ResumeToken, identity.ResumptionTokenPrefix) {
		t.Fatal("missing platform-neutral login grant")
	}
	requestAPI(one.ResumeToken, "GET", "/v1/session", 401)
	body := map[string]string{"resume_token": one.ResumeToken}
	challenge := decodeJSON[map[string]string](t, f.nativePOST(t, "resume/challenge", body, target, 200))["challenge"]
	participant := decodeJSON[struct {
		Participant string `json:"participant_identity"`
	}](t, firstResponse).Participant
	origin, err := identity.NormalizeOrigin(testOrigin)
	if err != nil {
		t.Fatal(err)
	}
	f.nativePOST(t, "resume/complete", body, target, 409)
	body["signature"] = identity.Sign(testidentity.New("existing-login-fixture").Key,
		identity.ResumptionMessage(origin, platform, participant, one.ResumeToken, challenge, one.Device))
	one = decodeJSON[store.ClientLogin](t, f.nativePOST(t, "resume/complete", body, target, 200))
	f.nativePOST(t, "resume/complete", body, target, 409)
	requestAPI(original.Credential, "GET", "/v1/session", 401)
	requestAPI(one.Credential, "GET", "/v1/session", 200)
	if original.ExpiresAt != one.ExpiresAt {
		t.Fatal("resume extended the deadline")
	}
	target.requestResumption = false
	secondCode := code(200)
	checkHandoff(secondCode, false)
	f.request(t, f.http, "POST", "/api/auth/login/windows-handoff", map[string]string{"code": firstCode}, 400)
	oldVersion := target
	oldVersion.client.Version = "0.0.0"
	exchange(secondCode, verifier, oldVersion, 403)
	requestAPI(one.Credential, "GET", "/v1/session", 200)
	two := decodeJSON[store.ClientLogin](t, exchange(secondCode, verifier, target, 200))
	if two.ResumeToken != "" {
		t.Fatal("a client without the capability received a grant")
	}
	requestAPI(one.Credential, "GET", "/v1/me", 401)
	requestAPI(two.Credential, "GET", "/v1/me", 200)
	requestAPI(two.Credential, "POST", "/v1/logout", 204)
	requestAPI(two.Credential, "GET", "/v1/me", 401)
	overview := f.request(t, f.admin, "GET", "/api/overview", nil, 200)
	if !strings.Contains(overview.Body.String(), "last_login_at") || strings.Contains(overview.Body.String(), two.Credential) {
		t.Fatal("admin missed login timestamp or leaked credential")
	}
	client.RedirectURI = "https://unrelated.test/callback"
	f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]any{"client": client}, 400)
}
