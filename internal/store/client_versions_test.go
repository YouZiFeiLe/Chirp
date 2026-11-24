package store

import (
	"context"
	"errors"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func latestTestClient(t *testing.T, db *Store, platform string) ClientIdentity {
	t.Helper()
	p, err := readClientPolicy(t.Context(), db.db, platform)
	if err != nil {
		t.Fatal(err)
	}
	return ClientIdentity{Platform: p.Platform, Version: p.LatestVersion, Build: p.LatestBuild}
}

func TestClientVersionOrderingUsesNumericVersionBeforeBuild(t *testing.T) {
	for _, test := range []struct {
		version    string
		build      int
		other      string
		otherBuild int
		want       int
	}{
		{"0.14.1", 1, "0.14.0", 14, 1},
		{"0.14.0", MaxClientBuild, "0.14.1", 1, -1},
		{"0.14.1", 1, "0.14.1", 2, -1},
		{"0.14.1", 2, "0.14.1", 1, 1},
		{"0.14.1", 1, "0.14.1", 1, 0},
		{"0.10.0", 1, "0.9.999999", MaxClientBuild, 1},
		{"1.0.0", 1, "0.999999.999999", MaxClientBuild, 1},
	} {
		if got := compareClientVersion(test.version, test.build, test.other, test.otherBuild); got != test.want {
			t.Fatalf("%s (%d) vs %s (%d): %d, want %d", test.version, test.build, test.other, test.otherBuild, got, test.want)
		}
	}
}

func TestClientPolicyValidatesTheEntireMinimumPair(t *testing.T) {
	valid := ClientVersionPolicy{Platform: "ios", LatestVersion: "0.14.1", LatestBuild: 1, MinimumVersion: "0.14.0", MinimumBuild: 14}
	if !valid.Valid() {
		t.Fatal("a newer version must allow a reset latest build")
	}
	for _, mutate := range []func(*ClientVersionPolicy){
		func(p *ClientVersionPolicy) { p.MinimumVersion = "" },
		func(p *ClientVersionPolicy) { p.MinimumVersion = "0.11" },
		func(p *ClientVersionPolicy) { p.MinimumVersion = "00.14.0" },
		func(p *ClientVersionPolicy) { p.MinimumVersion = "0.14.0\n" },
		func(p *ClientVersionPolicy) { p.MinimumVersion = "0.14.2"; p.MinimumBuild = 1 },
		func(p *ClientVersionPolicy) { p.MinimumVersion = "0.14.1"; p.MinimumBuild = 2 },
		func(p *ClientVersionPolicy) { p.MinimumBuild = 0 },
		func(p *ClientVersionPolicy) { p.MinimumBuild = MaxClientBuild + 1 },
		func(p *ClientVersionPolicy) { p.LatestBuild = 0 },
	} {
		policy := valid
		mutate(&policy)
		if policy.Valid() {
			t.Fatal("invalid minimum pair accepted", policy)
		}
	}
}

func TestDefaultClientPoliciesRejectRetiredReleases(t *testing.T) {
	db := openTestStore(t)
	for _, retired := range []ClientIdentity{
		{Platform: "ios", Version: "0.14.0", Build: 14},
		{Platform: "macos", Version: "0.14.0", Build: 14},
		{Platform: WindowsClientPlatform, Version: "0.1.0", Build: 1},
		{Platform: AndroidClientPlatform, Version: "2026.11.19", Build: 22},
	} {
		t.Run(retired.Platform, func(t *testing.T) {
			_, err := db.CheckClientVersion(t.Context(), retired)
			var update *ClientUpdateRequired
			if !errors.As(err, &update) || update.Policy.Platform != retired.Platform {
				t.Fatalf("retired client %+v: want an update for its platform, got %v", retired, err)
			}
		})
	}
}

func TestVersionResetAllowsNewVersionAndRejectsOldVersionWithHighBuild(t *testing.T) {
	ctx := context.Background()
	db := openTestStore(t)
	policy := ClientVersionPolicy{Platform: AndroidClientPlatform, LatestVersion: "2026.11.22", LatestBuild: 1, MinimumVersion: "2026.11.19", MinimumBuild: 22}
	if _, err := db.UpdateClientVersionPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	for _, client := range []ClientIdentity{
		{Platform: AndroidClientPlatform, Version: "2026.11.19", Build: 22},
		{Platform: AndroidClientPlatform, Version: "2026.11.22", Build: 1},
		{Platform: AndroidClientPlatform, Version: "2026.12.1", Build: 1},
	} {
		if _, err := db.CheckClientVersion(ctx, client); err != nil {
			t.Fatal("supported pair rejected", client, err)
		}
	}
	policy.MinimumVersion, policy.MinimumBuild = "2026.11.22", 1
	if _, err := db.UpdateClientVersionPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	_, err := db.CheckClientVersion(ctx, ClientIdentity{Platform: AndroidClientPlatform, Version: "2026.11.19", Build: MaxClientBuild})
	var update *ClientUpdateRequired
	if !errors.As(err, &update) || update.Policy.MinimumVersion != "2026.11.22" {
		t.Fatal("old version bypassed minimum with a high build", err)
	}
	if _, err := db.CheckClientVersion(ctx, ClientIdentity{Platform: AndroidClientPlatform, Version: "2026.11.22", Build: 1}); err != nil {
		t.Fatal(err)
	}
}

func TestClientPoliciesSeparatePlatformsPersistAndEnforceMinimum(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	policies, err := db.ClientVersionPolicies(ctx)
	if err != nil || len(policies) != 4 {
		t.Fatal(policies, err)
	}
	p, err := db.UpdateClientVersionPolicy(ctx, ClientVersionPolicy{Platform: "ios", LatestVersion: "2026.11.22", LatestBuild: 19, MinimumVersion: "2026.11.22", MinimumBuild: 17})
	if err != nil || p.UpdatedAt == "" {
		t.Fatal(p, err)
	}
	for _, build := range []int{1, 14, 16} {
		_, err := db.CheckClientVersion(ctx, ClientIdentity{Platform: "ios", Version: p.MinimumVersion, Build: build})
		var update *ClientUpdateRequired
		if !errors.As(err, &update) || update.Policy != p {
			t.Fatalf("build %d: want an update to %+v, got %#v", build, p, err)
		}
	}
	for _, build := range []int{17, 19, 20} {
		if _, err := db.CheckClientVersion(ctx, ClientIdentity{Platform: "ios", Version: p.MinimumVersion, Build: build}); err != nil {
			t.Fatal("minimum/newer build rejected", err)
		}
	}
	for _, before := range policies {
		if before.Platform == p.Platform {
			continue
		}
		minimum := ClientIdentity{Platform: before.Platform, Version: before.MinimumVersion, Build: before.MinimumBuild}
		after, err := db.CheckClientVersion(ctx, minimum)
		if err != nil || after != before {
			t.Fatalf("iOS edit affected %s: policy %v, want %v, err %v", before.Platform, after, before, err)
		}
	}
	windows, err := db.UpdateClientVersionPolicy(ctx, ClientVersionPolicy{Platform: WindowsClientPlatform, LatestVersion: "2026.11.21", LatestBuild: 3, MinimumVersion: "2026.11.21", MinimumBuild: 2})
	if err != nil {
		t.Fatal(err)
	}
	restarted, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	loaded, err := restarted.CheckClientVersion(ctx, ClientIdentity{Platform: p.Platform, Version: p.MinimumVersion, Build: p.MinimumBuild})
	if err != nil || loaded != p {
		t.Fatal("restart overwrote administrator policy", loaded, err)
	}
	loaded, err = restarted.CheckClientVersion(ctx, ClientIdentity{Platform: windows.Platform, Version: windows.MinimumVersion, Build: windows.MinimumBuild})
	if err != nil || loaded != windows {
		t.Fatal("restart overwrote Windows policy", loaded, err)
	}
	for _, invalid := range []ClientVersionPolicy{
		{Platform: "unknown", LatestVersion: "2026.11.22", LatestBuild: 19, MinimumVersion: "2026.11.22", MinimumBuild: 17},
		{Platform: "ios", LatestVersion: "0.12", LatestBuild: 19, MinimumVersion: "2026.11.22", MinimumBuild: 17},
		{Platform: "ios", LatestVersion: "01.12.0", LatestBuild: 19, MinimumVersion: "2026.11.22", MinimumBuild: 17},
		{Platform: "ios", LatestVersion: "2026.11.22", LatestBuild: 19, MinimumVersion: "2026.11.22", MinimumBuild: 20},
		{Platform: "ios", LatestVersion: "2026.11.22", LatestBuild: 19, MinimumVersion: "2026.11.22", MinimumBuild: 0},
	} {
		if _, err := db.UpdateClientVersionPolicy(ctx, invalid); !errors.Is(err, ErrInvalidClientPolicy) {
			t.Fatal("invalid policy saved", err)
		}
	}
}

func TestRaisingMinimumBeforeRedemptionPreservesLoginAndUnconsumedProofs(t *testing.T) {
	ctx := context.Background()
	db := openTestStore(t)
	account := approvedAccount(t, db)
	authorization, verifier := clientAuthorization()
	policy := ClientVersionPolicy{Platform: "macos", LatestVersion: "2026.11.22", LatestBuild: 2, MinimumVersion: "2026.11.22", MinimumBuild: 1}
	if _, err := db.UpdateClientVersionPolicy(ctx, policy); err != nil {
		t.Fatal(err)
	}
	client := ClientIdentity{Platform: policy.Platform, Version: policy.MinimumVersion, Build: policy.MinimumBuild}
	code, err := db.CreateClientAuthorization(ctx, account, account.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	previous, err := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, client, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	code, err = db.CreateClientAuthorization(ctx, account, account.CredentialJSON, authorization)
	if err != nil {
		t.Fatal(err)
	}
	device, err := db.BeginDeviceAuthorization(ctx, authorization.CodeChallenge, ClientID)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.ApproveDeviceAuthorization(ctx, device.RequestID, account, account.CredentialJSON); err != nil {
		t.Fatal(err)
	}
	policy.MinimumBuild = policy.LatestBuild
	policy, err = db.UpdateClientVersionPolicy(ctx, policy)
	if err != nil {
		t.Fatal(err)
	}
	_, exchangeErr := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, client, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier))
	_, pollErr := db.PollDeviceAuthorization(ctx, device.RequestID, verifier, client, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier))
	for _, err := range []error{exchangeErr, pollErr} {
		var update *ClientUpdateRequired
		if !errors.As(err, &update) || update.Policy != policy {
			t.Fatalf("client %+v: want an update to %+v, got %#v", client, policy, err)
		}
	}
	current, err := db.MemberByCredential(ctx, previous.Credential)
	if err != nil || current.LoginID != previous.Member.LoginID || current.LastLoginAt != previous.Member.LastLoginAt {
		t.Fatal("rejection changed existing login", current, err)
	}
	client.Build = policy.LatestBuild
	if _, err := db.PollDeviceAuthorization(ctx, device.RequestID, verifier, client, testidentity.New("existing-login-fixture").Login(ClientID, device.RequestID, verifier)); err != nil {
		t.Fatal("rejected poll consumed device authorization", err)
	}
	if _, err := db.ExchangeClientAuthorization(ctx, code, verifier, ClientID, ClientRedirectURI, client, testidentity.New("existing-login-fixture").Login(ClientID, code, verifier)); err != nil {
		t.Fatal("rejected exchange consumed authorization code", err)
	}
}
