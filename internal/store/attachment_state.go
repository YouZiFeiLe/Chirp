package store

import (
	"context"
	"errors"
	"strings"
	"time"
)

// State changes serialize with chunk commits and admission revocation through
// SQLite's write transaction. Completed content cannot be withdrawn by cancel.
func (s *Store) SetAttachmentState(ctx context.Context, member Member, roomID, entryID, id string, state AttachmentState) (Attachment, error) {
	if !ValidAttachmentID(id) || !ValidRoomID(roomID) || !ValidEntryID(entryID) || (state != AttachmentPaused && state != AttachmentCancelled && state != AttachmentCompleted) {
		return Attachment{}, ErrAttachmentInvalid
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Attachment{}, err
	}
	defer tx.Rollback()
	a, err := scanAttachment(tx.QueryRowContext(ctx, "SELECT "+attachmentColumns+" FROM room_attachments f WHERE f.id=? AND f.room_id=?", id, roomID))
	if err != nil {
		return Attachment{}, err
	}
	if a.Owner != AdmissionIdentity(member, entryID) {
		return Attachment{}, ErrNotFound
	}
	allowed, err := admissionInTx(ctx, tx, roomID, a.Owner)
	if err != nil {
		return Attachment{}, err
	}
	if !allowed {
		return Attachment{}, ErrAdmissionChanged
	}
	if a.State == AttachmentCompleted || a.State.Terminal() || a.ExpiresAt <= time.Now().Unix() {
		if state == AttachmentCompleted && a.CompletedAt == 0 {
			return Attachment{}, ErrAttachmentConflict
		}
		return a.PublicState(time.Now()), tx.Commit()
	}
	if state == AttachmentCompleted && a.Uploaded != a.ChunkCount() {
		return Attachment{}, ErrAttachmentConflict
	}
	if a.State == state {
		return a, tx.Commit()
	}
	a.State = state
	a.Revision++
	a.UpdatedAt = time.Now().Unix()
	if state.Terminal() {
		a.TerminalAt = a.UpdatedAt
	}
	if state == AttachmentCompleted {
		a.CompletedAt = a.UpdatedAt
		a.ExpiresAt = time.Now().Add(AttachmentDeliveryTTL).Unix()
	}
	_, err = tx.ExecContext(ctx, `UPDATE room_attachments SET state=?,revision=?,updated_at=?,completed_at=?,terminal_at=?,expires_at=? WHERE id=?`, a.State, a.Revision, a.UpdatedAt, a.CompletedAt, a.TerminalAt, a.ExpiresAt, a.ID)
	if err != nil {
		return Attachment{}, err
	}
	if state == AttachmentCompleted {
		a, err = finishAttachmentDelivery(ctx, tx, id)
		if err != nil {
			return Attachment{}, err
		}
	}
	return a, tx.Commit()
}

// A single batched read discovers expired, abandoned and inactive uploads. Only
// actual transitions acquire a write lock; a healthy idle room writes nothing.
func (s *Store) ReconcileAttachments(ctx context.Context) ([]Attachment, error) {
	changed, err := s.skipInactiveAttachmentRecipients(ctx)
	if err != nil {
		return nil, err
	}
	now := time.Now().Unix()
	idle := time.Now().Add(-30 * time.Second).Unix()
	const active = "f.state IN ('reserved','uploading','paused')"
	condition := `f.state NOT IN ('cancelled','expired','delivered') AND (f.expires_at<=? OR (` + active + ` AND NOT ` + attachmentOwnerAllowed + `) OR (f.state IN ('reserved','uploading') AND f.updated_at<=?))`
	args := []any{now, now, now, idle}
	rows, err := s.db.QueryContext(ctx, "SELECT f.id FROM room_attachments f WHERE "+condition, args...)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		// Recompute the transition under the write lock: a concurrent complete
		// must survive an uploader leaving immediately afterwards.
		expression := `CASE WHEN f.expires_at<=? THEN 'expired' WHEN ` + active + ` AND NOT ` + attachmentOwnerAllowed + ` THEN 'cancelled' ELSE 'paused' END`
		terminal := `CASE WHEN f.expires_at<=? OR (` + active + ` AND NOT ` + attachmentOwnerAllowed + `) THEN ? ELSE 0 END`
		query := `UPDATE room_attachments AS f SET state=` + expression + `,revision=revision+1,terminal_at=` + terminal + ` WHERE f.id=? AND ` + condition + ` RETURNING ` + strings.ReplaceAll(attachmentColumns, "f.", "")
		params := []any{now, now, now, now, now, now, now, id, now, now, now, idle}
		tx, err := s.beginWrite(ctx)
		if err != nil {
			return nil, err
		}
		a, err := scanAttachment(tx.QueryRowContext(ctx, query, params...))
		if err != nil {
			tx.Rollback()
			if errors.Is(err, ErrNotFound) {
				continue
			}
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		changed = append(changed, a)
	}
	return changed, nil
}

// Terminal tombstones remain briefly for the original recipients to observe.
// No remaining valid recipient means neither ciphertext nor metadata is kept.
func (s *Store) ReapAttachments(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `DELETE FROM room_attachments AS f WHERE
        (state IN ('cancelled','expired','delivered') AND terminal_at<=?) OR NOT EXISTS(
        SELECT 1 FROM attachment_recipients p JOIN room_admissions a ON p.identity=a.member_id||'.'||a.login_id||'.'||a.entry_id
        JOIN members m ON m.id=a.member_id JOIN room_settings r ON r.room_id=a.room_id
        WHERE p.attachment_id=f.id AND a.room_id=f.room_id AND a.expires_at>? AND m.login_id=a.login_id
        AND m.enabled=1 AND m.credential_expires_at>? AND r.deleted=0) RETURNING id`, time.Now().Add(-AttachmentTerminalRetention).Unix(), time.Now().Unix(), time.Now().Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
func (s *Store) AttachmentIDs(ctx context.Context) (map[string]bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM room_attachments WHERE state NOT IN ('cancelled','expired','delivered')`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		result[id] = true
	}
	return result, rows.Err()
}
