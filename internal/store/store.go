package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	_ "modernc.org/sqlite"
)

const SQLiteVersion = "3.54.1"
const SchemaVersion = 23
const schemaVersion = SchemaVersion
const DefaultRoomID = "friends"
const DefaultRoomDisplayName = "公开大厅"
const DefaultRoomDescription = "一个房间，几个朋友，随时聊聊。"

var (
	ErrNotFound    = errors.New("not found")
	ErrDefaultRoom = errors.New("the default room cannot be deleted")
	ErrInvalidName = errors.New("display name must contain 1 to 80 characters without control characters")
)

//go:embed schema.sql
var schemaSQL string

type Store struct {
	db   *sql.DB
	path string
}
type Member struct {
	IsAdmin             bool   `json:"is_admin,omitempty"`
	ID                  string `json:"id"`
	DisplayName         string `json:"display_name"`
	Enabled             bool   `json:"enabled"`
	CreatedAt           string `json:"created_at"`
	UpdatedAt           string `json:"updated_at"`
	LastLoginAt         string `json:"last_login_at,omitempty"`
	LoginID             string `json:"-"`
	CredentialExpiresAt int64  `json:"credential_expires_at,omitempty"`
	JoinSequence        int64  `json:"-"`
}
type RoomConfig struct {
	RoomID           string `json:"room_id"`
	DisplayName      string `json:"display_name"`
	Description      string `json:"description"`
	PasswordRequired bool   `json:"password_required"`
	IsDefault        bool   `json:"is_default"`
}
type Engine struct {
	Version string `json:"sqlite_version"`
}

