package authorization

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

func appendStatus(t *testing.T, s *Server, event Event) int {
	t.Helper()
	body, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest("POST", "/v5/append", bytes.NewReader(body)))
	return w.Code
}

func TestSeparateWritersCannotOverwriteACommittedHead(t *testing.T) {
	t.Parallel()
	key := ed25519.NewKeyFromSeed(make([]byte, 32))
	path := filepath.Join(t.TempDir(), "authority.db")
	first, err := Open(path, testOrigin, key)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := Open(path, testOrigin, key)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	owner := testidentity.New("CAS")
	initial := signedEvent(emptyState(owner.Device.AccountKey), owner, "enroll", "", nil)
	if appendStatus(t, first, initial) != 204 {
		t.Fatal("enrollment")
	}
	account, err := first.account(t.Context(), owner.Device.AccountKey)
	if err != nil {
		t.Fatal(err)
	}
	state, err := Replay(testOrigin, account)
	if err != nil {
		t.Fatal(err)
	}
	revoke := signedEvent(state, owner, "revoke", owner.Device.LeafKey(), nil)
	social := identity.SocialEvent{Origin: testOrigin, AccountID: "owner", Version: 1, Operation: "friend", FriendID: "friend", FriendKey: owner.Device.AccountKey, Signer: owner.Device}
	social.Signature = identity.Sign(owner.Key, social.Message())
	trust := signedEvent(state, owner, "social", "", &social)
	entered, release := make(chan struct{}, 2), make(chan struct{})
	clock := func() time.Time { entered <- struct{}{}; <-release; return time.Now() }
	first.now, second.now = clock, clock
	result := make(chan int, 2)
	go func() { result <- appendStatus(t, first, revoke) }()
	go func() { result <- appendStatus(t, second, trust) }()
	<-entered
	<-entered
	close(release)
	a, b := <-result, <-result
	if !((a == 204 && b == 409) || (a == 409 && b == 204)) {
		t.Fatalf("writers returned %d, %d", a, b)
	}
	stored, err := first.account(t.Context(), owner.Device.AccountKey)
	if err != nil || len(stored.Records) != 2 {
		t.Fatalf("history lost: %v", err)
	}
	winner := stored.Records[1].Event
	if appendStatus(t, first, winner) != 204 {
		t.Fatal("idempotent retry")
	}
}

func TestBackwardClockCannotCorruptHistory(t *testing.T) {
	t.Parallel()
	s, err := Open(filepath.Join(t.TempDir(), "authority.db"), testOrigin, ed25519.NewKeyFromSeed(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	s.now = func() time.Time { return now }
	owner := testidentity.New("clock")
	if appendStatus(t, s, signedEvent(emptyState(owner.Device.AccountKey), owner, "enroll", "", nil)) != 204 {
		t.Fatal("enrollment")
	}
	account, _ := s.account(t.Context(), owner.Device.AccountKey)
	state, _ := Replay(testOrigin, account)
	event := signedEvent(state, owner, "revoke", owner.Device.LeafKey(), nil)
	now = now.Add(-time.Second)
	if appendStatus(t, s, event) != 503 {
		t.Fatal("backward time accepted")
	}
	stored, _ := s.account(t.Context(), owner.Device.AccountKey)
	if len(stored.Records) != 1 {
		t.Fatal("failed write changed history")
	}
	now = now.Add(time.Second)
	if appendStatus(t, s, event) != 204 {
		t.Fatal("normal time rejected")
	}
}

func TestOrdinaryCapacityKeepsRoomForRevocation(t *testing.T) {
	t.Parallel()
	owner := testidentity.New("capacity")
	state := emptyState(owner.Device.AccountKey)
	now := time.Now()
	e := signedEvent(state, owner, "enroll", "", nil)
	if err := state.Apply(e, now); err != nil {
		t.Fatal(err)
	}
	state.Version = MaxOrdinaryRecords
	if state.Apply(signedEvent(state, owner, "enroll", "", nil), now) == nil {
		t.Fatal("ordinary quota bypass")
	}
	if err := state.Apply(signedEvent(state, owner, "revoke", owner.Device.LeafKey(), nil), now); err != nil {
		t.Fatal(err)
	}
	if state.Active(owner.Device, now) {
		t.Fatal("revocation was not applied")
	}
	if s, err := Open(filepath.Join(t.TempDir(), "db"), "https://"+strings.Repeat("a", 2050)+".test:443", ed25519.NewKeyFromSeed(make([]byte, 32))); err == nil {
		s.Close()
		t.Fatal("unbounded origin")
	}
}

func TestFullOrdinaryHistoryStillAcceptsRevocationAndCompleteSnapshot(t *testing.T) {
	t.Parallel()
	s, err := Open(filepath.Join(t.TempDir(), "authority.db"), testOrigin, ed25519.NewKeyFromSeed(make([]byte, 32)))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	owner := testidentity.New("byte-capacity")
	now := time.Now()
	state := emptyState(owner.Device.AccountKey)
	enrolled := signedEvent(state, owner, "enroll", "", nil)
	if err = state.Apply(enrolled, now); err != nil {
		t.Fatal(err)
	}
	account := Account{Root: owner.Device.AccountKey, Records: []Record{{Event: enrolled, AcceptedAt: now.Unix()}}}
	var rejected Event
	for i := int64(1); ; i++ {
		previous := ""
		if len(state.Social) > 0 {
			previous = state.Social[len(state.Social)-1].Hash()
		}
		social := identity.SocialEvent{Origin: testOrigin, AccountID: "owner", Version: i, PreviousHash: previous, Operation: "friend", FriendID: "friend", FriendKey: owner.Device.AccountKey, Name: strings.Repeat("n", 320), Signer: owner.Device}
		social.Signature = identity.Sign(owner.Key, social.Message())
		event := signedEvent(state, owner, "social", "", &social)
		candidate := Account{Root: account.Root, Records: append(append([]Record{}, account.Records...), Record{Event: event, AcceptedAt: now.Unix()})}
		encoded, _ := json.Marshal(candidate)
		if len(encoded) > 512*1024 {
			rejected = event
			break
		}
		if err = state.Apply(event, now); err != nil {
			t.Fatal(err)
		}
		account = candidate
	}
	data, _ := json.Marshal(account)
	if _, err = s.db.Exec("INSERT INTO authorization_accounts(root,document) VALUES(?,?)", account.Root, data); err != nil {
		t.Fatal(err)
	}
	if appendStatus(t, s, rejected) != 503 {
		t.Fatal("ordinary byte cap not enforced")
	}
	before, _ := s.account(t.Context(), account.Root)
	if len(before.Records) != len(account.Records) {
		t.Fatal("rejected append changed history")
	}
	if appendStatus(t, s, signedEvent(state, owner, "revoke", owner.Device.LeafKey(), nil)) != 204 {
		t.Fatal("revocation reserve unavailable")
	}
	body, _ := json.Marshal(SnapshotRequest{Origin: testOrigin, Nonce: identity.Hash([]byte("challenge")), Roots: []string{account.Root, testidentity.New("empty-root").Device.AccountKey}})
	response := httptest.NewRecorder()
	s.Handler().ServeHTTP(response, httptest.NewRequest("POST", "/v5/snapshot", bytes.NewReader(body)))
	if response.Code != 200 {
		t.Fatal("committed history cannot be read", response.Code)
	}
}
