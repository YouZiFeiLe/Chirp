// Package identity implements the public, independently verifiable V5 identity
// documents. Signing keys belong to clients; the server only verifies proofs.
package identity

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"
)

const Protocol = "chirp-mls-authenticated-v5"
const MaxChain = 8
const MaxDeviceLifetime = 5 * 365 * 24 * time.Hour
const MaxPolicyLifetime = 24 * time.Hour
const MaxEntryLifetime = 20 * time.Hour

var ErrInvalid = errors.New("invalid V5 identity or authorization proof")

// Message is the cross-language signing format: a domain and a sequence of
// byte fields, each prefixed by its unsigned 32-bit big-endian byte length.
// Text uses UTF-8; digest records embed the original binary message unchanged.
// Arrays include their count before their elements. No JSON bytes are signed.
func Message(domain string, fields ...string) []byte {
	var out []byte
	for _, field := range append([]string{domain}, fields...) {
		out = binary.BigEndian.AppendUint32(out, uint32(len(field)))
		out = append(out, field...)
	}
	return out
}

func Hash(data []byte) string {
	sum := sha256.Sum256(data)
	return base64.StdEncoding.EncodeToString(sum[:])
}

func Bytes(value string, size int) ([]byte, bool) {
	b, err := base64.StdEncoding.Strict().DecodeString(value)
	return b, err == nil && len(b) == size && base64.StdEncoding.EncodeToString(b) == value
}

func Verify(key, signature string, message []byte) bool {
	k, ok := Bytes(key, ed25519.PublicKeySize)
	s, valid := Bytes(signature, ed25519.SignatureSize)
	return ok && valid && ed25519.Verify(k, message, s)
}

func Sign(key ed25519.PrivateKey, message []byte) string {
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, message))
}

func validTime(start, end int64, limit time.Duration, now time.Time) bool {
	return start > 0 && end > start && end-start <= int64(limit/time.Second) && start <= now.Unix()+60 && end > now.Unix()
}

type Certificate struct {
	AccountKey string `json:"account_key"`
	DeviceKey  string `json:"device_key"`
	IssuerKey  string `json:"issuer_key"`
	ParentHash string `json:"parent_hash"`
	Serial     string `json:"serial"`
	CanEnroll  bool   `json:"can_enroll"`
	NotBefore  int64  `json:"not_before"`
	NotAfter   int64  `json:"not_after"`
	Signature  string `json:"signature"`
}

func (c Certificate) Message() []byte {
	permission := "0"
	if c.CanEnroll {
		permission = "1"
	}
	return Message("Chirp device certificate v5", c.AccountKey, c.DeviceKey, c.IssuerKey, c.ParentHash, c.Serial, permission, strconv.FormatInt(c.NotBefore, 10), strconv.FormatInt(c.NotAfter, 10))
}

func (c Certificate) Hash() string {
	return Hash(Message("Chirp device certificate digest v5", string(c.Message()), c.Signature))
}

type Device struct {
	AccountKey   string        `json:"account_key"`
	Certificates []Certificate `json:"certificates"`
}

func (d Device) LeafKey() string {
	if len(d.Certificates) == 0 {
		return ""
	}
	return d.Certificates[len(d.Certificates)-1].DeviceKey
}

func (d Device) Hash() string {
	fields := []string{d.AccountKey, strconv.Itoa(len(d.Certificates))}
	for _, c := range d.Certificates {
		fields = append(fields, c.Hash())
	}
	return Hash(Message("Chirp device identity digest v5", fields...))
}

func (d Device) Validate(now time.Time) error {
	if _, ok := Bytes(d.AccountKey, 32); !ok || len(d.Certificates) == 0 || len(d.Certificates) > MaxChain {
		return ErrInvalid
	}
	issuer, parent, deadline := d.AccountKey, "", int64(1<<63-1)
	seen := map[string]bool{issuer: true}
	for i, c := range d.Certificates {
		_, keyOK := Bytes(c.DeviceKey, 32)
		_, serialOK := Bytes(c.Serial, 16)
		if !keyOK || !serialOK || c.AccountKey != d.AccountKey || c.IssuerKey != issuer || c.ParentHash != parent || seen[c.DeviceKey] || c.NotAfter > deadline || !validTime(c.NotBefore, c.NotAfter, MaxDeviceLifetime, now) || !Verify(issuer, c.Signature, c.Message()) {
			return ErrInvalid
		}
		if i < len(d.Certificates)-1 && !c.CanEnroll {
			return ErrInvalid
		}
		seen[c.DeviceKey] = true
		issuer, parent, deadline = c.DeviceKey, c.Hash(), c.NotAfter
	}
	return nil
}

