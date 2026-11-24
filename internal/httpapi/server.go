package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type Server struct {
	store            *store.Store
	media            room.Backend
	issuer           room.Issuer
	wsURL            string
	logger           *slog.Logger
	directory        *room.Directory
	preflightProofs  preflightProofs
	passwordAttempts passwordAttempts
	avatarProcessing chan struct{}
	attachments      *AttachmentStorage
	deviceRevoked    store.DeviceRevocationCheck
	passkeyOrigin    string
	clientEndpoints  config.ClientEndpoints
	state            *stateFeed
}

func New(db *store.Store, media room.Backend, issuer room.Issuer, wsURL, passkeyOrigin string, logger *slog.Logger, endpoints ...config.ClientEndpoints) http.Handler {
	return newServer(db, media, issuer, wsURL, passkeyOrigin, logger, endpoints...).handler()
}

func NewWithAttachments(db *store.Store, media room.Backend, issuer room.Issuer, wsURL, passkeyOrigin string, logger *slog.Logger, endpoints config.ClientEndpoints, files *AttachmentStorage, deviceRevoked store.DeviceRevocationCheck, directories ...*room.Directory) http.Handler {
	s := newServer(db, media, issuer, wsURL, passkeyOrigin, logger, endpoints)
	s.attachments = files
	s.deviceRevoked = deviceRevoked
	if len(directories) > 0 {
		s.directory = directories[0]
	}
	return s.handler()
}

func newServer(db *store.Store, media room.Backend, issuer room.Issuer, wsURL, passkeyOrigin string, logger *slog.Logger, endpoints ...config.ClientEndpoints) *Server {
	s := &Server{store: db, media: media, issuer: issuer, wsURL: wsURL, logger: logger, directory: room.NewDirectory(media, nil, logger), preflightProofs: newPreflightProofs(), avatarProcessing: make(chan struct{}, 1)}
	s.passkeyOrigin = passkeyOrigin
	s.state = newStateFeed()
	s.clientEndpoints = config.DefaultClientEndpoints(passkeyOrigin)
	if len(endpoints) > 0 {
		s.clientEndpoints = endpoints[0]
	}
	return s
}

func (s *Server) handler() http.Handler {
	db := s.store
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", httpresponse.Health(db, "api"))
	mux.HandleFunc("GET /v1/client-config", s.clientConfig)
	mux.HandleFunc("GET /v1/me", s.authorized(s.me))
	mux.HandleFunc("PATCH /v1/me", s.authorized(s.updateProfile))
	mux.HandleFunc("PUT /v1/me/avatar", s.authorized(s.putAvatar))
	mux.HandleFunc("DELETE /v1/me/avatar", s.authorized(s.deleteAvatar))
	mux.HandleFunc("GET /v1/members", s.authorized(s.getProfiles))
	mux.HandleFunc("GET /v1/members/{member}/avatar/{revision}", s.authorized(s.getAvatar))
	mux.HandleFunc("GET /v1/session", s.authorized(s.session))
	mux.HandleFunc("POST /v1/logout", s.authorized(s.logout))
	mux.HandleFunc("GET /v1/rooms", s.authorized(s.getRooms))
	mux.HandleFunc("GET /v1/identity/devices", s.authorized(s.getDevices))
	mux.HandleFunc("PATCH /v1/identity/devices/{device}", s.authorized(s.renameDevice))
	mux.HandleFunc("DELETE /v1/identity/devices/{device}", s.authorized(s.revokeDevice))
	mux.HandleFunc("GET /v1/identity/blacklist", s.authorized(s.getBlacklist))
	mux.HandleFunc("GET /v1/identity/social/{after}", s.authorized(s.getSocial))
	mux.HandleFunc("POST /v1/identity/social", s.authorized(s.putSocial))
	mux.HandleFunc("GET /v1/identity/signals/{after}", s.authorized(s.getIdentitySignals))
	mux.HandleFunc("POST /v1/identity/signals", s.authorized(s.sendIdentitySignal))
	mux.HandleFunc("GET /v1/state", s.authorized(s.getState))
	mux.HandleFunc("GET /v1/events", s.authorized(s.events))
	mux.HandleFunc("POST /v1/rooms/{room}/preflight", s.authorized(s.preflight))
	mux.HandleFunc("POST /v1/rooms/{room}/join", s.authorized(s.join))
	mux.HandleFunc("POST /v1/rooms/{room}/media-token", s.authorized(s.refreshMediaToken))
	mux.HandleFunc("POST /v1/rooms/{room}/leave", s.authorized(s.leave))
	mux.HandleFunc("POST /v1/rooms/{room}/attachments", s.authorized(s.createAttachment))
	mux.HandleFunc("GET /v1/rooms/{room}/attachments", s.authorized(s.attachmentList))
	mux.HandleFunc("GET /v1/rooms/{room}/attachments/events", s.authorized(s.attachmentEvents))
	mux.HandleFunc("POST /v1/rooms/{room}/attachments/{attachment}/cancel", s.authorized(s.changeAttachment))
	mux.HandleFunc("POST /v1/rooms/{room}/attachments/{attachment}/pause", s.authorized(s.changeAttachment))
	mux.HandleFunc("POST /v1/rooms/{room}/attachments/{attachment}/complete", s.authorized(s.changeAttachment))
	mux.HandleFunc("POST /v1/rooms/{room}/attachments/{attachment}/received", s.authorized(s.receiveAttachment))
	mux.HandleFunc("GET /v1/rooms/{room}/attachments/{attachment}", s.authorized(s.attachment))
	mux.HandleFunc("PUT /v1/rooms/{room}/attachments/{attachment}/chunks/{chunk}", s.authorized(s.attachmentChunk))
	mux.HandleFunc("GET /v1/rooms/{room}/attachments/{attachment}/chunks/{chunk}", s.authorized(s.attachmentChunk))
	return mux
}

