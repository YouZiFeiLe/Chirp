package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

var ErrAdminNotInitialized = errors.New("initialize the first administrator with admin bootstrap first")
var ErrAdminInitialized = errors.New("the first administrator has already been initialized")
var ErrLastAdministrator = errors.New("the last enabled administrator cannot be disabled, deleted or demoted")

// BootstrapAdministrator is a local CLI operation, never an HTTP endpoint.
// The registration approval and the one-time marker commit in one writer transaction.
func (s *Store) BootstrapAdministrator(ctx context.Context, requestID string) (Member, error) {
	return s.approveAdministrator(ctx, requestID, true)
}

// GrantAdministratorRegistration supports local recovery if an administrator loses a passkey.
func (s *Store) GrantAdministratorRegistration(ctx context.Context, requestID string) (Member, error) {
	return s.approveAdministrator(ctx, requestID, false)
}

func (s *Store) approveAdministrator(ctx context.Context, requestID string, bootstrap bool) (Member, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Member{}, err
	}
	defer tx.Rollback()
	var initialized bool
	if err := tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM administrator_bootstrap)").Scan(&initialized); err != nil {
		return Member{}, err
	}
	if bootstrap && initialized {
		return Member{}, ErrAdminInitialized
	}
	if !bootstrap && !initialized {
		return Member{}, ErrAdminNotInitialized
	}
	member, err := approveRegistration(ctx, tx, requestID)
	if err != nil {
		return Member{}, err
	}
	if _, err := tx.ExecContext(ctx, "UPDATE members SET is_admin = 1 WHERE id = ?", member.ID); err != nil {
		return Member{}, err
	}
	if bootstrap {
		if _, err := tx.ExecContext(ctx, "INSERT INTO administrator_bootstrap(id, initialized_at) VALUES(1, ?)", time.Now().UTC().Format(time.RFC3339)); err != nil {
			return Member{}, err
		}
	}
	member.IsAdmin = true
	return member, tx.Commit()
}

// SetAdministrator requires host access. Role changes invalidate browser sessions.
func (s *Store) SetAdministrator(ctx context.Context, id string, administrator bool) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if !administrator {
		if err := protectAdministrator(ctx, tx, id); err != nil {
			return err
		}
	}
	result, err := tx.ExecContext(ctx, `UPDATE members SET is_admin = ?, updated_at = ? WHERE id = ? AND enabled = 1
		AND EXISTS(SELECT 1 FROM passkey_accounts a JOIN passkey_credentials c ON c.account_id = a.id WHERE a.member_id = members.id)`, administrator, time.Now().UTC().Format(time.RFC3339), id)
	if err := changed(result, err); err != nil {
		return err
	}
	if err := clearBrowserSessions(ctx, tx, id); err != nil {
		return err
	}
	return tx.Commit()
}

func protectAdministrator(ctx context.Context, tx *sql.Tx, id string) error {
	var last bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM members WHERE id = ? AND is_admin = 1 AND enabled = 1)
		AND (SELECT count(*) FROM members WHERE is_admin = 1 AND enabled = 1) <= 1`, id).Scan(&last)
	if err != nil {
		return err
	}
	if last {
		return ErrLastAdministrator
	}
	return nil
}

func clearBrowserSessions(ctx context.Context, tx *sql.Tx, id string) error {
	_, err := tx.ExecContext(ctx, "DELETE FROM passkey_sessions WHERE account_id IN (SELECT id FROM passkey_accounts WHERE member_id = ?)", id)
	return err
}
