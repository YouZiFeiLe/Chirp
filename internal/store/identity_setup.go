package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

const IdentitySetupTTL = 5 * time.Minute

var ErrIdentityConflict = errors.New("the account already has a different root identity")

type IdentitySetup struct {
	Token      string `json:"setup_token"`
	AccountID  string `json:"account_id"`
	Username   string `json:"username"`
	Origin     string `json:"service_origin"`
	AccountKey string `json:"account_key"`
	ExpiresAt  int64  `json:"expires_at"`
}

// No normal credential is issued, and the previous online login is untouched.
func (s *Store) BeginIdentitySetup(ctx context.Context, code, verifier, clientID, origin string, client ClientIdentity, deviceFlow bool) (IdentitySetup, error) {
	var result IdentitySetup
	origin, err := identity.NormalizeOrigin(origin)
	if err != nil {
		return result, ErrInvalidAuthorization
	}
	if clientID != clientIDForPlatform(client.Platform) {
		return result, ErrInvalidAuthorization
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	if _, err = checkClientVersion(ctx, tx, client); err != nil {
		return result, err
	}
	var memberID, challenge string
	if deviceFlow {
		state, err := readDeviceAuthorization(ctx, tx, code)
		if err != nil {
			return result, err
		}
		if state.ClientID != clientID {
			return result, ErrInvalidDeviceAuthorization
		}
		if !verifyPKCE(state.CodeChallenge, verifier) {
			return result, ErrInvalidDeviceAuthorization
		}
		if state.MemberID == "" {
			return result, ErrDeviceAuthorizationPending
		}
		memberID, challenge = state.MemberID, state.CodeChallenge
	} else {
		memberID, challenge, err = readPendingClientAuthorization(ctx, tx, code, clientID)
		if err != nil {
			return result, err
		}
	}
	if !verifyPKCE(challenge, verifier) {
		return result, ErrInvalidAuthorization
	}
	if err = accountAllowedForSetup(ctx, tx, memberID); err != nil {
		return result, err
	}
	result.AccountID, result.Origin, result.ExpiresAt = memberID, origin, time.Now().Add(IdentitySetupTTL).Unix()
	if err = tx.QueryRowContext(ctx, "SELECT coalesce(a.nickname, m.display_name), coalesce(i.account_key, '') FROM members m LEFT JOIN passkey_accounts a ON a.member_id = m.id LEFT JOIN member_identities i ON i.member_id = m.id WHERE m.id = ?", memberID).Scan(&result.Username, &result.AccountKey); err != nil {
		return result, err
	}
	result.Token, err = randomID("setup_", 32)
	if err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM identity_setups WHERE expires_at <= ?", time.Now().Unix()); err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO identity_setups(token_hash, member_id, client_id, origin, code_challenge, expires_at) VALUES(?, ?, ?, ?, ?, ?)", tokenHash(result.Token), memberID, clientID, origin, challenge, result.ExpiresAt); err != nil {
		return result, err
	}
	if deviceFlow {
		_, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE token_hash = ?", tokenHash(deviceAuthorizationKey(code)))
	} else {
		err = consumeClientAuthorization(ctx, tx, code, clientID)
	}
	if err != nil {
		return result, err
	}
	return result, tx.Commit()
}

func accountAllowedForSetup(ctx context.Context, tx *sql.Tx, memberID string) error {
	return accountAllowed(ctx, tx, memberID)
}

type setupState struct{ memberID, clientID, origin, root, device, challenge string }

