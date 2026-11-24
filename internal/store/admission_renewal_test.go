package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestAdmissionRenewalsCoalesceAcrossPoolsAndDoNotExtendCredentials(t *testing.T) {
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
	m, _, err := one.AddMember(ctx, "renewal")
	if err != nil {
		t.Fatal(err)
	}
	a, err := one.JoinRoom(ctx, m, DefaultRoomID, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{
		"CREATE TABLE renewal_counts (n INTEGER NOT NULL)",
		"INSERT INTO renewal_counts VALUES (0)",
		"CREATE TRIGGER count_renewals AFTER UPDATE OF expires_at ON room_admissions BEGIN UPDATE renewal_counts SET n=n+1; END",
	} {
		if _, err := one.db.ExecContext(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	count := func(want int) {
		t.Helper()
		var n int
		if err := one.db.QueryRowContext(ctx, "SELECT n FROM renewal_counts").Scan(&n); err != nil || n != want {
			t.Fatalf("actual row updates=%d want=%d: %v", n, want, err)
		}
	}
	touch := func() {
		t.Helper()
		var wg sync.WaitGroup
		for i := range 32 {
			wg.Go(func() {
				db := one
				if i%2 == 0 {
					db = two
				}
				if err := db.TouchAdmission(ctx, a.RoomID, a.Identity()); err != nil {
					t.Error(err)
				}
			})
		}
		wg.Wait()
	}
	touch()
	count(0)
	if _, err := one.db.ExecContext(ctx, "UPDATE room_admissions SET expires_at=? WHERE member_id=?", time.Now().Add(19*time.Second).Unix(), m.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := one.db.ExecContext(ctx, "UPDATE renewal_counts SET n=0"); err != nil {
		t.Fatal(err)
	}
	touch()
	count(1)
	var expiry int64
	if err := one.db.QueryRowContext(ctx, "SELECT expires_at FROM room_admissions WHERE member_id=?", m.ID).Scan(&expiry); err != nil || expiry <= time.Now().Add(20*time.Second).Unix() {
		t.Fatal("entry was not renewed", expiry, err)
	}

	// A login expiring shortly may remain valid, but renewal cannot extend it
	// or produce repeated identical UPDATEs near that fixed deadline.
	short := time.Now().Add(15 * time.Second).Unix()
	if _, err := two.db.ExecContext(ctx, "UPDATE members SET credential_expires_at=? WHERE id=?", short, m.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := two.db.ExecContext(ctx, "UPDATE room_admissions SET expires_at=? WHERE member_id=?", short, m.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := one.db.ExecContext(ctx, "UPDATE renewal_counts SET n=0"); err != nil {
		t.Fatal(err)
	}
	touch()
	count(0)
	if err := one.db.QueryRowContext(ctx, "SELECT expires_at FROM room_admissions WHERE member_id=?", m.ID).Scan(&expiry); err != nil || expiry != short {
		t.Fatal("credential deadline extended", expiry, err)
	}
	if err := two.DisableMember(ctx, m.ID); err != nil {
		t.Fatal(err)
	}
	if err := one.TouchAdmission(ctx, a.RoomID, a.Identity()); !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("revoked member renewed", err)
	}
	count(0)
	t.Log("32 fresh touches: 0 row updates; 32 concurrent due touches across 2 pools: 1 row update")
}

func TestBatchAdmissionAuthoritySeesCrossPoolRevocation(t *testing.T) {
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
	var members []Member
	var admissions []RoomAdmission
	for i, name := range []string{"disabled", "replaced", "expired", "deleted room", "valid"} {
		m, _, err := one.AddMember(ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		a, err := one.JoinRoom(ctx, m, []string{"friends", "friends", "friends", "room-2", "room-3"}[i], 1, 0)
		if err != nil {
			t.Fatal(err)
		}
		members = append(members, m)
		admissions = append(admissions, a)
	}
	before, err := one.ActiveAdmissions(ctx)
	if err != nil || len(before) != 5 {
		t.Fatal(before, err)
	}
	if err := two.DisableMember(ctx, members[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := two.ResetCredential(ctx, members[1].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := two.db.ExecContext(ctx, "UPDATE room_admissions SET expires_at=? WHERE member_id=?", time.Now().Add(-time.Second).Unix(), members[2].ID); err != nil {
		t.Fatal(err)
	}
	if err := two.DeleteRoom(ctx, "room-2"); err != nil {
		t.Fatal(err)
	}
	after, err := one.ActiveAdmissions(ctx)
	if err != nil || len(after) != 1 || after[admissions[4].Identity()] != "room-3" {
		t.Fatal("stale batch authority", after, err)
	}
}

func TestAdmissionRenewalCannotReviveEntryExpiredWhileWaitingForWriter(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s := openTestStore(t)
	m, _, err := s.AddMember(ctx, "waiting renewal")
	if err != nil {
		t.Fatal(err)
	}
	a, err := s.JoinRoom(ctx, m, DefaultRoomID, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	expires := time.Now().Add(2 * time.Second).Unix()
	if _, err := s.db.ExecContext(ctx, "UPDATE room_admissions SET expires_at=? WHERE member_id=?", expires, m.ID); err != nil {
		t.Fatal(err)
	}
	blocker, err := s.beginWrite(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback()
	done := make(chan error, 1)
	go func() { done <- s.TouchAdmission(ctx, a.RoomID, a.Identity()) }()
	select {
	case err := <-done:
		t.Fatal("renewal did not wait for the writer lock", err)
	case <-time.After(100 * time.Millisecond):
	}
	// WAL readers can observe that the entry has expired while the renewal
	// remains queued behind an unrelated writer.
	time.Sleep(time.Until(time.Unix(expires, 0)) + 20*time.Millisecond)
	if allowed, err := s.AdmissionAllowed(ctx, a.RoomID, a.Identity()); err != nil || allowed {
		t.Fatal("entry did not expire while the writer was blocked", allowed, err)
	}
	if err := blocker.Rollback(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrAdmissionChanged) {
		t.Fatal("waiting renewal revived an expired entry", err)
	}
	var stored int64
	if err := s.db.QueryRowContext(ctx, "SELECT expires_at FROM room_admissions WHERE member_id=?", m.ID).Scan(&stored); err != nil || stored != expires {
		t.Fatal("expired admission was extended", stored, err)
	}
}
