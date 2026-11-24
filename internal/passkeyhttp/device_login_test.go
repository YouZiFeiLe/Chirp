package passkeyhttp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func (f *fixture) nativeDevice(t *testing.T, action string, body any, want int) *httptest.ResponseRecorder {
	t.Helper()
	return f.nativeDeviceForPlatform(t, testclient.MustLatest(t, f.db, "macos"), action, body, want)
}

func (f *fixture) nativeDeviceForPlatform(t *testing.T, client store.ClientIdentity, action string, body any, want int) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", testOrigin+"/api/client/device/"+action, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	testclient.SetHeaders(r, client)
	w := httptest.NewRecorder()
	f.http.ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("device %s: got %d want %d: %s", action, w.Code, want, w.Body.String())
	}
	if w.Header().Get("Cache-Control") != "no-store" || len(w.Result().Cookies()) != 0 {
		t.Fatal("native response cached or set a browser cookie")
	}
	return w
}

func (f *fixture) startDevice(t *testing.T) (store.DeviceAuthorization, string) {
	t.Helper()
	return f.startDeviceForPlatform(t, f.nativeTarget(t, "macos"))
}

func (f *fixture) startDeviceForPlatform(
	t *testing.T, target nativeTestTarget,
) (store.DeviceAuthorization, string) {
	t.Helper()
	verifier := strings.Repeat("v", 43)
	digest := sha256.Sum256([]byte(verifier))
	w := f.nativeDeviceForPlatform(t, target.client, "start", map[string]string{
		"client_id": target.clientID, "code_challenge": b64(digest[:]), "code_challenge_method": "S256",
	}, 201)
	device := decodeJSON[struct {
		store.DeviceAuthorization
		VerificationURI string `json:"verification_uri"`
		Interval        int    `json:"interval"`
	}](t, w)
	uri, err := url.Parse(device.VerificationURI)
	if err != nil || uri.Scheme+"://"+uri.Host != testOrigin || uri.Path != "/device" || len(uri.Query()) != 1 || uri.Query().Get("request") != device.RequestID || strings.Contains(w.Body.String(), verifier) || device.Interval != 2 {
		t.Fatal("QR did not contain only a trusted public request URL")
	}
	if left := time.Until(time.Unix(device.ExpiresAt, 0)); left > 3*time.Minute || left < 3*time.Minute-2*time.Second {
		t.Fatal("incorrect QR lifetime")
	}
	return device.DeviceAuthorization, verifier
}

func (f *fixture) approveDevice(t *testing.T, a *authenticator, requestID string, want int) *httptest.ResponseRecorder {
	t.Helper()
	begin := f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]string{"device_request": requestID}, 200)
	options := decodeJSON[struct{ PublicKey struct{ Challenge string } }](t, begin)
	return f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, options.PublicKey.Challenge, testOrigin, "localhost", 0x05), want)
}

