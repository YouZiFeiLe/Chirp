package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func TestDeviceAuthorizationClaimAndSessionReplacement(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	ctx := context.Background()
	account := approvedAccount(t, db)
	client, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(ctx, account, account.CredentialJSON, client)
	if err != nil {
		t.Fatal(err)
	}
	previous, err := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, mac, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	// Use a distinct timestamp so an accidental phone-side update cannot pass
	// merely because both operations happened within the same second.
	previous.Member.LastLoginAt = "2026-10-17T00:00:00Z"
	if _, err = db.db.Exec("UPDATE members SET last_login_at = ? WHERE id = ?", previous.Member.LastLoginAt, previous.Member.ID); err != nil {
		t.Fatal(err)
	}
	device, err := db.BeginDeviceAuthorization(ctx, client.CodeChallenge, ClientID)
	if err != nil {
		t.Fatal(err)
	}
	if remaining := time.Until(time.Unix(device.ExpiresAt, 0)); remaining > DeviceAuthorizationTTL || remaining < DeviceAuthorizationTTL-time.Second*2 {
		t.Fatal("incorrect QR lifetime", remaining)
	}
	// The public QR ID cannot be consumed as a browser's ceremony cookie.
	if _, err = db.ConsumePasskeyCeremony(ctx, device.RequestID, "login"); !errors.Is(err, ErrNotFound) {
		t.Fatal("QR/browser namespaces overlap", err)
	}
	if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier)); !errors.Is(err, ErrDeviceAuthorizationPending) {
		t.Fatal("not pending", err)
	}
	if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, strings.Repeat("x", 43), mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, strings.Repeat("x", 43))); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("incorrect verifier accepted", err)
	}
	if err = db.CancelDeviceAuthorization(ctx, device.RequestID, strings.Repeat("x", 43)); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("incorrect verifier cancelled QR", err)
	}
	if err = db.ApproveDeviceAuthorization(ctx, device.RequestID, account, []byte(`{"counter":1}`)); err != nil {
		t.Fatal(err)
	}
	old, err := db.MemberByCredential(ctx, previous.Credential)
	if err != nil || old.LastLoginAt != previous.Member.LastLoginAt {
		t.Fatal("phone approval replaced the old login", err)
	}
	if err = db.DeviceAuthorizationPending(ctx, device.RequestID); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("approved QR accepted a second approval", err)
	}
	if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, strings.Repeat("x", 43), mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, strings.Repeat("x", 43))); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("approved QR did not require private proof", err)
	}
	login, err := db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier))
	if err != nil {
		t.Fatal(err)
	}
	if login.Member.ID != previous.Member.ID || login.Credential == previous.Credential || login.Member.LastLoginAt == "" || login.Member.LastLoginAt == previous.Member.LastLoginAt || login.Member.ParticipantIdentity() == previous.Member.ParticipantIdentity() {
		t.Fatal("claim did not issue a fresh member login")
	}
	if remaining := time.Until(time.Unix(login.ExpiresAt, 0)); remaining > ClientCredentialTTL || remaining < ClientCredentialTTL-time.Second*2 {
		t.Fatal("incorrect client credential lifetime")
	}
	if _, err = db.MemberByCredential(ctx, previous.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("claim did not replace old credential", err)
	}
	if allowed, err := db.ParticipantAllowed(ctx, previous.Member.ParticipantIdentity()); err != nil || allowed {
		t.Fatal("old voice session remains authorized", err)
	}
	if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier)); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("QR claimed more than once", err)
	}
	if err = db.CancelDeviceAuthorization(ctx, device.RequestID, verifier); err != nil {
		t.Fatal("completed cancellation is not idempotent", err)
	}
}

