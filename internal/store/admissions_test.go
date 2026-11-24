package store

import (
	"context"
	"errors"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
	"sync"
	"testing"
	"time"
)

func TestAdmissionSequenceScopeExpiryAndLoginReplacement(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	testdb.SeedRooms(t, dsn)
	m, token, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	first, err := db.JoinRoom(ctx, m, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	retry, err := db.JoinRoom(ctx, m, "friends", 1, 0)
	if err != nil || retry.EntryID != first.EntryID {
		t.Fatal("join retry was not idempotent", err)
	}
	if _, err := db.JoinRoom(ctx, m, "room-2", 1, 0); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("same sequence crossed rooms", err)
	}
	second, err := db.JoinRoom(ctx, m, "room-2", 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.LeaveRoom(ctx, m, "friends", first.EntryID); err != nil {
		t.Fatal(err)
	}
	for _, attempt := range []struct {
		room, id string
		want     bool
	}{{"friends", first.Identity(), false}, {"room-2", first.Identity(), false}, {"friends", second.Identity(), false}, {"room-2", second.Identity(), true}} {
		allowed, err := db.AdmissionAllowed(ctx, attempt.room, attempt.id)
		if err != nil || allowed != attempt.want {
			t.Fatal("room/entry binding failed", attempt, err)
		}
	}
	if err := db.TouchAdmission(ctx, "friends", first.Identity()); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("old entry renewed", err)
	}
	if _, err := db.JoinRoom(ctx, m, "friends", 1, 0); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("delayed join displaced new room", err)
	}
	if err := db.EndRoom(ctx, "friends"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := db.AdmissionAllowed(ctx, "room-2", second.Identity()); !ok {
		t.Fatal("ending another room revoked admission")
	}
	if _, err := db.db.ExecContext(ctx, "UPDATE room_admissions SET expires_at=? WHERE member_id=?", time.Now().Add(-time.Second).Unix(), m.ID); err != nil {
		t.Fatal(err)
	}
	if err := db.TouchAdmission(ctx, "room-2", second.Identity()); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("expired entry resurrected", err)
	}
	if _, err := db.JoinRoom(ctx, m, "room-2", 2, 0); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("retry resurrected an expired entry", err)
	}
	fresh, err := db.JoinRoom(ctx, m, "room-5", 3, 0)
	if err != nil {
		t.Fatal(err)
	}
	replacement, err := db.ResetCredential(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	newer, err := db.MemberByCredential(ctx, replacement)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.MemberByCredential(ctx, token); !errors.Is(err, ErrNotFound) {
		t.Fatal("old credential valid")
	}
	if err := db.TouchAdmission(ctx, "room-5", fresh.Identity()); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("old login admission survived replacement")
	}
	last, err := db.JoinRoom(ctx, newer, "room-3", 1, 0)
	if err != nil {
		t.Fatal("new login did not reset sequence", err)
	}
	if err := db.LeaveRoom(ctx, m, "room-5", fresh.EntryID); err != nil {
		t.Fatal(err)
	}
	if ok, _ := db.AdmissionAllowed(ctx, "room-3", last.Identity()); !ok {
		t.Fatal("old login leave revoked new login")
	}
}
func TestConcurrentRoomSelectionHasOneMonotonicWinner(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	one, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	testdb.SeedRooms(t, dsn)
	two, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	m, _, err := one.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			db := one
			if i%2 == 0 {
				db = two
			}
			_, err := db.JoinRoom(ctx, m, []string{"friends", "room-2", "room-3", "room-4", "room-5"}[i%5], int64(i+1), 0)
			if err != nil && !errors.Is(err, ErrAdmissionChanged) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	active, err := one.ActiveRoomMembers(ctx)
	if err != nil || len(active) != 1 || active[0].RoomID != "room-5" {
		t.Fatal("concurrent requests escaped unique room or sequence", active, err)
	}
	if _, err := two.JoinRoom(ctx, m, "friends", 19, 0); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("old request beat highest sequence", err)
	}
	rooms, err := one.Rooms(ctx)
	if err != nil || len(rooms) != 5 {
		t.Fatal("five rooms missing", err)
	}
	if _, err := one.RenameRoom(ctx, "room-6", "invalid"); !errors.Is(err, ErrNotFound) {
		t.Fatal("sixth room accepted")
	}
}
