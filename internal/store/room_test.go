package store

import (
	"context"
	"errors"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestRoomDisplayNamePersistsAcrossPoolsAndRestarts(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	one, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	cfg, err := one.Room(ctx, DefaultRoomID)
	if err != nil || cfg.RoomID != DefaultRoomID || cfg.DisplayName != DefaultRoomDisplayName {
		t.Fatal("missing default lobby", cfg, err)
	}
	name := "周末大厅 😀 <朋友>"
	for range 2 {
		updated, err := one.RenameRoom(ctx, DefaultRoomID, "  "+name+"  ")
		if err != nil || updated.RoomID != DefaultRoomID || updated.DisplayName != name {
			t.Fatal("rename changed routing or did not trim the name", updated, err)
		}
	}
	two, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	cfg, err = two.Room(ctx, DefaultRoomID)
	if err != nil || cfg.DisplayName != name || cfg.RoomID != DefaultRoomID {
		t.Fatal("restart or independent pool reset the saved name", cfg, err)
	}
	for _, invalid := range []string{"", " \n ", "bad\nname", "bad\x7fname", strings.Repeat("字", 81), string([]byte{0xff})} {
		if _, err := two.RenameRoom(ctx, DefaultRoomID, invalid); !errors.Is(err, ErrInvalidName) {
			t.Fatalf("invalid room name accepted: %q, %v", invalid, err)
		}
	}
	cfg, err = one.Room(ctx, DefaultRoomID)
	if err != nil || cfg.DisplayName != name {
		t.Fatal("rejected rename changed the stored name", cfg, err)
	}
}
