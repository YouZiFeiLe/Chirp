package store

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

const ClientCredentialTTL = 20 * time.Hour
const ClientRedirectURI = "cn.youzifeile.chirp://auth/callback"
const ClientID = "chirp-apple"
const WindowsClientRedirectURI = "cn.youzifeile.chirp.windows://auth/callback"
const WindowsClientID = "chirp-windows"
const AndroidClientID = "chirp-android"
const AndroidClientRedirectURI = "cn.youzifeile.chirp.android://auth/callback"

var ErrInvalidAuthorization = errors.New("client authorization is invalid or expired")

type ClientAuthorization struct {
	ClientID            string `json:"client_id"`
	RedirectURI         string `json:"redirect_uri"`
	State               string `json:"state"`
	CodeChallenge       string `json:"code_challenge"`
	CodeChallengeMethod string `json:"code_challenge_method"`
}

func (a ClientAuthorization) Valid() bool {
	return ValidClientRedirect(a.ClientID, a.RedirectURI) && a.CodeChallengeMethod == "S256" &&
		validCodeChallenge(a.CodeChallenge) && len(a.State) >= 32 && len(a.State) <= 128 && pkceText(a.State)
}

// ValidClientRedirect binds a native callback to the client that requested it.
func ValidClientRedirect(clientID, redirect string) bool {
	return redirect != "" && redirect == clientRedirectURI(clientID)
}

func clientRedirectURI(clientID string) string {
	switch clientID {
	case ClientID:
		return ClientRedirectURI
	case WindowsClientID:
		return WindowsClientRedirectURI
	case AndroidClientID:
		return AndroidClientRedirectURI
	default:
		return ""
	}
}

func clientIDForPlatform(platform string) string {
	switch platform {
	case "ios", "macos":
		return ClientID
	case WindowsClientPlatform:
		return WindowsClientID
	case AndroidClientPlatform:
		return AndroidClientID
	default:
		return ""
	}
}

func pkceText(value string) bool {
	return value != "" && !strings.ContainsFunc(value, func(c rune) bool {
		return !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune("-._~", c))
	})
}

type ClientLogin struct {
	Member     Member          `json:"member"`
	Credential string          `json:"credential"`
	ExpiresAt  int64           `json:"expires_at"`
	Device     identity.Device `json:"device_identity"`
}

// After assertion verification, the Passkey credential update and one-time code
// are committed under the shared write lock. Client credentials are replaced
// only on code exchange; ordinary website cookies cannot mint codes.
func (s *Store) CreateClientAuthorization(ctx context.Context, account PasskeyAccount, credentialJSON []byte, authorization ClientAuthorization) (string, error) {
	if !authorization.Valid() {
		return "", ErrInvalidAuthorization
	}
	code, err := randomID("", 32)
	if err != nil {
		return "", err
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var memberID string
	var enabled bool
	err = tx.QueryRowContext(ctx, "SELECT m.id, m.enabled FROM passkey_accounts a JOIN members m ON m.id = a.member_id WHERE a.id = ?", account.ID).Scan(&memberID, &enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotApproved
	}
	if err != nil {
		return "", err
	}
	if err = accountAllowed(ctx, tx, memberID); err != nil {
		return "", err
	}
	result, err := tx.ExecContext(ctx, "UPDATE passkey_credentials SET credential_json = ? WHERE id = ? AND account_id = ? AND credential_json = ?", credentialJSON, account.CredentialID, account.ID, account.CredentialJSON)
	if err = changed(result, err); errors.Is(err, ErrNotFound) {
		return "", ErrPasskeyChanged
	} else if err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM client_authorizations WHERE member_id = ? OR expires_at <= ?", memberID, time.Now().Unix()); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO client_authorizations(code_hash, member_id, client_id, code_challenge, expires_at) VALUES(?, ?, ?, ?, ?)", tokenHash(code), memberID, authorization.ClientID, authorization.CodeChallenge, time.Now().Add(time.Minute).Unix()); err != nil {
		return "", err
	}
	return code, tx.Commit()
}

