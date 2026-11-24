package group

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	v5 "gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func publicBlob(n int) string { return base64.StdEncoding.EncodeToString(make([]byte, n)) }

type hubPeer struct {
	member store.Member
	key    ed25519.PublicKey
}

func peer(name string) hubPeer {
	key, _, _ := ed25519.GenerateKey(rand.Reader)
	return hubPeer{store.Member{ID: name, LoginID: "login_1", DisplayName: name, Enabled: true}, key}
}

const testEntryID = "entry_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func (p hubPeer) identity() string { return store.AdmissionIdentity(p.member, testEntryID) }

func TestLiveIdentitiesExcludesExpiredHeartbeatsWithoutChangingRoom(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	now := time.Now()
	h.now = func() time.Time { return now }
	a, b := peer("a"), peer("b")
	apply(t, h, a, Request{Operation: "join"})
	now = now.Add(time.Second)
	apply(t, h, b, Request{Operation: "join"})
	server := &Server{hubs: map[string]*Hub{h.roomID: h}}
	if ids := server.LiveIdentities("missing"); len(ids) != 0 || len(server.hubs) != 1 {
		t.Fatal("directory lookup created a room", ids)
	}
	revision := h.revision
	now = now.Add(h.policy.HeartbeatTimeout - time.Second)
	if ids := server.LiveIdentities(h.roomID); !slices.Equal(ids, []string{b.identity()}) {
		t.Fatal("wrong live identities at the heartbeat deadline", ids)
	}
	now = now.Add(time.Second)
	if ids := server.LiveIdentities(h.roomID); len(ids) != 0 || len(h.members) != 2 || h.revision != revision {
		t.Fatal("directory lookup affected room state", ids, h.revision)
	}
}

func apply(t *testing.T, h *Hub, p hubPeer, r Request) Snapshot {
	t.Helper()
	r.ServerID = h.ServerID()
	r.RoomID = h.roomID
	r.EntryID = testEntryID
	s, err := h.Apply(p.member, p.key, randomID(), r)
	if err != nil {
		t.Fatalf("%s: %v", r.Operation, err)
	}
	return s
}

func roundRequest(s Snapshot, operation string) Request {
	return Request{RoomID: s.RoomID, EntryID: testEntryID, ServerID: s.ServerID, SessionID: s.SessionID, Generation: s.Generation, Operation: operation}
}

func complete(t *testing.T, h *Hub, peers ...hubPeer) Snapshot {
	t.Helper()
	var s Snapshot
	for _, p := range peers {
		s = apply(t, h, p, Request{Operation: "join"})
	}
	for _, p := range peers {
		r := roundRequest(s, "package")
		r.KeyPackage = publicBlob(128)
		s = apply(t, h, p, r)
	}
	var leader hubPeer
	for _, p := range peers {
		if p.identity() == s.Leader {
			leader = p
		}
	}
	r := roundRequest(s, "publish")
	r.Confirmation = publicBlob(32)
	if len(peers) > 1 {
		r.Welcome = publicBlob(512)
	}
	s = apply(t, h, leader, r)
	if s.Phase != "confirming" || s.LeaseMS != 0 {
		t.Fatal("media became ready before every member confirmed")
	}
	for _, p := range peers {
		r = roundRequest(s, "ack")
		r.Confirmation = publicBlob(32)
		s = apply(t, h, p, r)
	}
	if s.Phase != "ready" || s.LeaseMS == 0 {
		t.Fatalf("round failed to become ready: %+v", s)
	}
	if s.Welcome != "" {
		t.Fatal("ready heartbeats retransmitted a consumed Welcome")
	}
	for _, member := range s.Members {
		if member.KeyPackage != "" {
			t.Fatal("ready heartbeats retransmitted consumed key packages")
		}
	}
	return s
}

func TestMembershipChangesInvalidateAllMediaLeases(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	a, b, c := peer("a"), peer("b"), peer("c")
	s := complete(t, h, a, b)
	old := s
	s = apply(t, h, c, Request{Operation: "join"})
	if s.Generation <= old.Generation || s.Phase != "collecting" || s.LeaseMS != 0 || s.Welcome != "" {
		t.Fatal("join retained old media authority")
	}
	for _, p := range s.Members {
		if p.KeyPackage != "" {
			t.Fatal("a one-time package was reused")
		}
	}
	r := roundRequest(old, "ack")
	r.Confirmation = publicBlob(32)
	if _, err := h.Apply(a.member, a.key, randomID(), r); !errors.Is(err, ErrStale) {
		t.Fatal("old acknowledgement accepted", err)
	}
	s = complete(t, h, a, b, c)
	s = apply(t, h, b, roundRequest(s, "leave"))
	if len(s.Members) != 2 || s.LeaseMS != 0 {
		t.Fatal("leave did not revoke the round")
	}
	r = roundRequest(s, "snapshot")
	if _, err := h.Apply(b.member, b.key, randomID(), r); !errors.Is(err, ErrStale) {
		t.Fatal("removed client retained access", err)
	}
	s = complete(t, h, a, c)
	h.End()
	if _, err := h.Apply(a.member, a.key, randomID(), roundRequest(s, "snapshot")); !errors.Is(err, ErrStale) {
		t.Fatal("ended session resurrected", err)
	}
	newSession := apply(t, h, a, Request{Operation: "join"})
	if newSession.SessionID == s.SessionID {
		t.Fatal("empty room reused its cryptographic session")
	}
}

