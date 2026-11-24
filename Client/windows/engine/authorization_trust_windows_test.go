package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

// TestMain sets the working directory to the checkout for both Go and the packaged test runner.
const testTrustResources = "Client/apple/Shared/Resources"

// Opt-in integration fixture for testing an unmodified package from this checkout.
func testBundledSigner(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	data, err := os.ReadFile("deploy/authorization-key.default")
	ok(t, err)
	defer clear(data)
	seed, valid := identity.Bytes(string(data), ed25519.SeedSize)
	if !valid {
		t.Fatal("invalid deployment test key")
	}
	defer clear(seed)
	key := ed25519.NewKeyFromSeed(seed)
	t.Cleanup(func() { clear(key) })
	pin, err := bundledAuthorizationKey(testTrustResources)
	ok(t, err)
	if b64(key.Public().(ed25519.PublicKey)) != pin {
		t.Fatal("the bundled-key UI fixture requires a matching deployment key")
	}
	return key
}

func TestBundledAuthorizationKey(t *testing.T) {
	dir := t.TempDir()
	original, err := bundledAuthorizationKey(testTrustResources)
	ok(t, err)
	if _, err := bundledAuthorizationKey(dir); err == nil {
		t.Fatal("missing resource accepted")
	}
	for _, value := range []string{
		"{}", `{"public_key":"` + strings.Repeat("!", 44) + `"}`,
		`{"public_key":"` + b64(make([]byte, 33)) + `"}`,
		`{"public_key":"` + original + `","url":"https://unused.test"}`,
		`{"public_key":"` + original + `","public_key":"` + original + `"}`,
		`{"public_key":"` + original + `"}{}`,
	} {
		ok(t, os.WriteFile(filepath.Join(dir, "AuthorizationTrust.json"), []byte(value), 0600))
		if _, err := bundledAuthorizationKey(dir); err == nil {
			t.Fatal("invalid resource accepted")
		}
	}
}

func TestAuthorityPinnedSnapshotAndAppend(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	e, _ := f.client(t)
	f.enroll(t, e, f.account(t, "PinFixture"), false)
	owner := e.session.Device.AccountKey
	before := e.account.Heads[owner]
	var mode atomic.Int32
	previous := []byte(nil)
	snapshot, _ := f.mux.Handler(&http.Request{URL: &url.URL{Path: "/authorization/v5/snapshot"}})
	f.mux.HandleFunc("/authorization/v5/snapshot", func(w http.ResponseWriter, r *http.Request) {
		out := httptest.NewRecorder()
		snapshot.ServeHTTP(out, r)
		body := out.Body.Bytes()
		status := out.Code
		switch mode.Load() {
		case 0:
			previous = bytes.Clone(body)
		case 1:
			body = previous
		case 2:
			var envelope authorization.Envelope
			if err := json.Unmarshal(body, &envelope); err != nil {
				t.Error(err)
				return
			}
			envelope.Payload = "\n" + envelope.Payload
			body, _ = json.Marshal(envelope)
		case 3:
			status = http.StatusCreated
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write(body)
	})
	ok(t, e.refreshAuth(f.ctx, nil, false))
	for _, m := range []int32{1, 2, 3} {
		mode.Store(m)
		if e.refreshAuth(f.ctx, nil, false) == nil || e.auth.until != 0 || e.account.Heads[owner] != before {
			t.Fatalf("invalid response mode %d advanced authorization", m)
		}
	}
	mode.Store(0)
	other, _, err := ed25519.GenerateKey(nil)
	ok(t, err)
	e.trustKey = b64(other)
	if e.refreshAuth(f.ctx, nil, false) == nil || e.auth.until != 0 {
		t.Fatal("accepted server signed with another key")
	}
	e.trustKey = f.trust
	ok(t, e.refreshAuth(f.ctx, nil, false))
	f.mux.HandleFunc("/authorization/v5/append", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	if err := e.appendEvent(f.ctx, e.auth.states[owner], "enroll", "", nil); err == nil {
		t.Fatal("acknowledged append without 204")
	}
}

func TestAuthorityDeploymentOriginAndChallenge(t *testing.T) {
	for _, test := range []struct{ address, base string }{
		{"https://chirp.first.test", "https://chirp.first.test"},
		{"https://chirp.first.test/", "https://chirp.first.test"},
		{"https://chirp.second.test/", "https://chirp.second.test"},
		{"https://CHIRP.second.test:8443/", "https://chirp.second.test:8443"},
		{"https://[::1]:443/", "https://[::1]"},
	} {
		origin, err := identity.NormalizeOrigin(test.address)
		ok(t, err)
		conn := connection{origin: origin}
		for _, op := range []string{"snapshot", "append"} {
			if actual := conn.authorizationEndpoint(op); actual != test.base+"/authorization/v5/"+op {
				t.Fatal(test.address, actual)
			}
		}
	}
	key, signer, err := ed25519.GenerateKey(nil)
	ok(t, err)
	from := authorization.SnapshotRequest{Origin: "https://chirp.first.test:443", Nonce: b64(random(32))}
	data, err := json.Marshal(authorization.Snapshot{Protocol: 5, Origin: from.Origin, Nonce: from.Nonce, IssuedAt: 1, Accounts: []authorization.Account{}})
	ok(t, err)
	envelope := authorization.Envelope{Payload: b64(data), Signature: identity.Sign(signer, authorization.SnapshotMessage(from.Origin, from.Nonce, data))}
	_, err = verifiedSnapshot(envelope, b64(key), from)
	ok(t, err)
	other := from
	other.Origin = "https://chirp.second.test:443"
	if _, err := verifiedSnapshot(envelope, b64(key), other); err == nil {
		t.Fatal("snapshot accepted at another deployment with the same pinned key and challenge")
	}
	other = from
	other.Nonce = b64(random(32))
	if _, err := verifiedSnapshot(envelope, b64(key), other); err == nil {
		t.Fatal("snapshot accepted for a different challenge")
	}
}
