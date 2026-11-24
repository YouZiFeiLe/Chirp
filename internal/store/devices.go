package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

var ErrBlacklisted = errors.New("identity is permanently blacklisted")
var ErrCurrentDevice = errors.New("the current device cannot be revoked")
var ErrLastDevice = errors.New("at least one valid device must remain")
var ErrRevocationUnavailable = errors.New("device revocation history is unavailable")

type DeviceRevocationCheck func(ctx context.Context, accountKey, deviceKey string) (bool, error)

type RegisteredDevice struct {
	DeviceKey   string          `json:"device_key"`
	AccountID   string          `json:"account_id"`
	AccountKey  string          `json:"account_key"`
	Device      identity.Device `json:"device"`
	Name        string          `json:"name"`
	Platform    string          `json:"platform"`
	CreatedAt   int64           `json:"created_at"`
	LastLoginAt int64           `json:"last_login_at"`
	Revoked     bool            `json:"revoked"`
}

type BlacklistEntry struct {
	Sequence   int64  `json:"sequence"`
	Kind       string `json:"kind"`
	Subject    string `json:"subject"`
	AccountID  string `json:"account_id"`
	AccountKey string `json:"account_key"`
	Username   string `json:"username"`
	CreatedAt  int64  `json:"created_at"`
}

func accountAllowed(ctx context.Context, tx *sql.Tx, id string) error {
	var enabled, banned bool
	err := tx.QueryRowContext(ctx, "SELECT enabled, EXISTS(SELECT 1 FROM identity_blacklist WHERE kind = 'account' AND subject = members.id) FROM members WHERE id = ?", id).Scan(&enabled, &banned)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotApproved
	}
	if err != nil {
		return err
	}
	if banned {
		return ErrBlacklisted
	}
	if !enabled {
		return ErrMemberDisabled
	}
	return nil
}

func deviceBlocked(ctx context.Context, tx *sql.Tx, key string) (bool, error) {
	var banned bool
	err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM identity_blacklist WHERE kind = 'device' AND subject = ?)", key).Scan(&banned)
	return banned, err
}

// Only a new enrollment checks the issuer's current registration. Previously
// registered children stay independent when an issuer is later revoked.
func registerDevice(ctx context.Context, tx *sql.Tx, memberID string, device identity.Device, platform string, names ...string) error {
	if err := accountAllowed(ctx, tx, memberID); err != nil {
		return err
	}
	var rootBlocked bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM identity_blacklist WHERE kind='account' AND account_key=? UNION ALL SELECT 1 FROM member_identities WHERE account_key=? AND member_id!=?)", device.AccountKey, device.AccountKey, memberID).Scan(&rootBlocked); err != nil {
		return err
	}
	if rootBlocked {
		return ErrBlacklisted
	}
	if device.Validate(time.Now()) != nil {
		return ErrDeviceIdentity
	}
	blocked, err := deviceBlocked(ctx, tx, device.LeafKey())
	if err != nil {
		return err
	}
	if blocked {
		return ErrBlacklisted
	}
	var owner, root string
	err = tx.QueryRowContext(ctx, "SELECT member_id, account_key FROM registered_devices WHERE device_key = ?", device.LeafKey()).Scan(&owner, &root)
	if err == nil {
		if owner != memberID || root != device.AccountKey {
			return ErrDeviceIdentity
		}
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	leaf := device.Certificates[len(device.Certificates)-1]
	if leaf.IssuerKey != device.AccountKey {
		blocked, err = deviceBlocked(ctx, tx, leaf.IssuerKey)
		if err != nil {
			return err
		}
		if blocked {
			return ErrBlacklisted
		}
		var document []byte
		err = tx.QueryRowContext(ctx, "SELECT document FROM registered_devices WHERE device_key = ? AND member_id = ? AND account_key = ?", leaf.IssuerKey, memberID, device.AccountKey).Scan(&document)
		var issuer identity.Device
		if err != nil || json.Unmarshal(document, &issuer) != nil || issuer.Validate(time.Now()) != nil || !issuer.Certificates[len(issuer.Certificates)-1].CanEnroll || issuer.Certificates[len(issuer.Certificates)-1].Hash() != leaf.ParentHash {
			return ErrDeviceIdentity
		}
	}
	data, err := json.Marshal(device)
	if err != nil {
		return err
	}
	name := "Device"
	switch platform {
	case "ios":
		name = "iPhone"
	case "macos":
		name = "Mac"
	}
	if len(names) > 0 && names[0] != "" {
		if !validName(names[0]) {
			return ErrDeviceIdentity
		}
		name = names[0]
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO registered_devices(device_key, member_id, account_key, document, name, platform, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)", device.LeafKey(), memberID, device.AccountKey, data, name, platform, time.Now().Unix())
	return err
}

func (s *Store) Devices(ctx context.Context, accountID string) ([]RegisteredDevice, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT d.device_key, d.member_id, d.account_key, d.document, d.name, d.platform, d.created_at, d.last_login_at, EXISTS(SELECT 1 FROM identity_blacklist b WHERE b.kind = 'device' AND b.subject = d.device_key) FROM registered_devices d WHERE d.member_id = ? ORDER BY d.created_at, d.device_key", accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []RegisteredDevice{}
	for rows.Next() {
		var d RegisteredDevice
		var data []byte
		if err = rows.Scan(&d.DeviceKey, &d.AccountID, &d.AccountKey, &data, &d.Name, &d.Platform, &d.CreatedAt, &d.LastLoginAt, &d.Revoked); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(data, &d.Device); err != nil {
			return nil, err
		}
		result = append(result, d)
	}
	return result, rows.Err()
}

func (s *Store) RenameDevice(ctx context.Context, member Member, key, name string) error {
	name = strings.TrimSpace(name)
	if !validName(name) {
		return ErrInvalidName
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = activeSocialMember(ctx, tx, member); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, "UPDATE registered_devices SET name = ? WHERE device_key = ? AND member_id = ?", name, key, member.ID)
	if err = changed(result, err); err != nil {
		return err
	}
	return tx.Commit()
}

func blacklistAccount(ctx context.Context, tx *sql.Tx, id string) error {
	if _, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO identity_blacklist(kind, subject, account_id, account_key, username, created_at) SELECT 'account', m.id, m.id, coalesce(i.account_key, ''), coalesce(a.nickname, m.display_name), ? FROM members m LEFT JOIN member_identities i ON i.member_id = m.id LEFT JOIN passkey_accounts a ON a.member_id = m.id WHERE m.id = ?", time.Now().Unix(), id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO identity_blacklist(kind, subject, account_id, account_key, username, created_at) SELECT 'device', d.device_key, d.member_id, d.account_key, coalesce(a.nickname, m.display_name), ? FROM registered_devices d JOIN members m ON m.id = d.member_id LEFT JOIN passkey_accounts a ON a.member_id = m.id WHERE d.member_id = ?", time.Now().Unix(), id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE members SET enabled = 0, login_id = '', credential_expires_at = 0 WHERE id = ?", id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM identity_setups WHERE member_id = ?", id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM client_authorizations WHERE member_id = ?", id); err != nil {
		return err
	}
	return clearBrowserSessions(ctx, tx, id)
}

