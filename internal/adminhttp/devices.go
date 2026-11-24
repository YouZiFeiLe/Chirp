package adminhttp

import (
	"encoding/base64"
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
)

func (s *Server) adminDevices(w http.ResponseWriter, r *http.Request) {
	devices, err := s.store.Devices(r.Context(), r.PathValue("id"))
	if err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, devices)
}
func (s *Server) adminRevokeDevice(w http.ResponseWriter, r *http.Request) {
	devices, err := s.store.Devices(r.Context(), r.PathValue("id"))
	if err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	key := r.PathValue("device")
	if decoded, e := base64.RawURLEncoding.DecodeString(key); e == nil && len(decoded) == 32 {
		key = base64.StdEncoding.EncodeToString(decoded)
	}
	found := false
	for _, d := range devices {
		if d.DeviceKey == key {
			found = true
		}
	}
	if !found {
		httpresponse.Error(w, 404, "NOT_FOUND", "未找到设备")
		return
	}
	if err = s.store.AdminRevokeDevice(r.Context(), key); err != nil {
		s.adminStoreError(w, r, err)
		return
	}
	// Group and media monitors reconcile the exact invalidated login. Revoking
	// an offline issuer must not remove a still-valid online descendant.
	s.audit(r, "admin.device_revoked", "target_member_id", r.PathValue("id"))
	w.WriteHeader(204)
}
func (s *Server) adminBlacklist(w http.ResponseWriter, r *http.Request) {
	v, err := s.store.Blacklist(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, v)
}