func (s *Server) authorized(next func(http.ResponseWriter, *http.Request, store.Member)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		parts := strings.Fields(r.Header.Get("Authorization"))
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || len(parts[1]) > 128 {
			httpresponse.Error(w, 401, "UNAUTHORIZED", "请使用 Passkey 登录")
			return
		}
		member, err := s.store.MemberByCredential(r.Context(), parts[1])
		if errors.Is(err, store.ErrNotFound) {
			httpresponse.Error(w, 401, "UNAUTHORIZED", "登录已失效、到期或已在其他设备登录，请重新认证")
			return
		}
		if err != nil {
			s.internalError(w, r, err)
			return
		}
		if !member.Enabled {
			httpresponse.Error(w, 403, "MEMBER_DISABLED", "成员访问已停用，请联系维护者")
			return
		}
		logging.Annotate(r.Context(), "member_id", member.ID)
		next(w, r, member)
	}
}

func (s *Server) me(w http.ResponseWriter, r *http.Request, member store.Member) {
	p, err := s.store.MemberProfile(r.Context(), member.ID)
	if err != nil {
		s.profileError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, p)
}

func (s *Server) getRooms(w http.ResponseWriter, r *http.Request, _ store.Member) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rooms, err := s.directory.Rooms(ctx, s.store, group.Protocol)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, struct {
		Rooms []room.Overview `json:"rooms"`
	}{rooms})
}

