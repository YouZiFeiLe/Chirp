package adminhttp

import (
	"context"
	"errors"
	"net/http"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) adminCreateRoom(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Name string `json:"display_name"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	room, err := s.store.CreateRoom(r.Context(), request.Name)
	if err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	s.audit(r, "admin.room_created", "room_id", room.RoomID)
	httpresponse.JSON(w, http.StatusCreated, room)
}

func (s *Server) adminSetRoomDescription(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Description *string `json:"description"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	if request.Description == nil {
		httpresponse.Error(w, http.StatusBadRequest, "BAD_REQUEST", "请提交房间描述")
		return
	}
	cfg, err := s.store.SetRoomDescription(r.Context(), r.PathValue("room"), *request.Description)
	if err != nil {
		switch {
		case errors.Is(err, store.ErrNotFound):
			httpresponse.Error(w, http.StatusNotFound, "ROOM_NOT_FOUND", "房间不存在")
		case errors.Is(err, store.ErrInvalidRoomDescription):
			httpresponse.Error(w, http.StatusBadRequest, "INVALID_ROOM_DESCRIPTION", "房间描述最多 280 个字符，除换行外不能包含控制字符")
		default:
			s.internalError(w, r, err)
		}
		return
	}
	s.audit(r, "admin.room_description_updated", "room_id", cfg.RoomID)
	httpresponse.JSON(w, http.StatusOK, cfg)
}

func (s *Server) adminDeleteRoom(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("room")
	if err := s.store.DeleteRoom(r.Context(), id); err != nil {
		switch {
		case errors.Is(err, store.ErrDefaultRoom):
			httpresponse.Error(w, 409, "DEFAULT_ROOM_PROTECTED", "默认房间不能删除")
		case errors.Is(err, store.ErrNotFound):
			httpresponse.Error(w, 404, "ROOM_NOT_FOUND", "房间不存在")
		default:
			s.internalError(w, r, err)
		}
		return
	}
	s.audit(r, "admin.room_deleted", "room_id", id)
	// The database commit already revoked every admission. Request cancellation
	// must not skip cleanup; the continuous monitor also checks deleted IDs.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	groupErr := s.controlGroup(ctx, "end", id, "")
	mediaErr := s.media.EndRoom(ctx, id)
	if groupErr != nil || mediaErr != nil {
		logging.Request(r, s.logger).Warn("Room deleted; cleanup pending", "event", "admin.room_delete_pending", "room_id", id, "group_error", groupErr, "media_error", mediaErr)
		httpresponse.JSON(w, http.StatusAccepted, map[string]bool{"deleted": true, "cleanup_pending": true})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
