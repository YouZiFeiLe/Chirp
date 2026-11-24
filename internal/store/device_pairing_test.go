package store

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

type pairingFixture struct {
	db             *Store
	client         ClientIdentity
	account        PasskeyAccount
	old, candidate testidentity.Client
	login          ClientLogin
	setup          IdentitySetup
	verifier       string
	request        identity.DevicePairingRequest
}

func newPairingFixture(t *testing.T) pairingFixture {
	t.Helper()
	f := pairingFixture{db: openTestStore(t), old: testidentity.New(t.Name() + "-old")}
	f.client = latestTestClient(t, f.db, "macos")
	f.account = approvedAccount(t, f.db)
	setup, verifier := beginSetup(t, f.db, f.account)
	var err error
	f.login, err = finishSetup(t, f.db, setup, verifier, f.old)
	if err != nil {
		t.Fatal(err)
	}
	f.setup, f.verifier = beginSetup(t, f.db, f.account)
	f.candidate = testidentity.Child(f.old, t.Name()+"-new", true)
	f.request = identity.DevicePairingRequest{Version: 1, Origin: setupTestOrigin, AccountID: f.setup.AccountID, AccountKey: f.old.Device.AccountKey,
		DeviceKey: f.candidate.Device.LeafKey(), Nonce: identity.Hash([]byte(t.Name())), ExpiresAt: time.Now().Add(3 * time.Minute).Unix(), Commitment: identity.Hash([]byte("SAS commitment"))}
	f.request.Signature = identity.Sign(f.candidate.Key, f.request.Message())
	if _, err = f.db.BeginDevicePairing(t.Context(), f.setup.Token, f.verifier, setupTestOrigin, f.client, f.request); err != nil {
		t.Fatal(err)
	}
	return f
}

func pairingAction(t *testing.T, request identity.DevicePairingRequest, kind string, issuer identity.Device, payload string, key ed25519.PrivateKey) identity.DevicePairingAction {
	t.Helper()
	a := identity.DevicePairingAction{RequestID: request.Hash(), Action: kind, Issuer: issuer, Payload: payload,
		Nonce: identity.Hash([]byte(t.Name() + kind + payload)), CreatedAt: time.Now().Unix()}
	a.Signature = identity.Sign(key, a.Message())
	return a
}

func (f pairingFixture) apply(t *testing.T, kind, payload string, want error) DevicePairingState {
	t.Helper()
	key := f.old.Key
	if kind == "poll-new" || kind == "reveal" || kind == "new-confirm" || kind == "cancel-new" {
		key = f.candidate.Key
	}
	a := pairingAction(t, f.request, kind, f.old.Device, payload, key)
	state, err := f.db.ApplyDevicePairing(t.Context(), setupTestOrigin, f.client, a)
	if !errors.Is(err, want) {
		t.Fatalf("%s got %v want %v", kind, err, want)
	}
	return state
}

func TestDevicePairingRequiresBothConfirmationsAndOnlyActivationReplacesLogin(t *testing.T) {
	f := newPairingFixture(t)
	if _, err := f.db.MemberByCredential(t.Context(), f.setup.Token); !errors.Is(err, ErrNotFound) {
		t.Fatal("setup became business login", err)
	}
	if _, err := f.db.ConsumePasskeyCeremony(t.Context(), f.request.Hash(), "login"); !errors.Is(err, ErrNotFound) {
		t.Fatal("public QR consumed browser ceremony", err)
	}
	if err := f.db.DeviceAuthorizationPending(t.Context(), f.request.Hash()); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("pairing became phone Passkey authorization", err)
	}
	f.apply(t, "offer", `{"kind":"Accept","key":"ephemeral-old"}`, nil)
	f.apply(t, "new-confirm", `{"kind":"Mac","mac":"new-mac"}`, ErrDevicePairing)
	f.apply(t, "reveal", `{"kind":"Key","key":"ephemeral-new"}`, nil)
	payload, err := json.Marshal(identity.DevicePairingApproval{Device: f.candidate.Device})
	if err != nil {
		t.Fatal(err)
	}
	f.apply(t, "approve", string(payload), ErrDevicePairing)
	f.apply(t, "new-confirm", `{"kind":"Mac","mac":"new-mac"}`, nil)
	f.apply(t, "approve", string(payload), ErrDevicePairing)
	f.apply(t, "old-confirm", `{"kind":"Mac","mac":"old-mac"}`, nil)
	state := f.apply(t, "approve", string(payload), nil)
	if state.Approval == nil {
		t.Fatal("missing signed approval")
	}
	f.apply(t, "approve", string(payload), nil)
	f.apply(t, "offer", `{"kind":"Accept","key":"ephemeral-old"}`, nil)
	f.apply(t, "reveal", `{"kind":"Key","key":"ephemeral-new"}`, nil)
	f.apply(t, "new-confirm", `{"kind":"Mac","mac":"new-mac"}`, nil)
	f.apply(t, "old-confirm", `{"kind":"Mac","mac":"old-mac"}`, nil)
	if _, err = f.db.MemberByCredential(t.Context(), f.login.Credential); err != nil {
		t.Fatal("approval kicked old device", err)
	}
	devices, err := f.db.Devices(t.Context(), f.setup.AccountID)
	if err != nil || len(devices) != 1 {
		t.Fatal("relay enrolled a device before activation", devices, err)
	}
	if _, err = finishSetup(t, f.db, f.setup, f.verifier, f.candidate); err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.MemberByCredential(t.Context(), f.login.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("activation did not retire old login", err)
	}
}

