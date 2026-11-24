package httpapi

import (
	"context"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
	"testing"
)

type sessionTestMedia struct {
	participants map[string][]room.Participant
	removed      []string
}

func (m *sessionTestMedia) Participants(_ context.Context, id string) ([]room.Participant, error) {
	return m.participants[id], nil
}
func (m *sessionTestMedia) RemoveParticipant(_ context.Context, id, identity string) error {
	m.removed = append(m.removed, id+":"+identity)
	return nil
}
func TestEnforcerRemovesOldEntriesAcrossAllRooms(t *testing.T) {
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	testdb.SeedRooms(t, dsn)
	member, credential, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	old, err := db.JoinRoom(ctx, member, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	current, err := db.JoinRoom(ctx, member, "room-5", 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	media := &sessionTestMedia{participants: map[string][]room.Participant{"friends": {{ID: old.Identity()}}, "room-5": {{ID: current.Identity()}}}}
	for range 2 {
		media.removed = nil
		if err := EnforceSessions(ctx, db, media); err != nil {
			t.Fatal(err)
		}
		if len(media.removed) != 1 || media.removed[0] != "friends:"+old.Identity() {
			t.Fatal("wrong room entry removed", media.removed)
		}
	}
	if err := db.RevokeClientCredential(ctx, credential); err != nil {
		t.Fatal(err)
	}
	media.removed = nil
	if err := EnforceSessions(ctx, db, media); err != nil || len(media.removed) != 2 {
		t.Fatal("global revocation did not remove both old JWT entries", err, media.removed)
	}
}

func TestEnforcerStillRemovesCachedMediaTokensForDeletedRooms(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(ctx, testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r, err := db.CreateRoom(ctx, "temporary")
	if err != nil {
		t.Fatal(err)
	}
	m, _, err := db.AddMember(ctx, "Oliver")
	if err != nil {
		t.Fatal(err)
	}
	a, err := db.JoinRoom(ctx, m, r.RoomID, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.DeleteRoom(ctx, r.RoomID); err != nil {
		t.Fatal(err)
	}
	media := &sessionTestMedia{participants: map[string][]room.Participant{r.RoomID: {{ID: a.Identity()}}}}
	// A cached LiveKit JWT can attempt another media connection after the first
	// kick. The deleted ID must remain covered on every monitor iteration.
	for range 2 {
		media.removed = nil
		if err := EnforceSessions(ctx, db, media); err != nil || len(media.removed) != 1 || media.removed[0] != r.RoomID+":"+a.Identity() {
			t.Fatal("deleted room escaped cleanup", media.removed, err)
		}
	}
}
