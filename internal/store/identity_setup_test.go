package store

import (
	"context"
	"errors"
	"sync"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

const setupTestOrigin = "https://fixture.test:443"

func beginSetup(t *testing.T, db *Store, account PasskeyAccount) (IdentitySetup, string) {
	t.Helper()
	auth, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(t.Context(), account, account.CredentialJSON, auth)
	if err != nil {
		t.Fatal(err)
	}
	setup, err := db.BeginIdentitySetup(t.Context(), code, verifier, ClientID, "https://FIXTURE.test", latestTestClient(t, db, "macos"), false)
	if err != nil {
		t.Fatal(err)
	}
	return setup, verifier
}
func finishSetup(t *testing.T, db *Store, setup IdentitySetup, verifier string, client testidentity.Client) (ClientLogin, error) {
	t.Helper()
	mac := latestTestClient(t, db, "macos")
	challenge, err := db.BindIdentityChallenge(t.Context(), setup.Token, verifier, setupTestOrigin, mac, client.Device)
	if err != nil {
		return ClientLogin{}, err
	}
	signature := identity.Sign(client.Key, identity.ActivationMessage(setupTestOrigin, setup.AccountID, ClientID, setup.Token, verifier, challenge, client.Device))
	return db.CompleteIdentitySetup(t.Context(), setup.Token, verifier, setupTestOrigin, signature, mac, client.Device, IdentitySetupOptions{RequestResumption: true})
}
func TestIdentitySetupScopeProofAndActivationOrder(t *testing.T) {
	db := openTestStore(t)
	account := approvedAccount(t, db)
	candidate := testidentity.New("setup-first")
	setup, verifier := beginSetup(t, db, account)
	if setup.AccountKey != "" || setup.Username == "" || setup.Origin != setupTestOrigin {
		t.Fatal("incorrect authenticated state", setup)
	}
	if _, err := db.MemberByCredential(t.Context(), setup.Token); !errors.Is(err, ErrNotFound) {
		t.Fatal("setup token became a business credential", err)
	}
	if _, err := db.BindIdentityChallenge(t.Context(), setup.Token, verifier, "https://other.test", latestTestClient(t, db, "macos"), candidate.Device); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("wrong origin accepted", err)
	}
	login, err := finishSetup(t, db, setup, verifier, candidate)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = finishSetup(t, db, setup, verifier, candidate); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("setup replay accepted", err)
	}
	next, verifier := beginSetup(t, db, account)
	if next.AccountKey != candidate.Device.AccountKey {
		t.Fatal("root was not preserved")
	}
	if _, err = db.MemberByCredential(t.Context(), login.Credential); err != nil {
		t.Fatal("starting setup kicked online device", err)
	}
	rogue := testidentity.New("setup-rogue")
	if _, err = finishSetup(t, db, next, verifier, rogue); !errors.Is(err, ErrIdentityConflict) {
		t.Fatal("root overwrite accepted", err)
	}
	if _, err = db.MemberByCredential(t.Context(), login.Credential); err != nil {
		t.Fatal("failed binding kicked online device", err)
	}
	child := testidentity.Child(candidate, "setup-child", true)
	replacement, err := finishSetup(t, db, next, verifier, child)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.MemberByCredential(t.Context(), login.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("old online device survived", err)
	}
	devices, err := db.Devices(t.Context(), replacement.Member.ID)
	if err != nil || len(devices) != 2 {
		t.Fatal("registration failed", devices, err)
	}
}
func TestConcurrentFirstBindingHasOneWinner(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	account := approvedAccount(t, db)
	first, va := beginSetup(t, db, account)
	second, vb := beginSetup(t, db, account)
	a, b := testidentity.New("race-first"), testidentity.New("race-second")
	ca, err := db.BindIdentityChallenge(t.Context(), first.Token, va, setupTestOrigin, mac, a.Device)
	if err != nil {
		t.Fatal(err)
	}
	cb, err := db.BindIdentityChallenge(t.Context(), second.Token, vb, setupTestOrigin, mac, b.Device)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, v := range []struct {
		setup               IdentitySetup
		verifier, challenge string
		client              testidentity.Client
	}{{first, va, ca, a}, {second, vb, cb, b}} {
		wg.Go(func() {
			sig := identity.Sign(v.client.Key, identity.ActivationMessage(setupTestOrigin, v.setup.AccountID, ClientID, v.setup.Token, v.verifier, v.challenge, v.client.Device))
			_, err := db.CompleteIdentitySetup(context.Background(), v.setup.Token, v.verifier, setupTestOrigin, sig, mac, v.client.Device, IdentitySetupOptions{})
			results <- err
		})
	}
	wg.Wait()
	close(results)
	wins, conflicts := 0, 0
	for err := range results {
		if err == nil {
			wins++
		} else if errors.Is(err, ErrIdentityConflict) {
			conflicts++
		} else {
			t.Fatal(err)
		}
	}
	if wins != 1 || conflicts != 1 {
		t.Fatal("first binding was not atomic", wins, conflicts)
	}
	devices, err := db.Devices(t.Context(), first.AccountID)
	if err != nil || len(devices) != 1 {
		t.Fatal("duplicate or losing device registered", devices, err)
	}
}
func TestSetupRequiresCandidatePossessionAndUnexpiredAuthorization(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	account := approvedAccount(t, db)
	setup, verifier := beginSetup(t, db, account)
	candidate := testidentity.New("challenge-bound")
	challenge, err := db.BindIdentityChallenge(t.Context(), setup.Token, verifier, setupTestOrigin, mac, candidate.Device)
	if err != nil {
		t.Fatal(err)
	}
	wrong := testidentity.New("wrong-signature")
	sig := identity.Sign(wrong.Key, identity.ActivationMessage(setupTestOrigin, setup.AccountID, ClientID, setup.Token, verifier, challenge, candidate.Device))
	if _, err = db.CompleteIdentitySetup(t.Context(), setup.Token, verifier, setupTestOrigin, sig, mac, candidate.Device, IdentitySetupOptions{}); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("wrong possession proof accepted", err)
	}
	if _, err = db.db.Exec("UPDATE identity_setups SET expires_at=0 WHERE token_hash=?", tokenHash(setup.Token)); err != nil {
		t.Fatal(err)
	}
	if _, err = finishSetup(t, db, setup, verifier, candidate); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("expired setup accepted", err)
	}
	if _, err = db.db.Exec("SELECT 1 FROM member_identities"); err != nil {
		t.Fatal(err)
	}
}