type LoginProof struct {
	Device    Device `json:"device"`
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"`
}

func (p LoginProof) Message(client, authorization, verifier string) []byte {
	return Message("Chirp login activation v5", client, Hash([]byte(authorization)), Hash([]byte(verifier)), p.Device.Hash(), p.Nonce)
}

func (p LoginProof) Validate(client, authorization, verifier string, now time.Time) error {
	if _, ok := Bytes(p.Nonce, 32); !ok || p.Device.Validate(now) != nil || !Verify(p.Device.LeafKey(), p.Signature, p.Message(client, authorization, verifier)) {
		return ErrInvalid
	}
	return nil
}

type RoomPolicy struct {
	Origin         string   `json:"origin"`
	RoomID         string   `json:"room_id"`
	TrustID        string   `json:"trust_id"`
	OwnerKey       string   `json:"owner_key"`
	Version        int64    `json:"version"`
	PreviousHash   string   `json:"previous_hash"`
	Members        []string `json:"members"`
	RevokedDevices []string `json:"revoked_devices"`
	NotBefore      int64    `json:"not_before"`
	NotAfter       int64    `json:"not_after"`
	Signer         Device   `json:"signer"`
	Signature      string   `json:"signature"`
}

func (p RoomPolicy) Message() []byte {
	fields := []string{p.Origin, p.RoomID, p.TrustID, p.OwnerKey, strconv.FormatInt(p.Version, 10), p.PreviousHash, strconv.Itoa(len(p.Members))}
	fields = append(fields, p.Members...)
	fields = append(fields, strconv.Itoa(len(p.RevokedDevices)))
	fields = append(fields, p.RevokedDevices...)
	fields = append(fields, strconv.FormatInt(p.NotBefore, 10), strconv.FormatInt(p.NotAfter, 10), p.Signer.Hash())
	return Message("Chirp room policy v5", fields...)
}

func (p RoomPolicy) Hash() string {
	return Hash(Message("Chirp room policy digest v5", string(p.Message()), p.Signature))
}

func sortedUnique(values []string) bool {
	return slices.IsSorted(values) && len(slices.Compact(slices.Clone(values))) == len(values)
}

func (p RoomPolicy) Validate(now time.Time) error {
	if p.IsMutual() {
		if p.Origin == "" || p.RoomID == "" || len(p.Origin) > 2048 || len(p.RoomID) > 64 || p.Hash() != MutualRoom(p.Origin, p.RoomID).Hash() {
			return ErrInvalid
		}
		return nil
	}
	if p.Origin == "" || len(p.Origin) > 2048 || p.RoomID == "" || len(p.RoomID) > 64 || p.Version < 1 || len(p.Members) == 0 || len(p.Members) > 1024 || len(p.RevokedDevices) > 1024 || !sortedUnique(p.Members) || !sortedUnique(p.RevokedDevices) || !slices.Contains(p.Members, p.OwnerKey) || p.OwnerKey != p.Signer.AccountKey || p.Signer.Validate(now) != nil || !validTime(p.NotBefore, p.NotAfter, MaxPolicyLifetime, now) || !Verify(p.Signer.LeafKey(), p.Signature, p.Message()) {
		return ErrInvalid
	}
	if _, ok := Bytes(p.TrustID, 32); !ok {
		return ErrInvalid
	}
	if p.Version == 1 && p.PreviousHash != "" {
		return ErrInvalid
	}
	if p.Version > 1 {
		if _, ok := Bytes(p.PreviousHash, 32); !ok {
			return ErrInvalid
		}
	}
	for _, root := range p.Members {
		if _, ok := Bytes(root, 32); !ok {
			return ErrInvalid
		}
	}
	for _, id := range p.RevokedDevices {
		if _, ok := Bytes(id, 32); !ok {
			return ErrInvalid
		}
	}
	return p.Allows(p.Signer, now)
}

