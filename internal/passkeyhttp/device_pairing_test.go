package passkeyhttp

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func TestPairingHTTPUsesScopedNativeProofsAndPreservesOldLoginUntilActivation(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Pairing")
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	account, err := f.db.PasskeyByCredential(t.Context(), a.id, a.handle)
	if err != nil {
		t.Fatal(err)
	}
	target := f.nativeTarget(t, "macos")
	verifier := strings.Repeat("v", 43)
	challenge := sha256.Sum256([]byte(verifier))
	setup := func() store.IdentitySetup {
		t.Helper()
		code, err := f.db.CreateClientAuthorization(t.Context(), account, account.CredentialJSON, store.ClientAuthorization{
			ClientID: store.ClientID, RedirectURI: store.ClientRedirectURI, CodeChallenge: base64.RawURLEncoding.EncodeToString(challenge[:]),
			State: strings.Repeat("s", 32), CodeChallengeMethod: "S256"})
		if err != nil {
			t.Fatal(err)
		}
		value, err := f.db.BeginIdentitySetup(t.Context(), code, verifier, store.ClientID, testOrigin, target.client, false)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	activate := func(value store.IdentitySetup, device testidentity.Client) store.ClientLogin {
		t.Helper()
		body := map[string]any{"setup_token": value.Token, "code_verifier": verifier, "device": device.Device}
		challenge := decodeJSON[map[string]string](t, f.identityPOST(t, "challenge", body, target, 200))["challenge"]
		body["signature"] = identity.Sign(device.Key, identity.ActivationMessage(value.Origin, value.AccountID, store.ClientID, value.Token, verifier, challenge, device.Device))
		return decodeJSON[store.ClientLogin](t, f.identityPOST(t, "complete", body, target, 200))
	}
	old := testidentity.New("http-pairing-old")
	previous := activate(setup(), old)
	pending := setup()
	candidate := testidentity.Child(old, "http-pairing-new", true)
	request := identity.DevicePairingRequest{Version: 1, Origin: pending.Origin, AccountID: pending.AccountID, AccountKey: old.Device.AccountKey,
		DeviceKey: candidate.Device.LeafKey(), Nonce: identity.Hash([]byte("http-pairing")), ExpiresAt: time.Now().Add(2 * time.Minute).Unix(), Commitment: identity.Hash([]byte("SAS commitment"))}
	request.Signature = identity.Sign(candidate.Key, request.Message())
	body := map[string]any{"setup_token": "missing", "code_verifier": verifier, "request": request}
	f.identityPOST(t, "pairing/start", body, target, 400)
	body["setup_token"] = pending.Token
	started := f.identityPOST(t, "pairing/start", body, target, 200)
	if strings.Contains(started.Body.String(), "credential") {
		t.Fatal("pairing issued a business credential")
	}
	state := decodeJSON[store.DevicePairingState](t, started)
	if state.Request != request {
		t.Fatal("request changed")
	}
	apply := func(kind, payload string, want int) {
		t.Helper()
		a := identity.DevicePairingAction{RequestID: request.Hash(), Action: kind, Issuer: old.Device, Payload: payload,
			Nonce: identity.Hash([]byte(kind)), CreatedAt: time.Now().Unix()}
		key := old.Key
		if kind == "reveal" || kind == "new-confirm" {
			key = candidate.Key
		}
		a.Signature = identity.Sign(key, a.Message())
		f.identityPOST(t, "pairing/action", a, target, want)
	}
	apply("offer", `{"kind":"Accept","key":"old-ephemeral"}`, 200)
	apply("reveal", `{"kind":"Key","key":"new-ephemeral"}`, 200)
	payload, err := json.Marshal(identity.DevicePairingApproval{Device: candidate.Device})
	if err != nil {
		t.Fatal(err)
	}
	apply("approve", string(payload), 409)
	apply("new-confirm", `{"kind":"Mac","mac":"new-mac"}`, 200)
	apply("old-confirm", `{"kind":"Mac","mac":"old-mac"}`, 200)
	apply("approve", string(payload), 200)
	if _, err = f.db.MemberByCredential(t.Context(), previous.Credential); err != nil {
		t.Fatal("approval prematurely logged old client out", err)
	}
	current := activate(pending, candidate)
	if current.Credential == previous.Credential {
		t.Fatal("session was not replaced")
	}
	if _, err = f.db.MemberByCredential(t.Context(), previous.Credential); err == nil {
		t.Fatal("old session survived successful login")
	}

	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", testOrigin+"/api/client/identity/pairing/start", bytes.NewReader(data))
	r.Header.Set("Origin", "https://evil.test")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.http.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("native origin exemption admitted a foreign browser origin", w.Code)
	}
}
