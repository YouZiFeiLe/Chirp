package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

type stateMedia struct{ calls atomic.Int32 }

func (m *stateMedia) Participants(context.Context, string) ([]room.Participant, error) {
	m.calls.Add(1)
	return []room.Participant{}, nil
}
func (*stateMedia) EnsureRoom(context.Context, string) error { return nil }

func stateTestServer(t *testing.T) (*Server, *store.Store, store.Member, string, *stateMedia) {
	t.Helper()
	ctx := context.Background()
	dsn := testdb.Path(t)
	db, err := store.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	testdb.SeedRooms(t, dsn)
	m, token, err := db.AddMember(ctx, "Member")
	if err != nil {
		t.Fatal(err)
	}
	media := &stateMedia{}
	s := newServer(db, media, room.Issuer{}, "wss://rtc.example.test", "https://auth.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	return s, db, m, token, media
}

func invalidateState(s *Server) {
	s.state.mu.Lock()
	s.state.checked = time.Time{}
	s.state.mu.Unlock()
}

func TestStateVersionsPublicContentAndCoalescesConcurrentReaders(t *testing.T) {
	s, db, m, token, media := stateTestServer(t)
	ctx := context.Background()
	first, err := s.stateSnapshot(ctx)
	if err != nil || first.Revision != 1 || len(first.Rooms) != 5 || len(first.Members) != 1 {
		t.Fatal(first, err)
	}
	var wg sync.WaitGroup
	for range 24 {
		wg.Go(func() {
			state, err := s.stateSnapshot(ctx)
			if err != nil || state.Revision != first.Revision || state.ServerID != first.ServerID {
				t.Error("inconsistent concurrent snapshot", err)
			}
		})
	}
	wg.Wait()
	if media.calls.Load() != 5 {
		t.Fatal("subscribers caused separate SFU reads", media.calls.Load())
	}
	a, err := db.JoinRoom(ctx, m, "friends", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.TouchAdmission(ctx, a.RoomID, a.Identity()); err != nil {
		t.Fatal(err)
	}
	invalidateState(s)
	same, err := s.stateSnapshot(ctx)
	if err != nil || same.Revision != first.Revision {
		t.Fatal("admission TTL changed public version", same.Revision, err)
	}
	for i, mutate := range []func() error{
		func() error { _, err := db.RenameRoom(ctx, "friends", "Renamed"); return err },
		func() error { _, err := db.SetRoomDescription(ctx, "friends", "Weekend calls"); return err },
		func() error { _, err := db.UpdateOwnDisplayName(ctx, m, "New nickname"); return err },
		func() error { _, err := db.SetOwnAvatar(ctx, m, []byte("normalized avatar fixture")); return err },
		func() error { _, _, err := db.AddMember(ctx, "Another member"); return err },
		func() error { return db.DeleteRoom(ctx, "room-2") },
	} {
		if err := mutate(); err != nil {
			t.Fatal(err)
		}
		invalidateState(s)
		next, err := s.stateSnapshot(ctx)
		if err != nil || next.Revision != first.Revision+uint64(i)+1 {
			t.Fatal("public mutation did not advance version", next.Revision, err)
		}
	}
	encoded, err := json.Marshal(s.state.current)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{token, a.EntryID, "credential_hash", "avatar_data", "private_key", "lease_ms"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatal("state exposed authority or binary data", forbidden)
		}
	}
	if newStateFeed().current.ServerID == first.ServerID {
		t.Fatal("restart reused event version namespace")
	}
}

func readStateEvent(t *testing.T, reader *bufio.Reader) (string, map[string]any) {
	t.Helper()
	name := ""
	data := ""
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal("event stream ended", err)
		}
		line = strings.TrimSuffix(line, "\n")
		if line == "" && data != "" {
			var object map[string]any
			if err := json.Unmarshal([]byte(data), &object); err != nil {
				t.Fatal(err)
			}
			return name, object
		}
		if strings.HasPrefix(line, "event: ") {
			name = strings.TrimPrefix(line, "event: ")
		}
		if strings.HasPrefix(line, "data: ") {
			data = strings.TrimPrefix(line, "data: ")
		}
	}
}