func (p RoomPolicy) Allows(device Device, now time.Time) error {
	if device.Validate(now) != nil {
		return ErrInvalid
	}
	if p.IsMutual() {
		return p.Validate(now)
	}
	if !slices.Contains(p.Members, device.AccountKey) {
		return ErrInvalid
	}
	key, _ := Bytes(device.LeafKey(), 32)
	if slices.Contains(p.RevokedDevices, Hash(key)) {
		return ErrInvalid
	}
	return nil
}

type EntryBinding struct {
	Device     Device `json:"device"`
	Origin     string `json:"origin"`
	RoomID     string `json:"room_id"`
	TrustID    string `json:"trust_id"`
	PolicyHash string `json:"policy_hash"`
	Identity   string `json:"identity"`
	MLSKey     string `json:"mls_key"`
	Nonce      string `json:"nonce"`
	NotBefore  int64  `json:"not_before"`
	NotAfter   int64  `json:"not_after"`
	Signature  string `json:"signature"`
}

func (e EntryBinding) Message() []byte {
	return Message("Chirp admission binding v5", e.Device.Hash(), e.Origin, e.RoomID, e.TrustID, e.PolicyHash, e.Identity, e.MLSKey, e.Nonce, strconv.FormatInt(e.NotBefore, 10), strconv.FormatInt(e.NotAfter, 10))
}

func (e EntryBinding) Hash() string {
	return Hash(Message("Chirp admission binding digest v5", string(e.Message()), e.Signature))
}

func (e EntryBinding) Validate(policy RoomPolicy, now time.Time) error {
	_, keyOK := Bytes(e.MLSKey, 32)
	_, nonceOK := Bytes(e.Nonce, 32)
	if !keyOK || !nonceOK || e.Origin != policy.Origin || e.RoomID != policy.RoomID || e.TrustID != policy.TrustID || e.PolicyHash != policy.Hash() || e.Identity == "" || len(e.Identity) > 192 || strings.ContainsAny(e.Identity, "\x00\r\n") || policy.Allows(e.Device, now) != nil || !validTime(e.NotBefore, e.NotAfter, MaxEntryLifetime, now) || !Verify(e.Device.LeafKey(), e.Signature, e.Message()) {
		return ErrInvalid
	}
	return nil
}

type RoundProof struct {
	GroupID        string `json:"group_id"`
	KeyEpoch       uint64 `json:"key_epoch"`
	PolicyHash     string `json:"policy_hash"`
	RosterHash     string `json:"roster_hash"`
	KeyPackageHash string `json:"key_package_hash"`
	Signature      string `json:"signature"`
}

func (p RoundProof) Message() []byte {
	return Message("Chirp round offer v5", p.GroupID, strconv.FormatUint(p.KeyEpoch, 10), p.PolicyHash, p.RosterHash, p.KeyPackageHash)
}

type ReadyProof struct {
	GroupID      string `json:"group_id"`
	KeyEpoch     uint64 `json:"key_epoch"`
	PolicyHash   string `json:"policy_hash"`
	RosterHash   string `json:"roster_hash"`
	Confirmation string `json:"confirmation"`
	Signature    string `json:"signature"`
}

func (p ReadyProof) Message() []byte {
	return Message("Chirp epoch ready v5", p.GroupID, strconv.FormatUint(p.KeyEpoch, 10), p.PolicyHash, p.RosterHash, p.Confirmation)
}

func RosterHash(bindings []EntryBinding) string {
	hashes := make([]string, 0, len(bindings))
	for _, binding := range bindings {
		hashes = append(hashes, binding.Hash())
	}
	slices.Sort(hashes)
	fields := append([]string{strconv.Itoa(len(hashes))}, hashes...)
	return Hash(Message("Chirp roster digest v5", fields...))
}