func TestDeviceAuthorizationExpiryCancellationAndRevocation(t *testing.T) {
	for _, action := range []string{"cancel", "expire", "disable", "disable-update", "delete", "changed-passkey"} {
		t.Run(action, func(t *testing.T) {
			db := openTestStore(t)
			mac := latestTestClient(t, db, "macos")
			ctx := context.Background()
			account := approvedAccount(t, db)
			client, verifier := clientAuthorization()
			device, err := db.BeginDeviceAuthorization(ctx, client.CodeChallenge, ClientID)
			if err != nil {
				t.Fatal(err)
			}
			if action == "changed-passkey" {
				if _, err = db.db.Exec("UPDATE passkey_credentials SET credential_json = ? WHERE id = ?", []byte(`{"counter":2}`), account.CredentialID); err != nil {
					t.Fatal(err)
				}
				if err = db.ApproveDeviceAuthorization(ctx, device.RequestID, account, []byte(`{"counter":1}`)); !errors.Is(err, ErrPasskeyChanged) {
					t.Fatal("stale Passkey write accepted", err)
				}
				if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier)); !errors.Is(err, ErrDeviceAuthorizationPending) {
					t.Fatal("failed signature update authorized the QR", err)
				}
				return
			}
			if err = db.ApproveDeviceAuthorization(ctx, device.RequestID, account, account.CredentialJSON); err != nil {
				t.Fatal(err)
			}
			switch action {
			case "cancel":
				if err = db.CancelDeviceAuthorization(ctx, device.RequestID, verifier); err != nil {
					t.Fatal(err)
				}
				if err = db.CancelDeviceAuthorization(ctx, device.RequestID, verifier); err != nil {
					t.Fatal(err)
				}
			case "expire":
				if _, err = db.db.Exec("UPDATE passkey_ceremonies SET expires_at = ? WHERE token_hash = ?", time.Now().Unix()-1, tokenHash(deviceAuthorizationKey(device.RequestID))); err != nil {
					t.Fatal(err)
				}
			case "disable", "disable-update", "delete":
				requests, err := db.ListRegistrationRequests(ctx)
				if err != nil {
					t.Fatal(err)
				}
				id := requests[0].MemberID
				if action == "delete" {
					err = db.DeleteMember(ctx, id)
				} else {
					if action == "disable-update" {
						_, err = db.UpdateMember(ctx, id, "Oliver", false)
					} else {
						err = db.DisableMember(ctx, id)
					}
					if err == nil {
						_, reenableErr := db.UpdateMember(ctx, id, "Oliver", true)
						if !errors.Is(reenableErr, ErrBlacklisted) {
							t.Fatal("permanent ban was lifted", reenableErr)
						}
					}
				}
				if err != nil {
					t.Fatal(err)
				}
			}
			if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier)); err == nil {
				t.Fatal("invalidated QR issued a credential")
			}
		})
	}
}

func TestLegacyDeviceAuthorizationRemainsAppleOnly(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	ctx := context.Background()
	client, verifier := clientAuthorization()
	device, err := db.BeginDeviceAuthorization(ctx, client.CodeChallenge, ClientID)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(deviceAuthorizationState{
		Purpose: deviceAuthorizationPurpose, CodeChallenge: client.CodeChallenge,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.db.Exec("UPDATE passkey_ceremonies SET payload = ? WHERE token_hash = ?", payload, tokenHash(deviceAuthorizationKey(device.RequestID))); err != nil {
		t.Fatal(err)
	}
	if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, verifier, latestTestClient(t, db, WindowsClientPlatform), testidentity.New("existing-login-fixture").Login(WindowsClientID, device.RequestID, verifier)); !errors.Is(err, ErrInvalidDeviceAuthorization) {
		t.Fatal("Windows claimed a legacy Apple request", err)
	}
	if _, err = db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier)); !errors.Is(err, ErrDeviceAuthorizationPending) {
		t.Fatal("legacy Apple request became unusable", err)
	}
}

func TestDeviceAuthorizationSingleClaimAcrossConnections(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	ctx := context.Background()
	account := approvedAccount(t, db)
	client, verifier := clientAuthorization()
	device, err := db.BeginDeviceAuthorization(ctx, client.CodeChallenge, ClientID)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.ApproveDeviceAuthorization(ctx, device.RequestID, account, account.CredentialJSON); err != nil {
		t.Fatal(err)
	}
	var successes atomic.Int32
	var group sync.WaitGroup
	for range 12 {
		group.Go(func() {
			_, err := db.PollDeviceAuthorization(ctx, device.RequestID, verifier, mac, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier))
			if err == nil {
				successes.Add(1)
			} else if !errors.Is(err, ErrInvalidDeviceAuthorization) {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if successes.Load() != 1 {
		t.Fatal("concurrent claims issued multiple credentials", successes.Load())
	}
}
