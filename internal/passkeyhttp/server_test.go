package passkeyhttp

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-webauthn/webauthn/protocol/webauthncbor"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/adminhttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testadmin"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

const testOrigin = "http://localhost:18117"

type media struct{}

func (media) Participants(context.Context, string) ([]room.Participant, error) { return nil, nil }
func (media) RemoveParticipant(context.Context, string, string) error          { return nil }
func (media) EndRoom(context.Context, string) error                            { return nil }

type fixture struct {
	db      *store.Store
	dsn     string
	http    http.Handler
	admin   http.Handler
	cookies map[string]*http.Cookie
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{dsn: testdb.Path(t), cookies: map[string]*http.Cookie{}}
	f.restart(t)
	return f
}

func (f *fixture) restart(t *testing.T) {
	t.Helper()
	if f.db != nil {
		f.db.Close()
	}
	db, err := store.Open(context.Background(), f.dsn)
	if err != nil {
		t.Fatal(err)
	}
	f.db = db
	t.Cleanup(func() { db.Close() })
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	f.http, err = New(db, config.PasskeyConfig{RPID: "localhost", Origins: []string{testOrigin}}, logger)
	if err != nil {
		t.Fatal(err)
	}
	admin := adminhttp.New(db, media{}, "ws://localhost:18117", logger)
	var administrator *http.Cookie
	f.admin = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if administrator == nil {
			administrator = testadmin.Session(t, db)
		}
		r.Header.Set("Cookie", administrator.String())
		r.URL.Path = "/admin" + r.URL.Path
		admin.ServeHTTP(w, r)
	})
}

func (f *fixture) request(t *testing.T, handler http.Handler, method, path string, body any, want int) *httptest.ResponseRecorder {
	t.Helper()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	r := httptest.NewRequest(method, testOrigin+path, bytes.NewReader(data))
	if method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE" {
		r.Header.Set("Origin", testOrigin)
		r.Header.Set("Content-Type", "application/json")
		if strings.HasPrefix(path, "/api/client/") {
			testclient.SetHeaders(r, testclient.MustLatest(t, f.db, "macos"))
		}
		r.Header.Set("Sec-Fetch-Site", "same-origin")
	}
	for _, cookie := range f.cookies {
		r.AddCookie(cookie)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("%s %s: got %d want %d: %s", method, path, w.Code, want, w.Body.String())
	}
	for _, cookie := range w.Result().Cookies() {
		if cookie.MaxAge < 0 {
			delete(f.cookies, cookie.Name)
		} else {
			f.cookies[cookie.Name] = cookie
		}
	}
	return w
}

