package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
	"time"
)

func TestConcurrentApprovalAndCreationBeyondTwenty(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	one, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	two, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	var requests []RegistrationRequest
	for i := range 24 {
		name := fmt.Sprintf("Friend%c%c", 'A'+i/26, 'A'+i%26)
		id, _ := NewPasskeyID()
		request, err := one.RegisterPasskey(ctx, PasskeyAccount{ID: id, Nickname: name, CredentialID: []byte{byte(i + 1)}, CredentialJSON: []byte(`{}`)})
		if err != nil {
			t.Fatal(err)
		}
		requests = append(requests, request)
	}
	var accepted atomic.Int32
	var group sync.WaitGroup
	for _, request := range requests {
		group.Go(func() {
			_, err := one.ApproveRegistration(ctx, request.RequestID)
			if err == nil {
				accepted.Add(1)
			} else {
				t.Error(err)
			}
		})
		group.Go(func() {
			_, _, err := two.AddMember(ctx, "manual")
			if err == nil {
				accepted.Add(1)
			} else {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if accepted.Load() != 48 {
		t.Fatalf("admitted %d members", accepted.Load())
	}
	members, err := one.ListMembers(ctx)
	if err != nil || len(members) != 48 {
		t.Fatal("shared limit failed", err)
	}
}

func TestCeremonySingleUseAndExpiry(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	const token = "test-token"
	if err := s.SavePasskeyCeremony(ctx, token, "", "register", []byte(`{"session":1}`), time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConsumePasskeyCeremony(ctx, token, "login"); !errors.Is(err, ErrNotFound) {
		t.Fatal("wrong ceremony type accepted", err)
	}
	if _, err := s.ConsumePasskeyCeremony(ctx, token, "register"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConsumePasskeyCeremony(ctx, token, "register"); !errors.Is(err, ErrNotFound) {
		t.Fatal("replayed ceremony accepted", err)
	}
	if err := s.SavePasskeyCeremony(ctx, token, "", "login", []byte(`{}`), time.Now().Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConsumePasskeyCeremony(ctx, token, "login"); !errors.Is(err, ErrNotFound) {
		t.Fatal("expired ceremony accepted", err)
	}
}

func TestUnsupportedSchemaRequiresFreshDevelopmentDatabase(t *testing.T) {
	dsn := testdb.Path(t)
	s, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.Exec("UPDATE chirp_schema SET version = 99 WHERE id = 1"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	if db, err := Open(context.Background(), dsn); err == nil {
		db.Close()
		t.Fatal("unsupported schema was silently migrated or accepted")
	}
}
