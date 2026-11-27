package passkeyhttp

import (
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/clienthttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
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
	capability := r.Header.Values("X-Chirp-Login-Resumption")
	options := store.IdentitySetupOptions{DeviceName: v.DeviceName, RequestResumption: len(capability) == 1 && capability[0] == "1"}
	login, err := s.db.CompleteIdentitySetup(r.Context(), v.Token, v.Verifier, s.setupOrigin(), v.Signature, client, v.Device, options)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeClientLogin(w, login)
}

func (s *Server) resumeChallenge(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var req struct {
		Token string `json:"resume_token"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	challenge, err := s.db.BeginClientResumption(r.Context(), req.Token, s.setupOrigin(), client)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, map[string]string{"challenge": challenge})
}

func (s *Server) resumeComplete(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var req struct {
		Token     string `json:"resume_token"`
		Signature string `json:"signature"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	login, err := s.db.CompleteClientResumption(r.Context(), req.Token, s.setupOrigin(), req.Signature, client)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeClientLogin(w, login)
}