func TestMutualVerificationWaitKeepsLiveMembersWithoutMediaAuthority(t *testing.T) {
	t.Parallel()
	for _, partial := range []bool{false, true} {
		t.Run(fmt.Sprintf("partial_packages=%t", partial), func(t *testing.T) {
			h := NewHub(store.DefaultRoomID, DefaultPolicy())
			h.setIdentityPolicy(v5.MutualRoom("https://keys.example.test:443", h.roomID))
			now := time.Now()
			h.now = func() time.Time { return now }
			a, b := peer("a"), peer("b")
			s := apply(t, h, a, Request{Operation: "join"})
			s = apply(t, h, b, Request{Operation: "join"})
			generation := s.Generation
			if partial {
				r := roundRequest(s, "package")
				r.KeyPackage = publicBlob(128)
				s = apply(t, h, a, r)
			}
			// Comparing SAS is human-paced. Heartbeats keep the control
			// session alive without releasing a Welcome or a media lease.
			for range 20 {
				now = now.Add(2 * time.Second)
				for _, p := range []hubPeer{a, b} {
					s = apply(t, h, p, roundRequest(s, "heartbeat"))
					if len(s.Members) != 2 || s.Generation != generation || s.Phase != "collecting" || s.LeaseMS != 0 || s.Welcome != "" {
						t.Fatal("verification wait removed a live member or authorized content")
					}
				}
			}
			for _, p := range []hubPeer{a, b} {
				r := roundRequest(s, "package")
				r.KeyPackage = publicBlob(128)
				s = apply(t, h, p, r)
			}
			if s.Phase != "welcoming" || s.LeaseMS != 0 {
				t.Fatal("approved packages did not start a fresh MLS transition")
			}
			transitionBegan := now
			now = now.Add(2 * time.Second)
			s = apply(t, h, a, roundRequest(s, "heartbeat"))
			s = apply(t, h, b, roundRequest(s, "heartbeat"))
			if len(s.Members) != 2 || s.Phase != "welcoming" {
				t.Fatal("verification wait consumed the MLS transition deadline")
			}
			// Actual MLS stalls retain their timeout after trust is granted.
			for range 5 {
				now = now.Add(2 * time.Second)
				s = apply(t, h, b, roundRequest(s, "heartbeat"))
				if now.Sub(transitionBegan) < h.policy.TransitionTimeout {
					s = apply(t, h, a, roundRequest(s, "heartbeat"))
				}
			}
			if len(s.Members) != 1 || s.Leader != b.identity() || s.LeaseMS != 0 {
				t.Fatal("stalled committer was not removed after verification")
			}
			// The verification exception never extends an absent peer's heartbeat.
			now = now.Add(h.policy.HeartbeatTimeout)
			if _, err := h.Apply(b.member, b.key, randomID(), roundRequest(s, "heartbeat")); !errors.Is(err, ErrStale) {
				t.Fatal("verification wait retained an offline member", err)
			}
		})
	}
}

func TestSigningKeyBindingReplayAndConfirmation(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	a, b := peer("a"), peer("b")
	s := complete(t, h, a, b)
	r := roundRequest(s, "snapshot")
	nonce := randomID()
	if _, err := h.Apply(a.member, a.key, nonce, r); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Apply(a.member, a.key, nonce, r); !errors.Is(err, ErrReplay) {
		t.Fatal("replay accepted", err)
	}
	otherKey, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := h.Apply(a.member, otherKey, randomID(), r); !errors.Is(err, ErrBinding) {
		t.Fatal("identity key substitution accepted", err)
	}
	r = roundRequest(s, "ack")
	r.Confirmation = publicBlob(31)
	if _, err := h.Apply(b.member, b.key, randomID(), r); !errors.Is(err, ErrConflict) {
		t.Fatal("inconsistent group state acknowledged", err)
	}
}

func TestTimeoutRotationAndAuthorityFailure(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	now := time.Now()
	h.now = func() time.Time { return now }
	a, b := peer("a"), peer("b")
	s := complete(t, h, a, b)
	h.Reconcile(nil, false)
	s = apply(t, h, a, roundRequest(s, "snapshot"))
	if s.LeaseMS != 0 {
		t.Fatal("authority failure still issued a lease")
	}
	h.Reconcile(map[string]bool{b.identity(): false}, true)
	s = apply(t, h, a, roundRequest(s, "snapshot"))
	if len(s.Members) != 1 || s.Phase != "collecting" {
		t.Fatal("revoked login retained group membership")
	}
	s = complete(t, h, a)
	h.policy.Rotation = time.Second
	now = now.Add(2 * time.Second)
	s = apply(t, h, a, roundRequest(s, "snapshot"))
	if s.Phase != "collecting" || s.LeaseMS != 0 {
		t.Fatal("scheduled rotation did not pause media")
	}
	// A live follower replaces an unresponsive committer after the bounded transition.
	s = apply(t, h, b, Request{Operation: "join"})
	h.policy.HeartbeatTimeout = time.Hour
	r := roundRequest(s, "package")
	r.KeyPackage = publicBlob(128)
	s = apply(t, h, b, r)
	now = now.Add(h.policy.TransitionTimeout)
	s = apply(t, h, b, roundRequest(s, "snapshot"))
	if len(s.Members) != 1 || s.Leader != b.identity() {
		t.Fatal("failed committer blocked surviving client")
	}
}

