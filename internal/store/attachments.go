package store

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"slices"
	"time"
)

// Network requests are independent of the 256 KiB authenticated encryption records.
const AttachmentProtocol = 3
const AttachmentChunkBytes int64 = 1024 * 1024
const MaxAttachmentBytes int64 = 100*1024*1024 + 8192
const AttachmentRoomQuota int64 = 512 * 1024 * 1024
const AttachmentTotalQuota int64 = 4 * 1024 * 1024 * 1024
const AttachmentUploadTTL = 15 * time.Minute
const AttachmentDeliveryTTL = 15 * time.Minute
const AttachmentTerminalRetention = 5 * time.Minute

var ErrAttachmentInvalid = errors.New("invalid attachment")
var ErrAttachmentQuota = errors.New("attachment quota exceeded")
var ErrAttachmentConflict = errors.New("attachment upload state changed")

type AttachmentState string

const (
	AttachmentReserved  AttachmentState = "reserved"
	AttachmentUploading AttachmentState = "uploading"
	AttachmentPaused    AttachmentState = "paused"
	AttachmentCompleted AttachmentState = "completed"
	AttachmentDelivered AttachmentState = "delivered"
	AttachmentCancelled AttachmentState = "cancelled"
	AttachmentExpired   AttachmentState = "expired"
)

func (s AttachmentState) Terminal() bool {
	return s == AttachmentCancelled || s == AttachmentExpired || s == AttachmentDelivered
}

// Only randomized ciphertext hashes are stored, never plaintext hashes, file
// names, content types, decryption keys or recoverable key wrappers.
type Attachment struct {
	ID          string          `json:"id"`
	RoomID      string          `json:"room_id"`
	Owner       string          `json:"-"`
	Size        int64           `json:"ciphertext_size"`
	Uploaded    int64           `json:"uploaded_chunks"`
	Digest      string          `json:"ciphertext_sha256"`
	State       AttachmentState `json:"state"`
	Revision    uint64          `json:"revision"`
	CreatedAt   int64           `json:"-"`
	UpdatedAt   int64           `json:"updated_at"`
	CompletedAt int64           `json:"completed_at"`
	TerminalAt  int64           `json:"-"`
	ExpiresAt   int64           `json:"expires_at"`
}

const attachmentColumns = "f.id,f.room_id,f.owner_identity,f.ciphertext_size,f.uploaded_chunks,f.ciphertext_sha256,f.state,f.revision,f.created_at,f.updated_at,f.completed_at,f.terminal_at,f.expires_at"

type attachmentScanner interface{ Scan(...any) error }

func scanAttachment(row attachmentScanner) (Attachment, error) {
	var a Attachment
	err := row.Scan(&a.ID, &a.RoomID, &a.Owner, &a.Size, &a.Uploaded, &a.Digest, &a.State, &a.Revision, &a.CreatedAt, &a.UpdatedAt, &a.CompletedAt, &a.TerminalAt, &a.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrNotFound
	}
	return a, err
}
func validHex(value string, bytes int) bool {
	data, err := hex.DecodeString(value)
	return err == nil && len(data) == bytes && hex.EncodeToString(data) == value
}
func ValidAttachmentID(id string) bool         { return validHex(id, 16) }
func ValidCiphertextDigest(digest string) bool { return validHex(digest, 32) }
func (a Attachment) ChunkCount() int64 {
	return (a.Size + AttachmentChunkBytes - 1) / AttachmentChunkBytes
}
func (a Attachment) ChunkSize(index int64) int64 {
	if index < 0 || index >= a.ChunkCount() {
		return 0
	}
	return min(AttachmentChunkBytes, a.Size-index*AttachmentChunkBytes)
}
func (a Attachment) PublicState(now time.Time) Attachment {
	if a.ExpiresAt <= now.Unix() && !a.State.Terminal() {
		a.State = AttachmentExpired
	}
	return a
}

const attachmentOwnerAllowed = `EXISTS(SELECT 1 FROM room_admissions a JOIN members m ON m.id=a.member_id
    JOIN room_settings r ON r.room_id=a.room_id WHERE a.member_id||'.'||a.login_id||'.'||a.entry_id=f.owner_identity
    AND a.room_id=f.room_id AND a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1
    AND m.credential_expires_at>? AND r.deleted=0)`

