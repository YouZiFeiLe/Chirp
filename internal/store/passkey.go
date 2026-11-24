package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"regexp"
	"time"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

var (
	ErrInvalidNickname      = errors.New("nickname must contain 3 to 15 ASCII letters")
	ErrRegistrationExists   = errors.New("registration already exists")
	ErrRegistrationClosed   = errors.New("registration is closed")
	ErrAlreadyApproved      = errors.New("registration is already approved")
	ErrNotApproved          = errors.New("account is not approved")
	ErrMemberDisabled       = errors.New("member is disabled")
	ErrPasskeyChanged       = errors.New("credential changed during authentication")
	ErrRegistrationCapacity = errors.New("too many pending registrations")
	ErrRegistrationRejected = errors.New("registration was rejected")
	ErrCeremonyCapacity     = errors.New("too many active ceremonies")
	nicknamePattern         = regexp.MustCompile(`^[A-Za-z]{3,15}$`)
)

type RegistrationRequest struct {
	RequestID  string `json:"request_id"`
	Nickname   string `json:"nickname"`
	MemberID   string `json:"member_id,omitempty"`
	CreatedAt  string `json:"created_at"`
	ApprovedAt string `json:"approved_at,omitempty"`
}

type PasskeyAccount struct {
	Rejected       bool
	Blacklisted    bool
	ID             string
	Nickname       string
	CredentialID   []byte
	CredentialJSON []byte
}

func NewPasskeyID() (string, error) { return randomID("passkey_", 32) }

func randomID(prefix string, size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(value), nil
}

const registrationClosedQuery = "SELECT closed FROM registration_settings WHERE id = 1"

func (s *Store) RegistrationClosed(ctx context.Context) (bool, error) {
	var closed bool
	err := s.db.QueryRowContext(ctx, registrationClosedQuery).Scan(&closed)
	return closed, err
}

func (s *Store) SetRegistrationClosed(ctx context.Context, closed bool) error {
	result, err := s.write(ctx, "UPDATE registration_settings SET closed = ? WHERE id = 1", closed)
	return changed(result, err)
}

func (s *Store) CheckRegistrationName(ctx context.Context, nickname string) error {
	if !nicknamePattern.MatchString(nickname) {
		return ErrInvalidNickname
	}
	var exists bool
	if err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM passkey_accounts WHERE nickname = ? UNION ALL SELECT 1 FROM identity_blacklist WHERE kind = 'account' AND username = ? COLLATE NOCASE)", nickname, nickname).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return ErrRegistrationExists
	}
	return nil
}

func (s *Store) RegisterPasskey(ctx context.Context, account PasskeyAccount) (RegistrationRequest, error) {
	if !nicknamePattern.MatchString(account.Nickname) {
		return RegistrationRequest{}, ErrInvalidNickname
	}
	requestID, err := randomID("CHIRP-", 12)
	if err != nil {
		return RegistrationRequest{}, err
	}
	request := RegistrationRequest{RequestID: requestID, Nickname: account.Nickname, CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return request, err
	}
	defer tx.Rollback()
	// Serialize the registration with administrator updates to the switch.
	var closed bool
	if err = tx.QueryRowContext(ctx, registrationClosedQuery).Scan(&closed); err != nil {
		return RegistrationRequest{}, err
	}
	if closed {
		return RegistrationRequest{}, ErrRegistrationClosed
	}
	var reserved bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM identity_blacklist WHERE kind = 'account' AND username = ? COLLATE NOCASE)", account.Nickname).Scan(&reserved); err != nil {
		return request, err
	}
	if reserved {
		return request, ErrRegistrationExists
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM passkey_accounts WHERE member_id IS NULL").Scan(&count); err != nil {
		return request, err
	}
	if count >= 100 {
		return request, ErrRegistrationCapacity
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO passkey_accounts(id, nickname, request_id, created_at) VALUES(?, ?, ?, ?)", account.ID, account.Nickname, request.RequestID, request.CreatedAt); err == nil {
		_, err = tx.ExecContext(ctx, "INSERT INTO passkey_credentials(id, account_id, credential_json) VALUES(?, ?, ?)", account.CredentialID, account.ID, account.CredentialJSON)
	}
	if err != nil {
		var constraint *sqlite.Error
		if errors.As(err, &constraint) && (constraint.Code() == sqlite3.SQLITE_CONSTRAINT_UNIQUE || constraint.Code() == sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY) {
			return request, ErrRegistrationExists
		}
		return request, err
	}
	return request, tx.Commit()
}

