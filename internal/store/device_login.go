package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

const DeviceAuthorizationTTL = 3 * time.Minute
const deviceAuthorizationPurpose = "client-device-v1"

var ErrInvalidDeviceAuthorization = errors.New("device authorization is invalid or expired")
var ErrDeviceAuthorizationPending = errors.New("device authorization is awaiting approval")

type DeviceAuthorization struct {
	RequestID string `json:"request_id"`
	ExpiresAt int64  `json:"expires_at"`
}

type deviceAuthorizationState struct {
	Purpose       string `json:"purpose"`
	CodeChallenge string `json:"code_challenge"`
	ClientID      string `json:"client_id,omitempty"`
	MemberID      string `json:"member_id,omitempty"`
}

// A separate hash namespace prevents a public QR request from being consumed
// as a browser ceremony cookie, while sharing the bounded temporary store.
func deviceAuthorizationKey(id string) string { return "client-device-v1:" + id }

func (s *Store) BeginDeviceAuthorization(ctx context.Context, challenge, clientID string) (DeviceAuthorization, error) {
	if !validCodeChallenge(challenge) || (clientID != ClientID && clientID != WindowsClientID && clientID != AndroidClientID) {
		return DeviceAuthorization{}, ErrInvalidDeviceAuthorization
	}
	id, err := randomID("", 32)
	if err != nil {
		return DeviceAuthorization{}, err
	}
	payload, err := json.Marshal(deviceAuthorizationState{Purpose: deviceAuthorizationPurpose, CodeChallenge: challenge, ClientID: clientID})
	if err != nil {
		return DeviceAuthorization{}, err
	}
	expires := time.Now().Add(DeviceAuthorizationTTL)
	if err = s.SavePasskeyCeremony(ctx, deviceAuthorizationKey(id), "", "login", payload, expires); err != nil {
		return DeviceAuthorization{}, err
	}
	return DeviceAuthorization{RequestID: id, ExpiresAt: expires.Unix()}, nil
}

type deviceAuthorizationReader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readDeviceAuthorization(ctx context.Context, reader deviceAuthorizationReader, id string) (deviceAuthorizationState, error) {
	var state deviceAuthorizationState
	if !validCodeChallenge(id) {
		return state, ErrInvalidDeviceAuthorization
	}
	var payload []byte
	err := reader.QueryRowContext(ctx, "SELECT payload FROM passkey_ceremonies WHERE token_hash = ? AND kind = 'login' AND expires_at > ?", tokenHash(deviceAuthorizationKey(id)), time.Now().Unix()).Scan(&payload)
	if errors.Is(err, sql.ErrNoRows) {
		return state, ErrInvalidDeviceAuthorization
	}
	if err != nil {
		return state, err
	}
	if json.Unmarshal(payload, &state) != nil || state.Purpose != deviceAuthorizationPurpose || !validCodeChallenge(state.CodeChallenge) {
		return state, ErrInvalidDeviceAuthorization
	}
	// Requests issued before client binding were available only to Apple clients.
	if state.ClientID == "" {
		state.ClientID = ClientID
	}
	return state, nil
}

func (s *Store) DeviceAuthorizationPending(ctx context.Context, id string) error {
	state, err := readDeviceAuthorization(ctx, s.db, id)
	if err == nil && state.MemberID != "" {
		return ErrInvalidDeviceAuthorization
	}
	return err
}

