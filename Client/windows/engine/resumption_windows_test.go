package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestFirstBrowserLoginUsesConfirmedServer(t *testing.T) {
	_, signer, err := ed25519.GenerateKey(rand.Reader)
	ok(t, err)
	var requests atomic.Int32
	var requireUpdate atomic.Bool
	var exchanges atomic.Int32
	f := serviceWithHTTP(t, "ws://127.0.0.1:1", signer, func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requests.Add(1)
			if r.URL.Path == "/v1/client-config" && requireUpdate.Load() {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				fmt.Fprint(w, `{"error":{"code":"CLIENT_UPDATE_REQUIRED"}}`)
				return
			}
			if r.URL.Path == "/api/client/exchange" {
				exchanges.Add(1)
			}
			next.ServeHTTP(w, r)
		})
	})
	client, _ := f.client(t)
	client.loginPath = filepath.Join(t.TempDir(), "saved-login.v1")
	account := f.account(t, "FirstBrowser")
	before := requests.Load()
	start, err := client.handle(f.ctx, command{Op: "browser"})
	ok(t, err)
	u, err := url.Parse(start.(obj)["url"].(string))
	ok(t, err)
	if requests.Load() != before || client.flow.offerResumption || client.flow.wrappingKey != nil || u.Query().Get("code_challenge_method") != "S256" {
		t.Fatal("opening Passkey repeated discovery or prepared Windows Hello")
	}
	q := u.Query()
	auth := store.ClientAuthorization{ClientID: q.Get("client_id"), RedirectURI: q.Get("redirect_uri"), State: q.Get("state"),
		CodeChallenge: q.Get("code_challenge"), CodeChallengeMethod: q.Get("code_challenge_method")}
	code, err := f.db.CreateClientAuthorization(f.ctx, account, account.CredentialJSON, auth)
	ok(t, err)
	cb := store.WindowsClientRedirectURI + "?state=" + auth.State + "&code=" + code
	next, err := client.handle(f.ctx, command{Op: "exchange", Args: args{URL: cb, Enabled: true}})
	ok(t, err)
	if next.(obj)["step"] != "backup" || !client.flow.offerResumption || client.flow.wrappingKey != nil {
		t.Fatal("first browser callback did not proceed to initial device setup without a Hello key")
	}
	client.cancelLogin(f.ctx)
	_, err = client.restoreConnection()
	ok(t, err)
	before = requests.Load()
	_, err = client.handle(f.ctx, command{Op: "browser"})
	ok(t, err)
	if requests.Load() == before {
		t.Fatal("a server restored from disk was used without revalidation")
	}
	requireUpdate.Store(true)
	before = exchanges.Load()
	cb = store.WindowsClientRedirectURI + "?state=" + client.flow.state + "&code=" + code
	_, err = client.handle(f.ctx, command{Op: "exchange", Args: args{URL: cb, Enabled: true}})
	if err == nil || err.Error() != "CLIENT_UPDATE_REQUIRED" || exchanges.Load() != before {
		t.Fatal("browser callback sent secrets after the server required an update", err)
	}
}