func decodeJSON[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var data T
	if err := json.Unmarshal(w.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	return data
}

func b64(data []byte) string { return base64.RawURLEncoding.EncodeToString(data) }
func unb64(t *testing.T, value string) []byte {
	t.Helper()
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

type authenticator struct {
	key    *ecdsa.PrivateKey
	id     []byte
	handle []byte
	count  uint32
}

func (f *fixture) register(t *testing.T, nickname string) (*authenticator, string) {
	t.Helper()
	a, body := f.beginRegistration(t, nickname)
	receipt := decodeJSON[map[string]string](t, f.request(t, f.http, "POST", "/api/auth/register/finish", body, 201))
	if len(receipt) != 1 || !strings.HasPrefix(receipt["request_id"], "CHIRP-") {
		t.Fatal("registration did not return only its receipt")
	}
	return a, receipt["request_id"]
}

func (f *fixture) beginRegistration(t *testing.T, nickname string) (*authenticator, map[string]any) {
	t.Helper()
	begin := f.request(t, f.http, "POST", "/api/auth/register/begin", map[string]string{"nickname": nickname}, 200)
	options := decodeJSON[typeofOptions](t, begin)
	if options.PublicKey.RP.ID != "localhost" || options.PublicKey.AuthenticatorSelection.ResidentKey != "required" || options.PublicKey.AuthenticatorSelection.UserVerification != "required" {
		t.Fatal("registration is not a verified discoverable passkey")
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	a := &authenticator{key: key, id: make([]byte, 32), handle: unb64(t, options.PublicKey.User.ID)}
	if _, err = rand.Read(a.id); err != nil {
		t.Fatal(err)
	}
	publicKey, err := webauthncbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: key.X.FillBytes(make([]byte, 32)), -3: key.Y.FillBytes(make([]byte, 32))})
	if err != nil {
		t.Fatal(err)
	}
	rp := sha256.Sum256([]byte("localhost"))
	data := append(append([]byte{}, rp[:]...), 0x45, 0, 0, 0, 0)
	data = append(data, make([]byte, 16)...)
	data = binary.BigEndian.AppendUint16(data, uint16(len(a.id)))
	data = append(data, a.id...)
	data = append(data, publicKey...)
	attestation, err := webauthncbor.Marshal(map[string]any{"fmt": "none", "authData": data, "attStmt": map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := json.Marshal(map[string]any{"type": "webauthn.create", "challenge": options.PublicKey.Challenge, "origin": testOrigin, "crossOrigin": false})
	body := map[string]any{"id": b64(a.id), "rawId": b64(a.id), "type": "public-key", "authenticatorAttachment": "platform", "clientExtensionResults": map[string]any{}, "response": map[string]any{"clientDataJSON": b64(client), "attestationObject": b64(attestation), "transports": []string{"internal"}}}
	return a, body
}

type typeofOptions = struct {
	PublicKey struct {
		Challenge              string
		RP                     struct{ ID string }
		User                   struct{ ID string }
		AuthenticatorSelection struct {
			ResidentKey      string
			UserVerification string
		}
	}
}

func (a *authenticator) assertion(t *testing.T, challenge, origin, rpid string, flags byte) map[string]any {
	t.Helper()
	a.count++
	client, _ := json.Marshal(map[string]any{"type": "webauthn.get", "challenge": challenge, "origin": origin, "crossOrigin": false})
	rp := sha256.Sum256([]byte(rpid))
	data := append(append([]byte{}, rp[:]...), flags)
	data = binary.BigEndian.AppendUint32(data, a.count)
	clientHash := sha256.Sum256(client)
	signed := append(append([]byte{}, data...), clientHash[:]...)
	digest := sha256.Sum256(signed)
	signature, err := ecdsa.SignASN1(rand.Reader, a.key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"id": b64(a.id), "rawId": b64(a.id), "type": "public-key", "authenticatorAttachment": "platform", "clientExtensionResults": map[string]any{}, "response": map[string]any{"clientDataJSON": b64(client), "authenticatorData": b64(data), "signature": b64(signature), "userHandle": b64(a.handle)}}
}

func (f *fixture) loginChallenge(t *testing.T) string {
	w := f.request(t, f.http, "POST", "/api/auth/login/begin", map[string]any{}, 200)
	options := decodeJSON[struct {
		PublicKey struct {
			Challenge        string
			UserVerification string
			AllowCredentials []any
		}
	}](t, w)
	if options.PublicKey.UserVerification != "required" || len(options.PublicKey.AllowCredentials) != 0 {
		t.Fatal("login leaked account-specific credentials")
	}
	return options.PublicKey.Challenge
}

func TestAdminCanPauseAndResumeRegistration(t *testing.T) {
	f := newFixture(t)
	existing, receipt := f.register(t, "Oliver")
	_, inFlight := f.beginRegistration(t, "Juniper")
	registrationCeremony := f.cookies[ceremonyCookie]
	type settings struct {
		Closed *bool `json:"registration_closed"`
	}
	checkSetting := func(w *httptest.ResponseRecorder, want bool) {
		t.Helper()
		value := decodeJSON[settings](t, w)
		if value.Closed == nil || *value.Closed != want {
			t.Fatalf("registration_closed should be %t: %s", want, w.Body.String())
		}
	}
	const path = "/api/registration-settings"
	checkSetting(f.request(t, f.admin, "GET", "/api/overview", nil, 200), false)
	checkSetting(f.request(t, f.admin, "PUT", path, map[string]bool{"registration_closed": true}, 200), true)
	f.request(t, f.admin, "PUT", path, map[string]any{}, 400)
	checkSetting(f.request(t, f.admin, "GET", "/api/overview", nil, 200), true)

	begin := f.request(t, f.http, "POST", "/api/auth/register/begin", map[string]string{"nickname": "Morgan"}, 403)
	finish := f.request(t, f.http, "POST", "/api/auth/register/finish", inFlight, 403)
	for _, response := range []*httptest.ResponseRecorder{begin, finish} {
		if !strings.Contains(response.Body.String(), `"code":"REGISTRATION_CLOSED"`) {
			t.Fatal(response.Body.String())
		}
	}
	requests, err := f.db.ListRegistrationRequests(t.Context())
	if err != nil || len(requests) != 2 { // Oliver and the test administrator.
		t.Fatalf("closed registration changed the request list: %+v, %v", requests, err)
	}

	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	f.request(t, f.http, "POST", "/api/auth/login/finish", existing.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 200)
	checkSetting(f.request(t, f.admin, "PUT", path, map[string]bool{"registration_closed": false}, 200), false)
	f.cookies[ceremonyCookie] = registrationCeremony
	f.request(t, f.http, "POST", "/api/auth/register/finish", inFlight, 400)
	f.register(t, "Juniper")
}

func TestRegistrationApprovalLoginAndRevocation(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Oliver")
	if members, err := f.db.ListMembers(context.Background()); err != nil || len(members) != 0 {
		t.Fatal("pending registration became a member", err)
	}
	pending := f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 403)
	if !strings.Contains(pending.Body.String(), "REGISTRATION_PENDING") {
		t.Fatal("pending registration did not return its explicit state")
	}
	if strings.Contains(pending.Body.String(), receipt) {
		t.Fatal("login recovered a lost request number")
	}
	f.restart(t)
	overview := f.request(t, f.admin, "GET", "/api/overview", nil, 200)
	if !strings.Contains(overview.Body.String(), receipt) || strings.Contains(overview.Body.String(), "credential_json") || strings.Contains(overview.Body.String(), b64(a.id)) {
		t.Fatal("admin overview missed registration or leaked credentials")
	}
	approved := f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
	member := decodeJSON[store.Member](t, approved)
	if member.DisplayName != "Oliver" || member.ID == "" || strings.Contains(approved.Body.String(), "credential") {
		t.Fatal("approval exposed a credential or failed to create a member")
	}
	f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 409)
	f.request(t, f.admin, "DELETE", "/api/registrations/"+receipt, nil, 409)
	challenge := f.loginChallenge(t)
	oldCookie := *f.cookies[ceremonyCookie]
	body := a.assertion(t, challenge, testOrigin, "localhost", 0x05)
	f.request(t, f.http, "POST", "/api/auth/login/finish", body, 200)
	webCookie := f.cookies[sessionCookie]
	if webCookie == nil || !webCookie.HttpOnly || webCookie.SameSite != http.SameSiteStrictMode || webCookie.Domain != "" {
		t.Fatal("unsafe browser session cookie")
	}
	f.cookies[ceremonyCookie] = &oldCookie
	f.request(t, f.http, "POST", "/api/auth/login/finish", body, 400)
	f.restart(t)
	session := f.request(t, f.http, "GET", "/api/session", nil, 200)
	if !strings.Contains(session.Body.String(), member.ID) {
		t.Fatal("session did not survive restart")
	}
	f.request(t, f.http, "POST", "/api/auth/logout", map[string]any{}, 204)
	if strings.Contains(f.request(t, f.http, "GET", "/api/session", nil, 200).Body.String(), member.ID) {
		t.Fatal("logout failed")
	}
	f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 200)
	if err := f.db.DisableMember(context.Background(), member.ID); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(f.request(t, f.http, "GET", "/api/session", nil, 200).Body.String(), member.ID) {
		t.Fatal("disabled member kept a browser session")
	}
	f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 403)
	if err := f.db.DeleteMember(context.Background(), member.ID); err != nil {
		t.Fatal(err)
	}
	banned := f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 403)
	if !strings.Contains(banned.Body.String(), "IDENTITY_BLACKLISTED") {
		t.Fatal("deleted banned identity did not retain its permanent ban")
	}
	if err := f.db.CheckRegistrationName(context.Background(), "oliver"); !errors.Is(err, store.ErrRegistrationExists) {
		t.Fatal("member deletion released a permanently reserved username", err)
	}
}