func (s *Store) ApproveDeviceAuthorization(ctx context.Context, id string, account PasskeyAccount, credentialJSON []byte) error {
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	state, err := readDeviceAuthorization(ctx, tx, id)
	if err != nil {
		return err
	}
	if state.MemberID != "" {
		return ErrInvalidDeviceAuthorization
	}
	var enabled bool
	err = tx.QueryRowContext(ctx, "SELECT m.id, m.enabled FROM passkey_accounts a JOIN members m ON m.id = a.member_id WHERE a.id = ?", account.ID).Scan(&state.MemberID, &enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotApproved
	}
	if err != nil {
		return err
	}
	if err = accountAllowed(ctx, tx, state.MemberID); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, "UPDATE passkey_credentials SET credential_json = ? WHERE id = ? AND account_id = ? AND credential_json = ?", credentialJSON, account.CredentialID, account.ID, account.CredentialJSON)
	if err = changed(result, err); errors.Is(err, ErrNotFound) {
		return ErrPasskeyChanged
	} else if err != nil {
		return err
	}
	payload, err := json.Marshal(state)
	if err != nil {
		return err
	}
	result, err = tx.ExecContext(ctx, "UPDATE passkey_ceremonies SET payload = ? WHERE token_hash = ? AND expires_at > ?", payload, tokenHash(deviceAuthorizationKey(id)), time.Now().Unix())
	if err = changed(result, err); errors.Is(err, ErrNotFound) {
		return ErrInvalidDeviceAuthorization
	} else if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) PollDeviceAuthorization(ctx context.Context, id, verifier string, client ClientIdentity, deviceProof ...identity.LoginProof) (ClientLogin, error) {
	var login ClientLogin
	if len(verifier) < 43 || len(verifier) > 128 || !pkceText(verifier) {
		return login, ErrInvalidDeviceAuthorization
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return login, err
	}
	defer tx.Rollback()
	if _, err := checkClientVersion(ctx, tx, client); err != nil {
		return login, err
	}
	state, err := readDeviceAuthorization(ctx, tx, id)
	if err != nil {
		return login, err
	}
	if state.ClientID != clientIDForPlatform(client.Platform) || !verifyPKCE(state.CodeChallenge, verifier) {
		return login, ErrInvalidDeviceAuthorization
	}
	if state.MemberID == "" {
		return login, ErrDeviceAuthorizationPending
	}
	if len(deviceProof) != 1 {
		return login, ErrDeviceIdentity
	}
	if err = bindLoginDevice(ctx, tx, state.MemberID, deviceProof[0], state.ClientID, id, verifier); err != nil {
		return login, err
	}
	login, err = issueClientLogin(ctx, tx, state.MemberID)
	if err != nil {
		return login, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE token_hash = ?", tokenHash(deviceAuthorizationKey(id))); err != nil {
		return login, err
	}
	return login, tx.Commit()
}

func (s *Store) CancelDeviceAuthorization(ctx context.Context, id, verifier string) error {
	if !validCodeChallenge(id) || len(verifier) < 43 || len(verifier) > 128 || !pkceText(verifier) {
		return ErrInvalidDeviceAuthorization
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	state, err := readDeviceAuthorization(ctx, tx, id)
	if errors.Is(err, ErrInvalidDeviceAuthorization) {
		return nil // Already expired, consumed, or cancelled.
	}
	if err != nil {
		return err
	}
	if !verifyPKCE(state.CodeChallenge, verifier) {
		return ErrInvalidDeviceAuthorization
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE token_hash = ?", tokenHash(deviceAuthorizationKey(id))); err != nil {
		return err
	}
	return tx.Commit()
}

func revokeDeviceAuthorizations(ctx context.Context, tx *sql.Tx, memberID string) error {
	rows, err := tx.QueryContext(ctx, "SELECT token_hash, payload FROM passkey_ceremonies WHERE kind = 'login'")
	if err != nil {
		return err
	}
	var keys [][]byte
	for rows.Next() {
		var key, payload []byte
		if err = rows.Scan(&key, &payload); err != nil {
			rows.Close()
			return err
		}
		var state deviceAuthorizationState
		if json.Unmarshal(payload, &state) == nil && state.Purpose == deviceAuthorizationPurpose && state.MemberID == memberID {
			keys = append(keys, key)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, key := range keys {
		if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE token_hash = ?", key); err != nil {
			return err
		}
	}
	return nil
}
