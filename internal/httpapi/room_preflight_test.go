package httpapi

import (
	"encoding/base64"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestPreflightProofScopeExpiryAndProcessBinding(t *testing.T) {
	now := time.Unix(1000, 0)
	m := store.Member{ID: "member_test", LoginID: "login_test", CredentialExpiresAt: 2000}
	p := newPreflightProofs()
	proof, expires, err := p.issue(m, "room-2", 4, 9, now)
	if err != nil || expires != 1030 {
		t.Fatal("wrong proof deadline", err)
	}
	if revision, ok := p.verify(proof, m, "room-2", 4, now); !ok || revision != 9 {
		t.Fatal("valid proof rejected")
	}
	for _, attempt := range []struct {
		member   store.Member
		room     string
		sequence int64
		when     time.Time
	}{
		{store.Member{ID: "another", LoginID: m.LoginID, CredentialExpiresAt: 2000}, "room-2", 4, now},
		{store.Member{ID: m.ID, LoginID: "login_new", CredentialExpiresAt: 2000}, "room-2", 4, now},
		{m, "friends", 4, now}, {m, "room-2", 5, now}, {m, "room-2", 4, time.Unix(1030, 0)},
	} {
		if _, ok := p.verify(proof, attempt.member, attempt.room, attempt.sequence, attempt.when); ok {
			t.Fatal("proof crossed its authority boundary")
		}
	}
	other := newPreflightProofs()
	if _, ok := other.verify(proof, m, "room-2", 4, now); ok {
		t.Fatal("proof survived unrelated API process")
	}
	parts := strings.Split(proof, ".")
	for _, bad := range []string{"", proof + ".extra", strings.Repeat("x", 2049), parts[0] + "." + base64.RawURLEncoding.EncodeToString(make([]byte, 32)), "e30." + parts[1]} {
		if _, ok := p.verify(bad, m, "room-2", 4, now); ok {
			t.Fatal("tampered proof accepted")
		}
	}
	m.CredentialExpiresAt = 1005
	proof, expires, err = p.issue(m, "friends", 1, 0, now)
	if err != nil || expires != 1005 {
		t.Fatal("proof outlived login")
	}
	if _, ok := p.verify(proof, m, "friends", 1, time.Unix(1005, 0)); ok {
		t.Fatal("expired login proof accepted")
	}
}

func TestPasswordAttemptsAreAccountRoomScopedBoundedAndConcurrent(t *testing.T) {
	var limiter passwordAttempts
	now := time.Unix(1000, 0)
	var accepted atomic.Int32
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() {
			if limiter.begin("member/room", now) == 0 {
				accepted.Add(1)
			}
		})
	}
	wg.Wait()
	if accepted.Load() != 5 {
		t.Fatal("concurrent attempts escaped limit", accepted.Load())
	}
	if limiter.begin("other/room", now) != 0 || limiter.begin("member/other-room", now) != 0 {
		t.Fatal("one user locked others")
	}
	limiter.success("member/room")
	if limiter.begin("member/room", now) != 0 {
		t.Fatal("successful check not reset")
	}
	if limiter.begin("member/room", now.Add(30*time.Second)) != 0 {
		t.Fatal("backoff never expired")
	}
	for i := range 300 {
		limiter.begin(strings.Repeat("k", i+1), now)
	}
	if len(limiter.entries) > 256 {
		t.Fatal("attempt map grew unbounded")
	}
}
