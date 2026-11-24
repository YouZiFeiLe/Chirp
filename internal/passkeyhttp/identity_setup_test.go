package passkeyhttp

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func (f *fixture) identityPOST(t *testing.T, path string, body any, target nativeTestTarget, want int) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", testOrigin+"/api/client/identity/"+path, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	testclient.SetHeaders(r, target.client)
	w := httptest.NewRecorder()
	f.http.ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("identity %s got %d want %d: %s", path, w.Code, want, w.Body.String())
	}
	return w
}
func (f *fixture) finishIdentitySetup(t *testing.T, response *httptest.ResponseRecorder, verifier string, target nativeTestTarget, client testidentity.Client) *httptest.ResponseRecorder {
	t.Helper()
	setup := decodeJSON[store.IdentitySetup](t, response)
	if setup.Token == "" || setup.AccountID == "" {
		t.Fatal("missing authenticated setup state")
	}
	body := map[string]any{"setup_token": setup.Token, "code_verifier": verifier, "device": client.Device}
	challenge := decodeJSON[map[string]string](t, f.identityPOST(t, "challenge", body, target, 200))["challenge"]
	body["signature"] = identity.Sign(client.Key, identity.ActivationMessage(setup.Origin, setup.AccountID, target.clientID, setup.Token, verifier, challenge, client.Device))
	result := f.identityPOST(t, "complete", body, target, 200)
	f.identityPOST(t, "complete", body, target, 400)
	return result
}
func TestSetupEndpointsRequirePrivatePasskeyAuthorization(t *testing.T) {
	f := newFixture(t)
	target := f.nativeTarget(t, "ios")
	client := testidentity.New("unauthenticated-setup")
	f.identityPOST(t, "challenge", map[string]any{"setup_token": "missing", "code_verifier": "missing", "device": client.Device}, target, 400)
	f.identityPOST(t, "complete", map[string]any{"setup_token": "missing", "code_verifier": "missing", "device": client.Device, "signature": "missing"}, target, 400)
}
