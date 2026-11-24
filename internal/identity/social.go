package identity

import (
	"strconv"
	"time"
)

type SocialEvent struct {
	Origin       string `json:"origin"`
	AccountID    string `json:"account_id"`
	Version      int64  `json:"version"`
	PreviousHash string `json:"previous_hash"`
	Operation    string `json:"operation"`
	FriendID     string `json:"friend_id"`
	FriendKey    string `json:"friend_key"`
	DeviceKey    string `json:"device_key"`
	Name         string `json:"name"`
	Signer       Device `json:"signer"`
	Signature    string `json:"signature"`
}

func (e SocialEvent) Message() []byte {
	return Message("Chirp account social event v5", e.Origin, e.AccountID, strconv.FormatInt(e.Version, 10), e.PreviousHash, e.Operation, e.FriendID, e.FriendKey, e.DeviceKey, e.Name, e.Signer.Hash())
}
func (e SocialEvent) Hash() string {
	return Hash(Message("Chirp account social event digest v5", string(e.Message()), e.Signature))
}
func (e SocialEvent) Validate(now time.Time) error {
	if e.Version < 1 || e.AccountID == "" || len(e.AccountID) > 128 || e.FriendID == "" || len(e.FriendID) > 128 || len(e.Name) > 320 || e.Signer.Validate(now) != nil || !Verify(e.Signer.LeafKey(), e.Signature, e.Message()) {
		return ErrInvalid
	}
	if origin, err := NormalizeOrigin(e.Origin); err != nil || origin != e.Origin {
		return ErrInvalid
	}
	if _, ok := Bytes(e.FriendKey, 32); !ok {
		return ErrInvalid
	}
	if e.Version == 1 && e.PreviousHash != "" {
		return ErrInvalid
	}
	if e.Version > 1 {
		if _, ok := Bytes(e.PreviousHash, 32); !ok {
			return ErrInvalid
		}
	}
	switch e.Operation {
	case "friend", "remove_friend":
		if e.DeviceKey != "" {
			return ErrInvalid
		}
	case "trust", "untrust":
		if _, ok := Bytes(e.DeviceKey, 32); !ok {
			return ErrInvalid
		}
	default:
		return ErrInvalid
	}
	return nil
}

// Signals are routing envelopes for SAS and signed mutual-trust statements.
// They are never accepted as an instruction to trust a server-selected key.
type Signal struct {
	ID             string `json:"id"`
	Origin         string `json:"origin"`
	RoomID         string `json:"room_id"`
	Sender         string `json:"sender"`
	Recipient      string `json:"recipient"`
	SenderEntry    string `json:"sender_entry"`
	RecipientEntry string `json:"recipient_entry"`
	Kind           string `json:"kind"`
	Payload        string `json:"payload"`
	ExpiresAt      int64  `json:"expires_at"`
	Device         Device `json:"device"`
	Signature      string `json:"signature"`
}

func (s Signal) Message() []byte {
	return Message("Chirp identity signal v5", s.ID, s.Origin, s.RoomID, s.Sender, s.Recipient, s.SenderEntry, s.RecipientEntry, s.Kind, s.Payload, strconv.FormatInt(s.ExpiresAt, 10), s.Device.Hash())
}
func (s Signal) Validate(now time.Time) error {
	if _, ok := Bytes(s.ID, 32); !ok {
		return ErrInvalid
	}
	if s.Sender == "" || s.Recipient == "" || len(s.Payload) > 32768 || s.RoomID == "" || s.ExpiresAt <= now.Unix() || s.ExpiresAt > now.Add(10*time.Minute).Unix() || s.Device.Validate(now) != nil || !Verify(s.Device.LeafKey(), s.Signature, s.Message()) {
		return ErrInvalid
	}
	if s.Kind != "sas" && s.Kind != "trust" {
		return ErrInvalid
	}
	return nil
}
