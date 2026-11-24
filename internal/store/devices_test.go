package store

import (
	"context"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func revocationFor(device identity.Device) DeviceRevocationCheck {
	return func(_ context.Context, accountKey, deviceKey string) (bool, error) {
		return accountKey == device.AccountKey && deviceKey == device.LeafKey(), nil
	}
}

func TestDeviceTimestampsFollowSuccessfulLogins(t *testing.T) {
	db := openTestStore(t)
	mac := latestTestClient(t, db, "macos")
	account := approvedAccount(t, db)
	root := testidentity.New("device-timestamps-root")
	first := activateIdentity(t, db, account, root)
	read := func(key string) RegisteredDevice {
		t.Helper()
		devices, err := db.Devices(t.Context(), first.Member.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, device := range devices {
			if device.DeviceKey == key {
				return device
			}
		}
		t.Fatalf("device %q is missing", key)
		return RegisteredDevice{}
	}
	assertLoginTime := func(device RegisteredDevice, login ClientLogin) {
		t.Helper()
		stamp, err := time.Parse(time.RFC3339, login.Member.LastLoginAt)
		if err != nil || device.LastLoginAt != stamp.Unix() || device.CreatedAt <= 0 || device.CreatedAt > device.LastLoginAt {
			t.Fatalf("incorrect registration or login time: device=%+v, login=%q, err=%v", device, login.Member.LastLoginAt, err)
		}
	}
	assertLoginTime(read(root.Device.LeafKey()), first)
	// Distinct old timestamps make the check independent of wall-clock sleeps.
	const registeredAt int64 = 1700000000
	const previousLoginAt int64 = registeredAt + 100
	if _, err := db.db.Exec("UPDATE registered_devices SET created_at = ?, last_login_at = ? WHERE device_key = ?", registeredAt, previousLoginAt, root.Device.LeafKey()); err != nil {
		t.Fatal(err)
	}
	child := testidentity.Child(root, "device-timestamps-child", true)
	second := activateIdentity(t, db, account, child)
	childRecord := read(child.Device.LeafKey())
	assertLoginTime(childRecord, second)
	assertUnchanged := func(key string, createdAt, lastLoginAt int64) {
		t.Helper()
		device := read(key)
		if device.CreatedAt != createdAt || device.LastLoginAt != lastLoginAt {
			t.Fatalf("device timestamps changed: got (%d, %d), want (%d, %d)", device.CreatedAt, device.LastLoginAt, createdAt, lastLoginAt)
		}
	}
	assertUnchanged(root.Device.LeafKey(), registeredAt, previousLoginAt)
	if err := db.RenameDevice(t.Context(), second.Member, root.Device.LeafKey(), "Renamed device"); err != nil {
		t.Fatal(err)
	}
	assertUnchanged(root.Device.LeafKey(), registeredAt, previousLoginAt)
	client, verifier := clientAuthorization()
	code, err := db.CreateClientAuthorization(t.Context(), account, account.CredentialJSON, client)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.ExchangeClientAuthorization(t.Context(), code, verifier, ClientID, ClientRedirectURI, mac, root.Login(ClientID, "wrong-authorization", verifier)); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("mismatched login proof was accepted", err)
	}
	assertUnchanged(root.Device.LeafKey(), registeredAt, previousLoginAt)
	assertUnchanged(child.Device.LeafKey(), childRecord.CreatedAt, childRecord.LastLoginAt)
	third, err := db.ExchangeClientAuthorization(t.Context(), code, verifier, ClientID, ClientRedirectURI, mac, root.Login(ClientID, code, verifier))
	if err != nil {
		t.Fatal(err)
	}
	assertLoginTime(read(root.Device.LeafKey()), third)
	if read(root.Device.LeafKey()).CreatedAt != registeredAt {
		t.Fatal("signing in again changed the first registration time")
	}
	assertUnchanged(child.Device.LeafKey(), childRecord.CreatedAt, childRecord.LastLoginAt)
	rootRecord := read(root.Device.LeafKey())
	if _, err = db.db.Exec("UPDATE registered_devices SET last_login_at = ? WHERE device_key = ?", previousLoginAt, child.Device.LeafKey()); err != nil {
		t.Fatal(err)
	}
	request, err := db.BeginDeviceAuthorization(t.Context(), client.CodeChallenge, ClientID)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.ApproveDeviceAuthorization(t.Context(), request.RequestID, account, account.CredentialJSON); err != nil {
		t.Fatal(err)
	}
	assertUnchanged(child.Device.LeafKey(), childRecord.CreatedAt, previousLoginAt)
	fourth, err := db.PollDeviceAuthorization(t.Context(), request.RequestID, verifier, mac, child.Login(ClientID, request.RequestID, verifier))
	if err != nil {
		t.Fatal(err)
	}
	assertLoginTime(read(child.Device.LeafKey()), fourth)
	childRecord = read(child.Device.LeafKey())
	assertUnchanged(root.Device.LeafKey(), rootRecord.CreatedAt, rootRecord.LastLoginAt)
	if err = db.RevokeDevice(t.Context(), fourth.Member, root.Device.LeafKey(), revocationFor(root.Device)); err != nil {
		t.Fatal(err)
	}
	assertUnchanged(root.Device.LeafKey(), rootRecord.CreatedAt, rootRecord.LastLoginAt)
	assertUnchanged(child.Device.LeafKey(), childRecord.CreatedAt, childRecord.LastLoginAt)
}

func TestDeviceRevocationIsPermanentAndDoesNotRevokeRegisteredDescendants(t *testing.T) {
	db := openTestStore(t)
	account := approvedAccount(t, db)
	root := testidentity.New("registry-root")
	_ = activateIdentity(t, db, account, root)
	child := testidentity.Child(root, "registry-child", true)
	_ = activateIdentity(t, db, account, child)
	grandchild := testidentity.Child(child, "registry-grandchild", true)
	online := activateIdentity(t, db, account, grandchild)
	if err := db.RevokeDevice(t.Context(), online.Member, grandchild.Device.LeafKey(), revocationFor(grandchild.Device)); !errors.Is(err, ErrCurrentDevice) {
		t.Fatal("self revocation was accepted", err)
	}
	if err := db.RevokeDevice(t.Context(), online.Member, child.Device.LeafKey(), revocationFor(child.Device)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(t.Context(), online.Credential); err != nil {
		t.Fatal("revoking offline parent kicked registered descendant", err)
	}
	// The registered grandchild can authenticate again after its issuer's ban.
	next, verifier := beginSetup(t, db, account)
	if _, err := finishSetup(t, db, next, verifier, grandchild); err != nil {
		t.Fatal("descendant was transitively revoked", err)
	}
	candidate := testidentity.Child(child, "post-revocation-child", false)
	next, verifier = beginSetup(t, db, account)
	if _, err := finishSetup(t, db, next, verifier, candidate); !errors.Is(err, ErrBlacklisted) {
		t.Fatal("revoked parent registered a new child", err)
	}
	next, verifier = beginSetup(t, db, account)
	if _, err := finishSetup(t, db, next, verifier, child); !errors.Is(err, ErrBlacklisted) {
		t.Fatal("revoked device reactivated", err)
	}
	records, err := db.Blacklist(t.Context())
	if err != nil || len(records) != 1 || records[0].Subject != child.Device.LeafKey() {
		t.Fatal(records, err)
	}
	if _, err = db.db.Exec("DELETE FROM identity_blacklist"); err == nil {
		t.Fatal("permanent blacklist could be deleted")
	}
	if _, err = db.db.Exec("UPDATE identity_blacklist SET subject='other'"); err == nil {
		t.Fatal("permanent blacklist could be modified")
	}
}
func TestAdminLastDeviceBanReservesUsernameAndOriginalRoot(t *testing.T) {
	db := openTestStore(t)
	account := approvedAccount(t, db)
	root := testidentity.New("last-device")
	login := activateIdentity(t, db, account, root)
	if err := db.AdminRevokeDevice(t.Context(), root.Device.LeafKey()); err != nil {
		t.Fatal(err)
	}
	member, err := db.MemberByCredential(t.Context(), login.Credential)
	if err != nil || member.Enabled {
		t.Fatal("last-device removal did not disable account", err)
	}
	if _, err = db.UpdateMember(t.Context(), login.Member.ID, "new display", true); !errors.Is(err, ErrBlacklisted) {
		t.Fatal("permanent ban was removed", err)
	}
	if err = db.DeleteMember(t.Context(), login.Member.ID); err != nil {
		t.Fatal(err)
	}
	if err = db.CheckRegistrationName(t.Context(), account.Nickname); !errors.Is(err, ErrRegistrationExists) {
		t.Fatal("banned username released", err)
	}
	records, err := db.Blacklist(t.Context())
	if err != nil || len(records) != 2 {
		t.Fatal("blacklist lost on account deletion", records, err)
	}
}
func TestRecoveryRegistersANewDeviceButCannotRestoreRevokedKeys(t *testing.T) {
	db := openTestStore(t)
	account := approvedAccount(t, db)
	root := testidentity.New("recovery-registry")
	login := activateIdentity(t, db, account, root)
	fresh := testidentity.New("recovered-new-device")
	cert := fresh.Device.Certificates[0]
	cert.AccountKey = root.Device.AccountKey
	cert.IssuerKey = root.Device.AccountKey
	cert.Signature = identity.Sign(root.Root, cert.Message())
	fresh.Device = identity.Device{AccountKey: root.Device.AccountKey, Certificates: []identity.Certificate{cert}}
	setup, verifier := beginSetup(t, db, account)
	replacement, err := finishSetup(t, db, setup, verifier, fresh)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.RevokeDevice(t.Context(), replacement.Member, root.Device.LeafKey(), revocationFor(root.Device)); err != nil {
		t.Fatal(err)
	}
	if _, err = db.MemberByCredential(t.Context(), login.Credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("old credential survived new login", err)
	}
	devices, err := db.Devices(t.Context(), replacement.Member.ID)
	if err != nil || len(devices) != 2 {
		t.Fatal(devices, err)
	}
	if devices[0].DeviceKey == fresh.Device.LeafKey() && devices[0].Revoked {
		t.Fatal("new recovered identity revoked")
	}
	decoded, _ := base64.StdEncoding.DecodeString(fresh.Device.LeafKey())
	if len(decoded) != 32 {
		t.Fatal("invalid key")
	}
}
