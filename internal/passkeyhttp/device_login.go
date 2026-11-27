package passkeyhttp

import (
	"errors"
	"net/http"
	"net/url"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/clienthttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func nativeClientEndpoint(path string) bool {
	switch path {
	case "/api/client/resume/challenge", "/api/client/resume/complete":
		return true
	case "/api/client/exchange", "/api/client/device/start", "/api/client/device/poll", "/api/client/device/cancel", "/api/client/identity/challenge", "/api/client/identity/complete", "/api/client/identity/pairing/start", "/api/client/identity/pairing/action":
		return true
	default:
		return false
	}
}

func (s *Server) deviceStart(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	if _, err = s.db.CheckClientVersion(r.Context(), client); err != nil {
		s.fail(w, r, err)
		return
	}
	var request struct {
		ClientID            string `json:"client_id"`
		CodeChallenge       string `json:"code_challenge"`
		CodeChallengeMethod string `json:"code_challenge_method"`
	}
	if !readJSON(w, r, &request) {
		return
	}
	clientID := store.ClientID
	switch client.Platform {
	case store.WindowsClientPlatform:
		clientID = store.WindowsClientID
	case store.AndroidClientPlatform:
		clientID = store.AndroidClientID
	}
	if request.ClientID != clientID || request.CodeChallengeMethod != "S256" {
		s.fail(w, r, store.ErrInvalidDeviceAuthorization)
		return
	}
	device, err := s.db.BeginDeviceAuthorization(r.Context(), request.CodeChallenge, clientID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	uri := s.config.DeviceVerificationURL + "?" + url.Values{"request": {device.RequestID}}.Encode()
	logging.Request(r, s.logger).Info("Device login started", "event", "auth.device_started", "platform", client.Platform)
	httpresponse.JSON(w, http.StatusCreated, struct {
		store.DeviceAuthorization
		VerificationURI string `json:"verification_uri"`
		Interval        int    `json:"interval"`
	}{device, uri, 2})
}

type deviceProof struct {
	RequestID string `json:"request_id"`
	Verifier  string `json:"code_verifier"`
}

func (s *Server) devicePoll(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var proof deviceProof
	if !readJSON(w, r, &proof) {
		return
	}
	clientID := store.ClientID
	switch client.Platform {
	case store.WindowsClientPlatform:
		clientID = store.WindowsClientID
	case store.AndroidClientPlatform:
		clientID = store.AndroidClientID
	}
	setup, err := s.db.BeginIdentitySetup(r.Context(), proof.RequestID, proof.Verifier, clientID, s.setupOrigin(), client, true)
	if errors.Is(err, store.ErrDeviceAuthorizationPending) {
		httpresponse.JSON(w, http.StatusAccepted, map[string]string{"status": "pending"})
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, setup)
}

func (s *Server) deviceCancel(w http.ResponseWriter, r *http.Request) {
	var proof deviceProof
	if !readJSON(w, r, &proof) {
		return
	}
	if err := s.db.CancelDeviceAuthorization(r.Context(), proof.RequestID, proof.Verifier); err != nil {
		s.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
	logging.Request(r, s.logger).Info("Device login cancelled", "event", "auth.device_cancelled")
}

func writeClientLogin(w http.ResponseWriter, login store.ClientLogin) {
	httpresponse.JSON(w, http.StatusOK, struct {
		store.ClientLogin
		ParticipantIdentity string `json:"participant_identity"`
	}{login, login.Member.ParticipantIdentity()})
}
