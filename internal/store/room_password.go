package store

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"errors"
	"unicode"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

var (
	ErrInvalidRoomPassword  = errors.New("room password must have 8 to 128 Unicode characters without controls")
	ErrRoomPasswordRequired = errors.New("room password required")
	ErrRoomPasswordWrong    = errors.New("incorrect room password")
	ErrRoomPasswordChanged  = errors.New("room password changed; repeat preflight")
	ErrPasswordBusy         = errors.New("password verification is busy")
)

// Per-process bound: each Argon2id operation uses 19 MiB. Do not hold the shared
// database write lock while calculating a password hash.
var passwordWork = make(chan struct{}, 2)

func validRoomPassword(password string) bool {
	if !utf8.ValidString(password) || len(password) > 512 {
		return false
	}
	n := utf8.RuneCountInString(password)
	if n < 8 || n > 128 {
		return false
	}
	for _, r := range password {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func roomPasswordHash(ctx context.Context, password string, salt []byte) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	select {
	case passwordWork <- struct{}{}:
		defer func() { <-passwordWork }()
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
		return nil, ErrPasswordBusy
	}
	secret := []byte(password)
	defer clear(secret)
	hash := argon2.IDKey(secret, salt, 2, 19*1024, 1, 32)
	if err := ctx.Err(); err != nil {
		clear(hash)
		return nil, err
	}
	return hash, nil
}

// CheckRoomPassword is read-only. Its revision is only a password-check result,
// never an admission, media permit or cryptographic group secret.
func (s *Store) CheckRoomPassword(ctx context.Context, roomID, password string) (int64, error) {
	if !ValidRoomID(roomID) {
		return 0, ErrNotFound
	}
	var salt, expected []byte
	var revision int64
	err := s.db.QueryRowContext(ctx, "SELECT password_salt, password_hash, password_revision FROM room_settings WHERE room_id = ? AND deleted = 0", roomID).Scan(&salt, &expected, &revision)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	if expected == nil && salt == nil {
		return revision, nil
	}
	if len(expected) != 32 || len(salt) != 16 {
		return 0, errors.New("invalid stored room password verifier")
	}
	if password == "" {
		return 0, ErrRoomPasswordRequired
	}
	if !validRoomPassword(password) {
		return 0, ErrRoomPasswordWrong
	}
	actual, err := roomPasswordHash(ctx, password, salt)
	if err != nil {
		return 0, err
	}
	defer clear(actual)
	if subtle.ConstantTimeCompare(actual, expected) != 1 {
		return 0, ErrRoomPasswordWrong
	}
	return revision, nil
}

func (s *Store) SetRoomPassword(ctx context.Context, roomID, password string) (RoomConfig, error) {
	if !ValidRoomID(roomID) {
		return RoomConfig{}, ErrNotFound
	}
	if !validRoomPassword(password) {
		return RoomConfig{}, ErrInvalidRoomPassword
	}
	var salt [16]byte
	if _, err := rand.Read(salt[:]); err != nil {
		return RoomConfig{}, err
	}
	hash, err := roomPasswordHash(ctx, password, salt[:])
	if err != nil {
		return RoomConfig{}, err
	}
	defer clear(hash)
	result, err := s.write(ctx, "UPDATE room_settings SET password_salt=?, password_hash=?, password_revision=password_revision+1 WHERE room_id=? AND deleted=0", salt[:], hash, roomID)
	if err = changed(result, err); err != nil {
		return RoomConfig{}, err
	}
	return s.Room(ctx, roomID)
}

func (s *Store) ClearRoomPassword(ctx context.Context, roomID string) (RoomConfig, error) {
	if !ValidRoomID(roomID) {
		return RoomConfig{}, ErrNotFound
	}
	result, err := s.write(ctx, "UPDATE room_settings SET password_salt=NULL, password_hash=NULL, password_revision=password_revision+1 WHERE room_id=? AND deleted=0", roomID)
	if err = changed(result, err); err != nil {
		return RoomConfig{}, err
	}
	return s.Room(ctx, roomID)
}
