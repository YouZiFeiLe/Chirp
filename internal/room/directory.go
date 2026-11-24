package room

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type Overview struct {
	store.RoomConfig
	Participants    []Participant `json:"participants"`
	MediaStatus     string        `json:"media_status"`
	MaxParticipants int           `json:"max_participants"`
	KeyProtocol     string        `json:"key_protocol"`
}

type Directory struct {
	mu      sync.Mutex
	fetched time.Time
	media   interface {
		Participants(context.Context, string) ([]Participant, error)
	}
	liveGroupIdentities func(string) []string
	cached              map[string][]Participant
	cacheKey            string
	health              logging.FailureTracker
}

func NewDirectory(media interface {
	Participants(context.Context, string) ([]Participant, error)
}, liveGroupIdentities func(string) []string, loggers ...*slog.Logger) *Directory {
	logger := slog.Default()
	if len(loggers) > 0 {
		logger = loggers[0]
	}
	return &Directory{media: media, liveGroupIdentities: liveGroupIdentities, health: logging.FailureTracker{Logger: logger, Event: "media.directory"}}
}

func (d *Directory) mediaSnapshot(ctx context.Context, configs []store.RoomConfig) map[string][]Participant {
	d.mu.Lock()
	defer d.mu.Unlock()
	ids := make([]string, len(configs))
	for i, cfg := range configs {
		ids[i] = cfg.RoomID
	}
	key := strings.Join(ids, ",")
	if d.cached != nil && d.cacheKey == key && time.Since(d.fetched) < time.Second {
		return d.cached
	}
	values := make([][]Participant, len(ids))
	failures := make([]error, len(ids))
	var wg sync.WaitGroup
	workers := make(chan struct{}, 8)
	for i, id := range ids {
		wg.Add(1)
		go func(i int, id string) {
			defer wg.Done()
			select {
			case workers <- struct{}{}:
				defer func() { <-workers }()
			case <-ctx.Done():
				return
			}
			list, err := d.media.Participants(ctx, id)
			failures[i] = err
			if err == nil {
				if list == nil {
					list = []Participant{}
				}
				values[i] = list
			}
		}(i, id)
	}
	wg.Wait()
	var firstError error
	failedRooms := 0
	for i, err := range failures {
		if err != nil {
			failedRooms++
			if firstError == nil {
				firstError = fmt.Errorf("list media participants in room %s: %w", ids[i], err)
			}
		}
	}
	d.health.Observe(ctx, firstError, "failed_rooms", failedRooms)
	snapshot := make(map[string][]Participant, len(ids))
	for i, id := range ids {
		snapshot[id] = values[i]
	}
	d.cached = snapshot
	d.fetched = time.Now()
	d.cacheKey = key
	return snapshot
}

// Only metadata is exposed. Reading this directory neither admits a participant
// nor touches crypto membership, heartbeats, leases, or key material.
func (d *Directory) Rooms(ctx context.Context, db *store.Store, protocol string) ([]Overview, error) {
	configs, err := db.Rooms(ctx)
	if err != nil {
		return nil, err
	}
	media := d.mediaSnapshot(ctx, configs)
	current, err := db.ActiveRoomMembers(ctx)
	if err != nil {
		return nil, err
	}
	allowed := make(map[string]store.RoomMember, len(current))
	for _, m := range current {
		allowed[m.Identity] = m
	}
	result := make([]Overview, 0, len(configs))
	for _, cfg := range configs {
		r := Overview{RoomConfig: cfg, MaxParticipants: 0, KeyProtocol: protocol, MediaStatus: "available"}
		list := media[cfg.RoomID]
		if list == nil {
			r.MediaStatus = "unavailable"
		} else {
			// Devices exchange verification messages before connecting to the SFU.
			present := make(map[string]struct{}, len(list))
			for _, p := range list {
				present[p.ID] = struct{}{}
			}
			if d.liveGroupIdentities != nil {
				for _, id := range d.liveGroupIdentities(cfg.RoomID) {
					present[id] = struct{}{}
				}
			}
			r.Participants = make([]Participant, 0, len(present))
			for id := range present {
				if m, ok := allowed[id]; ok && m.RoomID == cfg.RoomID {
					r.Participants = append(r.Participants, Participant{ID: id, DisplayName: m.DisplayName})
				}
			}
			sort.Slice(r.Participants, func(i, j int) bool { return r.Participants[i].ID < r.Participants[j].ID })
		}
		result = append(result, r)
	}
	return result, nil
}
