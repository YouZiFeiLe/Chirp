package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) getRoomPolicy(w http.ResponseWriter, r *http.Request, _ store.Member) {
	if _, err := s.store.Room(r.Context(), r.PathValue("room")); err != nil {
		s.roomError(w, r, err)
		return
	}
	policy, err := s.store.RoomPolicy(r.Context(), r.PathValue("room"))
	if errors.Is(err, store.ErrRoomPolicy) {
		httpresponse.Error(w, 409, "ROOM_IDENTITY_REQUIRED", "此房间尚未建立有效的客户端签名授权，请核验房间邀请")
		return
	}
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, policy)
}

func (s *Server) getRoomPolicyHistory(w http.ResponseWriter, r *http.Request, _ store.Member) {
	if _, err := s.store.Room(r.Context(), r.PathValue("room")); err != nil {
		s.roomError(w, r, err)
		return
	}
	after, err := strconv.ParseInt(r.PathValue("after"), 10, 64)
	if err != nil || after < 0 {
		httpresponse.Error(w, 400, "BAD_REQUEST", "授权版本无效")
		return
	}
	policies, err := s.store.RoomPolicyHistory(r.Context(), r.PathValue("room"), after)
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, policies)
}

func (s *Server) putRoomPolicy(w http.ResponseWriter, r *http.Request, member store.Member) {
	if _, err := s.store.Room(r.Context(), r.PathValue("room")); err != nil {
		s.roomError(w, r, err)
		return
	}
	var policy identity.RoomPolicy
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&policy) != nil || decoder.Decode(new(any)) != io.EOF || policy.RoomID != r.PathValue("room") {
		httpresponse.Error(w, 400, "BAD_REQUEST", "房间授权文档无效")
		return
	}
	err := s.store.PutRoomPolicy(r.Context(), member, policy)
	if errors.Is(err, store.ErrRoomPolicy) || errors.Is(err, store.ErrDeviceIdentity) {
		httpresponse.Error(w, 403, "ROOM_AUTHORIZATION_INVALID", "房间授权签名、身份或版本无效")
		return
	}
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, policy)
}
