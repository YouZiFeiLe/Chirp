package passkeyhttp

import (
	"net/http"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/clienthttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

func (s *Server) pairingStart(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var v struct {
		Token    string                        `json:"setup_token"`
		Verifier string                        `json:"code_verifier"`
		Request  identity.DevicePairingRequest `json:"request"`
	}
	if !readJSON(w, r, &v) {
		return
	}
	state, err := s.db.BeginDevicePairing(r.Context(), v.Token, v.Verifier, s.setupOrigin(), client, v.Request)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, state)
}

func (s *Server) pairingAction(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var v identity.DevicePairingAction
	if !readJSON(w, r, &v) {
		return
	}
	state, err := s.db.ApplyDevicePairing(r.Context(), s.setupOrigin(), client, v)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, state)
}
