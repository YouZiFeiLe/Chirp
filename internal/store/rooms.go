package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const AdmissionTTL = 30 * time.Second

var ErrAdmissionChanged = errors.New("room admission changed or expired")
var ErrInvalidRoomDescription = errors.New("room description exceeds 280 characters or contains invalid text")

func ValidRoomID(id string) bool {
	return id != "" && len(id) <= 64 && !strings.ContainsFunc(id, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-')
	})
}
func (s *Store) Rooms(ctx context.Context) ([]RoomConfig, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT room_id, display_name, description, password_hash IS NOT NULL, room_id = ?
		FROM room_settings WHERE deleted = 0 ORDER BY room_id = ? DESC, sort_order`, DefaultRoomID, DefaultRoomID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	rooms := []RoomConfig{}
	for rows.Next() {
		var r RoomConfig
		if err := rows.Scan(&r.RoomID, &r.DisplayName, &r.Description, &r.PasswordRequired, &r.IsDefault); err != nil {
			return nil, err
		}
		rooms = append(rooms, r)
	}
	return rooms, rows.Err()
}
func (s *Store) Room(ctx context.Context, id string) (RoomConfig, error) {
	cfg := RoomConfig{RoomID: id}
	if !ValidRoomID(id) {
		return cfg, ErrNotFound
	}
	err := s.db.QueryRowContext(ctx, `
		SELECT display_name, description, password_hash IS NOT NULL, room_id = ?
		FROM room_settings WHERE room_id = ? AND deleted = 0`, DefaultRoomID, id).
		Scan(&cfg.DisplayName, &cfg.Description, &cfg.PasswordRequired, &cfg.IsDefault)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrNotFound
	}
	return cfg, err
}
func (s *Store) RenameRoom(ctx context.Context, id, name string) (RoomConfig, error) {
	if !ValidRoomID(id) {
		return RoomConfig{}, ErrNotFound
	}
	name = strings.TrimSpace(name)
	if !validName(name) {
		return RoomConfig{}, ErrInvalidName
	}
	result, err := s.write(ctx, "UPDATE room_settings SET display_name = ? WHERE room_id = ? AND deleted = 0", name, id)
	if err = changed(result, err); err != nil {
		return RoomConfig{}, err
	}
	return s.Room(ctx, id)
}

func (s *Store) CreateRoom(ctx context.Context, name string) (RoomConfig, error) {
	name = strings.TrimSpace(name)
	if !validName(name) {
		return RoomConfig{}, ErrInvalidName
	}
	id, err := randomID("room_", 18)
	if err != nil {
		return RoomConfig{}, err
	}
	if _, err = s.write(ctx, "INSERT INTO room_settings(room_id,display_name) VALUES(?,?)", id, name); err != nil {
		return RoomConfig{}, err
	}
	return s.Room(ctx, id)
}

func (s *Store) SetRoomDescription(ctx context.Context, id, description string) (RoomConfig, error) {
	if !ValidRoomID(id) {
		return RoomConfig{}, ErrNotFound
	}
	description = strings.TrimSpace(strings.ReplaceAll(description, "\r\n", "\n"))
	if description == "" {
		description = DefaultRoomDescription
	}
	if !utf8.ValidString(description) || utf8.RuneCountInString(description) > 280 ||
		strings.ContainsFunc(description, func(r rune) bool { return r != '\n' && unicode.IsControl(r) }) {
		return RoomConfig{}, ErrInvalidRoomDescription
	}
	result, err := s.write(ctx, "UPDATE room_settings SET description = ? WHERE room_id = ? AND deleted = 0", description, id)
	if err = changed(result, err); err != nil {
		return RoomConfig{}, err
	}
	return s.Room(ctx, id)
}

func (s *Store) DeleteRoom(ctx context.Context, id string) error {
	if id == DefaultRoomID {
		return ErrDefaultRoom
	}
	if !ValidRoomID(id) {
		return ErrNotFound
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, "UPDATE room_settings SET deleted = 1, password_salt = NULL, password_hash = NULL WHERE room_id = ? AND deleted = 0", id)
	if err = changed(result, err); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM room_admissions WHERE room_id = ?", id); err != nil {
		return err
	}
	return tx.Commit()
}

// Deleted IDs remain as revocation tombstones, so cached media JWTs cannot
// recreate a room that escapes the continuous admission cleanup.
func (s *Store) AllRoomIDs(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT room_id FROM room_settings ORDER BY sort_order")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	ids := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

type RoomAdmission struct {
	MemberID     string `json:"-"`
	LoginID      string `json:"-"`
	RoomID       string `json:"room_id"`
	EntryID      string `json:"entry_id"`
	JoinSequence int64  `json:"join_sequence"`
	ExpiresAt    int64  `json:"admission_expires_at"`
}

func (a RoomAdmission) Identity() string { return a.MemberID + "." + a.LoginID + "." + a.EntryID }
func AdmissionIdentity(member Member, entryID string) string {
	return member.ParticipantIdentity() + "." + entryID
}
func SplitAdmissionIdentity(identity string) (memberID, loginID, entryID string, ok bool) {
	parts := strings.Split(identity, ".")
	if len(parts) != 3 || parts[0] == "" || !strings.HasPrefix(parts[1], "login_") || !ValidEntryID(parts[2]) {
		return "", "", "", false
	}
	return parts[0], parts[1], parts[2], true
}
func ValidEntryID(id string) bool {
	return len(id) == 38 && strings.HasPrefix(id, "entry_") && pkceText(id)
}

// Every writer shares the same transaction lock. Sequence checks make retries
// idempotent, and a delayed join/leave cannot replace a later admission.
// passwordRevision must come from a verified, scoped API preflight proof.
func (s *Store) JoinRoom(ctx context.Context, m Member, roomID string, sequence, passwordRevision int64) (RoomAdmission, error) {
	var a RoomAdmission
	if !ValidRoomID(roomID) {
		return a, ErrNotFound
	}
	if sequence <= 0 {
		return a, ErrAdmissionChanged
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return a, err
	}
	defer tx.Rollback()
	var exists bool
	if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM room_settings WHERE room_id = ? AND deleted = 0)", roomID).Scan(&exists); err != nil {
		return a, err
	}
	if !exists {
		return a, ErrNotFound
	}
	var currentSequence int64
	err = tx.QueryRowContext(ctx, "SELECT room_join_sequence FROM members WHERE id = ? AND login_id = ? AND enabled = 1 AND credential_expires_at > ?", m.ID, m.LoginID, time.Now().Unix()).Scan(&currentSequence)
	if errors.Is(err, sql.ErrNoRows) {
		return a, ErrAdmissionChanged
	}
	if err != nil {
		return a, err
	}
	if sequence < currentSequence {
		return a, ErrAdmissionChanged
	}
	if sequence == currentSequence {
		err = tx.QueryRowContext(ctx, "SELECT member_id, login_id, room_id, entry_id, join_sequence, expires_at FROM room_admissions WHERE member_id = ? AND login_id = ? AND room_id = ? AND join_sequence = ? AND expires_at > ?", m.ID, m.LoginID, roomID, sequence, time.Now().Unix()).Scan(&a.MemberID, &a.LoginID, &a.RoomID, &a.EntryID, &a.JoinSequence, &a.ExpiresAt)
		if errors.Is(err, sql.ErrNoRows) {
			return a, ErrAdmissionChanged
		}
		if err != nil {
			return a, err
		}
		return a, tx.Commit()
	}
	// Recheck under the same write lock as password changes. Previously admitted
	// exact retries above remain valid; an unused old proof cannot admit anyone.
	var revision int64
	if err := tx.QueryRowContext(ctx, "SELECT password_revision FROM room_settings WHERE room_id = ? AND deleted = 0", roomID).Scan(&revision); err != nil {
		return a, err
	}
	if revision != passwordRevision {
		return a, ErrRoomPasswordChanged
	}
	entry, err := randomID("entry_", 24)
	if err != nil {
		return a, err
	}
	a = RoomAdmission{m.ID, m.LoginID, roomID, entry, sequence, min(m.CredentialExpiresAt, time.Now().Add(AdmissionTTL).Unix())}
	if _, err = tx.ExecContext(ctx, "UPDATE members SET room_join_sequence = ? WHERE id = ?", sequence, m.ID); err != nil {
		return a, err
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO room_admissions(member_id,login_id,room_id,entry_id,join_sequence,expires_at) VALUES(?,?,?,?,?,?) ON CONFLICT(member_id) DO UPDATE SET login_id=excluded.login_id,room_id=excluded.room_id,entry_id=excluded.entry_id,join_sequence=excluded.join_sequence,expires_at=excluded.expires_at", a.MemberID, a.LoginID, a.RoomID, a.EntryID, a.JoinSequence, a.ExpiresAt)
	if err != nil {
		return a, err
	}
	return a, tx.Commit()
}

func (s *Store) AdmissionAllowed(ctx context.Context, roomID, identity string) (bool, error) {
	memberID, loginID, entryID, ok := SplitAdmissionIdentity(identity)
	if !ok || !ValidRoomID(roomID) {
		return false, nil
	}
	var allowed bool
	err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM room_admissions a JOIN members m ON m.id=a.member_id WHERE a.member_id=? AND a.login_id=? AND a.entry_id=? AND a.room_id=? AND a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>?)", memberID, loginID, entryID, roomID, time.Now().Unix(), time.Now().Unix()).Scan(&allowed)
	return allowed, err
}

// Renew only in the final twenty seconds of a thirty-second admission. Every
// call still reads authoritative login/entry validity; no positive auth cache.
func (s *Store) TouchAdmission(ctx context.Context, roomID, identity string) error {
	memberID, loginID, entryID, ok := SplitAdmissionIdentity(identity)
	if !ok || !ValidRoomID(roomID) {
		return ErrAdmissionChanged
	}
	now := time.Now().Unix()
	const valid = " FROM room_admissions a JOIN members m ON m.id=a.member_id WHERE a.member_id=? AND a.login_id=? AND a.entry_id=? AND a.room_id=? AND a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>?"
	var expires int64
	err := s.db.QueryRowContext(ctx, "SELECT a.expires_at"+valid, memberID, loginID, entryID, roomID, now, now).Scan(&expires)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrAdmissionChanged
	}
	if err != nil {
		return err
	}
	cutoff := now + int64((AdmissionTTL-10*time.Second)/time.Second)
	if expires > cutoff {
		return nil
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Acquiring the writer lock may outlast the remaining admission. Evaluate
	// expiry again after that wait so an expired entry can never be revived.
	now = time.Now().Unix()
	cutoff = now + int64((AdmissionTTL-10*time.Second)/time.Second)
	result, err := tx.ExecContext(ctx, "UPDATE room_admissions AS a SET expires_at=MIN(m.credential_expires_at,?) FROM members AS m WHERE m.id=a.member_id AND a.member_id=? AND a.login_id=? AND a.entry_id=? AND a.room_id=? AND a.expires_at>? AND a.expires_at<=? AND a.expires_at<MIN(m.credential_expires_at,?) AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>?", now+int64(AdmissionTTL/time.Second), memberID, loginID, entryID, roomID, now, cutoff, now+int64(AdmissionTTL/time.Second), now)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count > 0 {
		return tx.Commit()
	}
	// Another writer may already have renewed. Distinguish that from a revoke
	// or expiry racing the conditional UPDATE; never resurrect an old entry.
	err = tx.QueryRowContext(ctx, "SELECT a.expires_at"+valid, memberID, loginID, entryID, roomID, now, now).Scan(&expires)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrAdmissionChanged
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

// One read validates the monitor's entire roster against current SQLite facts.
func (s *Store) ActiveAdmissions(ctx context.Context) (map[string]string, error) {
	now := time.Now().Unix()
	rows, err := s.db.QueryContext(ctx, "SELECT a.member_id,a.login_id,a.entry_id,a.room_id FROM room_admissions a JOIN members m ON m.id=a.member_id JOIN room_settings r ON r.room_id=a.room_id WHERE a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>? AND r.deleted=0", now, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make(map[string]string)
	for rows.Next() {
		var member, login, entry, room string
		if err := rows.Scan(&member, &login, &entry, &room); err != nil {
			return nil, err
		}
		result[member+"."+login+"."+entry] = room
	}
	return result, rows.Err()
}
func (s *Store) LeaveRoom(ctx context.Context, m Member, roomID, entryID string) error {
	if !ValidRoomID(roomID) || !ValidEntryID(entryID) {
		return ErrAdmissionChanged
	}
	_, err := s.write(ctx, "DELETE FROM room_admissions WHERE member_id=? AND login_id=? AND room_id=? AND entry_id=?", m.ID, m.LoginID, roomID, entryID)
	return err
}
func (s *Store) RemoveAdmission(ctx context.Context, roomID, identity string) error {
	memberID, loginID, entryID, ok := SplitAdmissionIdentity(identity)
	if !ok || !ValidRoomID(roomID) {
		return ErrAdmissionChanged
	}
	_, err := s.write(ctx, "DELETE FROM room_admissions WHERE member_id=? AND login_id=? AND room_id=? AND entry_id=?", memberID, loginID, roomID, entryID)
	return err
}
func (s *Store) EndRoom(ctx context.Context, roomID string) error {
	if _, err := s.Room(ctx, roomID); err != nil {
		return err
	}
	_, err := s.write(ctx, "DELETE FROM room_admissions WHERE room_id=?", roomID)
	return err
}

type RoomMember struct {
	RoomID      string
	Identity    string
	DisplayName string
}

func (s *Store) ActiveRoomMembers(ctx context.Context) ([]RoomMember, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT a.room_id, m.id, a.login_id, a.entry_id, m.display_name FROM room_admissions a JOIN members m ON m.id=a.member_id WHERE a.expires_at>? AND m.login_id=a.login_id AND m.enabled=1 AND m.credential_expires_at>?", time.Now().Unix(), time.Now().Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []RoomMember{}
	for rows.Next() {
		var m RoomMember
		var id, login, entry string
		if err := rows.Scan(&m.RoomID, &id, &login, &entry, &m.DisplayName); err != nil {
			return nil, err
		}
		m.Identity = id + "." + login + "." + entry
		members = append(members, m)
	}
	return members, rows.Err()
}
