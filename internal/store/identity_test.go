package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func activateIdentity(t *testing.T, db *Store, account PasskeyAccount, device testidentity.Client) ClientLogin {
	t.Helper()
	client, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(context.Background(), account, account.CredentialJSON, client)
	if err != nil {
		t.Fatal(err)
	}
	login, err := db.ExchangeClientAuthorization(context.Background(), code, verifier, ClientID, ClientRedirectURI, latestTestClient(t, db, "macos"), device.Login(ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	return login
}

func TestV4EnrollmentPrecedesSingleLoginReplacement(t *testing.T) {
	ctx := context.Background()
	db := openTestStore(t)
	account := approvedAccount(t, db)
	old := testidentity.New("sso-old")
	current := activateIdentity(t, db, account, old)
	client, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(ctx, account, account.CredentialJSON, client)
	if err != nil {
		t.Fatal(err)
	}
	platform := latestTestClient(t, db, "macos")
	rogue := testidentity.New("server-generated-identity")
	bad := old.Login(ClientID, code, verifier)
	bad.Signature = base64.StdEncoding.EncodeToString(make([]byte, 64))
	for _, proofs := range [][]identity.LoginProof{nil, {rogue.Login(ClientID, code, verifier)}, {bad}} {
		if _, err = db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, platform, proofs...); !errors.Is(err, ErrDeviceIdentity) {
			t.Fatal("unauthorized replacement was not refused", err)
		}
		if m, err := db.MemberByCredential(ctx, current.Credential); err != nil || m.LoginID != current.Member.LoginID {
			t.Fatal("failed enrollment kicked the old login", err)
		}
	}
	newDevice := testidentity.Child(old, "sso-new", true)
	next, err := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, platform, newDevice.Login(ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.MemberByCredential(ctx, current.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("old credential survived activation", err)
	}
	if _, err = db.MemberByCredential(ctx, next.Credential); err != nil {
		t.Fatal(err)
	}
	// A kicked device signs locally. It needs no restored credential or API
	// exception to approve another device, and the server keeps single login.
	later := testidentity.Child(old, "approved-after-kick", false)
	last := activateIdentity(t, db, account, later)
	if _, err = db.MemberByCredential(ctx, next.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("two active sessions", err)
	}
	device, err := db.LoginDevice(ctx, last.Member.ID, last.Member.LoginID)
	if err != nil || device.Hash() != later.Device.Hash() {
		t.Fatal("wrong activated certificate", err)
	}
}

func TestV4DevicePollCannotSwitchLoginWithoutCertificate(t *testing.T) {
	ctx := context.Background()
	db := openTestStore(t)
	account := approvedAccount(t, db)
	old := testidentity.New("poll-old")
	current := activateIdentity(t, db, account, old)
	authorization, verifier := clientAuthorization()
	pending, err := db.BeginDeviceAuthorization(ctx, authorization.CodeChallenge, ClientID)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.ApproveDeviceAuthorization(ctx, pending.RequestID, account, account.CredentialJSON); err != nil {
		t.Fatal(err)
	}
	platform := latestTestClient(t, db, "macos")
	if _, err = db.PollDeviceAuthorization(ctx, pending.RequestID, verifier, platform); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("missing certificate was accepted", err)
	}
	if _, err = db.MemberByCredential(ctx, current.Credential); err != nil {
		t.Fatal("pending device kicked old session", err)
	}
	newDevice := testidentity.Child(old, "poll-new", false)
	if _, err = db.PollDeviceAuthorization(ctx, pending.RequestID, verifier, platform, newDevice.Login(ClientID, pending.RequestID, verifier)); err != nil {
		t.Fatal(err)
	}
	if _, err = db.MemberByCredential(ctx, current.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("old session not revoked", err)
	}
}

func TestV4RoomPolicyContinuityAndRevokedOwnerCannotRestoreItself(t *testing.T) {
	ctx := context.Background()
	db := openTestStore(t)
	account := approvedAccount(t, db)
	owner := testidentity.New("policy-owner")
	login := activateIdentity(t, db, account, owner)
	first := owner.Policy("https://example.test", "friends")
	if err := db.PutRoomPolicy(ctx, login.Member, first); err != nil {
		t.Fatal(err)
	}
	child := testidentity.Child(owner, "revoked-owner-device", true)
	childLogin := activateIdentity(t, db, account, child)
	key, _ := base64.StdEncoding.DecodeString(child.Device.LeafKey())
	second := first
	second.Version = 2
	second.PreviousHash = first.Hash()
	second.RevokedDevices = []string{identity.Hash(key)}
	second.Signature = identity.Sign(owner.Key, second.Message())
	if err := db.PutRoomPolicy(ctx, childLogin.Member, second); err != nil {
		t.Fatal(err)
	}
	third := second
	third.Version = 3
	third.PreviousHash = second.Hash()
	third.RevokedDevices = []string{}
	third.Signer = child.Device
	third.Signature = identity.Sign(child.Key, third.Message())
	if third.Validate(time.Now()) != nil {
		t.Fatal("attack fixture must have a valid standalone signature")
	}
	if err := db.PutRoomPolicy(ctx, childLogin.Member, third); !errors.Is(err, ErrRoomPolicy) {
		t.Fatal("revoked owner restored its permissions", err)
	}
	if err := db.PutRoomPolicy(ctx, childLogin.Member, first); !errors.Is(err, ErrRoomPolicy) {
		t.Fatal("policy rollback accepted", err)
	}
	stored, err := db.RoomPolicy(ctx, "friends")
	if err != nil || stored.Hash() != second.Hash() {
		t.Fatal("current policy was overwritten", err)
	}
	history, err := db.RoomPolicyHistory(ctx, "friends", 0)
	if err != nil || len(history) != 2 || history[1].PreviousHash != history[0].Hash() {
		t.Fatal("policy history is not a complete chain", err)
	}
}

func TestFreshDeploymentRefusesLegacyDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(schemaSQL + "UPDATE chirp_schema SET version = 18 WHERE id = 1;"); err != nil {
		t.Fatal(err)
	}
	stamp := time.Now().UTC().Format(time.RFC3339)
	if _, err = db.Exec("INSERT INTO members(id,display_name,enabled,created_at,updated_at,credential_hash,login_id,credential_expires_at) VALUES(?,?,?,?,?,?,?,?)", "member_legacy", "Legacy", true, stamp, stamp, make([]byte, 32), "login_legacy", time.Now().Add(time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	upgraded, err := Open(context.Background(), path)
	if upgraded != nil {
		upgraded.Close()
		t.Fatal("legacy database unexpectedly opened")
	}
	if err == nil || !strings.Contains(err.Error(), "empty database") {
		t.Fatal("fresh deployment must reject old schema without changing it", err)
	}
}
