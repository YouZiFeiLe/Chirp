package group

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestRevisionHintsAndHeartbeatsNeverSubstituteForLease(t *testing.T) {
	h := NewHub("friends", DefaultPolicy())
	now := time.Now()
	h.now = func() time.Time { return now }
	a := peer("a")
	s := complete(t, h, a)
	_, changed, ok := h.watch(a.identity(), base64.StdEncoding.EncodeToString(a.key), s.SessionID)
	if !ok {
		t.Fatal("bound watcher rejected")
	}
	for _, op := range []string{"snapshot", "heartbeat", "watch"} {
		next := apply(t, h, a, roundRequest(s, op))
		if next.Revision != s.Revision {
			t.Fatal(op, "changed public state")
		}
	}
	select {
	case <-changed:
		t.Fatal("heartbeat woke state stream")
	default:
	}
	encoded, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	if _, exists := fields["lease_ms"]; exists {
		t.Fatal("snapshot granted lease")
	}
	r := roundRequest(s, "lease")
	r.Revision = s.Revision
	r.Confirmation = s.Confirmation
	if lease := apply(t, h, a, r); lease.LeaseMS != 3000 {
		t.Fatal("current installed round cannot renew")
	}
	r.Revision--
	if _, err := h.Apply(a.member, a.key, randomID(), r); !errors.Is(err, ErrStale) {
		t.Fatal("stale revision obtained lease", err)
	}
	r.Revision = s.Revision
	r.Confirmation = publicBlob(31)
	if _, err := h.Apply(a.member, a.key, randomID(), r); !errors.Is(err, ErrStale) {
		t.Fatal("wrong confirmation obtained lease", err)
	}
	s = apply(t, h, a, roundRequest(s, "refresh"))
	select {
	case <-changed:
	default:
		t.Fatal("round change did not wake watcher")
	}
	// Reading snapshots and keeping an event stream open cannot keep a peer alive.
	for i := 1; i <= 5; i++ {
		now = now.Add(time.Second)
		s = apply(t, h, a, roundRequest(s, "snapshot"))
	}
	now = now.Add(time.Second)
	if _, _, ok := h.watch(a.identity(), base64.StdEncoding.EncodeToString(a.key), s.SessionID); ok {
		t.Fatal("watcher renewed heartbeat")
	}
}

func TestMemberRequestBudgetDoesNotEvictOtherMembersOrResetOnLogin(t *testing.T) {
	h := NewHub("friends", DefaultPolicy())
	now := time.Now()
	h.now = func() time.Time { return now }
	a, b := peer("a"), peer("b")
	s := complete(t, h, a, b)
	r := roundRequest(s, "snapshot")
	for len(h.used[a.member.ID]) < 512 {
		if _, err := h.Apply(a.member, a.key, randomID(), r); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.Apply(a.member, a.key, randomID(), r); !errors.Is(err, ErrBudget) {
		t.Fatal("unbounded member ledger", err)
	}
	if _, err := h.Apply(b.member, b.key, randomID(), r); err != nil {
		t.Fatal("another member lost its budget", err)
	}
	a.member.LoginID = "login_replaced"
	if _, err := h.Apply(a.member, a.key, randomID(), Request{RoomID: h.roomID, EntryID: testEntryID, ServerID: h.ServerID(), Operation: "join"}); !errors.Is(err, ErrBudget) {
		t.Fatal("login reset flood budget", err)
	}
	if len(h.Identities()) != 2 {
		t.Fatal("flood evicted group members")
	}
	h.policy.HeartbeatTimeout = time.Hour
	h.policy.TransitionTimeout = time.Hour
	now = now.Add(2*time.Minute + time.Second)
	if _, err := h.Apply(b.member, b.key, randomID(), r); err != nil {
		t.Fatal("expired nonce budget did not recover", err)
	}
	if h.usedCount != 1 {
		t.Fatal("expired ledger retained", h.usedCount)
	}
	// The aggregate room bound remains in force even with many stable members.
	for i := h.usedCount; i < 16384; i++ {
		if err := h.consumeNonceLocked(fmt.Sprint(i/512), fmt.Sprint(i), now); err != nil {
			t.Fatal(i, err)
		}
	}
	if err := h.consumeNonceLocked("new member", "new nonce", now); !errors.Is(err, ErrBudget) {
		t.Fatal("unbounded room ledger", err)
	}
}

func TestStreamReplacementAndCleanupAreBoundToTheirOwnRegistration(t *testing.T) {
	h := NewHub("friends", DefaultPolicy())
	one, removeOne := h.registerStream("identity")
	two, removeTwo := h.registerStream("identity")
	select {
	case <-one:
	default:
		t.Fatal("old connection not canceled")
	}
	removeOne()
	if len(h.streams) != 1 {
		t.Fatal("old cleanup removed current connection")
	}
	select {
	case <-two:
		t.Fatal("current stream was canceled by old cleanup")
	default:
	}
	removeTwo()
	if len(h.streams) != 0 {
		t.Fatal("connection registration leaked")
	}
}