func TestDeletedApplicationCanRegisterAgain(t *testing.T) {
	f := newFixture(t)
	a, receipt := f.register(t, "Alice")
	f.request(t, f.http, "POST", "/api/auth/register/begin", map[string]string{"nickname": "alice"}, 409)
	f.request(t, f.admin, "DELETE", "/api/registrations/"+receipt, nil, 204)
	rejected := f.request(t, f.http, "POST", "/api/auth/login/finish", a.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 403)
	if !strings.Contains(rejected.Body.String(), "REGISTRATION_REJECTED") || f.cookies[sessionCookie] != nil {
		t.Fatal("rejected registration gained a session or lost its explicit state")
	}
	_, replacement := f.register(t, "alice")
	if receipt == replacement {
		t.Fatal("re-registration reused receipt")
	}
	for _, path := range []string{"/api/registrations/" + replacement, "/api/auth/register/status", "/api/status", "/admin", "/v1/me"} {
		f.request(t, f.http, "GET", path, nil, 404)
	}
}

func TestPasskeyChecksChallengeOriginSignatureAndVerification(t *testing.T) {
	for _, mode := range []string{"challenge", "origin", "rp", "verification", "signature", "handle"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			a, receipt := f.register(t, "Alice")
			f.request(t, f.admin, "POST", "/api/registrations/"+receipt+"/approve", map[string]any{}, 200)
			challenge, origin, rp, flags := f.loginChallenge(t), testOrigin, "localhost", byte(0x05)
			switch mode {
			case "challenge":
				challenge = b64(make([]byte, 32))
			case "origin":
				origin = "https://unrelated.test"
			case "rp":
				rp = "unrelated.test"
			case "verification":
				flags = 0x01
			case "signature":
				var err error
				a.key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
			case "handle":
				a.handle = []byte("unrelated-account")
			}
			body := a.assertion(t, challenge, origin, rp, flags)
			f.request(t, f.http, "POST", "/api/auth/login/finish", body, 400)
			if f.cookies[sessionCookie] != nil {
				t.Fatal("invalid authentication created a session")
			}
		})
	}
}

