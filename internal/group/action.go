package group

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpstream"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func ProofMessage(identity, roomID, timestamp, nonce string, body []byte) []byte {
	return proofMessage(identity, roomID, "action", timestamp, nonce, body)
}
func proofMessage(identity, roomID, endpoint, timestamp, nonce string, body []byte) []byte {
	digest := sha256.Sum256(body)
	return []byte("Chirp group request v5\n" + identity + "\nPOST\n/v1/group/rooms/" + roomID + "/" + endpoint + "\n" + timestamp + "\n" + nonce + "\n" + hex.EncodeToString(digest[:]))
}

func (s *Server) action(w http.ResponseWriter, r *http.Request) { s.request(w, r, false) }
func (s *Server) events(w http.ResponseWriter, r *http.Request) { s.request(w, r, true) }

func (s *Server) request(w http.ResponseWriter, r *http.Request, stream bool) {
	m, ok := s.member(w, r)
	if !ok {
		return
	}
	hub, ok := s.publicHub(w, r)
	if !ok {
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 256*1024))
	if err != nil {
		httpresponse.Error(w, 400, "BAD_REQUEST", "群组消息过大或无效")
		return
	}
	var request Request
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF || request.RoomID != hub.roomID || !store.ValidEntryID(request.EntryID) {
		httpresponse.Error(w, 400, "BAD_REQUEST", "无效的房间或入房请求")
		return
	}
	endpoint := "action"
	if stream {
		endpoint = "events"
	}
	if stream && request.Operation != "watch" || !stream && request.Operation == "watch" {
		httpresponse.Error(w, 400, "BAD_REQUEST", "事件订阅操作无效")
		return
	}
	identity := store.AdmissionIdentity(m, request.EntryID)
	logging.Annotate(r.Context(), "group_operation", request.Operation)
	stamp, nonce := r.Header.Get("X-Chirp-Time"), r.Header.Get("X-Chirp-Nonce")
	timestamp, err := strconv.ParseInt(stamp, 10, 64)
	key, keyErr := base64.StdEncoding.Strict().DecodeString(r.Header.Get("X-Chirp-Key"))
	signature, sigErr := base64.StdEncoding.Strict().DecodeString(r.Header.Get("X-Chirp-Signature"))
	if err != nil || keyErr != nil || sigErr != nil || len(key) != ed25519.PublicKeySize || len(signature) != ed25519.SignatureSize || len(nonce) < 16 || len(nonce) > 64 || strings.ContainsAny(nonce, "\r\n") || time.Since(time.Unix(timestamp, 0)).Abs() > time.Minute || !ed25519.Verify(key, proofMessage(identity, hub.roomID, endpoint, stamp, nonce, body), signature) {
		httpresponse.Error(w, 403, "INVALID_PROOF", "客户端签名或请求时效无效")
		return
	}
	allowed, err := s.db.AdmissionAllowed(r.Context(), hub.roomID, identity)
	if err != nil {
		logging.Request(r, s.logger).Warn("Admission authority unavailable", "event", "group.admission_failed", "error", err)
		hub.Reconcile(nil, false)
		// Only already-bound peers can observe paused state. Neither notifications
		// nor an authority outage renew persistent admission or grant a media lease.
		if request.Operation == "snapshot" || request.Operation == "heartbeat" || request.Operation == "lease" {
			state, applyErr := hub.Apply(m, key, identity+"|"+nonce, request)
			if applyErr == nil && state.LeaseMS == 0 {
				s.reply(w, request.Operation, state)
				return
			}
		}
		httpresponse.Error(w, 503, "UNAVAILABLE", "无法验证入房授权")
		return
	}
	if !allowed {
		httpresponse.Error(w, 409, "ADMISSION_EXPIRED", "本次入房已失效，请重新加入")
		return
	}
	if !s.verifyIdentity(w, r, hub, m, base64.StdEncoding.EncodeToString(key), request) {
		return
	}
	state, err := hub.Apply(m, key, identity+"|"+nonce, request)
	if err != nil {
		if errors.Is(err, ErrBudget) {
			w.Header().Set("Retry-After", "1")
			httpresponse.Error(w, 429, "GROUP_BUDGET", "成员请求过于频繁")
			return
		}
		code := "GROUP_CONFLICT"
		if errors.Is(err, ErrStale) {
			code = "GROUP_CHANGED"
		}
		if errors.Is(err, ErrReplay) {
			code = "REPLAYED_REQUEST"
		}
		if errors.Is(err, ErrBinding) {
			code = "IDENTITY_KEY_CHANGED"
		}
		httpresponse.Error(w, 409, code, "安全会话已变化，请同步或重新加入")
		return
	}
	if request.Operation == "join" || request.Operation == "heartbeat" {
		if err := s.db.TouchAdmission(r.Context(), hub.roomID, identity); err != nil {
			logging.Request(r, s.logger).Warn("Admission renewal failed", "event", "group.renewal_failed", "error", err)
			if errors.Is(err, store.ErrAdmissionChanged) {
				hub.Remove(identity)
				httpresponse.Error(w, 409, "ADMISSION_EXPIRED", "本次入房已失效，请重新加入")
			} else if paused, ok := hub.suspendSnapshot(identity); ok {
				s.reply(w, request.Operation, paused)
			} else {
				httpresponse.Error(w, 503, "UNAVAILABLE", "无法续期入房授权")
			}
			return
		}
	}
	if stream {
		s.stream(w, r, hub, m, key, request)
		return
	}
	s.reply(w, request.Operation, state, request.KeyEpoch)
}