func (s *Store) RevokeDevice(ctx context.Context, member Member, key string, check DeviceRevocationCheck) error {
	var root string
	err := s.db.QueryRowContext(ctx, "SELECT account_key FROM registered_devices WHERE member_id = ? AND device_key = ?", member.ID, key).Scan(&root)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if check == nil {
		return ErrRevocationUnavailable
	}
	// Replay the signed log before taking the business database write lock.
	// Revocations are permanent. Recheck the target's root and the login in the transaction.
	revoked, err := check(ctx, root, key)
	if err != nil {
		return errors.Join(ErrRevocationUnavailable, err)
	}
	var confirmedRoot string
	if revoked {
		confirmedRoot = root
	}
	return s.revokeDevice(ctx, member, key, confirmedRoot, false)
}

func (s *Store) AdminRevokeDevice(ctx context.Context, key string) error {
	return s.revokeDevice(ctx, Member{}, key, "", true)
}

func (s *Store) revokeDevice(ctx context.Context, member Member, key, confirmedRoot string, admin bool) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var owner, root, username string
	err = tx.QueryRowContext(ctx, "SELECT d.member_id, d.account_key, coalesce(a.nickname, m.display_name) FROM registered_devices d JOIN members m ON m.id = d.member_id LEFT JOIN passkey_accounts a ON a.member_id = m.id WHERE d.device_key = ?", key).Scan(&owner, &root, &username)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if !admin {
		if owner != member.ID {
			return ErrNotFound
		}
		if err = activeSocialMember(ctx, tx, member); err != nil {
			return err
		}
		var data []byte
		var current identity.Device
		if err = tx.QueryRowContext(ctx, "SELECT device_identity FROM member_identities WHERE member_id = ? AND login_id = ?", member.ID, member.LoginID).Scan(&data); err != nil {
			return ErrDeviceIdentity
		}
		if json.Unmarshal(data, &current) != nil {
			return ErrDeviceIdentity
		}
		if current.LeafKey() == key {
			return ErrCurrentDevice
		}
		if confirmedRoot == "" || confirmedRoot != root || confirmedRoot != current.AccountKey {
			return ErrDeviceIdentity
		}
	}
	devices, err := validDeviceCount(ctx, tx, owner, key)
	if err != nil {
		return err
	}
	if !admin && devices == 0 {
		return ErrLastDevice
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR IGNORE INTO identity_blacklist(kind, subject, account_id, account_key, username, created_at) VALUES('device', ?, ?, ?, ?, ?)", key, owner, root, username, time.Now().Unix()); err != nil {
		return err
	}
	var data []byte
	var current identity.Device
	if tx.QueryRowContext(ctx, "SELECT device_identity FROM member_identities WHERE member_id = ?", owner).Scan(&data) == nil && json.Unmarshal(data, &current) == nil && current.LeafKey() == key {
		if _, err = tx.ExecContext(ctx, "UPDATE members SET login_id = '', credential_expires_at = 0 WHERE id = ?", owner); err != nil {
			return err
		}
	}
	if admin && devices == 0 {
		if err = blacklistAccount(ctx, tx, owner); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func validDeviceCount(ctx context.Context, tx *sql.Tx, owner, except string) (int, error) {
	rows, err := tx.QueryContext(ctx, "SELECT document FROM registered_devices d WHERE member_id = ? AND device_key != ? AND NOT EXISTS(SELECT 1 FROM identity_blacklist b WHERE b.kind = 'device' AND b.subject = d.device_key)", owner, except)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var data []byte
		var d identity.Device
		if err = rows.Scan(&data); err != nil {
			return 0, err
		}
		if json.Unmarshal(data, &d) == nil && d.Validate(time.Now()) == nil {
			count++
		}
	}
	return count, rows.Err()
}

func (s *Store) Blacklist(ctx context.Context) ([]BlacklistEntry, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT sequence, kind, subject, account_id, account_key, username, created_at FROM identity_blacklist ORDER BY sequence")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []BlacklistEntry{}
	for rows.Next() {
		var b BlacklistEntry
		if err = rows.Scan(&b.Sequence, &b.Kind, &b.Subject, &b.AccountID, &b.AccountKey, &b.Username, &b.CreatedAt); err != nil {
			return nil, err
		}
		result = append(result, b)
	}
	return result, rows.Err()
}
