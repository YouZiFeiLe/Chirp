package group

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	v5 "gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type Store interface {
	MemberByCredential(context.Context, string) (store.Member, error)
	AdmissionAllowed(context.Context, string, string) (bool, error)
	ActiveAdmissions(context.Context) (map[string]string, error)
	TouchAdmission(context.Context, string, string) error
	Ping(context.Context) error
	Room(context.Context, string) (store.RoomConfig, error)
}

type Server struct {
	db      Store
	hubs    map[string]*Hub
	logger  *slog.Logger
	handler http.Handler
	mu      sync.Mutex
	policy  Policy
	origin  string
}

func New(db Store, policy Policy, logger *slog.Logger, origins ...string) *Server {
	s := &Server{db: db, hubs: map[string]*Hub{store.DefaultRoomID: NewHub(store.DefaultRoomID, policy, logger)}, policy: policy, logger: logger}
	if len(origins) > 0 {
		s.origin, _ = v5.NormalizeOrigin(origins[0])
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(r.Context()); err != nil {
			httpresponse.Error(w, 503, "UNAVAILABLE", "身份服务暂时不可用")
			return
		}
		httpresponse.JSON(w, 200, map[string]string{"service": "group", "status": "ok", "protocol": Protocol})
	})
	mux.HandleFunc("GET /v1/group/rooms/{room}/config", s.config)
	mux.HandleFunc("POST /v1/group/rooms/{room}/action", s.action)
	mux.HandleFunc("POST /v1/group/rooms/{room}/events", s.events)
	s.handler = mux
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.URL.RawQuery != "" {
		httpresponse.Error(w, 400, "BAD_REQUEST", "不接受查询参数")
		return
	}
	s.handler.ServeHTTP(w, r)
}

func (s *Server) member(w http.ResponseWriter, r *http.Request) (store.Member, bool) {
	parts := strings.Fields(r.Header.Get("Authorization"))
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || len(parts[1]) > 128 {
		httpresponse.Error(w, 401, "UNAUTHORIZED", "请重新使用 Passkey 登录")
		return store.Member{}, false
	}
	m, err := s.db.MemberByCredential(r.Context(), parts[1])
	if errors.Is(err, store.ErrNotFound) {
		httpresponse.Error(w, 401, "UNAUTHORIZED", "登录已失效，请重新认证")
		return m, false
	}
	if err != nil {
		logging.Request(r, s.logger).Error("Group identity lookup failed", "event", "group.identity_failed", "error", err)
		httpresponse.Error(w, 503, "UNAVAILABLE", "无法验证成员身份")
		return m, false
	}
	if !m.Enabled {
		httpresponse.Error(w, 403, "MEMBER_DISABLED", "成员已停用")
		return m, false
	}
	logging.Annotate(r.Context(), "member_id", m.ID)
	return m, true
}

func (s *Server) config(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.member(w, r); !ok {
		return
	}
	hub, ok := s.publicHub(w, r)
	if !ok {
		return
	}
	db, identityOK := s.db.(identityAuthorityStore)
	if !identityOK {
		httpresponse.Error(w, 503, "V5_IDENTITY_UNAVAILABLE", "身份授权不可用")
		return
	}
	identityPolicy, identityErr := s.roomPolicy(r.Context(), db, hub.roomID)
	if identityErr != nil {
		httpresponse.Error(w, 409, "ROOM_IDENTITY_REQUIRED", "请先核验房间签名授权")
		return
	}
	hub.setIdentityPolicy(identityPolicy)
	httpresponse.JSON(w, 200, struct {
		RoomID         string `json:"room_id"`
		Protocol       string `json:"protocol"`
		ServerID       string `json:"server_id"`
		HeartbeatMS    int    `json:"heartbeat_ms"`
		MaxLeaseMS     int64  `json:"max_lease_ms"`
		LeaseRefreshMS int    `json:"lease_refresh_ms"`
		SmoothRotation bool   `json:"smooth_rotation"`
		IdentityPolicy any    `json:"identity_policy"`
	}{hub.roomID, Protocol, hub.ServerID(), 2000, hub.policy.Lease.Milliseconds(), 1000, true, identityPolicy})
}

// Control is implemented in process. No administrative group routes are exposed.
type Control interface {
	Send(context.Context, string, string, string) error
}

func (s *Server) Send(ctx context.Context, operation, roomID, identity string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if operation != "end" && operation != "remove" {
		return errors.New("unknown group control operation")
	}
	if operation == "remove" && identity == "" {
		return errors.New("a participant identity is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if operation == "end" {
		if hub := s.hubs[roomID]; hub != nil {
			hub.End()
		}
	} else if roomID != "" {
		if hub := s.hubs[roomID]; hub != nil {
			hub.Remove(identity)
		}
	} else {
		for _, hub := range s.hubs {
			hub.RemoveLogin(identity)
		}
	}
	return nil
}

func (s *Server) Monitor(ctx context.Context) {
	health := logging.FailureTracker{Logger: s.logger, Event: "group.authority"}
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		// Capture participants before reading authority. A join committed after
		// the batch read must not be removed using that older database snapshot.
		hubs := s.hubSnapshot()
		members := make(map[string][]string, len(hubs))
		for roomID, hub := range hubs {
			members[roomID] = hub.Identities()
		}
		check, cancel := context.WithTimeout(ctx, 2*time.Second)
		admissions, err := s.db.ActiveAdmissions(check)
		cancel()
		health.Observe(ctx, err)
		for roomID, hub := range hubs {
			allowed := make(map[string]bool)
			if err == nil {
				for _, id := range members[roomID] {
					allowed[id] = admissions[id] == roomID
				}
			}
			hub.Reconcile(allowed, err == nil)
		}
	}
}

func (s *Server) hubSnapshot() map[string]*Hub {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make(map[string]*Hub, len(s.hubs))
	for id, hub := range s.hubs {
		result[id] = hub
	}
	return result
}

// LiveIdentities lists recent signaling participants without creating a hub,
// refreshing a heartbeat, or advancing the room's key schedule.
func (s *Server) LiveIdentities(roomID string) []string {
	s.mu.Lock()
	hub := s.hubs[roomID]
	s.mu.Unlock()
	if hub == nil {
		return nil
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	now := hub.now()
	ids := make([]string, 0, len(hub.members))
	for id, member := range hub.members {
		if now.Sub(member.lastSeen) < hub.policy.HeartbeatTimeout {
			ids = append(ids, id)
		}
	}
	return ids
}

func (s *Server) publicHub(w http.ResponseWriter, r *http.Request) (*Hub, bool) {
	id := r.PathValue("room")
	if _, err := s.db.Room(r.Context(), id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			httpresponse.Error(w, 404, "ROOM_NOT_FOUND", "房间不存在")
		} else {
			logging.Request(r, s.logger).Error("Group room lookup failed", "event", "group.room_lookup_failed", "error", err)
			httpresponse.Error(w, 503, "UNAVAILABLE", "无法验证房间")
		}
		return nil, false
	}
	logging.Annotate(r.Context(), "room_id", id)
	s.mu.Lock()
	defer s.mu.Unlock()
	hub := s.hubs[id]
	if hub == nil {
		hub = NewHub(id, s.policy, s.logger)
		s.hubs[id] = hub
	}
	return hub, true
}
