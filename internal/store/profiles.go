package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"time"
)

const MaxAvatarBytes = 5_000_000 // Strictly less than 5 MB; image bytes, not Base64.

var ErrProfileSessionChanged = errors.New("profile login is no longer current")

// MemberProfile contains display data only. Avatar bytes never enter member,
// session, room directory, or cryptographic membership responses.
type MemberProfile struct {
	ID              string `json:"id"`
	DisplayName     string `json:"display_name"`
	ProfileRevision int64  `json:"profile_revision"`
	AvatarRevision  string `json:"avatar_revision,omitempty"`
}

const profileSelect = "SELECT m.id, m.display_name, m.profile_revision, COALESCE(a.revision, '') FROM members m LEFT JOIN member_avatars a ON a.member_id = m.id"

type profileReader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readProfile(ctx context.Context, db profileReader, id string) (MemberProfile, error) {
	var p MemberProfile
	err := db.QueryRowContext(ctx, profileSelect+" WHERE m.id = ? AND m.enabled = 1", id).Scan(&p.ID, &p.DisplayName, &p.ProfileRevision, &p.AvatarRevision)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrNotFound
	}
	return p, err
}

func (s *Store) MemberProfile(ctx context.Context, id string) (MemberProfile, error) {
	return readProfile(ctx, s.db, id)
}

func (s *Store) MemberProfiles(ctx context.Context) ([]MemberProfile, error) {
	rows, err := s.db.QueryContext(ctx, profileSelect+" WHERE m.enabled = 1 ORDER BY m.id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	profiles := []MemberProfile{}
	for rows.Next() {
		var p MemberProfile
		if err := rows.Scan(&p.ID, &p.DisplayName, &p.ProfileRevision, &p.AvatarRevision); err != nil {
			return nil, err
		}
		profiles = append(profiles, p)
	}
	return profiles, rows.Err()
}

func (s *Store) MemberAvatar(ctx context.Context, id, revision string) ([]byte, error) {
	var data []byte
	err := s.db.QueryRowContext(ctx, "SELECT a.image_data FROM member_avatars a JOIN members m ON m.id = a.member_id WHERE a.member_id = ? AND a.revision = ? AND m.enabled = 1", id, revision).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrNotFound
	}
	return data, err
}

func (s *Store) UpdateOwnDisplayName(ctx context.Context, member Member, name string) (MemberProfile, error) {
	name = strings.TrimSpace(name)
	if !validName(name) {
		return MemberProfile{}, ErrInvalidName
	}
	return s.updateOwnProfile(ctx, member, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, "UPDATE members SET display_name = ? WHERE id = ?", name, member.ID)
		return err
	})
}

// data is the validated, re-encoded PNG produced by the HTTP image processor.
func (s *Store) SetOwnAvatar(ctx context.Context, member Member, data []byte) (MemberProfile, error) {
	if len(data) == 0 || len(data) >= MaxAvatarBytes {
		return MemberProfile{}, errors.New("invalid normalized avatar size")
	}
	hash := sha256.Sum256(data)
	revision := hex.EncodeToString(hash[:])
	return s.updateOwnProfile(ctx, member, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, "INSERT INTO member_avatars(member_id, image_data, revision, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(member_id) DO UPDATE SET image_data = excluded.image_data, revision = excluded.revision, updated_at = excluded.updated_at", member.ID, data, revision, time.Now().UTC().Format(time.RFC3339))
		return err
	})
}

func (s *Store) DeleteOwnAvatar(ctx context.Context, member Member) (MemberProfile, error) {
	return s.updateOwnProfile(ctx, member, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, "DELETE FROM member_avatars WHERE member_id = ?", member.ID)
		return err
	})
}

func (s *Store) updateOwnProfile(ctx context.Context, member Member, update func(*sql.Tx) error) (MemberProfile, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return MemberProfile{}, err
	}
	defer tx.Rollback()
	// Recheck inside the write transaction: an upload may outlive logout,
	// expiry, disable, or a newer device taking over the account.
	var current bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM members WHERE id = ? AND login_id = ? AND enabled = 1 AND credential_expires_at > ?)", member.ID, member.LoginID, time.Now().Unix()).Scan(&current); err != nil {
		return MemberProfile{}, err
	}
	if !current || member.LoginID == "" {
		return MemberProfile{}, ErrProfileSessionChanged
	}
	if err := update(tx); err != nil {
		return MemberProfile{}, err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE members SET profile_revision = profile_revision + 1, updated_at = ? WHERE id = ?", time.Now().UTC().Format(time.RFC3339), member.ID); err != nil {
		return MemberProfile{}, err
	}
	p, err := readProfile(ctx, tx, member.ID)
	if err != nil {
		return p, err
	}
	return p, tx.Commit()
}
