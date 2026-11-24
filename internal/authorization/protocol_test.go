package authorization

import (
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

const testOrigin = "https://fixture.test:443"

func signedEvent(state *State, signer testidentity.Client, operation, target string, social *identity.SocialEvent) Event {
	event := Event{Origin: testOrigin, Version: state.Version + 1, PreviousHash: state.Head,
		Operation: operation, Signer: signer.Device, TargetKey: target, Social: social}
	event.Signature = identity.Sign(signer.Key, event.Message())
	return event
}

func emptyState(root string) *State {
	return &State{Root: root, Devices: map[string]identity.Device{}, Revoked: map[string]bool{}}
}

func TestRevocationCutsOffNewAuthorityButPreservesRegisteredChildren(t *testing.T) {
	t.Parallel()
	owner := testidentity.New("authorization-owner")
	old := testidentity.Child(owner, "old", true)
	child := testidentity.Child(old, "already-registered-child", true)
	state := emptyState(owner.Device.AccountKey)
	now := time.Now()
	account := Account{Root: owner.Device.AccountKey}
	for _, device := range []testidentity.Client{owner, old, child} {
		event := signedEvent(state, device, "enroll", "", nil)
		if err := state.Apply(event, now); err != nil {
			t.Fatal(err)
		}
		account.Records = append(account.Records, Record{Event: event, AcceptedAt: now.Unix()})
	}
	event := signedEvent(state, owner, "revoke", old.Device.LeafKey(), nil)
	if err := state.Apply(event, now); err != nil {
		t.Fatal(err)
	}
	account.Records = append(account.Records, Record{Event: event, AcceptedAt: now.Unix()})
	for _, tc := range []struct {
		name  string
		event Event
	}{
		{"revoked device cannot enroll again", signedEvent(state, old, "enroll", "", nil)},
		{"revoked issuer cannot register another child", signedEvent(state, testidentity.Child(old, "late-child", true), "enroll", "", nil)},
		{"revoked device cannot revoke another", signedEvent(state, old, "revoke", owner.Device.LeafKey(), nil)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if state.Apply(tc.event, now) == nil {
				t.Fatal("unauthorized transition accepted")
			}
		})
	}
	social := identity.SocialEvent{Origin: testOrigin, AccountID: "owner", Version: 1, Operation: "trust", FriendID: "friend", FriendKey: child.Device.AccountKey, DeviceKey: child.Device.LeafKey(), Signer: old.Device}
	social.Signature = identity.Sign(old.Key, social.Message())
	if state.Apply(signedEvent(state, old, "social", "", &social), now) == nil {
		t.Fatal("revoked signer granted fresh trust")
	}
	replayed, err := Replay(testOrigin, account)
	if err != nil {
		t.Fatal(err)
	}
	if replayed.Active(old.Device, now) || !replayed.Active(child.Device, now) {
		t.Fatal("revocation incorrectly changed independent registered device")
	}
}

func TestHistoryPreservesOnlyOperationsCommittedWhileAuthorized(t *testing.T) {
	t.Parallel()
	owner := testidentity.New("history-owner")
	other := testidentity.Child(owner, "history-other", true)
	state := emptyState(owner.Device.AccountKey)
	now := time.Now()
	var records []Record
	appendEvent := func(e Event) {
		t.Helper()
		if err := state.Apply(e, now); err != nil {
			t.Fatal(err)
		}
		records = append(records, Record{Event: e, AcceptedAt: now.Unix()})
	}
	appendEvent(signedEvent(state, owner, "enroll", "", nil))
	appendEvent(signedEvent(state, other, "enroll", "", nil))
	social := identity.SocialEvent{Origin: testOrigin, AccountID: "owner", Version: 1, Operation: "friend", FriendID: "friend", FriendKey: owner.Device.AccountKey, Signer: other.Device}
	social.Signature = identity.Sign(other.Key, social.Message())
	appendEvent(signedEvent(state, other, "social", "", &social))
	appendEvent(signedEvent(state, owner, "revoke", other.Device.LeafKey(), nil))
	verified, err := Replay(testOrigin, Account{Root: owner.Device.AccountKey, Records: records})
	if err != nil || len(verified.Social) != 1 {
		t.Fatalf("historical trust lost: %v", err)
	}
	social.PreviousHash = social.Hash()
	social.Version = 2
	social.Signature = identity.Sign(other.Key, social.Message())
	if state.Apply(signedEvent(state, other, "social", "", &social), now) == nil {
		t.Fatal("new record accepted after revocation")
	}
	changed := append([]Record(nil), records...)
	changed[2].Event.PreviousHash = ""
	if _, err = Replay(testOrigin, Account{Root: owner.Device.AccountKey, Records: changed}); err == nil {
		t.Fatal("modified history accepted")
	}
}
