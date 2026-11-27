package store

import (
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func TestClientResumptionIsDeviceBoundAndKeepsSessionDeadline(t *testing.T) {
	db := openTestStore(t)
	ctx := t.Context()
	account := approvedAccount(t, db)
	mac := latestTestClient(t, db, "macos")
	device := testidentity.New("resume-mac")
	setup, verifier := beginSetup(t, db, account)
	first, err := finishSetup(t, db, setup, verifier, device)
	if err != nil || !strings.HasPrefix(first.ResumeToken, identity.ResumptionTokenPrefix) {
		t.Fatal("missing versioned resumption grant", err)
	}
	activated, err := time.Parse(time.RFC3339, first.Member.LastLoginAt)
	if err != nil || first.ExpiresAt != activated.Add(20*time.Hour).Unix() {
		t.Fatal("the live credential must retain its original 20-hour lifetime", err)
	}
	if _, err := db.MemberByCredential(ctx, first.ResumeToken); !errors.Is(err, ErrNotFound) {
		t.Fatal("resume handle accepted as bearer", err)
	}
	if _, err := db.BeginClientResumption(ctx, first.ResumeToken, "https://another.test", mac); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("wrong origin accepted", err)
	}
	if _, err := db.BeginClientResumption(ctx, first.ResumeToken, setupTestOrigin, latestTestClient(t, db, "ios")); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("wrong platform accepted", err)
	}
	challenge, err := db.BeginClientResumption(ctx, first.ResumeToken, setupTestOrigin, mac)
	if err != nil {
		t.Fatal(err)
	}
	message := identity.ResumptionMessage(setupTestOrigin, mac.Platform, first.Member.ParticipantIdentity(), first.ResumeToken, challenge, device.Device)
	wrong := identity.Sign(testidentity.New("different-device").Key, message)
	if _, err := db.CompleteClientResumption(ctx, first.ResumeToken, setupTestOrigin, wrong, mac); !errors.Is(err, ErrResumptionProof) {
		t.Fatal("copied grant worked with a different key", err)
	}
	if _, err := db.db.Exec("UPDATE members SET room_join_sequence=7 WHERE id=?", first.Member.ID); err != nil {
		t.Fatal(err)
	}
	signature := identity.Sign(device.Key, message)
	results := make(chan ClientLogin, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Go(func() {
			login, err := db.CompleteClientResumption(ctx, first.ResumeToken, setupTestOrigin, signature, mac)
			if err == nil {
				results <- login
			} else if !errors.Is(err, ErrResumptionProof) {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	close(results)
	if len(results) != 1 {
		t.Fatal("the challenge must have exactly one successful redemption")
	}
	resumed := <-results
	if resumed.Credential == first.Credential || resumed.ExpiresAt != first.ExpiresAt || resumed.Member.LoginID != first.Member.LoginID ||
		resumed.Member.LastLoginAt != first.Member.LastLoginAt || resumed.ResumeToken != "" {
		t.Fatal("resumption changed the grant, login generation or deadline")
	}
	if _, err := db.MemberByCredential(ctx, first.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("previous bearer survived rotation", err)
	}
	if m, err := db.MemberByCredential(ctx, resumed.Credential); err != nil || m.JoinSequence != 7 {
		t.Fatal("current bearer did not retain the room sequence", err)
	}
	next, err := db.BeginClientResumption(ctx, first.ResumeToken, setupTestOrigin, mac)
	if err != nil || next == challenge {
		t.Fatal("could not recover from a lost response with a fresh challenge", err)
	}
	if _, err := db.CompleteClientResumption(ctx, first.ResumeToken, setupTestOrigin, signature, mac); !errors.Is(err, ErrResumptionProof) {
		t.Fatal("previous signature accepted on a new challenge", err)
	}
}

func TestClientResumptionWorksInFinalHourAndSharesBearerCutoff(t *testing.T) {
	db := openTestStore(t)
	ctx := t.Context()
	mac := latestTestClient(t, db, "macos")
	device := testidentity.New("deadline")
	setup, verifier := beginSetup(t, db, approvedAccount(t, db))
	login, err := finishSetup(t, db, setup, verifier, device)
	if err != nil {
		t.Fatal(err)
	}
	// Move the original login to its final 30 seconds, past hour 19.
	deadline := time.Now().Add(30 * time.Second)
	activation := deadline.Add(-ClientCredentialTTL).UTC().Format(time.RFC3339)
	if _, err = db.db.Exec("UPDATE members SET last_login_at=?, credential_expires_at=? WHERE id=?", activation, deadline.Unix(), login.Member.ID); err != nil {
		t.Fatal(err)
	}
	challenge, err := db.BeginClientResumption(ctx, login.ResumeToken, setupTestOrigin, mac)
	if err != nil {
		t.Fatal(err)
	}
	var challengeDeadline int64
	if err = db.db.QueryRow("SELECT challenge_expires_at FROM client_login_resumptions WHERE member_id=?", login.Member.ID).Scan(&challengeDeadline); err != nil || challengeDeadline != deadline.Unix() {
		t.Fatal("the challenge extends past the business credential", err)
	}
	signature := identity.Sign(device.Key, identity.ResumptionMessage(setupTestOrigin, mac.Platform,
		login.Member.ParticipantIdentity(), login.ResumeToken, challenge, device.Device))
	resumed, err := db.CompleteClientResumption(ctx, login.ResumeToken, setupTestOrigin, signature, mac)
	if err != nil || resumed.ExpiresAt != deadline.Unix() || resumed.Member.LastLoginAt != activation {
		t.Fatal("final-hour resumption changed the original deadline", err)
	}
	challenge, err = db.BeginClientResumption(ctx, login.ResumeToken, setupTestOrigin, mac)
	if err != nil {
		t.Fatal(err)
	}
	signature = identity.Sign(device.Key, identity.ResumptionMessage(setupTestOrigin, mac.Platform,
		login.Member.ParticipantIdentity(), login.ResumeToken, challenge, device.Device))
	if _, err = db.db.Exec("UPDATE members SET credential_expires_at=unixepoch() WHERE id=?", login.Member.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = db.BeginClientResumption(ctx, login.ResumeToken, setupTestOrigin, mac); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("expired grant obtained a challenge", err)
	}
	if _, err = db.CompleteClientResumption(ctx, login.ResumeToken, setupTestOrigin, signature, mac); !errors.Is(err, ErrInvalidAuthorization) {
		t.Fatal("a challenge issued before the cutoff restored an expired grant", err)
	}
	if _, err = db.MemberByCredential(ctx, resumed.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("the bearer survived its own cutoff", err)
	}
}

func TestClientResumptionUpgradePreservesOnlineLoginAndPendingSetup(t *testing.T) {
	db := openTestStore(t)
	account := approvedAccount(t, db)
	device := testidentity.New("upgrade")
	setup, verifier := beginSetup(t, db, account)
	online, err := finishSetup(t, db, setup, verifier, device)
	if err != nil {
		t.Fatal(err)
	}
	pending, verifier := beginSetup(t, db, account)
	// Recreate the previous schema-23 layout with a live account and an in-flight setup.
	if _, err = db.db.Exec("DROP TABLE client_login_resumptions"); err != nil {
		t.Fatal(err)
	}
	path := db.Path()
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	upgraded, err := Open(t.Context(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer upgraded.Close()
	if _, err = upgraded.MemberByCredential(t.Context(), online.Credential); err != nil {
		t.Fatal("upgrade lost the existing login", err)
	}
	next, err := finishSetup(t, upgraded, pending, verifier, device)
	if err != nil || next.ResumeToken == "" || next.ExpiresAt > time.Now().Add(ClientCredentialTTL).Unix() {
		t.Fatal("upgrade lost or extended the pending authorization", err)
	}
}

func TestClientResumptionRespectsAnEarlierCertificateExpiry(t *testing.T) {
	db := openTestStore(t)
	setup, verifier := beginSetup(t, db, approvedAccount(t, db))
	device := testidentity.New("short-certificate")
	leaf := &device.Device.Certificates[0]
	leaf.NotAfter = time.Now().Add(time.Hour).Unix()
	leaf.Signature = identity.Sign(device.Root, leaf.Message())
	login, err := finishSetup(t, db, setup, verifier, device)
	if err != nil || login.ResumeToken == "" || login.ExpiresAt != leaf.NotAfter {
		t.Fatal("the device certificate should cap both the live login and its grant", err)
	}
}

func TestLegacyResumptionMigration(t *testing.T) {
	for _, layout := range []string{"shared expiry", "separate expiry", "expired grant"} {
		t.Run(layout, func(t *testing.T) {
			db := openTestStore(t)
			ctx := t.Context()
			device := testidentity.New("legacy-grant")
			client := latestTestClient(t, db, "macos")
			setup, verifier := beginSetup(t, db, approvedAccount(t, db))
			login, err := finishSetup(t, db, setup, verifier, device)
			if err != nil {
				t.Fatal(err)
			}
			legacy, err := randomID("resume_", 32)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = db.db.Exec("ALTER TABLE client_login_resumptions RENAME TO apple_login_resumptions"); err != nil {
				t.Fatal(err)
			}
			if _, err = db.db.Exec("UPDATE apple_login_resumptions SET token_hash=?,challenge='old' WHERE member_id=?", tokenHash(legacy), login.Member.ID); err != nil {
				t.Fatal(err)
			}
			if layout != "shared expiry" {
				if _, err = db.db.Exec("ALTER TABLE apple_login_resumptions ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0"); err != nil {
					t.Fatal(err)
				}
				if layout == "separate expiry" {
					if _, err = db.db.Exec("UPDATE apple_login_resumptions SET expires_at=unixepoch()+60"); err != nil {
						t.Fatal(err)
					}
				}
			}
			if err = db.initialize(ctx); err != nil {
				t.Fatal(err)
			}
			if m, err := db.MemberByCredential(ctx, login.Credential); err != nil || m.CredentialExpiresAt != login.ExpiresAt {
				t.Fatal("migration changed the original business credential", err)
			}
			challenge, err := db.BeginClientResumption(ctx, legacy, setupTestOrigin, client)
			if layout == "expired grant" {
				if !errors.Is(err, ErrInvalidAuthorization) {
					t.Fatal("migration revived an expired grant", err)
				}
				return
			}
			if err != nil || challenge == "old" {
				t.Fatal("migration did not issue a fresh challenge", err)
			}
			legacyProof := identity.Message("Chirp Apple login resumption v1", setupTestOrigin, client.Platform,
				login.Member.ParticipantIdentity(), identity.Hash([]byte(legacy)), challenge, device.Device.Hash())
			resumed, err := db.CompleteClientResumption(ctx, legacy, setupTestOrigin, identity.Sign(device.Key, legacyProof), client)
			if err != nil || resumed.ExpiresAt != login.ExpiresAt {
				t.Fatal("legacy receipt lost its login", err)
			}
		})
	}
}

func TestClientResumptionRechecksAuthorityAfterChallenge(t *testing.T) {
	for _, change := range []string{"logout", "new login", "deadline", "challenge expiry", "disabled", "revoked device"} {
		t.Run(change, func(t *testing.T) {
			db := openTestStore(t)
			ctx := t.Context()
			mac := latestTestClient(t, db, "macos")
			device := testidentity.New("resume-revoked")
			account := approvedAccount(t, db)
			setup, verifier := beginSetup(t, db, account)
			login, err := finishSetup(t, db, setup, verifier, device)
			if err != nil {
				t.Fatal(err)
			}
			challenge, err := db.BeginClientResumption(ctx, login.ResumeToken, setupTestOrigin, mac)
			if err != nil {
				t.Fatal(err)
			}
			sig := identity.Sign(device.Key, identity.ResumptionMessage(setupTestOrigin, mac.Platform,
				login.Member.ParticipantIdentity(), login.ResumeToken, challenge, device.Device))
			switch change {
			case "logout":
				err = db.RevokeClientCredential(ctx, login.Credential)
			case "new login":
				next, v := beginSetup(t, db, account)
				_, err = finishSetup(t, db, next, v, device)
			case "deadline":
				_, err = db.db.Exec("UPDATE members SET credential_expires_at=? WHERE id=?", time.Now().Unix(), login.Member.ID)
			case "challenge expiry":
				_, err = db.db.Exec("UPDATE client_login_resumptions SET challenge_expires_at=? WHERE member_id=?", time.Now().Unix(), login.Member.ID)
			case "disabled":
				err = db.DisableMember(ctx, login.Member.ID)
			case "revoked device":
				_, err = db.db.Exec("INSERT INTO identity_blacklist(kind,subject,account_id,account_key,username,created_at) VALUES('device',?,?,?,?,?)",
					device.Device.LeafKey(), login.Member.ID, device.Device.AccountKey, "test", time.Now().Unix())
			}
			if err != nil {
				t.Fatal(err)
			}
			want := ErrInvalidAuthorization
			switch change {
			case "challenge expiry":
				want = ErrResumptionProof
			case "revoked device":
				want = ErrBlacklisted
			}
			if _, err = db.CompleteClientResumption(ctx, login.ResumeToken, setupTestOrigin, sig, mac); !errors.Is(err, want) {
				t.Fatal("resumption ignored loss of authority", err)
			}
		})
	}
}
