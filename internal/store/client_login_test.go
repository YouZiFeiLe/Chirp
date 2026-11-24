package store

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func clientAuthorization() (ClientAuthorization, string) {
	verifier := strings.Repeat("v", 43)
	digest := sha256.Sum256([]byte(verifier))
	return ClientAuthorization{ClientID: ClientID, RedirectURI: ClientRedirectURI, State: strings.Repeat("s", 43), CodeChallenge: base64.RawURLEncoding.EncodeToString(digest[:]), CodeChallengeMethod: "S256"}, verifier
}

func approvedAccount(t *testing.T, db *Store) PasskeyAccount {
	t.Helper()
	id, _ := NewPasskeyID()
	a := PasskeyAccount{ID: id, Nickname: "Oliver", CredentialID: []byte("test-public-credential"), CredentialJSON: []byte(`{}`)}
	r, err := db.RegisterPasskey(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.ApproveRegistration(context.Background(), r.RequestID); err != nil {
		t.Fatal(err)
	}
	return a
}

func TestAndroidCallbackUpgradePreservesPendingNativeAuthorization(t *testing.T) {
	db := openTestStore(t)
	ctx := t.Context()
	account := approvedAccount(t, db)
	var definition string
	if err := db.db.QueryRow("SELECT sql FROM sqlite_schema WHERE name='client_authorizations'").Scan(&definition); err != nil {
		t.Fatal(err)
	}
	oldDefinition := strings.Replace(definition, ", 'chirp-android'", "", 1)
	if oldDefinition == definition {
		t.Fatal("Android callback constraint is missing")
	}
	if _, err := db.db.ExecContext(ctx, "DROP TABLE client_authorizations; "+oldDefinition); err != nil {
		t.Fatal(err)
	}
	auth, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(ctx, account, account.CredentialJSON, auth)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.initialize(ctx); err != nil {
		t.Fatal(err)
	}
	if err := db.initialize(ctx); err != nil {
		t.Fatal(err)
	}
	_, err = db.BeginIdentitySetup(ctx, code, verifier, ClientID, "https://example.test", latestTestClient(t, db, "ios"), false)
	if err != nil {
		t.Fatalf("pending Apple code after upgrade: %v", err)
	}
	auth.ClientID, auth.RedirectURI = AndroidClientID, AndroidClientRedirectURI
	if _, err = db.CreateClientAuthorization(ctx, account, account.CredentialJSON, auth); err != nil {
		t.Fatal(err)
	}
}

func TestClientLoginReplacementExpiryAndLogout(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	ctx := context.Background()
	account := approvedAccount(t, db)
	authorization, verifier := clientAuthorization()
	issue := func() ClientLogin {
		t.Helper()
		current, err := db.PasskeyByCredential(ctx, account.CredentialID, []byte(account.ID))
		if err != nil {
			t.Fatal(err)
		}
		code, err := db.CreateClientAuthorization(ctx, current, current.CredentialJSON, authorization)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = db.ExchangeClientAuthorization(ctx, code, strings.Repeat("x", 43), ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, strings.Repeat("x", 43))); !errors.Is(err, ErrInvalidAuthorization) {
			t.Fatal("PKCE mismatch accepted", err)
		}
		login, err := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier))
		if err != nil {
			t.Fatal(err)
		}
		if _, err = db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier)); !errors.Is(err, ErrInvalidAuthorization) {
			t.Fatal("authorization replay accepted", err)
		}
		return login
	}
	one := issue()
	if left := time.Until(time.Unix(one.ExpiresAt, 0)); left > ClientCredentialTTL || left < ClientCredentialTTL-time.Minute {
		t.Fatal("incorrect credential lifetime")
	}
	if one.Member.LastLoginAt == "" {
		t.Fatal("login timestamp missing")
	}
	var digest []byte
	if err := db.db.QueryRow("SELECT credential_hash FROM members WHERE id = ?", one.Member.ID).Scan(&digest); err != nil || string(digest) == one.Credential {
		t.Fatal("credential was stored in plaintext", err)
	}
	two := issue()
	if one.Credential == two.Credential || one.Member.ParticipantIdentity() == two.Member.ParticipantIdentity() {
		t.Fatal("login generation was reused")
	}
	if _, err := db.MemberByCredential(ctx, one.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("old login remains authorized", err)
	}
	if allowed, err := db.ParticipantAllowed(ctx, one.Member.ParticipantIdentity()); err != nil || allowed {
		t.Fatal("old media session remains authorized", err)
	}
	if allowed, err := db.ParticipantAllowed(ctx, two.Member.ParticipantIdentity()); err != nil || !allowed {
		t.Fatal("new media session denied", err)
	}
	if err := db.RevokeClientCredential(ctx, one.Credential); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(ctx, two.Credential); err != nil {
		t.Fatal("old logout revoked newer login", err)
	}
	if err := db.RevokeParticipant(ctx, one.Member.ParticipantIdentity()); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(ctx, two.Credential); err != nil {
		t.Fatal("stale kick revoked newer login", err)
	}
	if _, err := db.db.Exec("UPDATE members SET credential_expires_at = ? WHERE id = ?", time.Now().Unix()-1, two.Member.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(ctx, two.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("20-hour deadline not enforced", err)
	}
	three := issue()
	if err := db.RevokeParticipant(ctx, three.Member.ParticipantIdentity()); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(ctx, three.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("kick did not revoke credential", err)
	}
	if allowed, err := db.ParticipantAllowed(ctx, three.Member.ParticipantIdentity()); err != nil || allowed {
		t.Fatal("kicked participant remains authorized", err)
	}
	four := issue()
	if err := db.RevokeClientCredential(ctx, four.Credential); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(ctx, four.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("logout did not revoke credential", err)
	}
}

func TestClientAuthorizationSingleUseAcrossConnections(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	ctx := context.Background()
	a := approvedAccount(t, db)
	authorization, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(ctx, a, a.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	var success atomic.Int32
	var group sync.WaitGroup
	for range 12 {
		group.Go(func() {
			_, err := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier))
			if err == nil {
				success.Add(1)
			} else if !errors.Is(err, ErrInvalidAuthorization) {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if success.Load() != 1 {
		t.Fatal("code exchanged more than once", success.Load())
	}
	code, err = db.CreateClientAuthorization(ctx, a, a.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.db.Exec("UPDATE client_authorizations SET expires_at = ?", time.Now().Unix()-1); err != nil {
		t.Fatal(err)
	}
	if _, err = db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier)); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("expired code accepted", err)
	}
}

func TestDisablingRevokesUnexchangedAuthorizations(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	ctx := context.Background()
	account := approvedAccount(t, db)
	authorization, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(ctx, account, account.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := db.ListRegistrationRequests(ctx)
	if err != nil {
		t.Fatal(err)
	}
	id := rows[0].MemberID
	if err = db.DisableMember(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err = db.UpdateMember(ctx, id, "Oliver", true); !errors.Is(err, ErrBlacklisted) {
		t.Fatal(err)
	}
	if _, err = db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier)); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("disabled authorization revived after re-enable", err)
	}
}