func TestAuthenticatedStateStreamsReplaceOldConnectionsAndObserveRevocation(t *testing.T) {
	s, db, m, token, _ := stateTestServer(t)
	server := httptest.NewServer(s.handler())
	defer server.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	open := func(path, credential string, status int) *http.Response {
		t.Helper()
		req, _ := http.NewRequest("GET", server.URL+path, nil)
		if credential != "" {
			req.Header.Set("Authorization", "Bearer "+credential)
		}
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != status {
			_ = response.Body.Close()
			t.Fatal(path, response.StatusCode, "want", status)
		}
		return response
	}
	for _, path := range []string{"/v1/state", "/v1/events"} {
		_ = open(path, "", 401).Body.Close()
		_ = open(path, "expired", 401).Body.Close()
		_ = open(path+"?credential=forbidden", token, 400).Body.Close()
	}
	one := open("/v1/events", token, 200)
	defer one.Body.Close()
	if !strings.HasPrefix(one.Header.Get("Content-Type"), "text/event-stream") || one.Header.Get("X-Accel-Buffering") != "no" || one.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("event headers do not prevent buffering/caching")
	}
	name, hint := readStateEvent(t, bufio.NewReader(one.Body))
	if name != "state" || len(hint) != 2 || hint["revision"] != float64(1) {
		t.Fatal(name, hint)
	}
	two := open("/v1/events", token, 200)
	defer two.Body.Close()
	reader := bufio.NewReader(two.Body)
	_, _ = readStateEvent(t, reader)
	if tail, err := io.ReadAll(one.Body); err != nil || len(tail) != 0 {
		t.Fatal("replaced stream did not close", err)
	}
	if _, err := db.UpdateOwnDisplayName(context.Background(), m, "Updated by another request"); err != nil {
		t.Fatal(err)
	}
	invalidateState(s)
	name, hint = readStateEvent(t, reader)
	if name != "state" || hint["revision"].(float64) <= 1 {
		t.Fatal("profile event missing", name, hint)
	}
	if err := db.DisableMember(context.Background(), m.ID); err != nil {
		t.Fatal(err)
	}
	name, _ = readStateEvent(t, reader)
	if name != "revoked" {
		t.Fatal("revoked credential kept event access", name)
	}
	if _, err := io.ReadAll(two.Body); err != nil {
		t.Fatal(err)
	}
	_ = open("/v1/state", token, 403).Body.Close()
}

func TestStateAuthorityFailureClosesTheStreamWithoutPresentingCachedDataAsFresh(t *testing.T) {
	s, db, _, token, _ := stateTestServer(t)
	server := httptest.NewServer(s.handler())
	defer server.Close()
	req, _ := http.NewRequest("GET", server.URL+"/v1/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	reader := bufio.NewReader(response.Body)
	_, _ = readStateEvent(t, reader)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	name, _ := readStateEvent(t, reader)
	if name != "unavailable" {
		t.Fatal("database outage was not distinguished from revocation", name)
	}
	// The public endpoint must check current authority even while a public
	// content cache entry is still within its one-second reuse window.
	stateRequest, _ := http.NewRequest("GET", server.URL+"/v1/state", nil)
	stateRequest.Header.Set("Authorization", "Bearer "+token)
	stateResponse, err := client.Do(stateRequest)
	if err != nil {
		t.Fatal(err)
	}
	_ = stateResponse.Body.Close()
	if stateResponse.StatusCode < 500 {
		t.Fatal("public cache bypassed failed authentication authority", stateResponse.StatusCode)
	}
	invalidateState(s)
	if _, err := s.stateSnapshot(context.Background()); err == nil {
		t.Fatal("closed authority returned cached fresh data")
	}
}