func readRoomJSON(w http.ResponseWriter, r *http.Request, target any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	var raw json.RawMessage
	if decoder.Decode(&raw) != nil || len(raw) == 0 || raw[0] != '{' {
		httpresponse.Error(w, 400, "BAD_REQUEST", "请提交有效的入房 JSON 对象")
		return false
	}
	object := json.NewDecoder(strings.NewReader(string(raw)))
	object.DisallowUnknownFields()
	if object.Decode(target) != nil || decoder.Decode(new(any)) != io.EOF {
		httpresponse.Error(w, 400, "BAD_REQUEST", "入房请求字段不正确")
		return false
	}
	return true
}
func (s *Server) roomError(w http.ResponseWriter, r *http.Request, err error) {
	if passwordError(w, err) {
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		httpresponse.Error(w, 404, "ROOM_NOT_FOUND", "房间不存在")
		return
	}
	if errors.Is(err, store.ErrAdmissionChanged) {
		httpresponse.Error(w, 409, "ADMISSION_CHANGED", "入房请求已过时或失效，请重新加入")
		return
	}
	s.internalError(w, r, err)
}
func (s *Server) join(w http.ResponseWriter, r *http.Request, m store.Member) {
	var request struct {
		Sequence int64  `json:"join_sequence"`
		Proof    string `json:"preflight_proof"`
	}
	if !readRoomJSON(w, r, &request) {
		return
	}
	if request.Sequence <= 0 {
		s.roomError(w, r, store.ErrAdmissionChanged)
		return
	}
	cfg, err := s.store.Room(r.Context(), r.PathValue("room"))
	if err != nil {
		s.roomError(w, r, err)
		return
	}
	logging.Annotate(r.Context(), "room_id", cfg.RoomID, "join_sequence", request.Sequence)
	revision, valid := s.preflightProofs.verify(request.Proof, m, cfg.RoomID, request.Sequence, time.Now())
	if !valid {
		httpresponse.Error(w, 403, "ROOM_PREFLIGHT_EXPIRED", "入房预校验已失效，请重新验证")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err = s.media.EnsureRoom(ctx, cfg.RoomID); err != nil {
		logging.Annotate(r.Context(), "stage", "media.ensure_room")
		s.mediaError(w, r, err)
		return
	}
	admission, err := s.store.JoinRoom(ctx, m, cfg.RoomID, request.Sequence, revision)
	if err != nil {
		s.roomError(w, r, err)
		return
	}
	token, expires, err := s.issuer.Issue(m, admission)
	if err != nil {
		if rollbackErr := s.store.LeaveRoom(ctx, m, cfg.RoomID, admission.EntryID); rollbackErr != nil {
			logging.Request(r, s.logger).Error("Room admission rollback failed", "event", "room.join_rollback_failed", "error", rollbackErr)
		}
		s.internalError(w, r, err)
		return
	}
	logging.Request(r, s.logger).Info("Room admission issued", "event", "room.joined", "entry_id", admission.EntryID)
	httpresponse.JSON(w, 200, struct {
		DisplayName string `json:"display_name"`
		store.RoomAdmission
		LiveKitURL string `json:"livekit_url"`
		Identity   string `json:"participant_identity"`
		Token      string `json:"token"`
		ExpiresAt  string `json:"expires_at"`
		Protocol   string `json:"key_protocol"`
		Transport  string `json:"media_transport"`
		E2EE       bool   `json:"e2ee_required"`
	}{cfg.DisplayName, admission, s.wsURL, admission.Identity(), token, expires.Format(time.RFC3339), group.Protocol, "udp", true})
}
func (s *Server) leave(w http.ResponseWriter, r *http.Request, m store.Member) {
	var request struct {
		EntryID string `json:"entry_id"`
	}
	if !readRoomJSON(w, r, &request) {
		return
	}
	if err := s.store.LeaveRoom(r.Context(), m, r.PathValue("room"), request.EntryID); err != nil {
		s.roomError(w, r, err)
		return
	}
	logging.Request(r, s.logger).Info("Room admission released", "event", "room.left", "room_id", r.PathValue("room"), "entry_id", request.EntryID)
	w.WriteHeader(http.StatusNoContent)
}

// A fresh SFU connection for a new MLS generation keeps the same admission.
// Only the group protocol can renew that admission.
func (s *Server) refreshMediaToken(w http.ResponseWriter, r *http.Request, m store.Member) {
	var request struct {
		EntryID string `json:"entry_id"`
	}
	if !readRoomJSON(w, r, &request) {
		return
	}
	admission := store.RoomAdmission{MemberID: m.ID, LoginID: m.LoginID, RoomID: r.PathValue("room"), EntryID: request.EntryID}
	identity := admission.Identity()
	allowed, err := s.store.AdmissionAllowed(r.Context(), admission.RoomID, identity)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	if !allowed {
		s.roomError(w, r, store.ErrAdmissionChanged)
		return
	}
	token, expires, err := s.issuer.Issue(m, admission)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, struct {
		RoomID   string `json:"room_id"`
		EntryID  string `json:"entry_id"`
		Identity string `json:"participant_identity"`
		Token    string `json:"token"`
		Expires  string `json:"expires_at"`
	}{admission.RoomID, admission.EntryID, identity, token, expires.Format(time.RFC3339)})
}

func (s *Server) internalError(w http.ResponseWriter, r *http.Request, err error) {
	logging.Request(r, s.logger).Error("API operation failed", "event", "api.operation_failed", "error", err)
	httpresponse.Error(w, 500, "INTERNAL_ERROR", "服务暂时出现错误")
}

func (s *Server) mediaError(w http.ResponseWriter, r *http.Request, err error) {
	logging.Request(r, s.logger).Warn("LiveKit management request failed", "event", "media.operation_failed", "error", err)
	httpresponse.Error(w, 503, "MEDIA_SERVICE_UNAVAILABLE", "语音服务暂时不可用")
}

func (s *Server) session(w http.ResponseWriter, r *http.Request, member store.Member) {
	httpresponse.JSON(w, 200, struct {
		Member              store.Member `json:"member"`
		ExpiresAt           int64        `json:"expires_at"`
		ParticipantIdentity string       `json:"participant_identity"`
		JoinSequence        int64        `json:"join_sequence"`
	}{member, member.CredentialExpiresAt, member.ParticipantIdentity(), member.JoinSequence})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request, member store.Member) {
	parts := strings.Fields(r.Header.Get("Authorization"))
	if err := s.store.RevokeClientCredential(r.Context(), parts[1]); err != nil {
		s.internalError(w, r, err)
		return
	}
	logging.Request(r, s.logger).Info("Client session revoked", "event", "auth.client_logout")
	w.WriteHeader(http.StatusNoContent)
}
