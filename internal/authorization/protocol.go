// Package authorization implements the application's V5 authorization log and signed snapshots.
// It never receives MLS secrets, media keys, attachments, or chat plaintext.
package authorization

import (
	"errors"
	"strconv"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

const MaxRecords = 8192
const MaxOrdinaryRecords = 4096
const MaxDevices = 128

var ErrInvalid = errors.New("invalid authorization transition")
var ErrConflict = errors.New("authorization head changed")

// Event is signed by the acting device. Enrollment additionally requires an
// existing active issuer, or a direct root certificate (bootstrap/recovery).
type Event struct {
	Origin       string                `json:"origin"`
	Version      int64                 `json:"version"`
	PreviousHash string                `json:"previous_hash"`
	Operation    string                `json:"operation"`
	Signer       identity.Device       `json:"signer"`
	TargetKey    string                `json:"target_key"`
	Social       *identity.SocialEvent `json:"social,omitempty"`
	SocialHash   string                `json:"social_hash,omitempty"`
	Signature    string                `json:"signature"`
}

func (e Event) Message() []byte {
	social := e.SocialHash
	if e.Social != nil {
		social = e.Social.Hash()
	}
	return identity.Message("Chirp authorization event v5", e.Origin, strconv.FormatInt(e.Version, 10), e.PreviousHash, e.Operation, e.Signer.Hash(), e.TargetKey, social)
}

func (e Event) Hash() string {
	return identity.Hash(identity.Message("Chirp authorization event digest v5", string(e.Message()), e.Signature))
}

type Record struct {
	Event      Event `json:"event"`
	AcceptedAt int64 `json:"accepted_at"`
}

type Account struct {
	Root    string   `json:"root"`
	Records []Record `json:"records"`
}

// State is derived exclusively by replaying the authenticated, complete log.
type State struct {
	Root    string
	Version int64
	Head    string
	Devices map[string]identity.Device
	Revoked map[string]bool
	Social  []identity.SocialEvent
}

func Replay(origin string, account Account) (*State, error) {
	if _, ok := identity.Bytes(account.Root, 32); !ok || len(account.Records) > MaxRecords {
		return nil, ErrInvalid
	}
	s := &State{Root: account.Root, Devices: map[string]identity.Device{}, Revoked: map[string]bool{}}
	var previousTime int64
	for _, record := range account.Records {
		if record.AcceptedAt < previousTime || record.Event.Origin != origin {
			return nil, ErrInvalid
		}
		if err := s.Apply(record.Event, time.Unix(record.AcceptedAt, 0)); err != nil {
			return nil, err
		}
		previousTime = record.AcceptedAt
	}
	return s, nil
}

func (s *State) Active(device identity.Device, now time.Time) bool {
	registered, ok := s.Devices[device.LeafKey()]
	return ok && !s.Revoked[device.LeafKey()] && registered.Hash() == device.Hash() && device.Validate(now) == nil
}

func (s *State) Apply(e Event, now time.Time) error {
	if e.Version != s.Version+1 || e.PreviousHash != s.Head {
		return ErrConflict
	}
	if e.SocialHash != "" || e.Version > MaxRecords || e.Signer.AccountKey != s.Root || e.Signer.Validate(now) != nil ||
		!identity.Verify(e.Signer.LeafKey(), e.Signature, e.Message()) {
		return ErrInvalid
	}
	// Preserve room for revoking every registered key even after ordinary
	// writes reach capacity. Limits reject new grants, never silently evict history.
	if e.Operation != "revoke" && e.Version > MaxOrdinaryRecords {
		return ErrInvalid
	}
	switch e.Operation {
	case "enroll":
		if e.Social != nil || e.TargetKey != "" || s.Revoked[e.Signer.LeafKey()] || len(s.Devices) >= MaxDevices {
			return ErrInvalid
		}
		if _, exists := s.Devices[e.Signer.LeafKey()]; exists {
			return ErrInvalid
		}
		chain := e.Signer.Certificates
		last := chain[len(chain)-1]
		if len(chain) > 1 {
			issuer := identity.Device{AccountKey: s.Root, Certificates: chain[:len(chain)-1]}
			if !s.Active(issuer, now) || !issuer.Certificates[len(issuer.Certificates)-1].CanEnroll {
				return ErrInvalid
			}
		} else if last.IssuerKey != s.Root {
			return ErrInvalid
		}
		s.Devices[e.Signer.LeafKey()] = e.Signer
	case "revoke":
		if e.Social != nil || !s.Active(e.Signer, now) || !e.Signer.Certificates[len(e.Signer.Certificates)-1].CanEnroll {
			return ErrInvalid
		}
		if _, exists := s.Devices[e.TargetKey]; !exists || s.Revoked[e.TargetKey] {
			return ErrInvalid
		}
		s.Revoked[e.TargetKey] = true
	case "social":
		if e.TargetKey != "" || e.Social == nil || !s.Active(e.Signer, now) || e.Social.Signer.Hash() != e.Signer.Hash() ||
			e.Social.Origin != e.Origin || e.Social.Validate(now) != nil {
			return ErrInvalid
		}
		previous := ""
		if len(s.Social) > 0 {
			previous = s.Social[len(s.Social)-1].Hash()
		}
		if e.Social.Version != int64(len(s.Social))+1 || e.Social.PreviousHash != previous {
			return ErrConflict
		}
		s.Social = append(s.Social, *e.Social)
	default:
		return ErrInvalid
	}
	s.Version, s.Head = e.Version, e.Hash()
	return nil
}
