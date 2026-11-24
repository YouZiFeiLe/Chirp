// A disposable loopback API for the production Swift admission/state/SSE tests.
package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpapi"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// Admission tests do not connect media or request microphone access.
type media struct{}

func (media) Participants(context.Context, string) ([]room.Participant, error) {
	return []room.Participant{}, nil
}
func (media) EnsureRoom(context.Context, string) error { return nil }

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	root, err := os.MkdirTemp("", "chirp-admission-fixture-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(root)
	db, err := store.Open(ctx, filepath.Join(root, "test.db"))
	if err != nil {
		panic(err)
	}
	defer db.Close()
	member, credential, err := db.AddMember(ctx, "Admission fixture")
	if err != nil {
		panic(err)
	}
	protected, err := db.CreateRoom(ctx, "Protected fixture")
	if err != nil {
		panic(err)
	}
	const password = "disposable-fixture-password"
	if _, err = db.SetRoomPassword(ctx, protected.RoomID, password); err != nil {
		panic(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	issuer := room.Issuer{APIKey: "fixture", APISecret: strings.Repeat("s", 32), TTL: 5 * time.Minute}
	server := httptest.NewServer(httpapi.New(db, media{}, issuer, "wss://unused.example", "https://unused.example", logger))
	defer server.Close()
	if err = json.NewEncoder(os.Stdout).Encode(map[string]any{
		"url": server.URL, "password": password, "room": protected.RoomID,
		"login": map[string]any{"member": member, "credential": credential,
			"participant_identity": member.ID + "." + member.LoginID, "expires_at": member.CredentialExpiresAt},
	}); err != nil {
		panic(err)
	}
	<-ctx.Done()
}