func readIdentitySetup(ctx context.Context, tx *sql.Tx, token, verifier, origin string, client ClientIdentity) (setupState, error) {
	var v setupState
	var pkce string
	err := tx.QueryRowContext(ctx, "SELECT member_id, client_id, origin, candidate_root, candidate_device, challenge, code_challenge FROM identity_setups WHERE token_hash = ? AND expires_at > ? AND completed = 0", tokenHash(token), time.Now().Unix()).Scan(&v.memberID, &v.clientID, &v.origin, &v.root, &v.device, &v.challenge, &pkce)
	if errors.Is(err, sql.ErrNoRows) {
		return v, ErrInvalidAuthorization
	}
	if err != nil {
		return v, err
	}
	normalized, err := identity.NormalizeOrigin(origin)
	if err != nil || normalized != v.origin || v.clientID != clientIDForPlatform(client.Platform) || !verifyPKCE(pkce, verifier) {
		return v, ErrInvalidAuthorization
	}
	if _, err = checkClientVersion(ctx, tx, client); err != nil {
		return v, err
	}
	return v, accountAllowedForSetup(ctx, tx, v.memberID)
}

func (s *Store) BindIdentityChallenge(ctx context.Context, token, verifier, origin string, client ClientIdentity, device identity.Device) (string, error) {
	if device.Validate(time.Now()) != nil {
		return "", ErrDeviceIdentity
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	state, err := readIdentitySetup(ctx, tx, token, verifier, origin, client)
	if err != nil {
		return "", err
	}
	var root string
	err = tx.QueryRowContext(ctx, "SELECT account_key FROM member_identities WHERE member_id = ?", state.memberID).Scan(&root)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if root != "" && root != device.AccountKey {
		return "", ErrIdentityConflict
	}
	if state.root != "" && (state.root != device.AccountKey || state.device != device.Hash()) {
		return "", ErrIdentityConflict
	}
	if state.challenge == "" {
		state.challenge, err = randomID("", 32)
		if err != nil {
			return "", err
		}
	}
	if _, err = tx.ExecContext(ctx, "UPDATE identity_setups SET candidate_root = ?, candidate_device = ?, challenge = ? WHERE token_hash = ?", device.AccountKey, device.Hash(), state.challenge, tokenHash(token)); err != nil {
		return "", err
	}
	return state.challenge, tx.Commit()
}

type IdentitySetupOptions struct {
	DeviceName        string
	RequestResumption bool
}

func (s *Store) CompleteIdentitySetup(ctx context.Context, token, verifier, origin, signature string, client ClientIdentity, device identity.Device, options IdentitySetupOptions) (ClientLogin, error) {
	var result ClientLogin
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	state, err := readIdentitySetup(ctx, tx, token, verifier, origin, client)
	if err != nil {
		return result, err
	}
	if state.challenge == "" || state.root != device.AccountKey || state.device != device.Hash() || device.Validate(time.Now()) != nil || !identity.Verify(device.LeafKey(), signature, identity.ActivationMessage(state.origin, state.memberID, state.clientID, token, verifier, state.challenge, device)) {
		return result, ErrDeviceIdentity
	}
	var root string
	err = tx.QueryRowContext(ctx, "SELECT account_key FROM member_identities WHERE member_id = ?", state.memberID).Scan(&root)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return result, err
	}
	if root != "" && root != device.AccountKey {
		return result, ErrIdentityConflict
	}
	if err = registerDevice(ctx, tx, state.memberID, device, client.Platform, options.DeviceName); err != nil {
		return result, err
	}
	data, err := json.Marshal(device)
	if err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO member_identities(member_id, account_key, device_identity, login_id) VALUES(?, ?, ?, '') ON CONFLICT(member_id) DO UPDATE SET device_identity = excluded.device_identity", state.memberID, device.AccountKey, data); err != nil {
		return result, err
	}
	result, err = issueClientLogin(ctx, tx, state.memberID)
	if err != nil {
		return result, err
	}
	if options.RequestResumption {
		result.ResumeToken, err = issueClientResumption(ctx, tx, result.Member, state.origin, client.Platform)
		if err != nil {
			return ClientLogin{}, err
		}
	}
	if _, err = tx.ExecContext(ctx, "UPDATE identity_setups SET completed = 1 WHERE token_hash = ?", tokenHash(token)); err != nil {
		return result, err
	}
	return result, tx.Commit()
}
