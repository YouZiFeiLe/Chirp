// Package clienthttp shares version metadata and rejection responses between
// public discovery and the independent Passkey login service.
package clienthttp

import (
	"errors"
	"net/http"
	"strconv"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func Identity(r *http.Request) (store.ClientIdentity, error) {
	for _, key := range []string{"X-Chirp-Platform", "X-Chirp-Version", "X-Chirp-Build"} {
		if len(r.Header.Values(key)) != 1 {
			return store.ClientIdentity{}, store.ErrInvalidClientVersion
		}
	}
	raw := r.Header.Get("X-Chirp-Build")
	build, err := strconv.Atoi(raw)
	c := store.ClientIdentity{Platform: r.Header.Get("X-Chirp-Platform"), Version: r.Header.Get("X-Chirp-Version"), Build: build}
	if err != nil || strconv.Itoa(build) != raw || !c.Valid() {
		return c, store.ErrInvalidClientVersion
	}
	return c, nil
}

// WriteError returns false only for operational errors owned by the service.
func WriteError(w http.ResponseWriter, err error) bool {
	var update *store.ClientUpdateRequired
	if errors.As(err, &update) {
		httpresponse.JSON(w, http.StatusForbidden, struct {
			Error  map[string]string         `json:"error"`
			Policy store.ClientVersionPolicy `json:"client_policy"`
		}{map[string]string{"code": "CLIENT_UPDATE_REQUIRED", "message": "客户端版本过旧，请升级后重试"}, update.Policy})
		return true
	}
	if errors.Is(err, store.ErrInvalidClientVersion) {
		httpresponse.Error(w, http.StatusBadRequest, "CLIENT_VERSION_INVALID", "请使用具有有效版本信息的客户端")
		return true
	}
	if errors.Is(err, store.ErrClientPolicyUnavailable) {
		httpresponse.Error(w, http.StatusServiceUnavailable, "CLIENT_VERSION_POLICY_UNAVAILABLE", "客户端版本规则暂时不可用，请稍后重试")
		return true
	}
	return false
}
