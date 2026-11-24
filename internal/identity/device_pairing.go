package identity

import (
	"strconv"
	"strings"
	"time"
)

const DevicePairingLifetime = 5 * time.Minute

// DevicePairingRequest is signed by the candidate device. The SAS commitment
// is fixed before an approving device reveals its ephemeral agreement key.
type DevicePairingRequest struct {
	Version    int    `json:"version"`
	Origin     string `json:"origin"`
	AccountID  string `json:"account_id"`
	AccountKey string `json:"account_key"`
	DeviceKey  string `json:"device_key"`
	Nonce      string `json:"nonce"`
	ExpiresAt  int64  `json:"expires_at"`
	Commitment string `json:"commitment"`
	Signature  string `json:"signature"`
}

func (r DevicePairingRequest) Context() string {
	return Hash(Message("Chirp device pairing context v1", strconv.Itoa(r.Version), r.Origin, r.AccountID, r.AccountKey, r.DeviceKey, r.Nonce, strconv.FormatInt(r.ExpiresAt, 10)))
}

func (r DevicePairingRequest) Message() []byte {
	return Message("Chirp device pairing request v1", r.Context(), r.Commitment)
}

func (r DevicePairingRequest) Hash() string {
	return Hash(Message("Chirp device pairing digest v1", string(r.Message()), r.Signature))
}

func (r DevicePairingRequest) Validate(now time.Time) error {
	origin, err := NormalizeOrigin(r.Origin)
	if err != nil || origin != r.Origin || r.Version != 1 || r.AccountID == "" || len(r.AccountID) > 128 || strings.ContainsAny(r.AccountID, "\x00\r\n") || r.ExpiresAt <= now.Unix() || r.ExpiresAt > now.Add(DevicePairingLifetime).Unix() {
		return ErrInvalid
	}
	for _, v := range []string{r.AccountKey, r.DeviceKey, r.Nonce, r.Commitment} {
		if _, ok := Bytes(v, 32); !ok {
			return ErrInvalid
		}
	}
	if r.AccountKey == r.DeviceKey || !Verify(r.DeviceKey, r.Signature, r.Message()) {
		return ErrInvalid
	}
	return nil
}

type DevicePairingApproval struct {
	Device Device `json:"device"`
}

// Issuer pins the exact approving identity on every message after the offer.
// A signature covers the payload bytes, so a relay cannot change the keys
// between verification and certificate issuance.
type DevicePairingAction struct {
	RequestID string `json:"request_id"`
	Action    string `json:"action"`
	Issuer    Device `json:"issuer"`
	Payload   string `json:"payload"`
	Nonce     string `json:"nonce"`
	CreatedAt int64  `json:"created_at"`
	Signature string `json:"signature"`
}

func (a DevicePairingAction) Message() []byte {
	return Message("Chirp device pairing action v1", a.RequestID, a.Action, a.Issuer.Hash(), Hash([]byte(a.Payload)), a.Nonce, strconv.FormatInt(a.CreatedAt, 10))
}

func (a DevicePairingAction) Validate(r DevicePairingRequest, now time.Time) error {
	if a.RequestID != r.Hash() || len(a.Payload) > 16384 || a.CreatedAt <= 0 || a.CreatedAt > now.Unix()+60 || a.CreatedAt > r.ExpiresAt || a.CreatedAt < r.ExpiresAt-int64(DevicePairingLifetime/time.Second)-60 {
		return ErrInvalid
	}
	if _, ok := Bytes(a.Nonce, 32); !ok {
		return ErrInvalid
	}
	key := r.DeviceKey
	switch a.Action {
	case "poll-new", "reveal", "new-confirm", "cancel-new":
	case "offer", "poll-old", "old-confirm", "approve", "cancel-old":
		if a.Issuer.Validate(now) != nil || a.Issuer.AccountKey != r.AccountKey || len(a.Issuer.Certificates) >= MaxChain || !a.Issuer.Certificates[len(a.Issuer.Certificates)-1].CanEnroll || a.Issuer.LeafKey() == r.DeviceKey {
			return ErrInvalid
		}
		key = a.Issuer.LeafKey()
	default:
		return ErrInvalid
	}
	if !Verify(key, a.Signature, a.Message()) {
		return ErrInvalid
	}
	return nil
}

func (a DevicePairingApproval) Validate(r DevicePairingRequest, issuer Device, now time.Time) error {
	if a.Device.Validate(now) != nil || a.Device.AccountKey != r.AccountKey || a.Device.LeafKey() != r.DeviceKey || len(a.Device.Certificates) != len(issuer.Certificates)+1 {
		return ErrInvalid
	}
	for i, c := range issuer.Certificates {
		if a.Device.Certificates[i] != c {
			return ErrInvalid
		}
	}
	return nil
}