func TestDevicePairingCannotOutlivePasskeySetup(t *testing.T) {
	f := newPairingFixture(t)
	if _, err := f.db.db.Exec("UPDATE identity_setups SET expires_at=? WHERE token_hash=?", time.Now().Add(time.Minute).Unix(), tokenHash(f.setup.Token)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.BeginDevicePairing(t.Context(), f.setup.Token, f.verifier, setupTestOrigin, f.client, f.request); !errors.Is(err, ErrDevicePairing) {
		t.Fatal("pairing outlived Passkey setup", err)
	}
}

func TestDevicePairingAccountCapacityAndCancelledRequest(t *testing.T) {
	f := newPairingFixture(t)
	// An exact retry returns the same record without consuming another slot.
	if _, err := f.db.BeginDevicePairing(t.Context(), f.setup.Token, f.verifier, setupTestOrigin, f.client, f.request); err != nil {
		t.Fatal(err)
	}
	for i := range 3 {
		request := f.request
		request.Nonce = identity.Hash([]byte{byte(i)})
		request.Signature = identity.Sign(f.candidate.Key, request.Message())
		_, err := f.db.BeginDevicePairing(t.Context(), f.setup.Token, f.verifier, setupTestOrigin, f.client, request)
		if i < 2 && err != nil || i == 2 && !errors.Is(err, ErrCeremonyCapacity) {
			t.Fatalf("request %d: %v", i, err)
		}
	}
	cancel := pairingAction(t, f.request, "cancel-new", identity.Device{}, "", f.candidate.Key)
	if _, err := f.db.ApplyDevicePairing(t.Context(), setupTestOrigin, f.client, cancel); err != nil {
		t.Fatal(err)
	}
	request := f.request
	request.Nonce = identity.Hash([]byte("after-cancellation"))
	request.Signature = identity.Sign(f.candidate.Key, request.Message())
	if _, err := f.db.BeginDevicePairing(t.Context(), f.setup.Token, f.verifier, setupTestOrigin, f.client, request); err != nil {
		t.Fatal("cancelled request retained an active account slot", err)
	}
}

func TestDevicePairingRejectsTamperingWrongScopeAndOutOfOrderMessages(t *testing.T) {
	f := newPairingFixture(t)
	for _, change := range []string{"signature", "request", "origin", "issuer", "payload"} {
		t.Run(change, func(t *testing.T) {
			a := pairingAction(t, f.request, "offer", f.old.Device, `{"kind":"Accept","key":"old"}`, f.old.Key)
			origin := setupTestOrigin
			switch change {
			case "signature":
				a.Signature = identity.Hash([]byte("wrong"))
			case "request":
				a.RequestID = identity.Hash([]byte("another QR"))
			case "origin":
				origin = "https://other.test"
			case "issuer":
				a.Issuer = testidentity.New("unrelated").Device
			case "payload":
				a.Payload = `{"kind":"Accept","key":"substituted"}`
			}
			if _, err := f.db.ApplyDevicePairing(t.Context(), origin, f.client, a); !errors.Is(err, ErrDevicePairing) {
				t.Fatal("tampering accepted", err)
			}
		})
	}
	f.apply(t, "old-confirm", `{"kind":"Mac","mac":"x"}`, ErrDevicePairing)
	// The candidate can read the first offer even if the other device posted it
	// between creating this poll and the transaction taking its snapshot.
	f.apply(t, "offer", `{"kind":"Accept","key":"old"}`, nil)
	poll := pairingAction(t, f.request, "poll-new", identity.Device{}, "", f.candidate.Key)
	if _, err := f.db.ApplyDevicePairing(t.Context(), setupTestOrigin, f.client, poll); err != nil {
		t.Fatal("initial poll/offer race", err)
	}
	f.apply(t, "offer", `{"kind":"Accept","key":"changed"}`, ErrDevicePairing)
	f.apply(t, "cancel-new", "", nil)
	f.apply(t, "reveal", `{"kind":"Key","key":"new"}`, ErrDevicePairing)
}

func TestDevicePairingRechecksAccountAndIssuerOnEveryStep(t *testing.T) {
	for _, change := range []string{"expired", "disabled", "deleted", "revoked", "root"} {
		t.Run(change, func(t *testing.T) {
			f := newPairingFixture(t)
			f.apply(t, "offer", `{"kind":"Accept","key":"old"}`, nil)
			var err error
			switch change {
			case "expired":
				_, err = f.db.db.Exec("UPDATE passkey_ceremonies SET expires_at=0 WHERE token_hash=?", tokenHash(devicePairingKey(f.request.Hash())))
			case "disabled":
				_, err = f.db.db.Exec("UPDATE members SET enabled=0 WHERE id=?", f.setup.AccountID)
			case "deleted":
				_, err = f.db.db.Exec("DELETE FROM members WHERE id=?", f.setup.AccountID)
			case "revoked":
				_, err = f.db.db.Exec("INSERT INTO identity_blacklist(kind,subject,account_id,account_key,username,created_at) VALUES('device',?,?,?,?,?)", f.old.Device.LeafKey(), f.setup.AccountID, f.old.Device.AccountKey, "Fixture", time.Now().Unix())
			case "root":
				_, err = f.db.db.Exec("UPDATE member_identities SET account_key=? WHERE member_id=?", testidentity.New("wrong-root").Device.AccountKey, f.setup.AccountID)
			}
			if err != nil {
				t.Fatal(err)
			}
			a := pairingAction(t, f.request, "reveal", f.old.Device, `{"kind":"Key","key":"new"}`, f.candidate.Key)
			if _, err = f.db.ApplyDevicePairing(t.Context(), setupTestOrigin, f.client, a); err == nil {
				t.Fatal("stale eligibility accepted")
			}
		})
	}
}

func TestDevicePairingConcurrentOffersPinExactlyOneApprover(t *testing.T) {
	f := newPairingFixture(t)
	other := testidentity.Child(f.old, "other-approver", true)
	tx, err := f.db.beginWrite(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if err = registerDevice(t.Context(), tx, f.setup.AccountID, other.Device, "macos"); err != nil {
		tx.Rollback()
		t.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, c := range []testidentity.Client{f.old, other} {
		a := pairingAction(t, f.request, "offer", c.Device, `{"kind":"Accept","key":"old"}`, c.Key)
		wg.Go(func() {
			_, err := f.db.ApplyDevicePairing(t.Context(), setupTestOrigin, f.client, a)
			results <- err
		})
	}
	wg.Wait()
	close(results)
	wins := 0
	for err := range results {
		if err == nil {
			wins++
		} else if !errors.Is(err, ErrDevicePairing) {
			t.Fatal(err)
		}
	}
	if wins != 1 {
		t.Fatal("multiple approvers won", wins)
	}
}

func TestDevicePairingRevokedAfterApprovalCannotReplaceAnExistingLogin(t *testing.T) {
	f := newPairingFixture(t)
	online := testidentity.Child(f.old, "currently-online-device", true)
	onlineSetup, verifier := beginSetup(t, f.db, f.account)
	login, err := finishSetup(t, f.db, onlineSetup, verifier, online)
	if err != nil {
		t.Fatal(err)
	}
	// The issuer is no longer the online client, but its separate device proof
	// may still authorize. The descendant already registered above is independent.
	f.apply(t, "offer", `{"kind":"Accept","key":"old"}`, nil)
	f.apply(t, "reveal", `{"kind":"Key","key":"new"}`, nil)
	f.apply(t, "new-confirm", `{"kind":"Mac","mac":"new"}`, nil)
	f.apply(t, "old-confirm", `{"kind":"Mac","mac":"old"}`, nil)
	payload, err := json.Marshal(identity.DevicePairingApproval{Device: f.candidate.Device})
	if err != nil {
		t.Fatal(err)
	}
	f.apply(t, "approve", string(payload), nil)
	if err = f.db.AdminRevokeDevice(t.Context(), f.old.Device.LeafKey()); err != nil {
		t.Fatal(err)
	}
	if _, err = finishSetup(t, f.db, f.setup, f.verifier, f.candidate); !errors.Is(err, ErrBlacklisted) {
		t.Fatal("revoked issuer activated a new device", err)
	}
	if _, err = f.db.MemberByCredential(t.Context(), login.Credential); err != nil {
		t.Fatal("failed activation replaced the independent active login", err)
	}
}