func TestInputAndOriginBoundaries(t *testing.T) {
	f := newFixture(t)
	for _, name := range []string{"ab", "abcdefghijklmnop", "Alice1", "Alice Bob", "中文昵称", " Alice", "Alice ", "Ａlice"} {
		f.request(t, f.http, "POST", "/api/auth/register/begin", map[string]string{"nickname": name}, 400)
	}
	for _, path := range []string{"/", "/register", "/assets/app.js", "/assets/styles.css", "/assets/theme.css", "/assets/icon.svg", "/assets/i18n.js", "/assets/locales/zh-CN.js", "/assets/locales/en.js", "/healthz"} {
		w := f.request(t, f.http, "GET", path, nil, 200)
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("public response is cacheable")
		}
	}
	for _, origin := range []string{"", "https://unrelated.test"} {
		r := httptest.NewRequest("POST", testOrigin+"/api/auth/register/begin", strings.NewReader(`{"nickname":"Alice"}`))
		r.Header.Set("Origin", origin)
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		f.http.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal("unapproved HTTP origin accepted", w.Code)
		}
	}
	f.request(t, f.http, "POST", "/api/auth/register/finish", map[string]any{}, 400)
}

func TestBootstrapPasskeyAuthenticatesAdministratorAndLogoutRevokesAccess(t *testing.T) {
	f := newFixture(t)
	authenticator, receipt := f.register(t, "FirstAdmin")
	member, err := f.db.BootstrapAdministrator(context.Background(), receipt)
	if err != nil || !member.IsAdmin {
		t.Fatal(member, err)
	}
	// This request performs real ES256 WebAuthn challenge/origin/RP verification.
	login := f.request(t, f.http, "POST", "/api/auth/login/finish", authenticator.assertion(t, f.loginChallenge(t), testOrigin, "localhost", 0x05), 200)
	if !decodeJSON[store.Member](t, login).IsAdmin {
		t.Fatal("administrator role missing from verified login")
	}
	admin := adminhttp.New(f.db, media{}, "ws://localhost:18117", slog.New(slog.NewTextHandler(io.Discard, nil)))
	f.request(t, admin, "GET", "/admin/api/overview", nil, 200)
	f.request(t, f.http, "POST", "/api/auth/logout", map[string]any{}, 204)
	f.request(t, admin, "GET", "/admin/api/overview", nil, 401)
}
