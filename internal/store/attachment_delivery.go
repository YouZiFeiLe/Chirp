package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

// A receipt acknowledges this entry's verified local copy, never somebody
// else's. Keeping received rows makes a lost receipt response safely retryable.
func (s *Store) ReceiveAttachment(ctx context.Context, member Member, roomID, entryID, id, digest string) (Attachment, error) {
	if !ValidRoomID(roomID) || !ValidEntryID(entryID) || !ValidAttachmentID(id) || !ValidCiphertextDigest(digest) {
		return Attachment{}, ErrAttachmentInvalid
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Attachment{}, err
	}
	defer tx.Rollback()
	identity := AdmissionIdentity(member, entryID)
	allowed, err := admissionInTx(ctx, tx, roomID, identity)
	if err != nil {
		return Attachment{}, err
	}
	if !allowed {
		return Attachment{}, ErrAdmissionChanged
	}
	a, err := scanAttachment(tx.QueryRowContext(ctx, "SELECT "+attachmentColumns+" FROM room_attachments f WHERE f.id=? AND f.room_id=?", id, roomID))
	if err != nil {
		return Attachment{}, err
	}
	var state string
	if err = tx.QueryRowContext(ctx, "SELECT state FROM attachment_recipients WHERE attachment_id=? AND identity=?", id, identity).Scan(&state); errors.Is(err, sql.ErrNoRows) || state == "skipped" {
		return Attachment{}, ErrNotFound
	} else if err != nil {
		return Attachment{}, err
	}
	if a.Digest != digest {
		return Attachment{}, ErrAttachmentInvalid
	}
	if state == "received" && a.CompletedAt > 0 {
		return a.PublicState(time.Now()), tx.Commit()
	}
	if a.State != AttachmentCompleted || a.ExpiresAt <= time.Now().Unix() {
		return Attachment{}, ErrAttachmentConflict
	}
	if _, err = tx.ExecContext(ctx, "UPDATE attachment_recipients SET state='received' WHERE attachment_id=? AND identity=? AND state='pending'", id, identity); err != nil {
		return Attachment{}, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE room_attachments SET revision=revision+1,updated_at=? WHERE id=?", time.Now().Unix(), id); err != nil {
		return Attachment{}, err
	}
	a, err = finishAttachmentDelivery(ctx, tx, id)
	if err != nil {
		return Attachment{}, err
	}
	return a, tx.Commit()
}

func finishAttachmentDelivery(ctx context.Context, tx *sql.Tx, id string) (Attachment, error) {
	now := time.Now().Unix()
	_, err := tx.ExecContext(ctx, `UPDATE room_attachments SET state='delivered',revision=revision+1,updated_at=?,terminal_at=?
        WHERE id=? AND state='completed' AND NOT EXISTS(SELECT 1 FROM attachment_recipients WHERE attachment_id=? AND state='pending')`, now, now, id, id)
	if err != nil {
		return Attachment{}, err
	}
	return scanAttachment(tx.QueryRowContext(ctx, "SELECT "+attachmentColumns+" FROM room_attachments f WHERE f.id=?", id))
}

const attachmentRecipientAllowed = `EXISTS(SELECT 1 FROM room_admissions a JOIN members m ON m.id=a.member_id
    JOIN room_attachments f ON f.id=p.attachment_id JOIN room_settings r ON r.room_id=f.room_id
    WHERE p.identity=a.member_id||'.'||a.login_id||'.'||a.entry_id AND a.room_id=f.room_id
    AND a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>? AND r.deleted=0)`

func (s *Store) SkipAttachmentRecipients(ctx context.Context, identities []string) ([]Attachment, error) {
	if len(identities) == 0 {
		return nil, nil
	}
	args := make([]any, len(identities))
	for i, identity := range identities {
		args[i] = identity
	}
	return s.skipAttachmentRecipients(ctx, "p.identity IN ("+strings.TrimSuffix(strings.Repeat("?,", len(args)), ",")+")", args...)
}

func (s *Store) skipInactiveAttachmentRecipients(ctx context.Context) ([]Attachment, error) {
	now := time.Now().Unix()
	return s.skipAttachmentRecipients(ctx, "NOT "+attachmentRecipientAllowed, now, now)
}

func (s *Store) skipAttachmentRecipients(ctx context.Context, condition string, args ...any) ([]Attachment, error) {
	// Healthy idle rooms don't acquire the SQLite write lock on every tick.
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT p.attachment_id FROM attachment_recipients p
        JOIN room_attachments f ON f.id=p.attachment_id WHERE p.state='pending'
        AND f.state NOT IN ('cancelled','expired','delivered') AND `+condition, args...)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil || len(ids) == 0 {
		return nil, err
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var changed []Attachment
	for _, id := range ids {
		params := append([]any{id}, args...)
		result, err := tx.ExecContext(ctx, "UPDATE attachment_recipients AS p SET state='skipped' WHERE p.attachment_id=? AND p.state='pending' AND "+condition, params...)
		if err != nil {
			return nil, err
		}
		if n, _ := result.RowsAffected(); n == 0 {
			continue
		}
		if _, err = tx.ExecContext(ctx, "UPDATE room_attachments SET revision=revision+1,updated_at=? WHERE id=?", time.Now().Unix(), id); err != nil {
			return nil, err
		}
		a, err := finishAttachmentDelivery(ctx, tx, id)
		if err != nil {
			return nil, err
		}
		changed = append(changed, a)
	}
	return changed, tx.Commit()
}

// All attachment connections ended with the old API process. A restart cannot
// re-enrol those entries, even if their room admission hasn't expired yet.
func (s *Store) ResetAttachmentTransfers(ctx context.Context) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "UPDATE attachment_recipients SET state='skipped' WHERE state='pending'"); err != nil {
		return err
	}
	now := time.Now().Unix()
	if _, err = tx.ExecContext(ctx, `UPDATE room_attachments SET state=CASE WHEN completed_at>0 THEN 'delivered' ELSE 'cancelled' END,
        revision=revision+1,updated_at=?,terminal_at=? WHERE state NOT IN ('cancelled','expired','delivered')`, now, now); err != nil {
		return err
	}
	return tx.Commit()
}