// Open accepts a filesystem path only, so callers cannot disable locking or
// connection pragmas through URI parameters. All containers must share the
// entire directory on a single host's local filesystem, including WAL and SHM.
func Open(ctx context.Context, path string) (*Store, error) {
	if strings.TrimSpace(path) == "" || path == ":memory:" || strings.HasPrefix(path, "file:") || strings.ContainsRune(path, '\x00') {
		return nil, errors.New("a local SQLite database file path is required")
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	// Pre-create privately; the application runs as UID 65532.
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	params := url.Values{
		"_pragma": {"busy_timeout(10000)", "foreign_keys(ON)", "synchronous(FULL)"},
		"_txlock": {"immediate"},
		"cache":   {"private"},
	}
	// The authority makes URL.String prefix Windows drive paths with a slash.
	u := url.URL{Scheme: "file", Host: "localhost", Path: filepath.ToSlash(path), RawQuery: params.Encode()}
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	s := &Store{db: db, path: path}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	// WAL is persistent, but checking it also catches unsupported/read-only mounts.
	// Concurrent first opens can race while switching journal mode. Retry only
	// this idempotent setup statement; never replay committed business operations.
	for {
		var mode string
		err = db.QueryRowContext(ctx, "PRAGMA journal_mode=WAL").Scan(&mode)
		if err == nil {
			if mode != "wal" {
				err = fmt.Errorf("SQLite WAL mode is required, got %q", mode)
			}
			break
		}
		if !sqliteBusy(err) {
			break
		}
		select {
		case <-ctx.Done():
			err = ctx.Err()
		case <-time.After(20 * time.Millisecond):
			continue
		}
		break
	}
	if err == nil {
		err = s.initialize(ctx)
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error                   { return s.db.Close() }
func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

// Path identifies the database file so other local storage cannot reclaim it.
func (s *Store) Path() string { return s.path }

func (s *Store) Engine(ctx context.Context) (Engine, error) {
	var e Engine
	err := s.db.QueryRowContext(ctx, "SELECT sqlite_version()").Scan(&e.Version)
	return e, err
}

func (s *Store) initialize(ctx context.Context) error {
	// BEGIN IMMEDIATE acquires SQLite's cross-process writer lock before the
	// schema check. DDL and the final version marker commit atomically.
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	commonSchema, freshSchema, ok := strings.Cut(schemaSQL, "\n-- Fresh databases only")
	if !ok {
		return errors.New("fresh database schema is missing")
	}
	if _, err = tx.ExecContext(ctx, commonSchema); err != nil {
		return err
	}
	var version int
	err = tx.QueryRowContext(ctx, "SELECT version FROM chirp_schema WHERE id = 1").Scan(&version)
	if err == nil {
		if version != schemaVersion {
			return fmt.Errorf("database schema %d is unsupported; use an empty database for schema %d", version, schemaVersion)
		}
		if err := allowAndroidClientAuthorizations(ctx, tx, freshSchema); err != nil {
			return err
		}
		return tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	// Execute the complete fresh schema; trigger bodies contain semicolons.
	if _, err = tx.ExecContext(ctx, freshSchema); err != nil {
		return err
	}
	return tx.Commit()
}

// Existing schema-22 databases restricted pending native authorizations to Apple and Windows.
// Widen only that constraint, preserving in-flight codes under the initialization write lock.
func allowAndroidClientAuthorizations(ctx context.Context, tx *sql.Tx, freshSchema string) error {
	var definition string
	if err := tx.QueryRowContext(ctx, "SELECT sql FROM sqlite_schema WHERE type='table' AND name='client_authorizations'").Scan(&definition); err != nil {
		return err
	}
	if strings.Contains(definition, "'chirp-android'") {
		return nil
	}
	_, tail, found := strings.Cut(freshSchema, "-- Begin native client authorizations")
	table, _, ended := strings.Cut(tail, "-- End native client authorizations")
	if !found || !ended {
		return errors.New("client authorization schema is missing")
	}
	if _, err := tx.ExecContext(ctx, "DROP INDEX IF EXISTS client_authorizations_expiry; ALTER TABLE client_authorizations RENAME TO old_client_authorizations"); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, table); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO client_authorizations(code_hash,member_id,client_id,code_challenge,expires_at)
		SELECT code_hash,member_id,client_id,code_challenge,expires_at FROM old_client_authorizations;
		DROP TABLE old_client_authorizations`)
	return err
}

func (s *Store) beginWrite(ctx context.Context) (*sql.Tx, error) {
	// The driver uses BEGIN IMMEDIATE on every connection, waiting up to 10s
	// for other processes. No read snapshot is taken before the writer lock.
	return s.db.BeginTx(ctx, nil)
}

func (s *Store) write(ctx context.Context, query string, args ...any) (sql.Result, error) {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

func newCredential() (string, []byte, error) {
	var value [32]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", nil, err
	}
	token := "chirp_" + base64.RawURLEncoding.EncodeToString(value[:])
	hash := sha256.Sum256([]byte(token))
	return token, hash[:], nil
}

func (s *Store) AddMember(ctx context.Context, name string) (Member, string, error) {
	name = strings.TrimSpace(name)
	if !validName(name) {
		return Member{}, "", ErrInvalidName
	}
	token, hash, err := newCredential()
	if err != nil {
		return Member{}, "", err
	}
	var id [12]byte
	if _, err := rand.Read(id[:]); err != nil {
		return Member{}, "", err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	m := Member{ID: "member_" + base64.RawURLEncoding.EncodeToString(id[:]), DisplayName: name, Enabled: true, CreatedAt: now, UpdatedAt: now}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Member{}, "", err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, "INSERT INTO members(id, display_name, credential_hash, enabled, created_at, updated_at) VALUES(?, ?, ?, 1, ?, ?)", m.ID, name, hash, now, now)
	if err != nil {
		return Member{}, "", err
	}
	m.LoginID, err = randomID("login_", 12)
	if err != nil {
		return Member{}, "", err
	}
	m.CredentialExpiresAt = time.Now().Add(ClientCredentialTTL).Unix()
	if _, err = tx.ExecContext(ctx, "UPDATE members SET login_id = ?, credential_expires_at = ? WHERE id = ?", m.LoginID, m.CredentialExpiresAt, m.ID); err != nil {
		return Member{}, "", err
	}
	if err := tx.Commit(); err != nil {
		return Member{}, "", err
	}
	return m, token, nil
}

func (s *Store) MemberByCredential(ctx context.Context, token string) (Member, error) {
	hash := sha256.Sum256([]byte(token))
	var m Member
	err := s.db.QueryRowContext(ctx, "SELECT id, display_name, enabled, created_at, updated_at, login_id, credential_expires_at, last_login_at, room_join_sequence FROM members WHERE credential_hash = ? AND (credential_expires_at > ? OR enabled = 0)", hash[:], time.Now().Unix()).Scan(&m.ID, &m.DisplayName, &m.Enabled, &m.CreatedAt, &m.UpdatedAt, &m.LoginID, &m.CredentialExpiresAt, &m.LastLoginAt, &m.JoinSequence)
	if errors.Is(err, sql.ErrNoRows) {
		return m, ErrNotFound
	}
	return m, err
}

func (s *Store) ListMembers(ctx context.Context) ([]Member, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, display_name, enabled, created_at, updated_at, last_login_at, login_id, credential_expires_at, is_admin FROM members ORDER BY created_at, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []Member{}
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.ID, &m.DisplayName, &m.Enabled, &m.CreatedAt, &m.UpdatedAt, &m.LastLoginAt, &m.LoginID, &m.CredentialExpiresAt, &m.IsAdmin); err != nil {
			return nil, err
		}
		members = append(members, m)
	}
	return members, rows.Err()
}

func (s *Store) DisableMember(ctx context.Context, id string) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := protectAdministrator(ctx, tx, id); err != nil {
		return err
	}
	if err := clearBrowserSessions(ctx, tx, id); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, "UPDATE members SET enabled = 0, login_id = '', credential_expires_at = 0, updated_at = ? WHERE id = ?", time.Now().UTC().Format(time.RFC3339), id)
	if err = changed(result, err); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM client_authorizations WHERE member_id = ?", id); err != nil {
		return err
	}
	if err = revokeDeviceAuthorizations(ctx, tx, id); err != nil {
		return err
	}
	if err = blacklistAccount(ctx, tx, id); err != nil {
		return err
	}
	return tx.Commit()
}

func validName(name string) bool {
	return name != "" && utf8.ValidString(name) && utf8.RuneCountInString(name) <= 80 && !strings.ContainsFunc(name, unicode.IsControl)
}

func (s *Store) UpdateMember(ctx context.Context, id, name string, enabled bool) (Member, error) {
	name = strings.TrimSpace(name)
	if !validName(name) {
		return Member{}, ErrInvalidName
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return Member{}, err
	}
	defer tx.Rollback()
	var m Member
	err = tx.QueryRowContext(ctx, "SELECT id, display_name, enabled, created_at, updated_at FROM members WHERE id = ?", id).Scan(&m.ID, &m.DisplayName, &m.Enabled, &m.CreatedAt, &m.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Member{}, ErrNotFound
	}
	if err != nil {
		return Member{}, err
	}
	if enabled {
		var banned bool
		if err = tx.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM identity_blacklist WHERE kind = 'account' AND subject = ?)", id).Scan(&banned); err != nil {
			return Member{}, err
		}
		if banned {
			return Member{}, ErrBlacklisted
		}
	}
	if !enabled {
		if err := protectAdministrator(ctx, tx, id); err != nil {
			return Member{}, err
		}
		if err := clearBrowserSessions(ctx, tx, id); err != nil {
			return Member{}, err
		}
	}
	m.DisplayName, m.Enabled, m.UpdatedAt = name, enabled, time.Now().UTC().Format(time.RFC3339)
	if _, err := tx.ExecContext(ctx, "UPDATE members SET display_name = ?, profile_revision = profile_revision + 1, enabled = ?, credential_expires_at = CASE WHEN ? = 0 THEN 0 ELSE credential_expires_at END, login_id = CASE WHEN ? = 0 THEN '' ELSE login_id END, updated_at = ? WHERE id = ?", m.DisplayName, m.Enabled, m.Enabled, m.Enabled, m.UpdatedAt, m.ID); err != nil {
		return Member{}, err
	}
	if !enabled {
		if _, err = tx.ExecContext(ctx, "DELETE FROM client_authorizations WHERE member_id = ?", id); err != nil {
			return Member{}, err
		}
		if err = revokeDeviceAuthorizations(ctx, tx, id); err != nil {
			return Member{}, err
		}
	}
	if !enabled {
		if err = blacklistAccount(ctx, tx, id); err != nil {
			return Member{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return Member{}, err
	}
	return m, nil
}

func (s *Store) DeleteMember(ctx context.Context, id string) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := protectAdministrator(ctx, tx, id); err != nil {
		return err
	}
	if err = blacklistAccount(ctx, tx, id); err != nil {
		return err
	}
	// Retain only the public WebAuthn verification material so a valid old
	// passkey receives an explicit ban result after account deletion.
	if _, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO retired_passkeys(credential_id,account_id,nickname,credential_json,retired_at,status) SELECT c.id,a.id,a.nickname,c.credential_json,?,'blacklisted' FROM passkey_accounts a JOIN passkey_credentials c ON c.account_id=a.id WHERE a.member_id=?", time.Now().Unix(), id); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, "DELETE FROM members WHERE id = ?", id)
	if err := changed(result, err); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ResetCredential(ctx context.Context, id string) (string, error) {
	token, hash, err := newCredential()
	if err != nil {
		return "", err
	}
	loginID, err := randomID("login_", 12)
	if err != nil {
		return "", err
	}
	result, err := s.write(ctx, "UPDATE members SET credential_hash = ?, login_id = ?, room_join_sequence = 0, credential_expires_at = ?, updated_at = ? WHERE id = ?", hash, loginID, time.Now().Add(ClientCredentialTTL).Unix(), time.Now().UTC().Format(time.RFC3339), id)
	if err := changed(result, err); err != nil {
		return "", err
	}
	return token, nil
}

func changed(result sql.Result, err error) error {
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err == nil && n == 0 {
		return ErrNotFound
	}
	return err
}