func (s *Store) ListRegistrationRequests(ctx context.Context) ([]RegistrationRequest, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT request_id, nickname, coalesce(member_id, ''), created_at, coalesce(approved_at, '') FROM passkey_accounts ORDER BY approved_at IS NOT NULL, created_at DESC, request_id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	requests := []RegistrationRequest{}
	for rows.Next() {
		var item RegistrationRequest
		if err = rows.Scan(&item.RequestID, &item.Nickname, &item.MemberID, &item.CreatedAt, &item.ApprovedAt); err != nil {
			return nil, err
		}
		requests = append(requests, item)
	}
	return requests, rows.Err()
}

func (s *Store) ApproveRegistration(ctx context.Context, requestID string) (Member, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Member{}, err
	}
	defer tx.Rollback()
	member, err := approveRegistration(ctx, tx, requestID)
	if err != nil {
		return Member{}, err
	}
	return member, tx.Commit()
}

func approveRegistration(ctx context.Context, tx *sql.Tx, requestID string) (Member, error) {
	_, hash, err := newCredential()
	if err != nil {
		return Member{}, err
	}
	id, err := randomID("member_", 12)
	if err != nil {
		return Member{}, err
	}
	var nickname string
	var memberID sql.NullString
	if err = tx.QueryRowContext(ctx, "SELECT nickname, member_id FROM passkey_accounts WHERE request_id = ?", requestID).Scan(&nickname, &memberID); errors.Is(err, sql.ErrNoRows) {
		return Member{}, ErrNotFound
	} else if err != nil {
		return Member{}, err
	}
	if memberID.Valid {
		return Member{}, ErrAlreadyApproved
	}
	now := time.Now().UTC().Format(time.RFC3339)
	member := Member{ID: id, DisplayName: nickname, Enabled: true, CreatedAt: now, UpdatedAt: now}
	if _, err = tx.ExecContext(ctx, "INSERT INTO members(id, display_name, credential_hash, enabled, created_at, updated_at) VALUES(?, ?, ?, 1, ?, ?)", id, nickname, hash, now, now); err != nil {
		return Member{}, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE passkey_accounts SET member_id = ?, approved_at = ? WHERE request_id = ?", id, now, requestID); err != nil {
		return Member{}, err
	}
	return member, nil
}

func (s *Store) DeleteRegistration(ctx context.Context, requestID string) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var approved sql.NullString
	if err = tx.QueryRowContext(ctx, "SELECT member_id FROM passkey_accounts WHERE request_id=?", requestID).Scan(&approved); errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	if approved.Valid {
		return ErrAlreadyApproved
	}
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO retired_passkeys(credential_id,account_id,nickname,credential_json,retired_at,status) SELECT c.id,a.id,a.nickname,c.credential_json,?,'rejected' FROM passkey_accounts a JOIN passkey_credentials c ON c.account_id=a.id WHERE a.request_id=?", time.Now().Unix(), requestID); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_accounts WHERE request_id=?", requestID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) PasskeyByCredential(ctx context.Context, credentialID, userHandle []byte) (PasskeyAccount, error) {
	var account PasskeyAccount
	err := s.db.QueryRowContext(ctx, "SELECT a.id, a.nickname, c.id, c.credential_json FROM passkey_credentials c JOIN passkey_accounts a ON a.id = c.account_id WHERE c.id = ? AND a.id = ?", credentialID, string(userHandle)).Scan(&account.ID, &account.Nickname, &account.CredentialID, &account.CredentialJSON)
	if errors.Is(err, sql.ErrNoRows) {
		var status string
		err = s.db.QueryRowContext(ctx, "SELECT account_id,nickname,credential_id,credential_json,status FROM retired_passkeys WHERE credential_id=? AND account_id=?", credentialID, string(userHandle)).Scan(&account.ID, &account.Nickname, &account.CredentialID, &account.CredentialJSON, &status)
		if errors.Is(err, sql.ErrNoRows) {
			return account, ErrNotFound
		}
		account.Rejected = err == nil && status == "rejected"
		account.Blacklisted = err == nil && status == "blacklisted"
	}
	return account, err
}

