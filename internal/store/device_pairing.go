package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

const devicePairingPurpose = "device-pairing-v1"

var ErrDevicePairing = errors.New("device pairing is invalid, expired, or conflicts with an existing exchange")

type DevicePairingState struct {
	Request         identity.DevicePairingRequest `json:"request"`
	Offer           *identity.DevicePairingAction `json:"offer,omitempty"`
	Reveal          *identity.DevicePairingAction `json:"reveal,omitempty"`
	NewConfirmation *identity.DevicePairingAction `json:"new_confirmation,omitempty"`
	OldConfirmation *identity.DevicePairingAction `json:"old_confirmation,omitempty"`
	Approval        *identity.DevicePairingAction `json:"approval,omitempty"`
	Cancelled       bool                          `json:"cancelled"`
}

type devicePairingRecord struct {
	Purpose  string             `json:"purpose"`
	MemberID string             `json:"member_id"`
	State    DevicePairingState `json:"state"`
}

func devicePairingKey(id string) string { return devicePairingPurpose + ":" + id }

// Pairing shares the bounded temporary store, in a namespace separate from
// browser ceremonies and phone Passkey authorization. It grants no login.
func (s *Store) BeginDevicePairing(ctx context.Context, token, verifier, origin string, client ClientIdentity, request identity.DevicePairingRequest) (DevicePairingState, error) {
	var result DevicePairingState
	if request.Validate(time.Now()) != nil {
		return result, ErrDevicePairing
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	setup, err := readIdentitySetup(ctx, tx, token, verifier, origin, client)
	if err != nil {
		return result, err
	}
	if setup.memberID != request.AccountID || setup.origin != request.Origin {
		return result, ErrDevicePairing
	}
	var setupExpires int64
	if err = tx.QueryRowContext(ctx, "SELECT expires_at FROM identity_setups WHERE token_hash = ?", tokenHash(token)).Scan(&setupExpires); err != nil {
		return result, err
	}
	if request.ExpiresAt > setupExpires {
		return result, ErrDevicePairing
	}
	if err = pairingAccountAllowed(ctx, tx, request); err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM passkey_ceremonies WHERE expires_at <= ?", time.Now().Unix()); err != nil {
		return result, err
	}
	var previous []byte
	err = tx.QueryRowContext(ctx, "SELECT payload FROM passkey_ceremonies WHERE token_hash = ?", tokenHash(devicePairingKey(request.Hash()))).Scan(&previous)
	if err == nil {
		var record devicePairingRecord
		if json.Unmarshal(previous, &record) != nil || record.Purpose != devicePairingPurpose || record.MemberID != request.AccountID || record.State.Request != request {
			return result, ErrDevicePairing
		}
		return record.State, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return result, err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM passkey_ceremonies").Scan(&count); err != nil {
		return result, err
	}
	if count >= 512 {
		return result, ErrCeremonyCapacity
	}
	rows, err := tx.QueryContext(ctx, "SELECT payload FROM passkey_ceremonies WHERE kind = 'login'")
	if err != nil {
		return result, err
	}
	active := 0
	for rows.Next() {
		var data []byte
		if err = rows.Scan(&data); err != nil {
			rows.Close()
			return result, err
		}
		var record devicePairingRecord
		if json.Unmarshal(data, &record) == nil && record.Purpose == devicePairingPurpose && record.MemberID == request.AccountID && !record.State.Cancelled {
			active++
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return result, err
	}
	if active >= 3 {
		return result, ErrCeremonyCapacity
	}
	result.Request = request
	payload, err := json.Marshal(devicePairingRecord{Purpose: devicePairingPurpose, MemberID: request.AccountID, State: result})
	if err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO passkey_ceremonies(token_hash, kind, payload, expires_at) VALUES(?, 'login', ?, ?)", tokenHash(devicePairingKey(request.Hash())), payload, request.ExpiresAt); err != nil {
		return result, err
	}
	return result, tx.Commit()
}

func pairingAccountAllowed(ctx context.Context, tx *sql.Tx, request identity.DevicePairingRequest) error {
	if err := accountAllowed(ctx, tx, request.AccountID); err != nil {
		return err
	}
	var root string
	err := tx.QueryRowContext(ctx, "SELECT account_key FROM member_identities WHERE member_id = ?", request.AccountID).Scan(&root)
	if errors.Is(err, sql.ErrNoRows) || err == nil && root != request.AccountKey {
		return ErrIdentityConflict
	}
	if err != nil {
		return err
	}
	blocked, err := deviceBlocked(ctx, tx, request.DeviceKey)
	if err != nil {
		return err
	}
	if blocked {
		return ErrBlacklisted
	}
	return nil
}

func pairingIssuerAllowed(ctx context.Context, tx *sql.Tx, request identity.DevicePairingRequest, issuer identity.Device) error {
	if issuer.Validate(time.Now()) != nil || issuer.AccountKey != request.AccountKey || len(issuer.Certificates) >= identity.MaxChain || !issuer.Certificates[len(issuer.Certificates)-1].CanEnroll {
		return ErrDeviceIdentity
	}
	blocked, err := deviceBlocked(ctx, tx, issuer.LeafKey())
	if err != nil {
		return err
	}
	if blocked {
		return ErrBlacklisted
	}
	var data []byte
	err = tx.QueryRowContext(ctx, "SELECT document FROM registered_devices WHERE device_key = ? AND member_id = ? AND account_key = ?", issuer.LeafKey(), request.AccountID, request.AccountKey).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrDeviceIdentity
	}
	if err != nil {
		return err
	}
	var registered identity.Device
	if json.Unmarshal(data, &registered) != nil || registered.Hash() != issuer.Hash() {
		return ErrDeviceIdentity
	}
	return nil
}

