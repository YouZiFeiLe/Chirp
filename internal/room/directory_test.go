package room

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

type directoryMedia struct {
	calls       atomic.Int32
	lists       map[string][]Participant
	unavailable string
}

func (m *directoryMedia) Participants(_ context.Context, id string) ([]Participant, error) {
	m.calls.Add(1)
	if id == m.unavailable {
		return nil, errors.New("offline")
	}
	return m.lists[id], nil
}

func TestDirectoryIncludesDevicesStillVerifying(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	testdb.SeedRooms(t, dsn)
	join := func(name, roomID string) Participant {
		t.Helper()
		member, _, err := db.AddMember(ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		entry, err := db.JoinRoom(ctx, member, roomID, 1, 0)
		if err != nil {
			t.Fatal(err)
		}
		return Participant{ID: entry.Identity(), DisplayName: name}
	}
	a, b, c := join("Alice", "friends"), join("Bob", "friends"), join("Cora", "friends")
	other := join("Dan", "room-2")
	live := []string{c.ID, a.ID, b.ID, other.ID, "unknown"}
	media := &directoryMedia{lists: map[string][]Participant{"room-2": {other}}}
	groupIdentities := func(roomID string) []string {
		if roomID == "friends" {
			return live
		}
		return nil
	}
	directory := NewDirectory(media, groupIdentities)
	check := func(want ...Participant) {
		t.Helper()
		rooms, err := directory.Rooms(ctx, db, "protocol")
		if err != nil {
			t.Fatal(err)
		}
		slices.SortFunc(want, func(x, y Participant) int { return strings.Compare(x.ID, y.ID) })
		if !slices.Equal(rooms[0].Participants, want) || !slices.Equal(rooms[1].Participants, []Participant{other}) {
			t.Fatalf("unexpected directory: friends=%v, room-2=%v", rooms[0].Participants, rooms[1].Participants)
		}
	}
	check(a, b, c)
	media.lists["friends"] = []Participant{a}
	directory = NewDirectory(media, groupIdentities)
	check(a, b, c)
	// Signaling-only presence changes even while the SFU snapshot is cached.
	live = []string{b.ID}
	check(a, b)
}

func TestDirectoryCoalescesAndFiltersStaleRoomEntries(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	testdb.SeedRooms(t, dsn)
	member, _, err := db.AddMember(ctx, "Latest name")
	if err != nil {
		t.Fatal(err)
	}
	old, err := db.JoinRoom(ctx, member, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	current, err := db.JoinRoom(ctx, member, "room-2", 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	media := &directoryMedia{lists: map[string][]Participant{"friends": {{ID: old.Identity(), DisplayName: "stale"}}, "room-2": {{ID: current.Identity(), DisplayName: "Old nickname"}}}, unavailable: "room-4"}
	directory := NewDirectory(media, nil)
	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rooms, err := directory.Rooms(ctx, db, "protocol")
			if err != nil {
				t.Error(err)
				return
			}
			if len(rooms) != 5 || len(rooms[0].Participants) != 0 || len(rooms[1].Participants) != 1 || rooms[1].Participants[0].DisplayName != "Latest name" || rooms[3].Participants != nil || rooms[3].MediaStatus != "unavailable" {
				t.Error("directory leaked stale entries or hid failure", rooms)
			}
		}()
	}
	wg.Wait()
	if media.calls.Load() != 5 {
		t.Fatal("per-client requests did not share one five-room snapshot", media.calls.Load())
	}
	if err := db.LeaveRoom(ctx, member, "room-2", current.EntryID); err != nil {
		t.Fatal(err)
	}
	rooms, err := directory.Rooms(ctx, db, "protocol")
	if err != nil || len(rooms[1].Participants) != 0 {
		t.Fatal("cached SFU state retained revoked admission", err)
	}
}
