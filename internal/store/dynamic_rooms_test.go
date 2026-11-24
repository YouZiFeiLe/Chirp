package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestFreshDatabaseHasOneProtectedRoomAndDynamicRoomsSurviveRestart(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rooms, err := db.Rooms(ctx)
	if err != nil || len(rooms) != 1 || rooms[0].RoomID != DefaultRoomID || !rooms[0].IsDefault {
		t.Fatal("fresh deployment did not retain exactly one default room", rooms, err)
	}
	if rooms[0].Description != DefaultRoomDescription {
		t.Fatal("incorrect lobby description", rooms[0].Description)
	}
	if err := db.DeleteRoom(ctx, DefaultRoomID); !errors.Is(err, ErrDefaultRoom) {
		t.Fatal("default deleted", err)
	}
	if _, err := db.RenameRoom(ctx, DefaultRoomID, "保留大厅"); err != nil {
		t.Fatal(err)
	}
	var created []RoomConfig
	for i := range 8 {
		r, err := db.CreateRoom(ctx, fmt.Sprintf("房间 %d", i))
		if err != nil || !ValidRoomID(r.RoomID) || r.IsDefault || r.Description != DefaultRoomDescription {
			t.Fatal(r, err)
		}
		created = append(created, r)
	}
	const description = "周五晚八点\n带上你喜欢的歌 🎵"
	if _, err := db.SetRoomDescription(ctx, created[0].RoomID, description); err != nil {
		t.Fatal(err)
	}
	if err := db.DeleteRoom(ctx, created[2].RoomID); err != nil {
		t.Fatal(err)
	}
	restarted, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	rooms, err = restarted.Rooms(ctx)
	if err != nil || len(rooms) != 8 || rooms[0].DisplayName != "保留大厅" || !rooms[0].IsDefault {
		t.Fatal("room changes did not survive restart", rooms, err)
	}
	if rooms[1].RoomID != created[0].RoomID || rooms[1].Description != description || rooms[0].Description != DefaultRoomDescription {
		t.Fatal("stored descriptions did not match their rooms", rooms[:2])
	}
	if _, err := restarted.Room(ctx, created[2].RoomID); !errors.Is(err, ErrNotFound) {
		t.Fatal("deleted room returned", err)
	}
	for _, name := range []string{"", "bad\nname"} {
		if _, err := db.CreateRoom(ctx, name); !errors.Is(err, ErrInvalidName) {
			t.Fatal("invalid room name accepted", err)
		}
	}
}

func TestRoomDeletionSerializesWithJoinsAndRevokesEveryAdmission(t *testing.T) {
	ctx := context.Background()
	db := openTestStore(t)
	r, err := db.CreateRoom(ctx, "多人房间")
	if err != nil {
		t.Fatal(err)
	}
	var members []Member
	for i := range 32 {
		m, _, err := db.AddMember(ctx, fmt.Sprintf("朋友 %d", i))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.JoinRoom(ctx, m, r.RoomID, 1, 0); err != nil {
			t.Fatal("more than 20 participants rejected", err)
		}
		members = append(members, m)
	}
	var wg sync.WaitGroup
	for _, m := range members {
		wg.Go(func() {
			_, err := db.JoinRoom(ctx, m, r.RoomID, 2, 0)
			if err != nil && !errors.Is(err, ErrNotFound) {
				t.Error(err)
			}
		})
	}
	if err := db.DeleteRoom(ctx, r.RoomID); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	active, err := db.ActiveRoomMembers(ctx)
	if err != nil || len(active) != 0 {
		t.Fatal("deleted admissions survived", active, err)
	}
	for _, m := range members {
		if _, err := db.JoinRoom(ctx, m, r.RoomID, 3, 0); !errors.Is(err, ErrNotFound) {
			t.Fatal("deleted room accepted a fresh join", err)
		}
		if _, err := db.MemberProfile(ctx, m.ID); err != nil {
			t.Fatal("room deletion removed an account", err)
		}
	}
	if _, err := db.CheckRoomPassword(ctx, r.RoomID, ""); !errors.Is(err, ErrNotFound) {
		t.Fatal("deleted room preflight accepted", err)
	}
	if _, err := db.RenameRoom(ctx, r.RoomID, "revive"); !errors.Is(err, ErrNotFound) {
		t.Fatal("rename revived deleted room", err)
	}
	ids, err := db.AllRoomIDs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, id := range ids {
		if id == r.RoomID {
			found = true
		}
	}
	if !found {
		t.Fatal("deleted ID missing from media revocation monitor")
	}
}
