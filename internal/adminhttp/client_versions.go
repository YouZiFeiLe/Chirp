package adminhttp

import (
	"errors"
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) adminClientVersions(w http.ResponseWriter, r *http.Request) {
	policies, err := s.store.ClientVersionPolicies(r.Context())
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, map[string]any{"platforms": policies})
}

func (s *Server) adminUpdateClientVersion(w http.ResponseWriter, r *http.Request) {
	var request struct {
		LatestVersion  string `json:"latest_version"`
		LatestBuild    int    `json:"latest_build"`
		MinimumVersion string `json:"minimum_version"`
		MinimumBuild   int    `json:"minimum_build"`
	}
	if !readAdminJSON(w, r, &request) {
		return
	}
	p, err := s.store.UpdateClientVersionPolicy(r.Context(), store.ClientVersionPolicy{
		Platform: r.PathValue("platform"), LatestVersion: request.LatestVersion, LatestBuild: request.LatestBuild, MinimumVersion: request.MinimumVersion, MinimumBuild: request.MinimumBuild})
	if errors.Is(err, store.ErrInvalidClientPolicy) {
		httpresponse.Error(w, http.StatusBadRequest, "INVALID_CLIENT_POLICY", "请填写有效的平台、最新与最低支持版本及构建号，最低支持版本和构建组合不得高于最新版本和构建组合")
		return
	}
	if err != nil {
		s.internalError(w, r, err)
		return
	}
	s.audit(r, "admin.client_policy_updated", "platform", p.Platform, "minimum_version", p.MinimumVersion, "latest_version", p.LatestVersion)
	httpresponse.JSON(w, http.StatusOK, p)
}
