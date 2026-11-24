package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) identityError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, store.ErrBlacklisted):
		httpresponse.Error(w, 403, "IDENTITY_BLACKLISTED", "此身份已被永久撤销")
	case errors.Is(err, store.ErrCurrentDevice):
		httpresponse.Error(w, 409, "CURRENT_DEVICE", "不能撤销当前设备")
	case errors.Is(err, store.ErrLastDevice):
		httpresponse.Error(w, 409, "LAST_DEVICE", "必须至少保留一台有效设备")
	case errors.Is(err, store.ErrRevocationUnavailable):
		httpresponse.Error(w, 503, "UNAVAILABLE", "暂时无法核验设备撤销记录")
	case errors.Is(err, store.ErrSocialConflict):
		httpresponse.Error(w, 409, "SOCIAL_CONFLICT", "请同步最新好友状态后重试")
	case errors.Is(err, store.ErrDeviceIdentity):
		httpresponse.Error(w, 403, "DEVICE_IDENTITY_REQUIRED", "设备签名或资格无效")
	case errors.Is(err, store.ErrNotFound):
		httpresponse.Error(w, 404, "NOT_FOUND", "未找到设备")
	case errors.Is(err, store.ErrInvalidName):
		httpresponse.Error(w, 400, "BAD_REQUEST", "设备名称无效")
	default:
		s.internalError(w, r, err)
	}
}
func readIdentityJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(new(any)) != io.EOF {
		httpresponse.Error(w, 400, "BAD_REQUEST", "身份文档无效")
		return false
	}
	return true
}
func (s *Server) getDevices(w http.ResponseWriter, r *http.Request, m store.Member) {
	v, err := s.store.Devices(r.Context(), m.ID)
	if err != nil {
		s.identityError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, v)
}
func (s *Server) renameDevice(w http.ResponseWriter, r *http.Request, m store.Member) {
	var v struct {
		Name string `json:"name"`
	}
	if !readIdentityJSON(w, r, &v) {
		return
	}
	if err := s.store.RenameDevice(r.Context(), m, decodeDevicePath(r.PathValue("device")), v.Name); err != nil {
		s.identityError(w, r, err)
		return
	}
	w.WriteHeader(204)
}
func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request, m store.Member) {
	if err := s.store.RevokeDevice(r.Context(), m, decodeDevicePath(r.PathValue("device")), s.deviceRevoked); err != nil {
		s.identityError(w, r, err)
		return
	}
	w.WriteHeader(204)
}
func (s *Server) getBlacklist(w http.ResponseWriter, r *http.Request, _ store.Member) {
	v, err := s.store.Blacklist(r.Context())
	if err != nil {
		s.identityError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, v)
}
func identityAfter(w http.ResponseWriter, r *http.Request) (int64, bool) {
	n, err := strconv.ParseInt(r.PathValue("after"), 10, 64)
	if err != nil || n < 0 {
		httpresponse.Error(w, 400, "BAD_REQUEST", "版本无效")
		return 0, false
	}
	return n, true
}
func (s *Server) getSocial(w http.ResponseWriter, r *http.Request, m store.Member) {
	n, ok := identityAfter(w, r)
	if !ok {
		return
	}
	v, err := s.store.SocialEvents(r.Context(), m, n)
	if err != nil {
		s.identityError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, v)
}
func (s *Server) putSocial(w http.ResponseWriter, r *http.Request, m store.Member) {
	var v identity.SocialEvent
	if !readIdentityJSON(w, r, &v) {
		return
	}
	if origin, err := identity.NormalizeOrigin(s.passkeyOrigin); err != nil || v.Origin != origin {
		s.identityError(w, r, store.ErrDeviceIdentity)
		return
	}
	if err := s.store.AppendSocialEvent(r.Context(), m, v); err != nil {
		s.identityError(w, r, err)
		return
	}
	w.WriteHeader(204)
}
func (s *Server) sendIdentitySignal(w http.ResponseWriter, r *http.Request, m store.Member) {
	var v identity.Signal
	if !readIdentityJSON(w, r, &v) {
		return
	}
	if origin, err := identity.NormalizeOrigin(s.passkeyOrigin); err != nil || v.Origin != origin {
		s.identityError(w, r, store.ErrDeviceIdentity)
		return
	}
	if err := s.store.SendIdentitySignal(r.Context(), m, v); err != nil {
		s.identityError(w, r, err)
		return
	}
	w.WriteHeader(204)
}
func (s *Server) getIdentitySignals(w http.ResponseWriter, r *http.Request, m store.Member) {
	n, ok := identityAfter(w, r)
	if !ok {
		return
	}
	v, err := s.store.IdentitySignals(r.Context(), m, n)
	if err != nil {
		s.identityError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, v)
}

func decodeDevicePath(value string) string {
	b, e := base64.RawURLEncoding.DecodeString(value)
	if e == nil && len(b) == 32 {
		return base64.StdEncoding.EncodeToString(b)
	}
	return strings.TrimSpace(value)
}