func tokenHash(token string) []byte { hash := sha256.Sum256([]byte(token)); return hash[:] }

func (s *Store) SavePasskeyCeremony(ctx context.Context, token, previous, kind string, payload []byte, expires time.Time) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE expires_at <= ? OR token_hash = ?", time.Now().Unix(), tokenHash(previous)); err != nil {
		return err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM passkey_ceremonies").Scan(&count); err != nil {
		return err
	}
	if count >= 512 {
		return ErrCeremonyCapacity
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO passkey_ceremonies(token_hash, kind, payload, expires_at) VALUES(?, ?, ?, ?)", tokenHash(token), kind, payload, expires.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ConsumePasskeyCeremony(ctx context.Context, token, kind string) ([]byte, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var payload []byte
	hash := tokenHash(token)
	err = tx.QueryRowContext(ctx, "SELECT payload FROM passkey_ceremonies WHERE token_hash = ? AND kind = ? AND expires_at > ?", hash, kind, time.Now().Unix()).Scan(&payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE token_hash = ?", hash); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return payload, nil
}

func (s *Store) FinishPasskeyLogin(ctx context.Context, account PasskeyAccount, credentialJSON []byte, token string, expires time.Time) (Member, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Member{}, err
	}
	defer tx.Rollback()
	var member Member
	err = tx.QueryRowContext(ctx, "SELECT m.id, m.display_name, m.enabled, m.created_at, m.updated_at, m.is_admin FROM passkey_accounts a JOIN members m ON m.id = a.member_id WHERE a.id = ?", account.ID).Scan(&member.ID, &member.DisplayName, &member.Enabled, &member.CreatedAt, &member.UpdatedAt, &member.IsAdmin)
	if errors.Is(err, sql.ErrNoRows) {
		return member, ErrNotApproved
	} else if err != nil {
		return member, err
	}
	if err = accountAllowed(ctx, tx, member.ID); err != nil {
		return member, err
	}
	result, err := tx.ExecContext(ctx, "UPDATE passkey_credentials SET credential_json = ? WHERE id = ? AND account_id = ? AND credential_json = ?", credentialJSON, account.CredentialID, account.ID, account.CredentialJSON)
	if err = changed(result, err); errors.Is(err, ErrNotFound) {
		return member, ErrPasskeyChanged
	} else if err != nil {
		return member, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_sessions WHERE expires_at <= ?", time.Now().Unix()); err != nil {
		return member, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO passkey_sessions(token_hash, account_id, expires_at) VALUES(?, ?, ?)", tokenHash(token), account.ID, expires.Unix()); err != nil {
		return member, err
	}
	return member, tx.Commit()
}

func (s *Store) PasskeySession(ctx context.Context, token string) (Member, int64, error) {
	var member Member
	var expires int64
	err := s.db.QueryRowContext(ctx, "SELECT m.id, m.display_name, m.enabled, m.created_at, m.updated_at, m.is_admin, s.expires_at FROM passkey_sessions s JOIN passkey_accounts a ON a.id = s.account_id JOIN members m ON m.id = a.member_id WHERE s.token_hash = ? AND s.expires_at > ?", tokenHash(token), time.Now().Unix()).Scan(&member.ID, &member.DisplayName, &member.Enabled, &member.CreatedAt, &member.UpdatedAt, &member.IsAdmin, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return member, expires, ErrNotFound
	}
	return member, expires, err
}

func (s *Store) DeletePasskeySession(ctx context.Context, token string) error {
	_, err := s.write(ctx, "DELETE FROM passkey_sessions WHERE token_hash = ?", tokenHash(token))
	return err
}
