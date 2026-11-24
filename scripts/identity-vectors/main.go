// Regenerates deterministic PUBLIC test vectors, never deployment credentials.
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"golang.org/x/crypto/argon2"
)

func key(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("V5 PUBLIC TEST VECTOR " + label))
	return ed25519.NewKeyFromSeed(seed[:])
}
func public(key ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
}
func check(err error) {
	if err != nil {
		panic(err)
	}
}
func write(name string, value any) {
	data, err := json.MarshalIndent(value, "", "  ")
	check(err)
	data = append(data, '\n')
	for _, directory := range []string{"internal/identity/testdata", "Client/apple/MLS/Tests/ChirpMLSTests/Fixtures"} {
		check(os.WriteFile(filepath.Join(directory, name), data, 0644))
	}
}

func main() {
	root, deviceKey, mls := key("root"), key("device"), key("mls")
	const now int64 = 1800000000
	certificate := identity.Certificate{AccountKey: public(root), DeviceKey: public(deviceKey), IssuerKey: public(root), Serial: base64.StdEncoding.EncodeToString(make([]byte, 16)), CanEnroll: true, NotBefore: now - 1, NotAfter: now + 3600}
	certificate.Signature = identity.Sign(root, certificate.Message())
	device := identity.Device{AccountKey: public(root), Certificates: []identity.Certificate{certificate}}
	policy := identity.RoomPolicy{Origin: "https://voice.example.test", RoomID: "friends", TrustID: identity.Hash([]byte("V5 vector room")), OwnerKey: public(root), Version: 1, Members: []string{public(root)}, RevokedDevices: []string{}, NotBefore: now - 1, NotAfter: now + 1800, Signer: device}
	policy.Signature = identity.Sign(deviceKey, policy.Message())
	binding := identity.EntryBinding{Device: device, Origin: policy.Origin, RoomID: policy.RoomID, TrustID: policy.TrustID, PolicyHash: policy.Hash(), Identity: "member.login.entry_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", MLSKey: public(mls), Nonce: identity.Hash([]byte("V5 vector nonce")), NotBefore: now - 1, NotAfter: now + 1200}
	binding.Signature = identity.Sign(deviceKey, binding.Message())
	offer := identity.RoundProof{GroupID: "fixture/server/session/1", PolicyHash: policy.Hash(), RosterHash: identity.RosterHash([]identity.EntryBinding{binding}), KeyPackageHash: identity.Hash([]byte("public fixture package"))}
	offer.Signature = identity.Sign(mls, offer.Message())
	ready := identity.ReadyProof{GroupID: offer.GroupID, PolicyHash: policy.Hash(), RosterHash: offer.RosterHash, Confirmation: identity.Hash([]byte("public fixture confirmation"))}
	ready.Signature = identity.Sign(mls, ready.Message())
	login := identity.LoginProof{Device: device, Nonce: identity.Hash([]byte("public fixture login nonce"))}
	login.Signature = identity.Sign(deviceKey, login.Message("chirp-apple", "authorization-vector", "pkce-verifier-vector"))
	messages := map[string]string{}
	for name, message := range map[string][]byte{"certificate": certificate.Message(), "policy": policy.Message(), "binding": binding.Message(), "offer": offer.Message(), "ready": ready.Message(), "login": login.Message("chirp-apple", "authorization-vector", "pkce-verifier-vector")} {
		messages[name] = base64.StdEncoding.EncodeToString(message)
	}
	write("v5.json", map[string]any{"now": now, "device": device, "policy": policy, "binding": binding, "offer": offer, "ready": ready, "login": login, "messages": messages,
		"hashes": map[string]string{"certificate": certificate.Hash(), "device": device.Hash(), "policy": policy.Hash(), "binding": binding.Hash(), "roster": offer.RosterHash}})
	request := identity.DevicePairingRequest{Version: 1, Origin: "https://fixture.test:443", AccountID: "member_pairing_vector", AccountKey: public(root), DeviceKey: public(deviceKey), Nonce: identity.Hash([]byte("pairing nonce")), ExpiresAt: 1700000297, Commitment: identity.Hash([]byte("pairing commitment"))}
	request.Signature = identity.Sign(deviceKey, request.Message())
	action := identity.DevicePairingAction{RequestID: request.Hash(), Action: "reveal", Issuer: identity.Device{Certificates: []identity.Certificate{}}, Payload: `{"kind":"Key","key":"ephemeral-public-key"}`, Nonce: identity.Hash([]byte("pairing action nonce")), CreatedAt: 1700000001}
	action.Signature = identity.Sign(deviceKey, action.Message())
	write("device-pairing-v1.json", map[string]any{"request": request, "action": action, "context": request.Context(), "request_digest": request.Hash(), "request_message": base64.StdEncoding.EncodeToString(request.Message()), "action_message": base64.StdEncoding.EncodeToString(action.Message())})
	// This known-answer container has public fixed salt/nonce/password. Never use
	// this deterministic operation to encrypt a real recovery backup.
	data, err := os.ReadFile("internal/identity/testdata/recovery-v1.json")
	check(err)
	var recovery map[string]string
	check(json.Unmarshal(data, &recovery))
	payload := []byte(recovery["payload"])
	header := []byte("CHIRPKEY")
	header = binary.BigEndian.AppendUint16(header, 1) // container version
	header = binary.BigEndian.AppendUint16(header, 1) // cipher suite
	header = binary.BigEndian.AppendUint32(header, 65536)
	header = binary.BigEndian.AppendUint32(header, 3)
	header = binary.BigEndian.AppendUint16(header, 4)
	publicBytes := sha256.Sum256([]byte("CHIRPKEY v1 public fixture salt and nonce"))
	salt, nonce := publicBytes[:16], publicBytes[16:28]
	header = append(header, salt...)
	header = append(header, nonce...)
	header = binary.BigEndian.AppendUint32(header, uint32(len(payload)))
	derived := argon2.IDKey([]byte(recovery["password"]), salt, 3, 65536, 4, 32)
	block, err := aes.NewCipher(derived)
	check(err)
	gcm, err := cipher.NewGCM(block)
	check(err)
	sealed := gcm.Seal(nil, nonce, payload, header)
	recovery["file"] = base64.StdEncoding.EncodeToString(append(header, sealed...))
	write("recovery-v1.json", recovery)
}
