package store

import (
	"errors"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
	"testing"
	"time"
)

func TestSocialHistoryUsesSignedVersionedOperationsAndPermanentTombstones(t *testing.T) {
	db := openTestStore(t)
	account := approvedAccount(t, db)
	client := testidentity.New("social-owner")
	login := activateIdentity(t, db, account, client)
	friend := testidentity.New("social-friend")
	event := identity.SocialEvent{Origin: setupTestOrigin, AccountID: login.Member.ID, Version: 1, Operation: "friend", FriendID: "member_friend", FriendKey: friend.Device.AccountKey, Name: "Friend", Signer: client.Device}
	if err := db.AppendSocialEvent(t.Context(), login.Member, event); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("unsigned trust source accepted", err)
	}
	event.Signature = identity.Sign(client.Key, event.Message())
	if err := db.AppendSocialEvent(t.Context(), login.Member, event); err != nil {
		t.Fatal(err)
	}
	if err := db.AppendSocialEvent(t.Context(), login.Member, event); err != nil {
		t.Fatal("lost response retry was not idempotent", err)
	}
	trust := event
	trust.Version = 2
	trust.PreviousHash = event.Hash()
	trust.Operation = "trust"
	trust.DeviceKey = friend.Device.LeafKey()
	trust.Signature = identity.Sign(client.Key, trust.Message())
	if err := db.AppendSocialEvent(t.Context(), login.Member, trust); err != nil {
		t.Fatal(err)
	}
	removal := trust
	removal.Version = 3
	removal.PreviousHash = trust.Hash()
	removal.Operation = "remove_friend"
	removal.DeviceKey = ""
	removal.Signature = identity.Sign(client.Key, removal.Message())
	if err := db.AppendSocialEvent(t.Context(), login.Member, removal); err != nil {
		t.Fatal(err)
	}
	if err := db.AppendSocialEvent(t.Context(), login.Member, trust); !errors.Is(err, ErrSocialConflict) {
		t.Fatal("old snapshot restored deleted trust", err)
	}
	history, err := db.SocialEvents(t.Context(), login.Member, 0)
	if err != nil || len(history) != 3 || history[2].Operation != "remove_friend" || history[2].PreviousHash != history[1].Hash() {
		t.Fatal(history, err)
	}
	child := testidentity.Child(client, "social-next-device", true)
	next := activateIdentity(t, db, account, child)
	if err := db.AppendSocialEvent(t.Context(), login.Member, removal); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("replaced login modified shared trust", err)
	}
	history, err = db.SocialEvents(t.Context(), next.Member, 0)
	if err != nil || len(history) != 3 {
		t.Fatal("new device did not receive account history", err)
	}
}

func TestIdentitySignalsAreSignedAndBoundToBothCurrentRoomEntries(t *testing.T) {
	db := openTestStore(t)
	accountA := approvedAccount(t, db)
	accountB := PasskeyAccount{ID: "account_signals_b", Nickname: "Bobby", CredentialID: []byte("signals-public-b"), CredentialJSON: []byte(`{}`)}
	request, err := db.RegisterPasskey(t.Context(), accountB)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.ApproveRegistration(t.Context(), request.RequestID); err != nil {
		t.Fatal(err)
	}
	a, b := testidentity.New("signals-a"), testidentity.New("signals-b")
	loginA, loginB := activateIdentity(t, db, accountA, a), activateIdentity(t, db, accountB, b)
	entryA, err := db.JoinRoom(t.Context(), loginA.Member, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	entryB, err := db.JoinRoom(t.Context(), loginB.Member, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	signal := identity.Signal{ID: identity.Hash([]byte("test signal")), Origin: setupTestOrigin, RoomID: "friends", Sender: loginA.Member.ID, Recipient: loginB.Member.ID, SenderEntry: entryA.Identity(), RecipientEntry: entryB.Identity(), Kind: "sas", Payload: `{"kind":"Request"}`, ExpiresAt: time.Now().Add(time.Minute).Unix(), Device: a.Device}
	if err = db.SendIdentitySignal(t.Context(), loginA.Member, signal); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("unsigned verification accepted", err)
	}
	signal.Signature = identity.Sign(a.Key, signal.Message())
	if err = db.SendIdentitySignal(t.Context(), loginA.Member, signal); err != nil {
		t.Fatal(err)
	}
	received, err := db.IdentitySignals(t.Context(), loginB.Member, 0)
	if err != nil || len(received) != 1 || received[0].Signal.Signature != signal.Signature {
		t.Fatal("signal routing failed", received, err)
	}
	received, err = db.IdentitySignals(t.Context(), loginA.Member, 0)
	if err != nil || len(received) != 0 {
		t.Fatal("recipient isolation failed", received, err)
	}
	if err = db.LeaveRoom(t.Context(), loginB.Member, "friends", entryB.EntryID); err != nil {
		t.Fatal(err)
	}
	if err = db.SendIdentitySignal(t.Context(), loginA.Member, signal); !errors.Is(err, ErrDeviceIdentity) {
		t.Fatal("old room entry still accepted signals", err)
	}
}