func TestDevicePasskeyApprovalAndNativeClaim(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Oliver")
	device, verifier := f.startDevice(t)
	proof := deviceProof{RequestID: device.RequestID, Verifier: verifier}
	f.approveDevice(t, a, device.RequestID, 403)
	f.nativeDevice(t, "poll", proof, 202)
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	account, err := f.db.PasskeyByCredential(context.Background(), a.id, a.handle)
	if err != nil {
		t.Fatal(err)
	}
	// A pre-existing desktop login remains valid until the new Mac claims.
	digest := sha256.Sum256([]byte(verifier))
	mac := f.nativeTarget(t, "macos")
	windows := f.nativeTarget(t, "windows")
	f.nativeDeviceForPlatform(t, windows.client, "start", map[string]string{
		"client_id": store.ClientID, "code_challenge": b64(digest[:]), "code_challenge_method": "S256",
	}, 400)
	client := store.ClientAuthorization{ClientID: store.ClientID, RedirectURI: store.ClientRedirectURI, State: strings.Repeat("s", 43), CodeChallenge: b64(digest[:]), CodeChallengeMethod: "S256"}
	code, err := f.db.CreateClientAuthorization(context.Background(), account, account.CredentialJSON, client)
	if err != nil {
		t.Fatal(err)
	}
	previous, err := f.db.ExchangeClientAuthorization(context.Background(), code, verifier, store.ClientID, store.ClientRedirectURI, mac.client, testidentity.New("existing-login-fixture").Login(store.ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	f.nativeDevice(t, "poll", deviceProof{RequestID: device.RequestID, Verifier: strings.Repeat("x", 43)}, 400)
	f.restart(t) // Pending QR requests survive a service/database connection restart.
	approved := f.approveDevice(t, a, device.RequestID, 200)
	result := decodeJSON[map[string]string](t, approved)
	if len(result) != 1 || result["status"] != "approved" || strings.Contains(approved.Body.String(), "credential") || f.cookies[sessionCookie] != nil {
		t.Fatal("phone got a credential, redirect, or browser login")
	}
	member, err := f.db.MemberByCredential(context.Background(), previous.Credential)
	if err != nil || member.LastLoginAt != previous.Member.LastLoginAt {
		t.Fatal("phone approval changed the active login", err)
	}
	f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]string{"device_request": device.RequestID}, 400)
	f.nativeDeviceForPlatform(t, windows.client, "poll", proof, 400)
	claimed := f.nativeDevice(t, "poll", proof, 200)
	if _, err := f.db.MemberByCredential(context.Background(), previous.Credential); err != nil {
		t.Fatal("setup prematurely replaced active login", err)
	}
	claimed = f.finishIdentitySetup(t, claimed, verifier, mac, testidentity.New("existing-login-fixture"))
	login := decodeJSON[struct {
		store.ClientLogin
		ParticipantIdentity string `json:"participant_identity"`
	}](t, claimed)
	if login.Member.ID != member.ID || login.Credential == "" || login.Credential == previous.Credential || login.Member.LastLoginAt == "" || !strings.HasPrefix(login.ParticipantIdentity, member.ID+".login_") || login.ParticipantIdentity == previous.Member.ParticipantIdentity() || login.ExpiresAt > time.Now().Add(20*time.Hour).Unix() {
		t.Fatal("Mac did not receive its own fresh, bounded credential")
	}
	if _, err = f.db.MemberByCredential(context.Background(), previous.Credential); err == nil {
		t.Fatal("old device still logged in after claim")
	}
	if _, err = f.db.MemberByCredential(context.Background(), login.Credential); err != nil {
		t.Fatal("new device credential rejected", err)
	}
	f.nativeDevice(t, "poll", proof, 400)
}

func TestWindowsDevicePasskeyClaim(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Windows")
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	windows := f.nativeTarget(t, "windows")
	device, verifier := f.startDeviceForPlatform(t, windows)
	proof := deviceProof{RequestID: device.RequestID, Verifier: verifier}
	f.nativeDeviceForPlatform(t, windows.client, "poll", proof, 202)
	f.nativeDevice(t, "poll", proof, 400)
	f.approveDevice(t, a, device.RequestID, 200)
	f.nativeDeviceForPlatform(t, store.ClientIdentity{Platform: store.WindowsClientPlatform, Version: "0.0.0", Build: 1}, "poll", proof, 403)
	f.nativeDeviceForPlatform(t, windows.client, "poll", deviceProof{
		RequestID: device.RequestID, Verifier: strings.Repeat("x", 43),
	}, 400)
	w := f.nativeDeviceForPlatform(t, windows.client, "poll", proof, 200)
	w = f.finishIdentitySetup(t, w, verifier, windows, testidentity.New("existing-login-fixture"))
	login := decodeJSON[store.ClientLogin](t, w)
	if login.Member.DisplayName != "Windows" || login.Credential == "" {
		t.Fatal("Windows did not receive a login for the approved account")
	}
	f.nativeDeviceForPlatform(t, windows.client, "poll", proof, 400)
	device, verifier = f.startDeviceForPlatform(t, windows)
	proof = deviceProof{RequestID: device.RequestID, Verifier: verifier}
	f.nativeDeviceForPlatform(t, windows.client, "cancel", proof, 204)
	f.nativeDeviceForPlatform(t, windows.client, "poll", proof, 400)
	f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]string{"device_request": device.RequestID}, 400)
}