func TestConcurrentMembersBeyondTwentyAndBoundedReplays(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	peers := make([]hubPeer, 24)
	for i := range peers {
		peers[i] = peer(fmt.Sprintf("member%02d", i))
	}
	var wg sync.WaitGroup
	for _, p := range peers {
		wg.Add(1)
		go func() { defer wg.Done(); apply(t, h, p, Request{Operation: "join"}) }()
	}
	wg.Wait()
	s := complete(t, h, peers...)
	if len(s.Members) != 24 {
		t.Fatal("concurrent members were lost")
	}
	old := peers[0]
	replacement := peer(old.member.ID)
	replacement.member.LoginID = "login_new"
	s = apply(t, h, replacement, Request{Operation: "join"})
	if len(s.Members) != 24 || s.Phase != "collecting" || s.LeaseMS != 0 {
		t.Fatal("new login could not replace a member at capacity")
	}
	for _, m := range s.Members {
		if m.Identity == old.identity() {
			t.Fatal("old login survived replacement")
		}
	}
}

func TestRefreshInvalidatesLeasesAndRequiresNewPackages(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	a, b := peer("a"), peer("b")
	s := complete(t, h, a, b)
	old := s.Generation
	s = apply(t, h, a, roundRequest(s, "refresh"))
	if s.Generation <= old || s.LeaseMS != 0 || s.Phase != "collecting" {
		t.Fatal("reconnect retained old media round")
	}
	for _, member := range s.Members {
		if member.KeyPackage != "" {
			t.Fatal("refresh reused a package")
		}
	}
}

func TestLeaderMustAcknowledgeMediaInstallation(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	a, b := peer("a"), peer("b")
	apply(t, h, a, Request{Operation: "join"})
	s := apply(t, h, b, Request{Operation: "join"})
	for _, p := range []hubPeer{a, b} {
		r := roundRequest(s, "package")
		r.KeyPackage = publicBlob(128)
		s = apply(t, h, p, r)
	}
	r := roundRequest(s, "publish")
	r.Welcome, r.Confirmation = publicBlob(512), publicBlob(32)
	s = apply(t, h, a, r)
	r = roundRequest(s, "ack")
	r.Confirmation = publicBlob(32)
	s = apply(t, h, b, r)
	if s.Phase != "confirming" || s.LeaseMS != 0 {
		t.Fatal("publishing the Welcome counted as the leader installing media keys")
	}
	s = apply(t, h, a, r)
	if s.Phase != "ready" || s.LeaseMS == 0 {
		t.Fatal("the leader's explicit installation acknowledgement did not open the barrier")
	}
}

func TestAuthorityRecoveryRequiresFreshRound(t *testing.T) {
	h := NewHub(store.DefaultRoomID, DefaultPolicy())
	a := peer("a")
	s := complete(t, h, a)
	h.Reconcile(nil, false)
	paused := apply(t, h, a, roundRequest(s, "snapshot"))
	if paused.LeaseMS != 0 {
		t.Fatal("authority outage did not suspend media leases")
	}
	h.Reconcile(map[string]bool{a.identity(): true}, true)
	recovered := apply(t, h, a, roundRequest(paused, "snapshot"))
	if recovered.Generation <= s.Generation || recovered.LeaseMS != 0 || recovered.Phase != "collecting" {
		t.Fatal("authority recovery resumed a possibly retired media key")
	}
}

func TestRoomsHaveIndependentGenerationsAndRejectCrossRoomRequests(t *testing.T) {
	a, b := NewHub("friends", DefaultPolicy()), NewHub("room-2", DefaultPolicy())
	alice, bob := peer("alice"), peer("bob")
	sa, sb := complete(t, a, alice), complete(t, b, bob)
	apply(t, a, peer("carol"), Request{Operation: "join"})
	unchanged := apply(t, b, bob, roundRequest(sb, "snapshot"))
	if unchanged.Generation != sb.Generation || unchanged.Phase != "ready" || unchanged.LeaseMS == 0 {
		t.Fatal("another room's join affected this room")
	}
	wrong := roundRequest(sa, "snapshot")
	wrong.ServerID = b.ServerID()
	if _, err := b.Apply(bob.member, bob.key, randomID(), wrong); !errors.Is(err, ErrStale) {
		t.Fatal("cross-room request accepted", err)
	}
	b.Remove(alice.identity())
	unchanged = apply(t, b, bob, roundRequest(sb, "snapshot"))
	if unchanged.Generation != sb.Generation {
		t.Fatal("unrelated removal rotated room")
	}
}
