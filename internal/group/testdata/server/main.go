// A loopback-only protocol fixture. It uses deterministic fake login identities
// and is excluded from production builds by its testdata directory.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testidentity"
)

type fixtureStore struct {
	authorityUnavailable atomic.Bool
	touches              atomic.Uint64
	mu                   sync.Mutex
	admissions           map[string]store.RoomAdmission
	devices              map[string]identity.Device
	policies             map[string]identity.RoomPolicy
	origin               string
}

func (*fixtureStore) MemberByCredential(_ context.Context, token string) (store.Member, error) {
	for i := range 24 {
		if token == fmt.Sprintf("chirp_%02d%s", i, strings.Repeat("a", 41)) {
			return store.Member{ID: fmt.Sprintf("member%02d", i), LoginID: "login_test", DisplayName: fmt.Sprintf("Peer %d", i), Enabled: true}, nil
		}
	}
	return store.Member{}, store.ErrNotFound
}
func (s *fixtureStore) AdmissionAllowed(_ context.Context, roomID, identity string) (bool, error) {
	if s.authorityUnavailable.Load() {
		return false, errors.New("test authority outage")
	}
	member, _, _, ok := store.SplitAdmissionIdentity(identity)
	if !ok {
		return false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	a, exists := s.admissions[member]
	return exists && a.RoomID == roomID && a.Identity() == identity, nil
}
func (s *fixtureStore) ActiveAdmissions(ctx context.Context) (map[string]string, error) {
	if s.authorityUnavailable.Load() {
		return nil, errors.New("test authority outage")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make(map[string]string)
	for _, a := range s.admissions {
		result[a.Identity()] = a.RoomID
	}
	return result, nil
}
func (s *fixtureStore) TouchAdmission(ctx context.Context, roomID, identity string) error {
	s.touches.Add(1)
	ok, err := s.AdmissionAllowed(ctx, roomID, identity)
	if err != nil {
		return err
	}
	if !ok {
		return store.ErrAdmissionChanged
	}
	return nil
}
func (*fixtureStore) Room(_ context.Context, id string) (store.RoomConfig, error) {
	if !store.ValidRoomID(id) {
		return store.RoomConfig{}, store.ErrNotFound
	}
	return store.RoomConfig{RoomID: id}, nil
}
func (*fixtureStore) Ping(context.Context) error { return nil }

func (s *fixtureStore) LoginDevice(_ context.Context, member, login string) (identity.Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	device, ok := s.devices[member]
	if !ok || login != "login_test" {
		return device, store.ErrDeviceIdentity
	}
	return device, nil
}
func (s *fixtureStore) RoomPolicy(_ context.Context, room string) (identity.RoomPolicy, error) {
	if strings.HasPrefix(room, "mutual-") {
		return identity.MutualRoom("https://keys.example.test:443", room), nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.policies[room]; ok {
		return p, nil
	}
	clients := make([]testidentity.Client, 24)
	for i := range clients {
		clients[i] = testidentity.New(fmt.Sprintf("group-peer-%02d", i))
	}
	p := clients[0].Policy(s.origin, room, clients...)
	s.policies[room] = p
	return p, nil
}

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	policy := group.DefaultPolicy()
	policy.Rotation = 5 * time.Second
	if value := os.Getenv("CHIRP_GROUP_TEST_ROTATION"); value != "" {
		var err error
		policy.Rotation, err = time.ParseDuration(value)
		if err != nil {
			panic(err)
		}
	}
	if value := os.Getenv("CHIRP_GROUP_TEST_TRANSITION"); value != "" {
		var err error
		policy.TransitionTimeout, err = time.ParseDuration(value)
		if err != nil {
			panic(err)
		}
	}
	db := &fixtureStore{admissions: make(map[string]store.RoomAdmission), devices: make(map[string]identity.Device), policies: make(map[string]identity.RoomPolicy), origin: "http://" + listener.Addr().String()}
	var server atomic.Pointer[group.Server]
	var restartMu sync.Mutex
	var monitorCancel context.CancelFunc
	streamContext, cancelStreams := context.WithCancel(context.Background())
	var streamsMu sync.Mutex
	restart := func() {
		restartMu.Lock()
		defer restartMu.Unlock()
		if monitorCancel != nil {
			monitorCancel()
		}
		next := group.New(db, policy, slog.New(slog.NewTextHandler(os.Stderr, nil)))
		ctx, cancel := context.WithCancel(context.Background())
		monitorCancel = cancel
		server.Store(next)
		go next.Monitor(ctx)
	}
	disconnect := func() {
		streamsMu.Lock()
		defer streamsMu.Unlock()
		cancelStreams()
		streamContext, cancelStreams = context.WithCancel(context.Background())
	}
	restart()
	var unavailable atomic.Bool
	var legacy atomic.Bool
	var requests, responseBytes atomic.Uint64
	type delayRule struct {
		RoomID     string `json:"room_id"`
		Operation  string `json:"operation"`
		RequestMS  int    `json:"request_ms"`
		ResponseMS int    `json:"response_ms"`
	}
	var delayMu sync.Mutex
	delays := make(map[string]delayRule)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/v1/group/rooms/") && strings.HasSuffix(r.URL.Path, "/config") {
			roomID := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/group/rooms/"), "/config")
			delayMu.Lock()
			delay := delays[roomID+"/config"]
			delayMu.Unlock()
			if ms := delay.RequestMS + delay.ResponseMS; ms > 0 {
				timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
				defer timer.Stop()
				select {
				case <-timer.C:
				case <-r.Context().Done():
					return
				}
			}
		}
		if r.Method == "POST" && r.URL.Path == "/test/v5-expiry" {
			var input struct {
				RoomID  string `json:"room_id"`
				Seconds int64  `json:"seconds"`
			}
			if json.NewDecoder(r.Body).Decode(&input) != nil || !store.ValidRoomID(input.RoomID) || input.Seconds < 1 || input.Seconds > 20 {
				w.WriteHeader(400)
				return
			}
			p, _ := db.RoomPolicy(r.Context(), input.RoomID)
			p.NotBefore = time.Now().Unix() - 1
			p.NotAfter = time.Now().Unix() + input.Seconds
			owner := testidentity.New("group-peer-00")
			p.Signature = identity.Sign(owner.Key, p.Message())
			db.mu.Lock()
			db.policies[input.RoomID] = p
			db.mu.Unlock()
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/group-delay" {
			var rule delayRule
			if json.NewDecoder(r.Body).Decode(&rule) != nil || !store.ValidRoomID(rule.RoomID) || rule.Operation == "" ||
				rule.RequestMS < 0 || rule.RequestMS > 1800 || rule.ResponseMS < 0 || rule.ResponseMS > 1800 {
				w.WriteHeader(400)
				return
			}
			delayMu.Lock()
			delays[rule.RoomID+"/"+rule.Operation] = rule
			delayMu.Unlock()
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && (r.URL.Path == "/test/legacy" || r.URL.Path == "/test/modern") {
			legacy.Store(r.URL.Path == "/test/legacy")
			w.WriteHeader(204)
			return
		}
		if legacy.Load() && strings.HasPrefix(r.URL.Path, "/v1/group/") {
			if strings.HasSuffix(r.URL.Path, "/config") {
				recorder := httptest.NewRecorder()
				server.Load().ServeHTTP(recorder, r)
				var config map[string]json.RawMessage
				_ = json.Unmarshal(recorder.Body.Bytes(), &config)
				delete(config, "smooth_rotation")
				config["protocol"] = json.RawMessage(`"chirp-mls-reinit-v3"`)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(recorder.Code)
				_ = json.NewEncoder(w).Encode(config)
				return
			}
			if r.Method == "POST" {
				body, _ := io.ReadAll(r.Body)
				r.Body = io.NopCloser(bytes.NewReader(body))
				var payload map[string]json.RawMessage
				_ = json.Unmarshal(body, &payload)
				if payload["smooth_rotation"] != nil || payload["key_epoch"] != nil {
					http.Error(w, "legacy parser rejected extension", 400)
					return
				}
			}
		}
		if r.Method == "POST" && r.URL.Path == "/test/disconnect-events" {
			disconnect()
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/restart" {
			restart()
			disconnect()
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/revoke" {
			var request struct {
				MemberID string `json:"member_id"`
			}
			if json.NewDecoder(r.Body).Decode(&request) != nil {
				w.WriteHeader(400)
				return
			}
			db.mu.Lock()
			delete(db.admissions, request.MemberID)
			db.mu.Unlock()
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == "/test/metrics" {
			if r.Method == "DELETE" {
				requests.Store(0)
				responseBytes.Store(0)
				db.touches.Store(0)
				w.WriteHeader(204)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]uint64{"requests": requests.Load(), "response_bytes": responseBytes.Load(), "touches": db.touches.Load()})
			return
		}
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/test/v5-policy/") {
			p, _ := db.RoomPolicy(r.Context(), strings.TrimPrefix(r.URL.Path, "/test/v5-policy/"))
			_ = json.NewEncoder(w).Encode(p)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/admission" {
			var a struct {
				MemberID string          `json:"member_id"`
				RoomID   string          `json:"room_id"`
				EntryID  string          `json:"entry_id"`
				Device   identity.Device `json:"device_identity"`
			}
			if json.NewDecoder(r.Body).Decode(&a) != nil || !store.ValidRoomID(a.RoomID) || !store.ValidEntryID(a.EntryID) || a.Device.Validate(time.Now()) != nil {
				w.WriteHeader(400)
				return
			}
			db.mu.Lock()
			db.devices[a.MemberID] = a.Device
			db.admissions[a.MemberID] = store.RoomAdmission{MemberID: a.MemberID, LoginID: "login_test", RoomID: a.RoomID, EntryID: a.EntryID}
			db.mu.Unlock()
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/authority-outage" {
			db.authorityUnavailable.Store(true)
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/authority-recover" {
			db.authorityUnavailable.Store(false)
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/recover" {
			unavailable.Store(false)
			w.WriteHeader(204)
			return
		}
		if r.Method == "POST" && r.URL.Path == "/test/outage" {
			unavailable.Store(true)
			w.WriteHeader(204)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/group/") && unavailable.Load() {
			w.WriteHeader(503)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/group/") {
			requests.Add(1)
			w = &measuredWriter{ResponseWriter: w, bytes: &responseBytes}
		}
		if strings.HasSuffix(r.URL.Path, "/events") {
			streamsMu.Lock()
			streamParent := streamContext
			streamsMu.Unlock()
			ctx, cancel := context.WithCancel(r.Context())
			stop := context.AfterFunc(streamParent, cancel)
			defer cancel()
			defer stop()
			r = r.WithContext(ctx)
		}
		if strings.HasSuffix(r.URL.Path, "/action") {
			body, _ := io.ReadAll(r.Body)
			r.Body = io.NopCloser(bytes.NewReader(body))
			var action group.Request
			_ = json.Unmarshal(body, &action)
			delayMu.Lock()
			rule := delays[action.RoomID+"/"+action.Operation]
			delayMu.Unlock()
			if rule.RequestMS == 0 && rule.ResponseMS == 0 {
				server.Load().ServeHTTP(w, r)
				return
			}
			wait := func(ms int) bool {
				timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
				defer timer.Stop()
				select {
				case <-timer.C:
					return true
				case <-r.Context().Done():
					return false
				}
			}
			if !wait(rule.RequestMS) {
				return
			}
			recorder := httptest.NewRecorder()
			server.Load().ServeHTTP(recorder, r)
			if !wait(rule.ResponseMS) {
				return
			}
			for key, values := range recorder.Header() {
				w.Header()[key] = values
			}
			w.WriteHeader(recorder.Code)
			_, _ = w.Write(recorder.Body.Bytes())
			return
		}
		server.Load().ServeHTTP(w, r)
	})
	if err := json.NewEncoder(os.Stdout).Encode(map[string]string{"url": "http://" + listener.Addr().String()}); err != nil {
		panic(err)
	}
	if err := http.Serve(listener, handler); err != nil {
		panic(err)
	}
}

type measuredWriter struct {
	http.ResponseWriter
	bytes *atomic.Uint64
}

func (w *measuredWriter) Write(p []byte) (int, error) {
	n, err := w.ResponseWriter.Write(p)
	w.bytes.Add(uint64(n))
	return n, err
}
func (w *measuredWriter) Flush()                      { _ = http.NewResponseController(w.ResponseWriter).Flush() }
func (w *measuredWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
