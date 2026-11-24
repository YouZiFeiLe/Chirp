package adminhttp

import (
	"errors"
	"net/http"
	"net/url"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/browserauth"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func (s *Server) requireAdministrator(next http.Handler) http.Handler {
	origin, _ := url.Parse(s.wsURL)
	if origin.Scheme == "wss" {
		origin.Scheme = "https"
	} else {
		origin.Scheme = "http"
	}
	origin.Path, origin.RawQuery, origin.Fragment = "", "", ""
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(browserauth.SessionCookie)
		if err != nil || len(cookie.Value) != 43 {
			s.loginRequired(w, r)
			return
		}
		member, _, err := s.store.PasskeySession(r.Context(), cookie.Value)
		if errors.Is(err, store.ErrNotFound) || (err == nil && !member.Enabled) {
			s.loginRequired(w, r)
			return
		}
		if err != nil {
			logging.Request(r, s.logger).Error("Administrator session lookup failed", "event", "admin.session_failed", "error", err)
			httpresponse.Error(w, 503, "UNAVAILABLE", "暂时无法验证管理员身份")
			return
		}
		logging.Annotate(r.Context(), "actor_id", member.ID)
		if !member.IsAdmin {
			httpresponse.Error(w, 403, "ADMIN_REQUIRED", "此账号没有管理员权限")
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Header.Get("Origin") != origin.String() {
			httpresponse.Error(w, 403, "ORIGIN_NOT_ALLOWED", "请从 Chirp 管理台操作")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) loginRequired(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet && r.URL.Path == "/admin/" {
		http.Redirect(w, r, "/?admin=1", http.StatusSeeOther)
		return
	}
	httpresponse.Error(w, 401, "ADMIN_LOGIN_REQUIRED", "请使用管理员通行密钥登录")
}
