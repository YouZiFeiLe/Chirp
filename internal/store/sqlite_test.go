package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestV5RejectsPreviousSchemasWithoutMigration(t *testing.T) {
	for _, version := range []int{20, 21, 22} {
		t.Run(fmt.Sprint(version), func(t *testing.T) {
			db := openTestStore(t)
			if _, err := db.db.Exec("UPDATE chirp_schema SET version = ? WHERE id = 1", version); err != nil {
				t.Fatal(err)
			}
			path := db.Path()
			if err := db.Close(); err != nil {
				t.Fatal(err)
			}
			if reopened, err := Open(t.Context(), path); err == nil {
				reopened.Close()
				t.Fatal("legacy database accepted")
			}
		})
	}
}

func TestSQLiteOpensEscapedDatabasePath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "Chirp 数据 # 100%.db")
	s, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(data), "SQLite format 3\x00") {
		t.Fatal("SQLite initialized a different file")
	}
}

func TestConcurrentInitializationAndRestart(t *testing.T) {
	dsn := testdb.Path(t)
	var group sync.WaitGroup
	for range 6 {
		group.Go(func() {
			s, err := Open(context.Background(), dsn)
			if err != nil {
				t.Error(err)
				return
			}
			defer s.Close()
			var count int
			if err := s.db.QueryRow("SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").Scan(&count); err != nil || count != 26 {
				t.Errorf("incomplete schema: tables=%d, error=%v", count, err)
			}
		})
	}
	group.Wait()
}

func TestRegistrationSettingsPreserveExistingDatabaseAndSurviveRestart(t *testing.T) {
	ctx := t.Context()
	db := openTestStore(t)
	request, err := db.RegisterPasskey(ctx, PasskeyAccount{ID: "existing", Nickname: "Oliver", CredentialID: []byte("existing"), CredentialJSON: []byte(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	// Check that opening the database initializes a missing registration switch.
	if _, err := db.db.ExecContext(ctx, "DROP TABLE registration_settings"); err != nil {
		t.Fatal(err)
	}
	path := db.Path()
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if closed, err := db.RegistrationClosed(ctx); err != nil || closed {
		t.Fatalf("registration should initially be open: closed=%t, err=%v", closed, err)
	}
	if requests, err := db.ListRegistrationRequests(ctx); err != nil || len(requests) != 1 || requests[0] != request {
		t.Fatalf("database lost an existing request: %+v, %v", requests, err)
	}
	if err := db.SetRegistrationClosed(ctx, true); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	restarted, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { restarted.Close() })
	if closed, err := restarted.RegistrationClosed(ctx); err != nil || !closed {
		t.Fatalf("registration should remain closed after a restart: closed=%t, err=%v", closed, err)
	}
}

func TestCeremonyConcurrentConsumptionAcrossPools(t *testing.T) {
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
	if err := one.SavePasskeyCeremony(ctx, "once", "", "login", []byte(`{"challenge":1}`), time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	var accepted atomic.Int32
	var group sync.WaitGroup
	for i := range 20 {
		s := []*Store{one, two}[i%2]
		group.Go(func() {
			payload, err := s.ConsumePasskeyCeremony(ctx, "once", "login")
			if err == nil {
				if string(payload) != `{"challenge":1}` {
					t.Error("payload changed")
				}
				accepted.Add(1)
			} else if !errors.Is(err, ErrNotFound) {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("challenge consumed %d times", accepted.Load())
	}
}

func TestSQLiteCollationsAndIdempotentUpdates(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	member, _, err := s.AddMember(ctx, "朋友 😀")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateMember(ctx, member.ID, member.DisplayName, true); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := s.DisableMember(ctx, member.ID); err != nil {
			t.Fatal("idempotent disable failed", err)
		}
	}
	if _, err := s.UpdateMember(ctx, strings.ToUpper(member.ID), "wrong", true); !errors.Is(err, ErrNotFound) {
		t.Fatal("member IDs are not case sensitive", err)
	}
	id, _ := NewPasskeyID()
	account := PasskeyAccount{ID: id, Nickname: "Alice", CredentialID: []byte("case-test"), CredentialJSON: []byte(`{}`)}
	if _, err := s.RegisterPasskey(ctx, account); err != nil {
		t.Fatal(err)
	}
	if err := s.CheckRegistrationName(ctx, "aLiCe"); !errors.Is(err, ErrRegistrationExists) {
		t.Fatal("nickname uniqueness is not case insensitive", err)
	}
	account.ID, _ = NewPasskeyID()
	account.Nickname = "alice"
	account.CredentialID = []byte("different-key")
	if _, err := s.RegisterPasskey(ctx, account); !errors.Is(err, ErrRegistrationExists) {
		t.Fatal("duplicate nickname accepted", err)
	}
}

func TestConcurrentPendingRegistrationLimit(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	register := func(i int) error {
		id, err := NewPasskeyID()
		if err != nil {
			return err
		}
		_, err = s.RegisterPasskey(ctx, PasskeyAccount{ID: id, Nickname: fmt.Sprintf("Friend%c%c", 'A'+i/26, 'A'+i%26), CredentialID: []byte(fmt.Sprint(i)), CredentialJSON: []byte(`{}`)})
		return err
	}
	for i := range 98 {
		if err := register(i); err != nil {
			t.Fatal(err)
		}
	}
	var accepted atomic.Int32
	var group sync.WaitGroup
	for i := range 12 {
		group.Go(func() {
			err := register(98 + i)
			if err == nil {
				accepted.Add(1)
			} else if !errors.Is(err, ErrRegistrationCapacity) {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if accepted.Load() != 2 {
		t.Fatalf("accepted %d pending requests, want 2", accepted.Load())
	}
}