func TestAndroidDevicePasskeyClaim(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Android")
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)

	android := f.nativeTarget(t, "android")
	device, verifier := f.startDeviceForPlatform(t, android)
	proof := deviceProof{RequestID: device.RequestID, Verifier: verifier}
	f.nativeDeviceForPlatform(t, android.client, "poll", proof, 202)
	f.approveDevice(t, a, device.RequestID, 200)
	f.nativeDeviceForPlatform(t, store.ClientIdentity{Platform: store.AndroidClientPlatform, Version: "0.0.0", Build: 1}, "poll", proof, 403)

	w := f.nativeDeviceForPlatform(t, android.client, "poll", proof, 200)
	w = f.finishIdentitySetup(t, w, verifier, android, testidentity.New("android-owner"))
	login := decodeJSON[store.ClientLogin](t, w)
	if login.Member.DisplayName != "Android" || login.Credential == "" {
		t.Fatal("Android did not receive a login for the approved account")
	}
	f.nativeDeviceForPlatform(t, android.client, "poll", proof, 400)
}

func TestDeviceCancellationAndFreshPasskeyBinding(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Oliver")
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	device, verifier := f.startDevice(t)
	proof := deviceProof{RequestID: device.RequestID, Verifier: verifier}
	// A regular browser login cannot authorize an unrelated device request.
	begin := f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]any{}, 200)
	options := decodeJSON[struct{ PublicKey struct{ Challenge string } }](t, begin)
	f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, options.PublicKey.Challenge, testOrigin, "localhost", 0x05), 200)
	f.nativeDevice(t, "poll", proof, 202)
	// Public request ID alone cannot cancel or claim. Browser session is irrelevant.
	f.nativeDevice(t, "cancel", deviceProof{RequestID: device.RequestID}, 400)
	begin = f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]string{"device_request": device.RequestID}, 200)
	options = decodeJSON[struct{ PublicKey struct{ Challenge string } }](t, begin)
	f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, options.PublicKey.Challenge, testOrigin, "localhost", 0x01), 400) // UV is required.
	f.nativeDevice(t, "poll", proof, 202)
	begin = f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]string{"device_request": device.RequestID}, 200)
	options = decodeJSON[struct{ PublicKey struct{ Challenge string } }](t, begin)
	f.nativeDevice(t, "cancel", proof, 204)
	f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, options.PublicKey.Challenge, testOrigin, "localhost", 0x05), 400)
	f.nativeDevice(t, "poll", proof, 400)
	f.nativeDevice(t, "cancel", proof, 204)
	f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]string{"device_request": device.RequestID}, 400)
}

func TestDeviceRequestOriginAndInputBoundaries(t *testing.T) {
	f := newFixture(t)
	device, _ := f.startDevice(t)
	f.nativeDevice(t, "start", map[string]string{"client_id": "unrelated", "code_challenge": strings.Repeat("a", 43), "code_challenge_method": "S256"}, 400)
	f.nativeDevice(t, "start", map[string]string{"client_id": store.ClientID, "code_challenge": strings.Repeat("a", 43), "code_challenge_method": "plain"}, 400)
	f.nativeDevice(t, "start", map[string]string{"client_id": store.ClientID, "code_challenge": "short", "code_challenge_method": "S256"}, 400)
	f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]any{"device_request": device.RequestID, "client": store.ClientAuthorization{}}, 400)
	mac := testclient.MustLatest(t, f.db, "macos")
	for _, path := range []string{"/api/client/device/start", "/api/client/device/poll", "/api/client/device/cancel", "/api/auth/login/begin"} {
		r := httptest.NewRequest("POST", testOrigin+path, strings.NewReader(`{}`))
		r.Header.Set("Content-Type", "application/json")
		testclient.SetHeaders(r, mac)
		r.Header.Set("Origin", "https://unrelated.test")
		w := httptest.NewRecorder()
		f.http.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatalf("cross-origin POST accepted for %s: %d", path, w.Code)
		}
		r.Header.Del("Origin")
		r.Header.Set("Sec-Fetch-Site", "cross-site")
		w = httptest.NewRecorder()
		f.http.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatalf("cross-site request without Origin accepted for %s: %d", path, w.Code)
		}
	}
	r := httptest.NewRequest("POST", testOrigin+"/api/auth/login/begin", strings.NewReader(`{}`))
	r.Header.Set("Content-Type", "application/json")
	testclient.SetHeaders(r, mac)
	w := httptest.NewRecorder()
	f.http.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("native Origin exemption extended to browser Passkey endpoints")
	}
	f.request(t, f.http, "GET", "/device?request="+device.RequestID, nil, 200)
}
