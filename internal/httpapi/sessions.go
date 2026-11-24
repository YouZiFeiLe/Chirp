package httpapi

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type sessionMedia interface {
	Participants(context.Context, string) ([]room.Participant, error)
	RemoveParticipant(context.Context, string, string) error
}

// Self-hosted LiveKit cannot revoke a cached media JWT. Recheck the exact room
// admission (login generation and entry), including after rejoin and room
// deletion, rather than relying on a one-time kick.
func EnforceSessions(ctx context.Context, db *store.Store, media sessionMedia, loggers ...*slog.Logger) error {
	var firstErr error
	ids, err := db.AllRoomIDs(ctx)
	if err != nil {
		return fmt.Errorf("list room admissions: %w", err)
	}
	for _, roomID := range ids {
		participants, err := media.Participants(ctx, roomID)
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("list media participants in room %s: %w", roomID, err)
			}
			continue
		}
		for _, participant := range participants {
			allowed, err := db.AdmissionAllowed(ctx, roomID, participant.ID)
			if err != nil {
				if firstErr == nil {
					firstErr = fmt.Errorf("check admission in room %s: %w", roomID, err)
				}
				continue
			}
			if !allowed {
				if err = media.RemoveParticipant(ctx, roomID, participant.ID); err != nil {
					if firstErr == nil {
						firstErr = fmt.Errorf("remove revoked participant %s in room %s: %w", participant.ID, roomID, err)
					}
				} else if len(loggers) > 0 {
					loggers[0].InfoContext(ctx, "Revoked media participant removed", "event", "sessions.participant_removed", "room_id", roomID, "participant_id", participant.ID)
				}
			}
		}
	}
	if firstErr != nil {
		return firstErr
	}
	return nil
}

func MonitorSessions(ctx context.Context, db *store.Store, media sessionMedia, logger *slog.Logger) {
	health := logging.FailureTracker{Logger: logger.With("module", "sessions"), Event: "sessions.enforcement"}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			checkCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := EnforceSessions(checkCtx, db, media, logger)
			cancel()
			health.Observe(ctx, err)
		}
	}
}
