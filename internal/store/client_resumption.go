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

var ErrResumptionProof = errors.New("invalid or expired resumption proof")

func issueClientResumption(ctx context.Context, tx *sql.Tx, member Member, origin, platform string) (string, error) {
	token, err := randomID(identity.ResumptionTokenPrefix, 32)
	if err != nil {
		return "", err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO client_login_resumptions(member_id, token_hash, login_id, origin, platform)
		VALUES(?,?,?,?,?) ON CONFLICT(member_id) DO UPDATE SET token_hash=excluded.token_hash, login_id=excluded.login_id,
		origin=excluded.origin, platform=excluded.platform, challenge='', challenge_expires_at=0`,
		member.ID, tokenHash(token), member.LoginID, origin, platform)
	return token, err
}

type clientResumption struct {
	login              ClientLogin
	origin, challenge  string
	challengeExpiresAt int64
}

func readClientResumption(ctx context.Context, tx *sql.Tx, token, origin string, client ClientIdentity) (clientResumption, error) {
	var a clientResumption
	raw, ok := strings.CutPrefix(token, identity.ResumptionTokenPrefix)
	if !ok {
		// Handles issued by the earlier Apple protocol identify its signing domain.
		raw, ok = strings.CutPrefix(token, "resume_")
	}
	origin, err := identity.NormalizeOrigin(origin)
	if !ok || !validCodeChallenge(raw) || err != nil {
		return a, ErrInvalidAuthorization
	}
	if _, err = checkClientVersion(ctx, tx, client); err != nil {
		return a, err
	}
	var device []byte
	m := &a.login.Member
	now := time.Now()
	err = tx.QueryRowContext(ctx, `SELECT m.id, m.display_name, m.enabled, m.created_at, m.updated_at, m.last_login_at,
		m.login_id, m.credential_expires_at, i.device_identity, r.challenge, r.challenge_expires_at
		FROM client_login_resumptions r JOIN members m ON m.id=r.member_id AND m.login_id=r.login_id
		JOIN member_identities i ON i.member_id=m.id AND i.login_id=m.login_id
		WHERE r.token_hash=? AND r.origin=? AND r.platform=? AND m.credential_expires_at>?`,
		tokenHash(token), origin, client.Platform, now.Unix()).Scan(&m.ID, &m.DisplayName, &m.Enabled, &m.CreatedAt, &m.UpdatedAt,
		&m.LastLoginAt, &m.LoginID, &m.CredentialExpiresAt, &device, &a.challenge, &a.challengeExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return a, ErrInvalidAuthorization
	}
	if err != nil {
		return a, err
	}
	if err = accountAllowed(ctx, tx, m.ID); err != nil {
		return a, err
	}
	if json.Unmarshal(device, &a.login.Device) != nil || a.login.Device.Validate(now) != nil {
		return a, ErrDeviceIdentity
	}
	blocked, err := deviceBlocked(ctx, tx, a.login.Device.LeafKey())
	if err != nil {
		return a, err
	}
	if blocked {
		return a, ErrBlacklisted
	}
	a.origin = origin
	a.login.ExpiresAt = m.CredentialExpiresAt
	return a, nil
}

func (s *Store) BeginClientResumption(ctx context.Context, token, origin string, client ClientIdentity) (string, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	a, err := readClientResumption(ctx, tx, token, origin, client)
	if err != nil {
		return "", err
	}
	now := time.Now()
	if a.challenge == "" || a.challengeExpiresAt <= now.Unix() {
		a.challenge, err = randomID("", 32)
		if err != nil {
			return "", err
		}
		_, err = tx.ExecContext(ctx, "UPDATE client_login_resumptions SET challenge=?, challenge_expires_at=? WHERE member_id=?",
			a.challenge, min(a.login.ExpiresAt, now.Add(time.Minute).Unix()), a.login.Member.ID)
		if err != nil {
			return "", err
		}
	}
	return a.challenge, tx.Commit()
}

// Replace only the bearer. A retry after a lost response can sign a fresh challenge.
// The login generation, room sequence and original credential expiry stay fixed.
func (s *Store) CompleteClientResumption(ctx context.Context, token, origin, signature string, client ClientIdentity) (ClientLogin, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return ClientLogin{}, err
	}
	defer tx.Rollback()
	a, err := readClientResumption(ctx, tx, token, origin, client)
	if err != nil {
		return ClientLogin{}, err
	}
	m := a.login.Member
	message := identity.ResumptionMessage(a.origin, client.Platform, m.ParticipantIdentity(), token, a.challenge, a.login.Device)
	if a.challenge == "" || a.challengeExpiresAt <= time.Now().Unix() || !identity.Verify(a.login.Device.LeafKey(), signature, message) {
		return ClientLogin{}, ErrResumptionProof
	}
	bearer, hash, err := newCredential()
	if err != nil {
		return ClientLogin{}, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE members SET credential_hash=? WHERE id=? AND login_id=?", hash, m.ID, m.LoginID); err != nil {
		return ClientLogin{}, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE client_login_resumptions SET challenge='', challenge_expires_at=0 WHERE member_id=?", m.ID); err != nil {
		return ClientLogin{}, err
	}
	a.login.Credential = bearer
	return a.login, tx.Commit()
}

// Migrate only grants that were still valid. Discard outstanding challenges so
// the original device must request a fresh proof. The member keeps its bearer and deadline.
func migrateLegacyLoginResumptions(ctx context.Context, tx *sql.Tx) error {
	var columns, expiryColumns int
	err := tx.QueryRowContext(ctx, "SELECT count(*), count(*) FILTER (WHERE name='expires_at') FROM pragma_table_info('apple_login_resumptions')").Scan(&columns, &expiryColumns)
	if err != nil || columns == 0 {
		return err
	}
	query := `INSERT INTO client_login_resumptions(member_id, token_hash, login_id, origin, platform)
		SELECT r.member_id, r.token_hash, r.login_id, r.origin, r.platform
		FROM apple_login_resumptions r JOIN members m ON m.id=r.member_id AND m.login_id=r.login_id
		WHERE m.enabled=1 AND m.credential_expires_at>unixepoch()`
	if expiryColumns != 0 {
		query += " AND r.expires_at>unixepoch()"
	}
	query += ` ON CONFLICT(member_id) DO UPDATE SET token_hash=excluded.token_hash, login_id=excluded.login_id,
		origin=excluded.origin, platform=excluded.platform, challenge='', challenge_expires_at=0
		WHERE client_login_resumptions.login_id<>excluded.login_id`
	if _, err = tx.ExecContext(ctx, query); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, "DROP TABLE apple_login_resumptions")
	return err
}
