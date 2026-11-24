package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
)

func TestDirectoryPresenceContract(t *testing.T) {
	first := room.Participant{ID: "member_a", DisplayName: "A"}
	for _, tc := range []struct {
		name   string
		status string
		peers  []room.Participant
		valid  bool
	}{
		{"empty available", "available", []room.Participant{}, true},
		{"available members", "available", []room.Participant{first}, true},
		{"unavailable", "unavailable", nil, true},
		{"missing list", "available", nil, false},
		{"stale list", "unavailable", []room.Participant{}, false},
		{"unknown status", "other", nil, false},
		{"duplicate member", "available", []room.Participant{first, first}, false},
		{"empty member id", "available", []room.Participant{{DisplayName: "A"}}, false},
		{"control in id", "available", []room.Participant{{ID: "member_a\nx", DisplayName: "A"}}, false},
		{"invalid display name", "available", []room.Participant{{ID: "member_a", DisplayName: " A"}}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if validRoomPresence(room.Overview{MediaStatus: tc.status, Participants: tc.peers}) != tc.valid {
				t.Fatal("incorrect presence validation")
			}
		})
	}
}

func TestDirectoryReconnectImmediatelyRequestsSnapshot(t *testing.T) {
	var streams atomic.Uint32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.(http.Flusher).Flush()
		if streams.Add(1) > 1 {
			<-r.Context().Done()
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	events := make(chan string, 8)
	go watchDirectory(ctx, server.URL, "fixture", func(kind string, _ any) { events <- kind })
	for _, want := range []string{"directoryStale", "directoryChanged"} {
		select {
		case kind := <-events:
			if kind != want {
				t.Fatalf("got %s, want %s", kind, want)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("missing %s after the stream reconnected without an event", want)
		}
	}
}

func TestDirectoryStreamLossMarksSnapshotStale(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: state\ndata: {\"server_id\":\"fixture\",\"revision\":1}\n\n"))
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := make(chan string, 4)
	go watchDirectory(ctx, server.URL, "fixture", func(kind string, _ any) { events <- kind })
	for _, want := range []string{"directoryChanged", "directoryStale"} {
		select {
		case got := <-events:
			if got != want {
				t.Fatalf("got %s, want %s", got, want)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("missing directory notification", want)
		}
	}
}

func TestDirectoryRecoversAfterStreamAccessDenial(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) == 1 {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	events := make(chan string, 8)
	go watchDirectory(ctx, server.URL, "fixture", func(kind string, _ any) { events <- kind })
	for _, want := range []string{"directoryChanged", "directoryStale", "directoryChanged"} {
		select {
		case got := <-events:
			if got != want {
				t.Fatalf("got %s, want %s", got, want)
			}
		case <-ctx.Done():
			t.Fatal("the next connection never restored directory updates")
		}
	}
}

func TestDirectorySignedFriendNameRequiresCurrentRoot(t *testing.T) {
	friends := []friend{{ID: "member_a", Root: "root-A", Name: "Ana"}}
	if trustedFriendName(friends, "member_a", "root-A") != "Ana" ||
		trustedFriendName(friends, "member_a", "root-B") != "" ||
		trustedFriendName(friends, "member_b", "root-A") != "" || trustedFriendName(nil, "member_a", "root-A") != "" {
		t.Fatal("signed nickname was not bound to the current friend account and root")
	}
}