func TestWindowsColdLogin(t *testing.T) {
	requireNative(t)
	_, signer, err := ed25519.GenerateKey(rand.Reader)
	ok(t, err)
	var mode atomic.Value
	mode.Store("")
	completed := make(chan struct{})
	var challenges atomic.Int32
	var requested atomic.Bool
	f := serviceWithHTTP(t, "ws://127.0.0.1:1", signer, func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			path := r.URL.Path
			if path == "/api/client/identity/complete" {
				requested.Store(r.Header.Get("X-Chirp-Login-Resumption") == "1")
				if mode.Load() == "oldServer" {
					r.Header.Del("X-Chirp-Login-Resumption")
				}
			}
			if strings.HasPrefix(path, "/api/client/resume/") {
				if r.Method != "POST" || r.Header.Get("X-Chirp-Platform") != "windows" || r.Header.Get("X-Chirp-Version") != version ||
					r.Header.Get("X-Chirp-Build") == "" || r.Header.Get("Cache-Control") != "no-store" || r.Header.Get("Authorization") != "" {
					t.Error("incorrect resumption headers")
				}
				if strings.HasSuffix(path, "/challenge") {
					challenges.Add(1)
				}
				switch mode.Load() {
				case "offline":
					w.WriteHeader(503)
					return
				case "proof":
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(409)
					_, _ = w.Write([]byte(`{"error":{"code":"RESUMPTION_PROOF_INVALID"}}`))
					return
				case "expires_at", "participant_identity", "member", "device_identity":
					if strings.HasSuffix(path, "/complete") {
						actual := httptest.NewRecorder()
						next.ServeHTTP(actual, r)
						var result obj
						if json.Unmarshal(actual.Body.Bytes(), &result) != nil {
							t.Error("invalid fixture response")
						}
						switch field := mode.Load().(string); field {
						case "expires_at":
							result[field] = result[field].(float64) + 1
						case "participant_identity":
							result[field] = result[field].(string) + "other"
						case "member", "device_identity":
							result[field] = obj{}
						}
						w.Header().Set("Content-Type", "application/json")
						_ = json.NewEncoder(w).Encode(result)
						return
					}
				case "late":
					if strings.HasSuffix(path, "/complete") {
						// The real server has rotated the bearer before the client leaves the foreground.
						next.ServeHTTP(httptest.NewRecorder(), r)
						close(completed)
						<-r.Context().Done()
						return
					}
				}
			}
			next.ServeHTTP(w, r)
		})
	})
	account := f.account(t, "ResumeTest")
	client, _ := f.client(t)
	client.loginPath = filepath.Join(t.TempDir(), "saved-login.v1")
	f.enroll(t, client, account, false)
	if requested.Load() {
		t.Fatal("activation requested a grant without Windows Hello")
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	ok(t, err)
	public, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	ok(t, err)
	signIn := func(wrappingKey []byte) obj {
		t.Helper()
		client.reset(f.ctx)
		_, err := client.handle(f.ctx, command{Op: "phone"})
		ok(t, err)
		ok(t, f.db.ApproveDeviceAuthorization(f.ctx, client.flow.requestID, account, account.CredentialJSON))
		id := client.flow.state
		_, err = client.handle(f.ctx, command{Op: "pollPhone", Args: args{ID: id}})
		ok(t, err)
		result, err := client.handle(f.ctx, command{Op: "finishPhone", Args: args{ID: id, Enabled: true, File: wrappingKey}})
		ok(t, err)
		step := result.(obj)
		if step["step"] != "signedIn" || !requested.Load() {
			t.Fatal("capable activation failed")
		}
		return step
	}
	passkey := func() { signIn(public) }
	mode.Store("oldServer")
	step := signIn(nil)
	if hint, err := client.readSavedLogin(); err != nil || hint != nil || client.session == nil || step["resumption"] != "unavailable" {
		t.Fatal("an older server must permit a memory-only sign-in")
	}
	mode.Store("")
	step = signIn(nil)
	if step["resumption"] != "available" || step["login"] != client.session.Identity || client.pendingLoginGrant == "" {
		t.Fatal("a fresh login did not offer optional enrollment in settings")
	}
	if hint, err := client.readSavedLogin(); err != nil || hint != nil {
		t.Fatal("a fresh login was persisted before the user enabled Hello")
	}
	enable := func(login string, key []byte) error {
		_, err := client.handle(f.ctx, command{Op: "enableLoginResumption", Args: args{ID: login, File: key}})
		return err
	}
	staleLogin := client.session.Identity
	client.reset(f.ctx)
	if client.pendingLoginGrant != "" || enable(staleLogin, public) == nil {
		t.Fatal("sign-out retained the pending grant")
	}
	signIn(nil)
	if enable(staleLogin, public) == nil || enable(client.session.Identity, nil) == nil {
		t.Fatal("stale or cancelled enrollment saved the current login")
	}
	client.session.Expires = time.Now().Unix()
	if err := enable(client.session.Identity, public); !errors.Is(err, errSessionExpired) || client.pendingLoginGrant != "" {
		t.Fatal("an expired login could enable Hello", err)
	}
	signIn(nil)
	ok(t, enable(client.session.Identity, public))
	if client.pendingLoginGrant != "" {
		t.Fatal("grant was retained in memory after enrollment")
	}
	original := *client.session
	onDisk, err := os.ReadFile(client.loginPath)
	ok(t, err)
	if bytes.Contains(onDisk, []byte(original.Credential)) || bytes.Contains(onDisk, []byte(identity.ResumptionTokenPrefix)) ||
		bytes.Contains(onDisk, []byte(original.Identity)) {
		t.Fatal("sensitive plaintext in saved login")
	}
	// Open the DPAPI identity vault and the sealed record just as a new process does.
	v, err := loadVault(filepath.Dir(client.vault.path))
	ok(t, err)
	cold := &engine{vault: v, loginPath: client.loginPath, local: true}
	_, err = cold.restoreConnection()
	ok(t, err)
	attempt := func(id string) command {
		t.Helper()
		hint, err := cold.readSavedLogin()
		ok(t, err)
		if hint == nil || hint.Expires != original.Expires {
			t.Fatal("missing original deadline")
		}
		dek, err := rsa.DecryptPKCS1v15(rand.Reader, key, hint.WrappedKey)
		ok(t, err)
		return command{Op: "resumeLogin", resume: cold.beginResume(f.ctx, id), Args: args{File: dek}}
	}
	unlock := func(id string) error {
		t.Helper()
		c := attempt(id)
		_, err := cold.handle(f.ctx, c)
		if !bytes.Equal(c.Args.File, make([]byte, 32)) {
			t.Fatal("unwrapped key retained after use")
		}
		return err
	}
	for _, problem := range []string{"offline", "proof"} {
		mode.Store(problem)
		if err := unlock(problem); err == nil || cold.session != nil {
			t.Fatal("transient failure unlocked or consumed the record")
		}
	}
	mode.Store("late")
	reply := make(chan error, 1)
	delayed := attempt("delayed")
	go func() {
		_, err := cold.handle(f.ctx, delayed)
		reply <- err
	}()
	select {
	case <-completed:
	case <-time.After(5 * time.Second):
		t.Fatal("resumption never reached the server")
	}
	queue := newActorMailbox[command]()
	cold.enqueueCommand(f.ctx, queue, command{Op: "cancelResume", Args: args{ID: "delayed"}})
	if err := <-reply; !errors.Is(err, context.Canceled) {
		t.Fatalf("background cancellation = %v", err)
	}
	_, err = cold.handle(f.ctx, queue.take(1)[0])
	ok(t, err)
	if _, err := cold.commitResume("delayed"); err == nil || cold.session != nil {
		t.Fatal("late response unlocked a background window")
	}
	mode.Store("")
	ok(t, unlock("retry"))
	if _, err := cold.handle(f.ctx, command{Op: "state"}); err == nil {
		t.Fatal("business API accessible before foreground acceptance")
	}
	result, err := cold.commitResume("retry")
	ok(t, err)
	if result["step"] != "signedIn" || cold.session.Credential == original.Credential || cold.session.Identity != original.Identity ||
		cold.session.Expires != original.Expires || cold.room != nil || cold.account.Active.Device.Hash() != original.Device.Hash() {
		t.Fatal("incorrect restored session")
	}
	if _, err := f.db.MemberByCredential(f.ctx, original.Credential); err == nil {
		t.Fatal("old bearer survived rotation")
	}
	accepted := cold.session
	_, err = cold.handle(f.ctx, command{Op: "checkLogin"})
	ok(t, err)
	if cold.session != accepted || challenges.Load() != 4 {
		t.Fatal("foreground check replaced an in-memory session")
	}
	_, err = cold.handle(f.ctx, command{Op: "logout"})
	ok(t, err)
	if hint, err := cold.readSavedLogin(); err != nil || hint != nil || cold.session != nil {
		t.Fatal("explicit logout retained local login")
	}
	// A copied pre-logout record is rejected by the server and cleared locally.
	ok(t, os.WriteFile(cold.loginPath, onDisk, 0600))
	if err := unlock("revoked"); err == nil || err.Error() != "INVALID_AUTHORIZATION" {
		t.Fatalf("revoked grant = %v", err)
	}
	if hint, err := cold.readSavedLogin(); err != nil || hint != nil {
		t.Fatal("revoked record was retained")
	}
	for _, field := range []string{"expires_at", "participant_identity", "member", "device_identity"} {
		mode.Store("")
		passkey()
		original = *client.session
		mode.Store(field)
		if err := unlock("mismatch"); !errors.Is(err, errSavedLoginInvalid) || cold.session != nil {
			t.Fatalf("mismatched %s in recovery response: %v", field, err)
		}
		if _, err := os.Stat(cold.loginPath); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("invalid recovery material survived")
		}
	}
	mode.Store("")
	passkey()
	original = *client.session
	before := challenges.Load()
	cold.conn.endpoints.APIBaseURL += "/changed"
	if err := unlock("differentService"); err == nil || err.Error() != "SERVER_CONFIGURATION_CHANGED" || challenges.Load() != before {
		t.Fatal("a changed business endpoint was accepted or contacted for a proof")
	}
	client.loginPath = filepath.Join(t.TempDir(), "unavailable", "saved-login.v1")
	step = signIn(public)
	if client.session == nil || step["resumption"] != "available" || client.pendingLoginGrant == "" {
		t.Fatal("local save failure prevented retry from the current login")
	}
}

