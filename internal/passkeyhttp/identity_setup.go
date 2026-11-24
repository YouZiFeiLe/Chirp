package passkeyhttp

import (
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/clienthttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"net/http"
)

type setupRequest struct {
	Token      string          `json:"setup_token"`
	Verifier   string          `json:"code_verifier"`
	Device     identity.Device `json:"device"`
	Signature  string          `json:"signature"`
	DeviceName string          `json:"device_name"`
}

func (s *Server) setupOrigin() string { return s.config.Origins[0] }
func (s *Server) identityChallenge(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var v setupRequest
	if !readJSON(w, r, &v) {
		return
	}
	challenge, err := s.db.BindIdentityChallenge(r.Context(), v.Token, v.Verifier, s.setupOrigin(), client, v.Device)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, map[string]string{"challenge": challenge})
}
func (s *Server) identityComplete(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var v setupRequest
	if !readJSON(w, r, &v) {
		return
	}
	login, err := s.db.CompleteIdentitySetup(r.Context(), v.Token, v.Verifier, s.setupOrigin(), v.Signature, client, v.Device, v.DeviceName)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeClientLogin(w, login)
}
