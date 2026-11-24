package httpapi

import (
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/clienthttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) clientConfig(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	identity, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	policy, err := s.store.CheckClientVersion(r.Context(), identity)
	if err != nil {
		if !clienthttp.WriteError(w, err) {
			httpresponse.Error(w, 503, "CLIENT_VERSION_POLICY_UNAVAILABLE", "客户端版本规则暂时不可用")
		}
		return
	}
	origin, err := config.PublicPasskeyOrigin(s.passkeyOrigin)
	if err != nil || s.clientEndpoints.Validate(origin) != nil {
		httpresponse.Error(w, http.StatusServiceUnavailable, "CLIENT_CONFIG_UNAVAILABLE", "认证服务地址尚未正确配置")
		return
	}
	registrationClosed, err := s.store.RegistrationClosed(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, struct {
		Service         string                    `json:"service"`
		ProtocolVersion int                       `json:"protocol_version"`
		PasskeyOrigin   string                    `json:"passkey_origin"`
		DefaultRoomID   string                    `json:"default_room_id"`
		Endpoints       config.ClientEndpoints    `json:"endpoints"`
		Capabilities    map[string]any            `json:"capabilities"`
		ClientPolicy    store.ClientVersionPolicy `json:"client_policy"`
	}{"chirp", 5, origin, store.DefaultRoomID, s.clientEndpoints, map[string]any{
		"registration": !registrationClosed, "device_login": true, "android_native_login": true, "dynamic_rooms": true, "state_events": true, "attachment_protocol": store.AttachmentProtocol,
		"max_members": 0, "max_room_participants": 0,
	}, policy})
}