type pulse struct {
	RoomID           string           `json:"room_id"`
	Protocol         string           `json:"protocol"`
	ServerID         string           `json:"server_id"`
	SessionID        string           `json:"session_id"`
	Generation       uint64           `json:"generation"`
	Revision         uint64           `json:"revision"`
	Phase            string           `json:"phase"`
	Suspended        bool             `json:"suspended"`
	LeaseMS          int64            `json:"lease_ms"`
	KeyEpoch         uint64           `json:"key_epoch,omitempty"`
	RotationRevision uint64           `json:"rotation_revision,omitempty"`
	RoomInformation  *RoomInformation `json:"room_information,omitempty"`
}

func (s *Server) reply(w http.ResponseWriter, operation string, state Snapshot, epochs ...uint64) {
	if operation == "heartbeat" || operation == "lease" {
		lease := int64(0)
		if operation == "lease" {
			lease = state.LeaseMS
		}
		epoch := state.KeyEpoch
		if operation == "lease" && len(epochs) > 0 {
			epoch = epochs[0]
		}
		httpresponse.JSON(w, 200, pulse{RoomID: state.RoomID, Protocol: Protocol, ServerID: state.ServerID, SessionID: state.SessionID,
			Generation: state.Generation, Revision: state.Revision, Phase: state.Phase, Suspended: state.Suspended,
			LeaseMS: lease, KeyEpoch: epoch, RotationRevision: state.RotationRevision, RoomInformation: state.RoomInformation})
		return
	}
	httpresponse.JSON(w, 200, state)
}

func (s *Server) stream(w http.ResponseWriter, r *http.Request, hub *Hub, m store.Member, key ed25519.PublicKey, request Request) {
	identity := store.AdmissionIdentity(m, request.EntryID)
	stop, unregister := hub.registerStream(identity)
	defer unregister()
	httpstream.Start(w)
	check := time.NewTicker(time.Second)
	defer check.Stop()
	ping := time.NewTicker(10 * time.Second)
	defer ping.Stop()
	var sent, sentRotation uint64
	for {
		state, changed, ok := hub.watch(identity, base64.StdEncoding.EncodeToString(key), request.SessionID)
		if !ok {
			_ = httpstream.Write(w, "revoked", sent, map[string]bool{"revoked": true})
			return
		}
		if sent != state.Revision || sentRotation != state.RotationRevision {
			if err := httpstream.Write(w, "state", state.Revision, struct {
				RoomID           string `json:"room_id"`
				ServerID         string `json:"server_id"`
				Revision         uint64 `json:"revision"`
				RotationRevision uint64 `json:"rotation_revision,omitempty"`
			}{state.RoomID, state.ServerID, state.Revision, state.RotationRevision}); err != nil {
				return
			}
			sent = state.Revision
			sentRotation = state.RotationRevision
		}
		select {
		case <-r.Context().Done():
			return
		case <-stop:
			return
		case <-changed:
		case <-ping.C:
			if httpstream.Ping(w) != nil {
				return
			}
		case <-check.C:
			allowed, err := s.db.AdmissionAllowed(r.Context(), hub.roomID, identity)
			if err != nil {
				hub.Reconcile(nil, false)
			} else if !allowed {
				hub.Remove(identity)
			}
		}
	}
}
