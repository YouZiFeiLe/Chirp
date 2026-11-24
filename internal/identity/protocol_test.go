package identity_test

import (
	"encoding/base64"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func TestCertificateDelegationAndPossession(t *testing.T) {
	owner := testidentity.New("owner")
	child := testidentity.Child(owner, "new-device", false)
	if err := child.Device.Validate(time.Now()); err != nil {
		t.Fatal(err)
	}
	grandchild := testidentity.Child(child, "unauthorized-delegation", false)
	if grandchild.Device.Validate(time.Now()) == nil {
		t.Fatal("device without enrollment permission issued a certificate")
	}
	proof := child.Login("chirp-apple", "authorization", "verifier")
	if proof.Validate("chirp-apple", "authorization", "verifier", time.Now()) != nil {
		t.Fatal("valid login failed")
	}
	if proof.Validate("chirp-apple", "other-authorization", "verifier", time.Now()) == nil {
		t.Fatal("cross-authorization replay accepted")
	}
	proof.Device = owner.Device
	if proof.Validate("chirp-apple", "authorization", "verifier", time.Now()) == nil {
		t.Fatal("copied public identity authenticated without private key")
	}
}

func TestRoomPolicyRevocationIsLimitedToTheExactLeaf(t *testing.T) {
	owner := testidentity.New("room-owner")
	bob := testidentity.New("bob")
	impostor := testidentity.New("impostor")
	policy := owner.Policy("https://example.test", "friends", bob)
	if policy.Validate(time.Now()) != nil {
		t.Fatal("valid policy failed")
	}
	if policy.Allows(impostor.Device, time.Now()) == nil {
		t.Fatal("unapproved account admitted")
	}
	child := testidentity.Child(bob, "bob-child", true)
	key, _ := base64.StdEncoding.DecodeString(bob.Device.LeafKey())
	policy.RevokedDevices = []string{identity.Hash(key)}
	policy.Signature = identity.Sign(owner.Key, policy.Message())
	if policy.Allows(child.Device, time.Now()) != nil {
		t.Fatal("registered child lost independent identity")
	}
	if policy.Allows(bob.Device, time.Now()) == nil {
		t.Fatal("revoked leaf survived")
	}
	policy.Members = append(policy.Members, impostor.Device.AccountKey)
	if policy.Validate(time.Now()) == nil {
		t.Fatal("server changed signed membership")
	}
}

func TestEntryBindingCannotBeMovedAcrossIdentitiesRoomsOrMLSKeys(t *testing.T) {
	owner := testidentity.New("entry-owner")
	policy := owner.Policy("https://example.test", "friends")
	binding := owner.Binding(policy, "member.login.entry", owner.Device.LeafKey())
	if binding.Validate(policy, time.Now()) != nil {
		t.Fatal("valid binding failed")
	}
	for _, mutate := range []func(*identity.EntryBinding){func(e *identity.EntryBinding) { e.Identity = "other.login.entry" }, func(e *identity.EntryBinding) { e.RoomID = "other" }, func(e *identity.EntryBinding) { e.MLSKey = testidentity.New("replacement").Device.LeafKey() }, func(e *identity.EntryBinding) { e.Nonce = identity.Hash([]byte("replayed")) }} {
		copy := binding
		mutate(&copy)
		if copy.Validate(policy, time.Now()) == nil {
			t.Fatal("modified binding accepted")
		}
	}
}