func TestSavedLoginBindingAndDeadline(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	_, root, err := ed25519.GenerateKey(rand.Reader)
	ok(t, err)
	device := issueKey(root)
	leaf := &device.Device.Certificates[0]
	leaf.NotAfter = now.Add(time.Minute).Unix()
	leaf.Signature = identity.Sign(root, leaf.Message())
	r := savedLogin{Token: identity.ResumptionTokenPrefix + rawURL(random(32)), Account: "member_a", Participant: "member_a.login_b",
		Origin: "https://keys.example.test:443", DeviceDigest: device.Device.Hash(), Expires: leaf.NotAfter}
	a := &storedAccount{Active: device}
	e := engine{vault: &vault{Accounts: map[string]*storedAccount{r.Origin + "|" + r.Account: a}}}
	_, err = r.device(&e, time.Unix(r.Expires-1, 0))
	ok(t, err)
	if _, err = r.device(&e, time.Unix(r.Expires, 0)); !errors.Is(err, errSessionExpired) {
		t.Fatal("deadline was extended")
	}
	r.Expires++
	if _, err = r.device(&e, now); err == nil {
		t.Fatal("deadline beyond leaf certificate accepted")
	}
	r.Expires--
	leaf.Serial = b64(random(16))
	leaf.Signature = identity.Sign(root, leaf.Message())
	if _, err = r.device(&e, now); err == nil {
		t.Fatal("replacement certificate for the same leaf key accepted")
	}
	r.DeviceDigest = device.Device.Hash()
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	ok(t, err)
	disk, err := r.seal(&other.PublicKey)
	ok(t, err)
	var sealed sealedLogin
	ok(t, json.Unmarshal(disk, &sealed))
	dek, err := rsa.DecryptPKCS1v15(rand.Reader, other, sealed.WrappedKey)
	ok(t, err)
	if _, err := sealed.open(random(32)); err == nil {
		t.Fatal("copied ciphertext opened without its data key")
	}
	if _, err := sealed.open(dek); err != nil {
		t.Fatal(err)
	}
	sealed.Expires++
	if _, err := sealed.open(dek); err == nil {
		t.Fatal("modified deadline hint accepted")
	}
}
