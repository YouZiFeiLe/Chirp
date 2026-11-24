package adminhttp

import (
	"errors"
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) adminSetRoomPassword(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Password string `json:"password"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	cfg, err := s.store.SetRoomPassword(r.Context(), r.PathValue("room"), request.Password)
	request.Password = ""
	if err != nil {
		s.roomPasswordError(w, r, err)
		return
	}
	s.audit(r, "admin.room_password_set", "room_id", cfg.RoomID)
	httpresponse.JSON(w, 200, cfg)
}
func (s *Server) adminClearRoomPassword(w http.ResponseWriter, r *http.Request) {
	cfg, err := s.store.ClearRoomPassword(r.Context(), r.PathValue("room"))
	if err != nil {
		s.roomPasswordError(w, r, err)
		return
	}
	s.audit(r, "admin.room_password_cleared", "room_id", cfg.RoomID)
	httpresponse.JSON(w, 200, cfg)
}
func (s *Server) roomPasswordError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		httpresponse.Error(w, 404, "ROOM_NOT_FOUND", "房间不存在")
	case errors.Is(err, store.ErrInvalidRoomPassword):
		httpresponse.Error(w, 400, "INVALID_ROOM_PASSWORD", "房间密码须为 8–128 个字符，且不含控制字符；首尾空格参与匹配")
	case errors.Is(err, store.ErrPasswordBusy):
		w.Header().Set("Retry-After", "1")
		httpresponse.Error(w, 429, "ROOM_PASSWORD_BUSY", "密码设置繁忙，请稍后再试")
	default:
		s.internalError(w, r, err)
	}
}