func validCodeChallenge(challenge string) bool {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(challenge)
	return err == nil && len(decoded) == 32 && len(challenge) == 43
}

func verifyPKCE(challenge, verifier string) bool {
	if len(verifier) < 43 || len(verifier) > 128 || !pkceText(verifier) {
		return false
	}
	digest := sha256.Sum256([]byte(verifier))
	return subtle.ConstantTimeCompare([]byte(base64.RawURLEncoding.EncodeToString(digest[:])), []byte(challenge)) == 1
}

func readPendingClientAuthorization(ctx context.Context, tx *sql.Tx, code, clientID string) (string, string, error) {
	var memberID, challenge string
	err := tx.QueryRowContext(ctx, `
		SELECT member_id, code_challenge FROM client_authorizations
		WHERE code_hash = ? AND client_id = ? AND code_challenge <> '' AND expires_at > ?`,
		tokenHash(code), clientID, time.Now().Unix()).Scan(&memberID, &challenge)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrInvalidAuthorization
	}
	return memberID, challenge, err
}

func consumeClientAuthorization(ctx context.Context, tx *sql.Tx, code, clientID string) error {
	if clientID == WindowsClientID {
		// Clearing the PKCE challenge consumes the code. Keep its hash briefly so
		// the browser can confirm this specific callback reached the Windows app.
		_, err := tx.ExecContext(ctx, "UPDATE client_authorizations SET code_challenge = '', expires_at = ? WHERE code_hash = ?", time.Now().Add(IdentitySetupTTL).Unix(), tokenHash(code))
		return err
	}
	_, err := tx.ExecContext(ctx, "DELETE FROM client_authorizations WHERE code_hash = ?", tokenHash(code))
	return err
}

// WindowsLoginReceived reports whether the app redeemed this browser's one-time code.
func (s *Store) WindowsLoginReceived(ctx context.Context, code string) (bool, error) {
	if len(code) != 43 {
		return false, ErrInvalidAuthorization
	}
	var received bool
	err := s.db.QueryRowContext(ctx, "SELECT code_challenge = '' FROM client_authorizations WHERE code_hash = ? AND client_id = ? AND expires_at > ?", tokenHash(code), WindowsClientID, time.Now().Unix()).Scan(&received)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrInvalidAuthorization
	}
	return received, err
}

func (s *Store) ExchangeClientAuthorization(ctx context.Context, code, verifier, clientID, redirectURI string, client ClientIdentity, deviceProof ...identity.LoginProof) (ClientLogin, error) {
	var login ClientLogin
	redirect := clientRedirectURI(clientID)
	if len(code) != 43 || len(verifier) < 43 || len(verifier) > 128 || !pkceText(verifier) || redirect == "" || redirectURI != redirect {
		return login, ErrInvalidAuthorization
	}
	if !client.Valid() {
		return login, ErrInvalidClientVersion
	}
	if clientID != clientIDForPlatform(client.Platform) {
		return login, ErrInvalidAuthorization
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return login, err
	}
	defer tx.Rollback()
	if _, err := checkClientVersion(ctx, tx, client); err != nil {
		return login, err
	}
	memberID, challenge, err := readPendingClientAuthorization(ctx, tx, code, clientID)
	if err != nil {
		return login, err
	}
	if !verifyPKCE(challenge, verifier) {
		return login, ErrInvalidAuthorization
	}
	if len(deviceProof) != 1 {
		return login, ErrDeviceIdentity
	}
	if err = bindLoginDevice(ctx, tx, memberID, deviceProof[0], clientID, code, verifier); err != nil {
		return login, err
	}
	login, err = issueClientLogin(ctx, tx, memberID)
	if err != nil {
		return login, err
	}
	if err = consumeClientAuthorization(ctx, tx, code, clientID); err != nil {
		return login, err
	}
	return login, tx.Commit()
}

