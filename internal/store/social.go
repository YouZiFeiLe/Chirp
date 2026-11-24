package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

var ErrSocialConflict = errors.New("shared identity state has a newer version")

func activeSocialMember(ctx context.Context, tx *sql.Tx, m Member) error {
	if err := accountAllowed(ctx, tx, m.ID); err != nil {
		return err
	}
	var active bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM members WHERE id = ? AND login_id = ? AND enabled = 1 AND credential_expires_at > ?)", m.ID, m.LoginID, time.Now().Unix()).Scan(&active); err != nil {
		return err
	}
	if !active {
		return ErrDeviceIdentity
	}
	return nil
}

func (s *Store) SocialEvents(ctx context.Context, m Member, after int64) ([]identity.SocialEvent, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT document FROM account_social_events WHERE member_id = ? AND version > ? ORDER BY version LIMIT 256", m.ID, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []identity.SocialEvent{}
	for rows.Next() {
		var data []byte
		var e identity.SocialEvent
		if err = rows.Scan(&data); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(data, &e); err != nil {
			return nil, err
		}
		result = append(result, e)
	}
	return result, rows.Err()
}

func (s *Store) AppendSocialEvent(ctx context.Context, m Member, event identity.SocialEvent) error {
	if event.AccountID != m.ID || event.Validate(time.Now()) != nil {
		return ErrDeviceIdentity
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = activeSocialMember(ctx, tx, m); err != nil {
		return err
	}
	var data []byte
	var device identity.Device
	if err = tx.QueryRowContext(ctx, "SELECT device_identity FROM member_identities WHERE member_id = ? AND login_id = ?", m.ID, m.LoginID).Scan(&data); err != nil {
		return ErrDeviceIdentity
	}
	if json.Unmarshal(data, &device) != nil || device.Hash() != event.Signer.Hash() {
		return ErrDeviceIdentity
	}
	var previous identity.SocialEvent
	err = tx.QueryRowContext(ctx, "SELECT document FROM account_social_events WHERE member_id = ? ORDER BY version DESC LIMIT 1", m.ID).Scan(&data)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil && json.Unmarshal(data, &previous) != nil {
		return ErrDeviceIdentity
	}
	if previous.Hash() == event.Hash() {
		return tx.Commit()
	}
	expected := ""
	if previous.Version > 0 {
		expected = previous.Hash()
	}
	if event.Version != previous.Version+1 || event.PreviousHash != expected {
		return ErrSocialConflict
	}
	data, err = json.Marshal(event)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO account_social_events(member_id,version,document) VALUES(?,?,?)", m.ID, event.Version, data); err != nil {
		return err
	}
	return tx.Commit()
}

type RoutedSignal struct {
	Sequence int64           `json:"sequence"`
	Signal   identity.Signal `json:"signal"`
}

func (s *Store) SendIdentitySignal(ctx context.Context, m Member, signal identity.Signal) error {
	if signal.Sender != m.ID || signal.Validate(time.Now()) != nil {
		return ErrDeviceIdentity
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = activeSocialMember(ctx, tx, m); err != nil {
		return err
	}
	var data []byte
	var current identity.Device
	if tx.QueryRowContext(ctx, "SELECT device_identity FROM member_identities WHERE member_id=? AND login_id=?", m.ID, m.LoginID).Scan(&data) != nil || json.Unmarshal(data, &current) != nil || current.Hash() != signal.Device.Hash() {
		return ErrDeviceIdentity
	}
	var both bool
	if err = tx.QueryRowContext(ctx, "SELECT count(*) = 2 FROM room_admissions a JOIN members m ON m.id=a.member_id WHERE a.room_id=? AND (a.member_id || '.' || a.login_id || '.' || a.entry_id) IN (?,?) AND m.login_id=a.login_id AND m.enabled=1 AND a.expires_at > unixepoch() AND m.credential_expires_at > unixepoch()", signal.RoomID, signal.SenderEntry, signal.RecipientEntry).Scan(&both); err != nil {
		return err
	}
	if !both {
		return ErrDeviceIdentity
	}
	if ParticipantMemberID(signal.SenderEntry) != m.ID || ParticipantMemberID(signal.RecipientEntry) != signal.Recipient {
		return ErrDeviceIdentity
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM identity_signals WHERE expires_at <= ?", time.Now().Unix()); err != nil {
		return err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM identity_signals WHERE sender=?", m.ID).Scan(&count); err != nil {
		return err
	}
	if count >= 2048 {
		return ErrCeremonyCapacity
	}
	data, err = json.Marshal(signal)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO identity_signals(sender,recipient,document,expires_at) VALUES(?,?,?,?)", m.ID, signal.Recipient, data, signal.ExpiresAt); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Store) IdentitySignals(ctx context.Context, m Member, after int64) ([]RoutedSignal, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT sequence,document FROM identity_signals WHERE recipient=? AND sequence>? AND expires_at>? ORDER BY sequence LIMIT 128", m.ID, after, time.Now().Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []RoutedSignal{}
	for rows.Next() {
		var v RoutedSignal
		var data []byte
		if err = rows.Scan(&v.Sequence, &data); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(data, &v.Signal); err != nil {
			return nil, err
		}
		result = append(result, v)
	}
	return result, rows.Err()
}