func pairingPacket(payload, kind string) bool {
	var packet struct{ Kind, Key, Mac string }
	if json.Unmarshal([]byte(payload), &packet) != nil || packet.Kind != kind {
		return false
	}
	if kind == "Mac" {
		return packet.Mac != "" && len(packet.Mac) <= 128 && packet.Key == ""
	}
	return packet.Key != "" && len(packet.Key) <= 128 && packet.Mac == ""
}

// ApplyDevicePairing only authenticates and routes signed messages. The SAS
// comparison and MAC verification are performed independently on both clients.
func (s *Store) ApplyDevicePairing(ctx context.Context, origin string, client ClientIdentity, action identity.DevicePairingAction) (DevicePairingState, error) {
	var result DevicePairingState
	if _, ok := identity.Bytes(action.RequestID, 32); !ok {
		return result, ErrDevicePairing
	}
	tx, err := s.beginWrite(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	if _, err = checkClientVersion(ctx, tx, client); err != nil {
		return result, err
	}
	var payload []byte
	err = tx.QueryRowContext(ctx, "SELECT payload FROM passkey_ceremonies WHERE token_hash = ? AND kind = 'login' AND expires_at > ?", tokenHash(devicePairingKey(action.RequestID)), time.Now().Unix()).Scan(&payload)
	if errors.Is(err, sql.ErrNoRows) {
		return result, ErrDevicePairing
	}
	if err != nil {
		return result, err
	}
	var record devicePairingRecord
	if json.Unmarshal(payload, &record) != nil || record.Purpose != devicePairingPurpose || record.MemberID != record.State.Request.AccountID {
		return result, ErrDevicePairing
	}
	result = record.State
	request := result.Request
	normalized, err := identity.NormalizeOrigin(origin)
	if err != nil || normalized != request.Origin || request.Validate(time.Now()) != nil || action.Validate(request, time.Now()) != nil {
		return result, ErrDevicePairing
	}
	if err = pairingAccountAllowed(ctx, tx, request); err != nil {
		return result, err
	}
	oldActor := action.Action == "offer" || action.Action == "old-confirm" || action.Action == "approve" || action.Action == "poll-old" || action.Action == "cancel-old"
	if oldActor {
		if err = pairingIssuerAllowed(ctx, tx, request, action.Issuer); err != nil {
			return result, err
		}
	}
	if result.Offer != nil {
		if err = pairingIssuerAllowed(ctx, tx, request, result.Offer.Issuer); err != nil {
			return result, err
		}
		unselectedNewRead := (action.Action == "poll-new" || action.Action == "cancel-new") && action.Issuer.LeafKey() == ""
		if !unselectedNewRead && action.Issuer.Hash() != result.Offer.Issuer.Hash() {
			return result, ErrDevicePairing
		}
	} else if !oldActor && action.Issuer.LeafKey() != "" {
		return result, ErrDevicePairing
	}
	if action.Action == "poll-new" || action.Action == "poll-old" {
		return result, tx.Commit()
	}
	// A response can be lost after either client has already progressed. Return
	// the immutable transcript even if approval overtook an earlier exact retry.
	var recorded *identity.DevicePairingAction
	switch action.Action {
	case "offer":
		recorded = result.Offer
	case "reveal":
		recorded = result.Reveal
	case "new-confirm":
		recorded = result.NewConfirmation
	case "old-confirm":
		recorded = result.OldConfirmation
	case "approve":
		recorded = result.Approval
	}
	if recorded != nil && recorded.Payload == action.Payload && recorded.Issuer.Hash() == action.Issuer.Hash() {
		return result, tx.Commit()
	}
	if result.Cancelled || result.Approval != nil {
		if result.Cancelled && (action.Action == "cancel-new" || action.Action == "cancel-old") {
			return result, tx.Commit()
		}
		return result, ErrDevicePairing
	}
	var slot **identity.DevicePairingAction
	switch action.Action {
	case "offer":
		if !pairingPacket(action.Payload, "Accept") {
			return result, ErrDevicePairing
		}
		slot = &result.Offer
	case "reveal":
		if result.Offer == nil || !pairingPacket(action.Payload, "Key") {
			return result, ErrDevicePairing
		}
		slot = &result.Reveal
	case "new-confirm":
		if result.Reveal == nil || !pairingPacket(action.Payload, "Mac") {
			return result, ErrDevicePairing
		}
		slot = &result.NewConfirmation
	case "old-confirm":
		if result.Reveal == nil || !pairingPacket(action.Payload, "Mac") {
			return result, ErrDevicePairing
		}
		slot = &result.OldConfirmation
	case "approve":
		var approval identity.DevicePairingApproval
		if result.NewConfirmation == nil || result.OldConfirmation == nil || json.Unmarshal([]byte(action.Payload), &approval) != nil || approval.Validate(request, action.Issuer, time.Now()) != nil {
			return result, ErrDevicePairing
		}
		slot = &result.Approval
	case "cancel-new", "cancel-old":
		result.Cancelled = true
	default:
		return result, ErrDevicePairing
	}
	if slot != nil {
		if *slot != nil {
			if (*slot).Payload != action.Payload || (*slot).Issuer.Hash() != action.Issuer.Hash() {
				return result, ErrDevicePairing
			}
			return result, tx.Commit()
		}
		*slot = &action
	}
	record.State = result
	payload, err = json.Marshal(record)
	if err != nil {
		return result, err
	}
	updated, err := tx.ExecContext(ctx, "UPDATE passkey_ceremonies SET payload = ? WHERE token_hash = ? AND expires_at > ?", payload, tokenHash(devicePairingKey(action.RequestID)), time.Now().Unix())
	if err = changed(updated, err); err != nil {
		return result, err
	}
	return result, tx.Commit()
}
