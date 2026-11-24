package store

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"sync"
	"sync/atomic"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	dsn := testdb.Path(t)
	s, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	testdb.SeedRooms(t, dsn)
	return s
}

func TestCredentialLifecycleAndPersistence(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	s, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	m, token, err := s.AddMember(ctx, "朋友甲")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.MemberByCredential(ctx, token); err != nil {
		t.Fatal(err)
	}
	var persisted []byte
	if err := s.db.QueryRowContext(ctx, "SELECT credential_hash FROM members WHERE id = ?", m.ID).Scan(&persisted); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256([]byte(token))
	if !bytes.Equal(persisted, hash[:]) {
		t.Fatal("credential was not persisted as a SHA-256 digest")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if loaded, err := s.MemberByCredential(ctx, token); err != nil || loaded.ID != m.ID {
		t.Fatal("member was not persisted", err)
	}
	replacement, err := s.ResetCredential(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.MemberByCredential(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Fatal("old credential remains valid")
	}
	if err := s.DisableMember(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	if disabled, err := s.MemberByCredential(ctx, replacement); err != nil || disabled.Enabled {
		t.Fatal("disabled member remains enabled", err)
	}
	if _, err := s.ResetCredential(ctx, "unknown"); !errors.Is(err, ErrNotFound) {
		t.Fatal("reset created an unknown member")
	}
}

func TestConcurrentMembersBeyondTwenty(t *testing.T) {
	s := openTestStore(t)
	var accepted atomic.Int32
	var wg sync.WaitGroup
	for range 48 {
		wg.Go(func() {
			_, _, err := s.AddMember(context.Background(), "朋友")
			if err == nil {
				accepted.Add(1)
			} else {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if accepted.Load() != 48 {
		t.Fatalf("accepted %d members", accepted.Load())
	}
	members, err := s.ListMembers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.DisableMember(context.Background(), members[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AddMember(context.Background(), "新朋友"); err != nil {
		t.Fatal("disabled member should release a place", err)
	}
}

func TestRoomInitializationAndEngine(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	r, err := s.Room(ctx, DefaultRoomID)
	if err != nil || r.RoomID != DefaultRoomID {
		t.Fatal("default room is unavailable", err)
	}
	e, err := s.Engine(ctx)
	if err != nil || e.Version != SQLiteVersion {
		t.Fatal("wrong actual SQLite engine", err)
	}
}

func TestMemberEditingAndDeletion(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	member, credential, err := s.AddMember(ctx, "original")
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.UpdateMember(ctx, member.ID, "  renamed  ", false)
	if err != nil || updated.Enabled || updated.DisplayName != "renamed" || updated.CreatedAt != member.CreatedAt {
		t.Fatal("member update failed", err)
	}
	if stored, err := s.MemberByCredential(ctx, credential); err != nil || stored != updated {
		t.Fatal("editing replaced the member credential", err)
	}
	if _, err := s.UpdateMember(ctx, member.ID, "bad\nname", true); !errors.Is(err, ErrInvalidName) {
		t.Fatal("control characters accepted", err)
	}
	if _, err := s.UpdateMember(ctx, "missing", "test", true); !errors.Is(err, ErrNotFound) {
		t.Fatal("unknown member was updated", err)
	}
	if err := s.DeleteMember(ctx, member.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.MemberByCredential(ctx, credential); !errors.Is(err, ErrNotFound) {
		t.Fatal("deleted member remains authorized")
	}
	if err := s.DeleteMember(ctx, member.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("missing member deletion succeeded")
	}
}

func TestConcurrentReenableAndCreateBeyondTwenty(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	s, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	other, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { other.Close() })
	var disabled []Member
	for range 32 {
		member, _, err := s.AddMember(ctx, "disabled")
		if err != nil {
			t.Fatal(err)
		}
		if err := s.DisableMember(ctx, member.ID); err != nil {
			t.Fatal(err)
		}
		disabled = append(disabled, member)
	}
	var accepted atomic.Int32
	var wg sync.WaitGroup
	for _, member := range disabled {
		wg.Go(func() {
			_, err := s.UpdateMember(ctx, member.ID, "enabled", true)
			if err == nil {
				accepted.Add(1)
			} else if !errors.Is(err, ErrBlacklisted) {
				t.Error(err)
			}
		})
		wg.Go(func() {
			_, _, err := other.AddMember(ctx, "new")
			if err == nil {
				accepted.Add(1)
			} else {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if accepted.Load() != 32 {
		t.Fatalf("concurrent updates enabled %d members, want %d", accepted.Load(), 32)
	}
	members, err := s.ListMembers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, member := range members {
		if !member.Enabled {
			if _, err := s.UpdateMember(ctx, member.ID, "reenabled", true); !errors.Is(err, ErrBlacklisted) {
				t.Fatal("re-enabling bypassed member limit", err)
			}
		} else if _, err := s.UpdateMember(ctx, member.ID, "renamed at capacity", true); err != nil {
			t.Fatal("renaming an enabled member consumed an extra place", err)
		}
	}
}
