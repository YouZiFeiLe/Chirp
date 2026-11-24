package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

var ErrDeviceIdentity = errors.New("a valid previously authorized device identity is required")
var ErrRoomPolicy = errors.New("room authorization is missing, changed, or invalid")

// bindLoginDevice runs before credential replacement in the same transaction.
// Once established, the account root cannot be reset by another Passkey login.
func bindLoginDevice(ctx context.Context, tx *sql.Tx, memberID string, proof identity.LoginProof, client, authorization, verifier string) error {
	if proof.Validate(client, authorization, verifier, time.Now()) != nil {
		return ErrDeviceIdentity
	}
	var root string
	err := tx.QueryRowContext(ctx, "SELECT account_key FROM member_identities WHERE member_id = ?", memberID).Scan(&root)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil && root != proof.Device.AccountKey {
		return ErrDeviceIdentity
	}
	if err := registerDevice(ctx, tx, memberID, proof.Device, ""); err != nil {
		return err
	}
	data, err := json.Marshal(proof.Device)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO member_identities(member_id, account_key, device_identity, login_id) VALUES(?, ?, ?, '') ON CONFLICT(member_id) DO UPDATE SET device_identity = excluded.device_identity", memberID, proof.Device.AccountKey, data)
	return err
}

func (s *Store) LoginDevice(ctx context.Context, memberID, loginID string) (identity.Device, error) {
	var result identity.Device
	var data []byte
	err := s.db.QueryRowContext(ctx, "SELECT i.device_identity FROM member_identities i JOIN members m ON m.id = i.member_id WHERE i.member_id = ? AND i.login_id = ? AND m.login_id = ? AND m.enabled = 1 AND m.credential_expires_at > ?", memberID, loginID, loginID, time.Now().Unix()).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return result, ErrDeviceIdentity
	}
	if err != nil {
		return result, err
	}
	if json.Unmarshal(data, &result) != nil || result.Validate(time.Now()) != nil {
		return result, ErrDeviceIdentity
	}
	var banned bool
	if err = s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM identity_blacklist WHERE (kind = 'account' AND subject = ?) OR (kind = 'device' AND subject = ?))", memberID, result.LeafKey()).Scan(&banned); err != nil {
		return result, err
	}
	if banned {
		return result, ErrBlacklisted
	}
	return result, nil
}

func (s *Store) RoomPolicy(ctx context.Context, roomID string) (identity.RoomPolicy, error) {
	var policy identity.RoomPolicy
	var data []byte
	err := s.db.QueryRowContext(ctx, "SELECT document FROM room_identity_policies WHERE room_id = ?", roomID).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return policy, ErrRoomPolicy
	}
	if err != nil {
		return policy, err
	}
	if json.Unmarshal(data, &policy) != nil || policy.Validate(time.Now()) != nil {
		return policy, ErrRoomPolicy
	}
	return policy, nil
}

func (s *Store) RoomPolicyHistory(ctx context.Context, roomID string, after int64) ([]identity.RoomPolicy, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT document FROM room_identity_history WHERE room_id = ? AND version > ? ORDER BY version LIMIT 64", roomID, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	policies := []identity.RoomPolicy{}
	for rows.Next() {
		var data []byte
		if err = rows.Scan(&data); err != nil {
			return nil, err
		}
		var policy identity.RoomPolicy
		if err = json.Unmarshal(data, &policy); err != nil {
			return nil, err
		}
		policies = append(policies, policy)
	}
	return policies, rows.Err()
}

// PutRoomPolicy stores client signatures, never an authority private key. Its
// compare-and-swap prevents accidental forks; clients independently pin owners
// and policy versions and do not rely on this server-side check for secrecy.
func (s *Store) PutRoomPolicy(ctx context.Context, member Member, policy identity.RoomPolicy) error {
	if policy.Validate(time.Now()) != nil {
		return ErrRoomPolicy
	}
	device, err := s.LoginDevice(ctx, member.ID, member.LoginID)
	if err != nil {
		return err
	}
	if device.AccountKey != policy.OwnerKey {
		return ErrRoomPolicy
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var active bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM members WHERE id = ? AND login_id = ? AND enabled = 1 AND credential_expires_at > ?)", member.ID, member.LoginID, time.Now().Unix()).Scan(&active); err != nil {
		return err
	}
	if !active {
		return ErrDeviceIdentity
	}
	var previous []byte
	err = tx.QueryRowContext(ctx, "SELECT document FROM room_identity_policies WHERE room_id = ?", policy.RoomID).Scan(&previous)
	if errors.Is(err, sql.ErrNoRows) {
		if policy.Version != 1 || policy.PreviousHash != "" {
			return ErrRoomPolicy
		}
	} else if err != nil {
		return err
	} else {
		var old identity.RoomPolicy
		if json.Unmarshal(previous, &old) != nil {
			return ErrRoomPolicy
		}
		if old.Hash() == policy.Hash() {
			return tx.Commit()
		}
		if policy.OwnerKey != old.OwnerKey || policy.TrustID != old.TrustID || policy.Origin != old.Origin || policy.Version != old.Version+1 || policy.PreviousHash != old.Hash() {
			return ErrRoomPolicy
		}
		if old.Allows(policy.Signer, time.Now()) != nil {
			return ErrRoomPolicy
		}
	}
	data, err := json.Marshal(policy)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO room_identity_policies(room_id, document) VALUES(?, ?) ON CONFLICT(room_id) DO UPDATE SET document = excluded.document", policy.RoomID, data); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO room_identity_history(room_id, version, document) VALUES(?, ?, ?)", policy.RoomID, policy.Version, data); err != nil {
		return err
	}
	return tx.Commit()
}
