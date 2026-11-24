package adminhttp

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

//go:embed web/*
var adminFiles embed.FS

type Server struct {
	store        *store.Store
	media        room.AdminBackend
	wsURL        string
	logger       *slog.Logger
	groupControl group.Control
	directory    *room.Directory
}

func New(db *store.Store, media room.AdminBackend, wsURL string, logger *slog.Logger, controls ...group.Control) http.Handler {
	return NewWithDirectory(db, media, wsURL, logger, room.NewDirectory(media, nil, logger), controls...)
}

func NewWithDirectory(db *store.Store, media room.AdminBackend, wsURL string, logger *slog.Logger, directory *room.Directory, controls ...group.Control) http.Handler {
	s := &Server{store: db, media: media, wsURL: wsURL, logger: logger, directory: directory}
	if len(controls) > 0 {
		s.groupControl = controls[0]
	}
	mux := http.NewServeMux()
	assets, err := fs.Sub(adminFiles, "web")
	if err != nil {
		panic(err)
	}
	mux.Handle("/", http.NotFoundHandler())
	mux.HandleFunc("GET /admin/healthz", httpresponse.Health(db, "admin"))
	mux.HandleFunc("GET /admin/{$}", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFileFS(w, r, assets, "index.html")
	})
	pages := http.StripPrefix("/admin/assets/", http.FileServerFS(assets))
	for _, path := range []string{"/admin/assets/app.js", "/admin/assets/styles.css"} {
		mux.Handle("GET "+path, pages)
	}
	api := http.NewServeMux()
	api.HandleFunc("GET /admin/api/overview", s.adminOverview)
	api.HandleFunc("GET /admin/api/blacklist", s.adminBlacklist)
	api.HandleFunc("GET /admin/api/members/{id}/devices", s.adminDevices)
	api.HandleFunc("DELETE /admin/api/members/{id}/devices/{device}", s.adminRevokeDevice)
	api.HandleFunc("GET /admin/api/client-versions", s.adminClientVersions)
	api.HandleFunc("PUT /admin/api/client-versions/{platform}", s.adminUpdateClientVersion)
	api.HandleFunc("POST /admin/api/rooms", s.adminCreateRoom)
	api.HandleFunc("DELETE /admin/api/rooms/{room}", s.adminDeleteRoom)
	api.HandleFunc("PUT /admin/api/rooms/{room}", s.adminRenameRoom)
	api.HandleFunc("PUT /admin/api/rooms/{room}/description", s.adminSetRoomDescription)
	api.HandleFunc("PUT /admin/api/rooms/{room}/password", s.adminSetRoomPassword)
	api.HandleFunc("DELETE /admin/api/rooms/{room}/password", s.adminClearRoomPassword)
	api.HandleFunc("PUT /admin/api/members/{id}", s.adminUpdateMember)
	api.HandleFunc("DELETE /admin/api/members/{id}", s.adminDeleteMember)
	api.HandleFunc("POST /admin/api/members/{id}/revoke-login", s.adminRevokeLogin)
	api.HandleFunc("DELETE /admin/api/rooms/{room}/participants/{id}", s.adminRemoveParticipant)
	api.HandleFunc("POST /admin/api/rooms/{room}/end", s.adminEndRoom)
	api.HandleFunc("PUT /admin/api/registration-settings", s.adminUpdateRegistrationSettings)
	api.HandleFunc("POST /admin/api/registrations/{id}/approve", s.approveRegistration)
	api.HandleFunc("DELETE /admin/api/registrations/{id}", s.deleteRegistration)
	// Browser sessions and administrator roles are checked before every request.
	mux.Handle("/admin/api/", api)
	return adminHeaders(s.requireAdministrator(http.NewCrossOriginProtection().Handler(mux)))
}

func (s *Server) internalError(w http.ResponseWriter, r *http.Request, err error) {
	logging.Request(r, s.logger).Error("Admin operation failed", "event", "admin.operation_failed", "error", err)
	httpresponse.Error(w, http.StatusInternalServerError, "INTERNAL_ERROR", "服务暂时出现错误")
}

func adminHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) adminOverview(w http.ResponseWriter, r *http.Request) {
	members, err := s.store.ListMembers(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	registrations, err := s.store.ListRegistrationRequests(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	registrationClosed, err := s.store.RegistrationClosed(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rooms, err := s.directory.Rooms(ctx, s.store, group.Protocol)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	participants := []room.Participant{}
	mediaStatus := "available"
	for _, r := range rooms {
		if r.MediaStatus != "available" {
			mediaStatus = "unavailable"
		}
		participants = append(participants, r.Participants...)
	}

	engine, err := s.store.Engine(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	type adminMember struct {
		store.Member
		ParticipantIdentity string `json:"participant_identity,omitempty"`
		LoginActive         bool   `json:"login_active"`
	}
	memberStates := make([]adminMember, 0, len(members))
	for _, member := range members {
		state := adminMember{Member: member, LoginActive: member.Enabled && member.LoginID != "" && member.CredentialExpiresAt > time.Now().Unix()}
		if state.LoginActive {
			state.ParticipantIdentity = member.ParticipantIdentity()
		}
		memberStates = append(memberStates, state)
	}
	httpresponse.JSON(w, http.StatusOK, struct {
		Members            []adminMember               `json:"members"`
		Rooms              []room.Overview             `json:"rooms"`
		MaxMembers         int                         `json:"max_members"`
		Participants       []room.Participant          `json:"participants"`
		MediaStatus        string                      `json:"media_status"`
		SQLiteVersion      string                      `json:"sqlite_version"`
		LiveKitURL         string                      `json:"livekit_url"`
		MediaTransport     string                      `json:"media_transport"`
		E2EERequired       bool                        `json:"e2ee_required"`
		Registrations      []store.RegistrationRequest `json:"registrations"`
		RegistrationClosed bool                        `json:"registration_closed"`
	}{memberStates, rooms, 0, participants, mediaStatus, engine.Version, s.wsURL, "udp", true, registrations, registrationClosed})
}

func (s *Server) adminUpdateRegistrationSettings(w http.ResponseWriter, r *http.Request) {
	var request struct {
		RegistrationClosed *bool `json:"registration_closed"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	if request.RegistrationClosed == nil {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "请指定注册开关状态")
		return
	}
	if err := s.store.SetRegistrationClosed(r.Context(), *request.RegistrationClosed); err != nil {
		s.internalError(w, r, err)
		return
	}
	s.audit(r, "admin.registration_settings_updated", "registration_closed", *request.RegistrationClosed)
	httpresponse.JSON(w, http.StatusOK, request)
}

func (s *Server) approveRegistration(w http.ResponseWriter, r *http.Request) {
	if !readAdminJSON(w, r, &struct{}{}) {
		return
	}
	member, err := s.store.ApproveRegistration(r.Context(), r.PathValue("id"))
	if err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	s.audit(r, "admin.registration_approved", "target_member_id", member.ID)
	httpresponse.JSON(w, http.StatusOK, member)
}

func (s *Server) deleteRegistration(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteRegistration(r.Context(), r.PathValue("id")); err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	s.audit(r, "admin.registration_deleted")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminRenameRoom(w http.ResponseWriter, r *http.Request) {
	var request struct {
		DisplayName string `json:"display_name"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	cfg, err := s.store.RenameRoom(r.Context(), r.PathValue("room"), request.DisplayName)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			httpresponse.Error(w, 404, "ROOM_NOT_FOUND", "房间不存在")
			return
		}
		if errors.Is(err, store.ErrInvalidName) {
			httpresponse.Error(w, http.StatusBadRequest, "INVALID_NAME", "房间名称须为 1–80 个字符，且不含控制字符")
			return
		}
		s.internalError(w, r, err)
		return
	}
	s.audit(r, "admin.room_renamed", "room_id", cfg.RoomID)
	httpresponse.JSON(w, http.StatusOK, cfg)
}

func (s *Server) adminUpdateMember(w http.ResponseWriter, r *http.Request) {
	var request struct {
		DisplayName string `json:"display_name"`
		Enabled     *bool  `json:"enabled"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	if request.Enabled == nil {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "请指定成员启用状态")
		return
	}
	member, err := s.store.UpdateMember(r.Context(), r.PathValue("id"), request.DisplayName, *request.Enabled)
	if err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	s.audit(r, "admin.member_updated", "target_member_id", member.ID, "enabled", member.Enabled)
	httpresponse.JSON(w, http.StatusOK, member)
}

func (s *Server) adminDeleteMember(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteMember(r.Context(), r.PathValue("id")); err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	s.audit(r, "admin.member_deleted", "target_member_id", r.PathValue("id"))
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminRevokeLogin(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Identity string `json:"participant_identity"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	memberID, loginID, found := strings.Cut(request.Identity, ".")
	if !found || strings.Contains(loginID, ".") || memberID != r.PathValue("id") || !strings.HasPrefix(loginID, "login_") || len(loginID) <= len("login_") || len(loginID) > 64 {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "请指定此成员的准确登录标识，刷新后重试")
		return
	}
	s.removeLogin(w, r, request.Identity)
}

func (s *Server) adminRemoveParticipant(w http.ResponseWriter, r *http.Request) {
	roomID, identity := r.PathValue("room"), r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.store.RemoveAdmission(ctx, roomID, identity); err != nil {
		logging.Request(r, s.logger).Warn("Remove admission failed", "event", "admin.remove_admission_failed", "room_id", roomID, "error", err)
		httpresponse.Error(w, 400, "BAD_REQUEST", "无效的房间或入房身份")
		return
	}
	s.audit(r, "admin.admission_revoked", "room_id", roomID, "participant_id", identity)
	groupErr := s.controlGroup(ctx, "remove", roomID, identity)
	mediaErr := s.media.RemoveParticipant(ctx, roomID, identity)
	if groupErr != nil || mediaErr != nil {
		logging.Request(r, s.logger).Warn("Admission revoked but cleanup incomplete", "event", "admin.admission_cleanup_pending", "room_id", roomID, "participant_id", identity, "group_error", groupErr, "media_error", mediaErr)
		httpresponse.Error(w, 503, "ADMISSION_REVOKED_CLEANUP_PENDING", "本次入房已撤销，连接清理暂未完成；请刷新状态。账号仍保持登录。")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) removeLogin(w http.ResponseWriter, r *http.Request, identity string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.store.RevokeParticipant(ctx, identity); err != nil {
		s.internalError(w, r, err)
		return
	}
	s.audit(r, "admin.login_revoked", "participant_id", identity)
	cleanupErr := s.controlGroup(ctx, "remove", "", identity)
	ids, err := s.store.AllRoomIDs(ctx)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	for _, roomID := range ids {
		participants, err := s.media.Participants(ctx, roomID)
		if err != nil {
			cleanupErr = err
			continue
		}
		for _, p := range participants {
			if strings.HasPrefix(p.ID, identity+".") {
				if err := s.media.RemoveParticipant(ctx, roomID, p.ID); err != nil {
					cleanupErr = err
				}
			}
		}
	}
	if cleanupErr != nil {
		logging.Request(r, s.logger).Warn("Login revoked but room cleanup incomplete", "event", "admin.login_cleanup_pending", "participant_id", identity, "error", cleanupErr)
		httpresponse.Error(w, 503, "LOGIN_REVOKED_CLEANUP_PENDING", "此登录已撤销；部分房间连接清理暂未完成，请刷新状态。服务恢复后会继续清理。")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
func (s *Server) adminEndRoom(w http.ResponseWriter, r *http.Request) {
	if !readAdminJSON(w, r, &struct{}{}) {
		return
	}
	roomID := r.PathValue("room")
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.store.EndRoom(ctx, roomID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			httpresponse.Error(w, 404, "ROOM_NOT_FOUND", "房间不存在")
		} else {
			s.internalError(w, r, err)
		}
		return
	}
	s.audit(r, "admin.room_ended", "room_id", roomID)
	groupErr := s.controlGroup(ctx, "end", roomID, "")
	mediaErr := s.media.EndRoom(ctx, roomID)
	if groupErr != nil || mediaErr != nil {
		logging.Request(r, s.logger).Warn("Room admissions revoked but end incomplete", "event", "admin.room_end_pending", "room_id", roomID, "group_error", groupErr, "media_error", mediaErr)
		httpresponse.Error(w, 503, "ROOM_END_INCOMPLETE", "此房间入房授权已撤销，但安全群组或媒体连接清理未全部完成，请刷新后重试。")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func readAdminJSON(w http.ResponseWriter, r *http.Request, target any) bool {
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || contentType != "application/json" {
		httpresponse.Error(w, http.StatusUnsupportedMediaType, "JSON_REQUIRED", "请使用 application/json 提交")
		return false
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil || len(raw) == 0 || raw[0] != '{' {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "请提交有效的 JSON 对象")
		return false
	}
	object := json.NewDecoder(bytes.NewReader(raw))
	object.DisallowUnknownFields()
	if err := object.Decode(target); err != nil {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "请求字段不正确")
		return false
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "只允许一个 JSON 请求对象")
		return false
	}
	return true
}

func (s *Server) adminStoreError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, store.ErrBlacklisted):
		httpresponse.Error(w, 403, "IDENTITY_BLACKLISTED", "身份已被永久撤销，不能重新启用")
	case errors.Is(err, store.ErrLastAdministrator):
		httpresponse.Error(w, http.StatusConflict, "LAST_ADMINISTRATOR", "请先通过本机 CLI 指定另一位管理员")
	case errors.Is(err, store.ErrNotFound):
		httpresponse.Error(w, http.StatusNotFound, "MEMBER_NOT_FOUND", "成员不存在，请刷新列表")
	case errors.Is(err, store.ErrInvalidName):
		httpresponse.Error(w, http.StatusBadRequest, "INVALID_NAME", "昵称须为 1–80 个字符，且不含控制字符")
	case errors.Is(err, store.ErrAlreadyApproved):
		httpresponse.Error(w, http.StatusConflict, "ALREADY_APPROVED", "该申请已通过，请在成员管理中维护或删除账号")
	default:
		s.internalError(w, r, err)
	}
}

func (s *Server) controlGroup(ctx context.Context, operation, roomID, identity string) error {
	if s.groupControl == nil {
		return nil
	}
	return s.groupControl.Send(ctx, operation, roomID, identity)
}

func (s *Server) audit(r *http.Request, event string, attrs ...any) {
	logging.Request(r, s.logger).Info("Administrator operation committed", append([]any{"event", event}, attrs...)...)
}
