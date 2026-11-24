// Package testidentity builds deterministic public V5 fixtures. Its keys are
// intentionally public test data and must never be used by production clients.
package testidentity

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"sort"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

type Client struct {
	Root, Key ed25519.PrivateKey
	Device    identity.Device
}

func key(label string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("chirp-v5-test-only:" + label))
	return ed25519.NewKeyFromSeed(seed[:])
}
func public(private ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(private.Public().(ed25519.PublicKey))
}

func New(label string) Client {
	root, private := key(label+":root"), key(label+":device")
	now := time.Now().Unix()
	cert := identity.Certificate{AccountKey: public(root), DeviceKey: public(private), IssuerKey: public(root), Serial: base64.StdEncoding.EncodeToString(make([]byte, 16)), CanEnroll: true, NotBefore: now - 1, NotAfter: now + int64(identity.MaxDeviceLifetime/time.Second) - 1}
	cert.Signature = identity.Sign(root, cert.Message())
	return Client{root, private, identity.Device{AccountKey: public(root), Certificates: []identity.Certificate{cert}}}
}

func Child(parent Client, label string, canEnroll bool) Client {
	private := key(label + ":device")
	now := time.Now().Unix()
	cert := identity.Certificate{AccountKey: parent.Device.AccountKey, DeviceKey: public(private), IssuerKey: parent.Device.LeafKey(), ParentHash: parent.Device.Certificates[len(parent.Device.Certificates)-1].Hash(), Serial: base64.StdEncoding.EncodeToString(make([]byte, 16)), CanEnroll: canEnroll, NotBefore: now - 1, NotAfter: parent.Device.Certificates[len(parent.Device.Certificates)-1].NotAfter}
	cert.Signature = identity.Sign(parent.Key, cert.Message())
	chain := append(append([]identity.Certificate{}, parent.Device.Certificates...), cert)
	return Client{nil, private, identity.Device{AccountKey: parent.Device.AccountKey, Certificates: chain}}
}

func (c Client) Login(client, authorization, verifier string) identity.LoginProof {
	proof := identity.LoginProof{Device: c.Device, Nonce: base64.StdEncoding.EncodeToString(make([]byte, 32))}
	proof.Signature = identity.Sign(c.Key, proof.Message(client, authorization, verifier))
	return proof
}

func (c Client) Policy(origin, room string, clients ...Client) identity.RoomPolicy {
	roots := []string{c.Device.AccountKey}
	seen := map[string]bool{c.Device.AccountKey: true}
	for _, peer := range clients {
		if !seen[peer.Device.AccountKey] {
			roots = append(roots, peer.Device.AccountKey)
			seen[peer.Device.AccountKey] = true
		}
	}
	sort.Strings(roots)
	now := time.Now().Unix()
	policy := identity.RoomPolicy{Origin: origin, RoomID: room, TrustID: identity.Hash([]byte(origin + "/" + room)), OwnerKey: c.Device.AccountKey, Version: 1, Members: roots, RevokedDevices: []string{}, NotBefore: now - 1, NotAfter: now + int64(identity.MaxPolicyLifetime/time.Second) - 1, Signer: c.Device}
	policy.Signature = identity.Sign(c.Key, policy.Message())
	return policy
}

func (c Client) Binding(policy identity.RoomPolicy, admission, mlsKey string) identity.EntryBinding {
	now := time.Now().Unix()
	binding := identity.EntryBinding{Device: c.Device, Origin: policy.Origin, RoomID: policy.RoomID, TrustID: policy.TrustID, PolicyHash: policy.Hash(), Identity: admission, MLSKey: mlsKey, Nonce: identity.Hash([]byte("nonce:" + admission)), NotBefore: now - 1, NotAfter: now + int64(identity.MaxEntryLifetime/time.Second) - 1}
	binding.Signature = identity.Sign(c.Key, binding.Message())
	return binding
}
