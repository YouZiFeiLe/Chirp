package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpstream"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type clientState struct {
	ServerID string                `json:"server_id"`
	Revision uint64                `json:"revision"`
	Rooms    []room.Overview       `json:"rooms"`
	Members  []store.MemberProfile `json:"members"`
}

// Cross-process admin/passkey writes are observed by one shared read per second,
// independent of the subscriber count. TTL renewals do not change public state.
type stateFeed struct {
	mu        sync.Mutex
	current   clientState
	digest    [32]byte
	checked   time.Time
	err       error
	streamsMu sync.Mutex
	streams   map[string]chan struct{}
}

func newStateFeed() *stateFeed {
	var id [24]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic("system random source unavailable")
	}
	return &stateFeed{current: clientState{ServerID: hex.EncodeToString(id[:])}, streams: make(map[string]chan struct{})}
}

func (s *Server) stateSnapshot(ctx context.Context) (clientState, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	f := s.state
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return clientState{}, err
	}
	if !f.checked.IsZero() && time.Since(f.checked) < time.Second {
		return f.current, f.err
	}
	rooms, err := s.directory.Rooms(ctx, s.store, group.Protocol)
	var profiles []store.MemberProfile
	if err == nil {
		profiles, err = s.store.MemberProfiles(ctx)
	}
	if err != nil {
		f.checked = time.Now()
		f.err = err
		return clientState{}, err
	}
	next := clientState{ServerID: f.current.ServerID, Rooms: rooms, Members: profiles}
	// Version the public value, not database write counts or lease renewals.
	encoded, err := json.Marshal(struct {
		Rooms   []room.Overview
		Members []store.MemberProfile
	}{rooms, profiles})
	if err == nil && len(encoded) > 2*1024*1024 {
		err = errors.New("client state exceeds size limit")
	}
	if err != nil {
		f.checked = time.Now()
		f.err = err
		return clientState{}, err
	}
	digest := sha256.Sum256(encoded)
	next.Revision = f.current.Revision
	if next.Revision == 0 || digest != f.digest {
		next.Revision++
	}
	f.current = next
	f.digest = digest
	f.checked = time.Now()
	f.err = nil
	return next, nil
}

func (s *Server) getState(w http.ResponseWriter, r *http.Request, _ store.Member) {
	if r.URL.RawQuery != "" {
		httpresponse.Error(w, 400, "BAD_REQUEST", "不接受查询参数")
		return
	}
	state, err := s.stateSnapshot(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, state)
}

func (f *stateFeed) register(identity string) (<-chan struct{}, func()) {
	f.streamsMu.Lock()
	defer f.streamsMu.Unlock()
	if previous := f.streams[identity]; previous != nil {
		close(previous)
	}
	stop := make(chan struct{})
	f.streams[identity] = stop
	return stop, func() {
		f.streamsMu.Lock()
		defer f.streamsMu.Unlock()
		if f.streams[identity] == stop {
			delete(f.streams, identity)
		}
	}
}

func (s *Server) events(w http.ResponseWriter, r *http.Request, m store.Member) {
	if r.URL.RawQuery != "" {
		httpresponse.Error(w, 400, "BAD_REQUEST", "不接受查询参数")
		return
	}
	stop, unregister := s.state.register(m.ParticipantIdentity())
	defer unregister()
	token := strings.Fields(r.Header.Get("Authorization"))[1]
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	httpstream.Start(w)
	var sent uint64
	keepalive := time.Now()
	for {
		// A cached public snapshot never substitutes for current login authority.
		current, err := s.store.MemberByCredential(r.Context(), token)
		if err != nil || !current.Enabled || current.ParticipantIdentity() != m.ParticipantIdentity() {
			event := "revoked"
			if err != nil && !errors.Is(err, store.ErrNotFound) {
				event = "unavailable"
				logging.Request(r, s.logger).Warn("State stream identity lookup failed", "event", "state.stream_failed", "error", err)
			}
			logging.Annotate(r.Context(), "stream_end", event)
			_ = httpstream.Write(w, event, sent, map[string]bool{"available": false})
			return
		}
		state, err := s.stateSnapshot(r.Context())
		if err != nil {
			logging.Request(r, s.logger).Warn("State stream snapshot failed", "event", "state.stream_failed", "error", err)
			_ = httpstream.Write(w, "unavailable", sent, map[string]bool{"available": false})
			return
		}
		if sent != state.Revision {
			err = httpstream.Write(w, "state", state.Revision, struct {
				ServerID string `json:"server_id"`
				Revision uint64 `json:"revision"`
			}{state.ServerID, state.Revision})
			if err != nil {
				return
			}
			sent = state.Revision
			keepalive = time.Now()
		} else if time.Since(keepalive) >= 10*time.Second {
			if httpstream.Ping(w) != nil {
				return
			}
			keepalive = time.Now()
		}
		select {
		case <-r.Context().Done():
			return
		case <-stop:
			return
		case <-tick.C:
		}
	}
}