func admissionInTx(ctx context.Context, tx *sql.Tx, roomID, identity string) (bool, error) {
	member, login, entry, ok := SplitAdmissionIdentity(identity)
	if !ok {
		return false, nil
	}
	var allowed bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM room_admissions a JOIN members m ON m.id=a.member_id
        JOIN room_settings r ON r.room_id=a.room_id WHERE a.member_id=? AND a.login_id=? AND a.entry_id=? AND a.room_id=?
        AND a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>? AND r.deleted=0)`, member, login, entry, roomID, time.Now().Unix(), time.Now().Unix()).Scan(&allowed)
	return allowed, err
}

func (s *Store) CreateAttachment(ctx context.Context, member Member, roomID, entryID, id string, size int64, digest string, recipients []string, online ...map[string]bool) (Attachment, error) {
	if !ValidAttachmentID(id) || !ValidRoomID(roomID) || !ValidEntryID(entryID) || !ValidCiphertextDigest(digest) || size < 16 || size > MaxAttachmentBytes || len(recipients) > 256 {
		return Attachment{}, ErrAttachmentInvalid
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Attachment{}, err
	}
	defer tx.Rollback()
	owner := AdmissionIdentity(member, entryID)
	allowed, err := admissionInTx(ctx, tx, roomID, owner)
	if err != nil {
		return Attachment{}, err
	}
	if !allowed {
		return Attachment{}, ErrAdmissionChanged
	}
	seen := map[string]bool{owner: true}
	for _, id := range recipients {
		seen[id] = true
	}
	if len(seen) > 256 {
		return Attachment{}, ErrAttachmentInvalid
	}
	existing, err := scanAttachment(tx.QueryRowContext(ctx, "SELECT "+attachmentColumns+" FROM room_attachments f WHERE f.id=?", id))
	if err == nil {
		if existing.Owner != owner || existing.RoomID != roomID || existing.Size != size || existing.Digest != digest {
			return Attachment{}, ErrAttachmentConflict
		}
		rows, err := tx.QueryContext(ctx, "SELECT identity FROM attachment_recipients WHERE attachment_id=?", id)
		if err != nil {
			return Attachment{}, err
		}
		var previous []string
		for rows.Next() {
			var identity string
			if err := rows.Scan(&identity); err != nil {
				rows.Close()
				return Attachment{}, err
			}
			previous = append(previous, identity)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return Attachment{}, err
		}
		if len(previous) != len(seen) {
			return Attachment{}, ErrAttachmentConflict
		}
		for _, id := range previous {
			if !seen[id] {
				return Attachment{}, ErrAttachmentConflict
			}
		}
		return existing.PublicState(time.Now()), tx.Commit()
	}
	if !errors.Is(err, ErrNotFound) {
		return Attachment{}, err
	}
	var total, roomSize, count, totalCount int64
	err = tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(CASE WHEN state NOT IN ('cancelled','expired','delivered') THEN ciphertext_size ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN room_id=? AND state NOT IN ('cancelled','expired','delivered') THEN ciphertext_size ELSE 0 END),0),
        COUNT(CASE WHEN room_id=? THEN 1 END),COUNT(*) FROM room_attachments`, roomID, roomID).Scan(&total, &roomSize, &count, &totalCount)
	if err != nil {
		return Attachment{}, err
	}
	if total+size > AttachmentTotalQuota || roomSize+size > AttachmentRoomQuota || count >= 256 || totalCount >= 4096 {
		return Attachment{}, ErrAttachmentQuota
	}
	for id := range seen {
		ok, err := admissionInTx(ctx, tx, roomID, id)
		if err != nil {
			return Attachment{}, err
		}
		if !ok {
			return Attachment{}, ErrAdmissionChanged
		}
	}
	now := time.Now().Unix()
	a := Attachment{ID: id, RoomID: roomID, Owner: owner, Size: size, Digest: digest, State: AttachmentReserved, Revision: 1, CreatedAt: now, UpdatedAt: now, ExpiresAt: time.Now().Add(AttachmentUploadTTL).Unix()}
	_, err = tx.ExecContext(ctx, `INSERT INTO room_attachments(id,room_id,owner_identity,ciphertext_size,ciphertext_sha256,state,created_at,updated_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?)`, id, roomID, owner, size, digest, a.State, now, now, a.ExpiresAt)
	if err != nil {
		return Attachment{}, err
	}
	audience := make([]string, 0, len(seen))
	for id := range seen {
		audience = append(audience, id)
	}
	slices.Sort(audience)
	for _, id := range audience {
		state := "pending"
		if id == owner {
			state = "received" // The sender already owns the authenticated local copy.
		} else if len(online) != 0 && !online[0][id] {
			state = "skipped"
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO attachment_recipients(attachment_id,identity,state) VALUES(?,?,?)`, a.ID, id, state); err != nil {
			return Attachment{}, err
		}
	}
	return a, tx.Commit()
}

// Terminal lookups still require a current, exact admission and immutable ACL.
func (s *Store) Attachment(ctx context.Context, member Member, roomID, entryID, id string) (Attachment, error) {
	if !ValidRoomID(roomID) || !ValidEntryID(entryID) || !ValidAttachmentID(id) {
		return Attachment{}, ErrNotFound
	}
	list, err := s.attachmentQuery(ctx, member, roomID, entryID, id)
	if err != nil {
		return Attachment{}, err
	}
	if len(list) != 1 {
		return Attachment{}, ErrNotFound
	}
	return list[0], nil
}
func (s *Store) Attachments(ctx context.Context, member Member, roomID, entryID string) ([]Attachment, error) {
	if !ValidRoomID(roomID) || !ValidEntryID(entryID) {
		return nil, ErrAdmissionChanged
	}
	if ok, err := s.AdmissionAllowed(ctx, roomID, AdmissionIdentity(member, entryID)); err != nil || !ok {
		if err != nil {
			return nil, err
		}
		return nil, ErrAdmissionChanged
	}
	return s.attachmentQuery(ctx, member, roomID, entryID, "")
}
func (s *Store) attachmentQuery(ctx context.Context, member Member, roomID, entryID, id string) ([]Attachment, error) {
	query := "SELECT " + attachmentColumns + ` FROM room_attachments f JOIN attachment_recipients p ON p.attachment_id=f.id
        JOIN room_admissions a ON a.entry_id=? AND a.member_id=? AND a.login_id=? AND a.room_id=f.room_id
        JOIN members m ON m.id=a.member_id JOIN room_settings r ON r.room_id=f.room_id
        WHERE f.room_id=? AND p.identity=? AND p.state!='skipped' AND a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1
        AND m.credential_expires_at>? AND r.deleted=0`
	args := []any{entryID, member.ID, member.LoginID, roomID, AdmissionIdentity(member, entryID), time.Now().Unix(), time.Now().Unix()}
	if id != "" {
		query += " AND f.id=?"
		args = append(args, id)
	}
	query += " ORDER BY f.id"
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []Attachment{}
	for rows.Next() {
		a, err := scanAttachment(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, a.PublicState(time.Now()))
	}
	return list, rows.Err()
}
func (s *Store) AttachmentDigests(ctx context.Context, a Attachment) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT chunk_index,sha256 FROM attachment_chunks WHERE attachment_id=? AND chunk_index<? ORDER BY chunk_index`, a.ID, a.Uploaded)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []string{}
	for rows.Next() {
		var index int
		var hash string
		if err := rows.Scan(&index, &hash); err != nil {
			return nil, err
		}
		if index != len(result) || !ValidCiphertextDigest(hash) {
			return nil, ErrAttachmentConflict
		}
		result = append(result, hash)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if int64(len(result)) != a.Uploaded {
		return nil, ErrAttachmentConflict
	}
	return result, nil
}
func (s *Store) AdvanceAttachment(ctx context.Context, a Attachment, digest string) error {
	if !ValidCiphertextDigest(digest) || a.Uploaded >= a.ChunkCount() {
		return ErrAttachmentInvalid
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := time.Now().Unix()
	result, err := tx.ExecContext(ctx, `UPDATE room_attachments AS f SET uploaded_chunks=uploaded_chunks+1,state='uploading',revision=revision+1,updated_at=?
        WHERE id=? AND uploaded_chunks=? AND expires_at>? AND state IN ('reserved','uploading','paused') AND `+attachmentOwnerAllowed, now, a.ID, a.Uploaded, now, now, now)
	if err != nil {
		return err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return ErrAttachmentConflict
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO attachment_chunks(attachment_id,chunk_index,sha256) VALUES(?,?,?)`, a.ID, a.Uploaded, digest); err != nil {
		return err
	}
	return tx.Commit()
}