// Both login transports commit credential replacement and the last-login time
// only when the originating client redeems its authorization.
func issueClientLogin(ctx context.Context, tx *sql.Tx, memberID string) (ClientLogin, error) {
	var login ClientLogin
	err := tx.QueryRowContext(ctx, "SELECT id, display_name, enabled, created_at, updated_at FROM members WHERE id = ?", memberID).Scan(&login.Member.ID, &login.Member.DisplayName, &login.Member.Enabled, &login.Member.CreatedAt, &login.Member.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return login, ErrInvalidAuthorization
	}
	if err != nil {
		return login, err
	}
	if !login.Member.Enabled {
		return login, ErrMemberDisabled
	}
	var deviceJSON []byte
	if err = tx.QueryRowContext(ctx, "SELECT device_identity FROM member_identities WHERE member_id = ?", memberID).Scan(&deviceJSON); err != nil {
		return login, ErrDeviceIdentity
	}
	if err = json.Unmarshal(deviceJSON, &login.Device); err != nil {
		return login, err
	}
	if login.Device.Validate(time.Now()) != nil {
		return login, ErrDeviceIdentity
	}
	token, hash, err := newCredential()
	if err != nil {
		return login, err
	}
	loginID, err := randomID("login_", 12)
	if err != nil {
		return login, err
	}
	now := time.Now().UTC()
	login.Credential, login.ExpiresAt = token, min(now.Add(ClientCredentialTTL).Unix(), login.Device.Certificates[len(login.Device.Certificates)-1].NotAfter)
	login.Member.LastLoginAt = now.Format(time.RFC3339)
	login.Member.LoginID, login.Member.CredentialExpiresAt = loginID, login.ExpiresAt
	if _, err = tx.ExecContext(ctx, "UPDATE members SET credential_hash = ?, login_id = ?, room_join_sequence = 0, credential_expires_at = ?, last_login_at = ?, updated_at = ? WHERE id = ?", hash, loginID, login.ExpiresAt, login.Member.LastLoginAt, login.Member.LastLoginAt, memberID); err != nil {
		return login, err
	}

	if _, err = tx.ExecContext(ctx, "UPDATE registered_devices SET last_login_at = ? WHERE member_id = ? AND device_key = ?", now.Unix(), memberID, login.Device.LeafKey()); err != nil {
		return login, err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE member_identities SET login_id = ? WHERE member_id = ?", loginID, memberID); err != nil {
		return login, err
	}
	return login, nil
}

func (s *Store) RevokeClientCredential(ctx context.Context, credential string) error {
	_, err := s.write(ctx, "UPDATE members SET login_id = '', credential_expires_at = 0 WHERE credential_hash = ?", tokenHash(credential))
	return err
}

func (m Member) ParticipantIdentity() string { return m.ID + "." + m.LoginID }

// ParticipantAllowed checks a member/login identity, not a room admission.
// Media and group access require AdmissionAllowed for the exact room entry.
func (s *Store) ParticipantAllowed(ctx context.Context, identity string) (bool, error) {
	memberID, loginID, found := strings.Cut(identity, ".")
	if !found || loginID == "" {
		return false, nil
	}
	var allowed bool
	err := s.db.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM members WHERE id = ? AND login_id = ? AND enabled = 1 AND credential_expires_at > ?)", memberID, loginID, time.Now().Unix()).Scan(&allowed)
	return allowed, err
}

func ParticipantMemberID(identity string) string {
	memberID, _, _ := strings.Cut(identity, ".")
	return memberID
}

// RevokeParticipant revokes only the matching login generation; stale identities
// cannot revoke a newer login. Room kicks remove a scoped admission instead.
func (s *Store) RevokeParticipant(ctx context.Context, identity string) error {
	memberID, loginID, found := strings.Cut(identity, ".")
	if !found || loginID == "" {
		return nil
	}
	_, err := s.write(ctx, "UPDATE members SET login_id = '', credential_expires_at = 0 WHERE id = ? AND login_id = ?", memberID, loginID)
	return err
}
