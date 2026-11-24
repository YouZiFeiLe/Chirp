package passkeyhttp

import (
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"slices"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/browserauth"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/clienthttp"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/config"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/httpresponse"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/logging"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/webui"
)

//go:embed web/*
var files embed.FS

const ceremonyCookie = "chirp_passkey_ceremony"
const sessionCookie = browserauth.SessionCookie
const ceremonyTTL = 5 * time.Minute
const sessionTTL = 8 * time.Hour

type Server struct {
	db     *store.Store
	auth   *webauthn.WebAuthn
	config config.PasskeyConfig
	logger *slog.Logger
}

type user struct {
	ID          string
	Nickname    string
	Credentials []webauthn.Credential
}

func (u user) WebAuthnID() []byte                         { return []byte(u.ID) }
func (u user) WebAuthnName() string                       { return u.Nickname }
func (u user) WebAuthnDisplayName() string                { return u.Nickname }
func (u user) WebAuthnCredentials() []webauthn.Credential { return u.Credentials }

type ceremony struct {
	Session       webauthn.SessionData
	User          user
	Client        *store.ClientAuthorization
	DeviceRequest string
}

func New(db *store.Store, cfg config.PasskeyConfig, logger *slog.Logger) (http.Handler, error) {
	if cfg.DeviceVerificationURL == "" && len(cfg.Origins) > 0 {
		cfg.DeviceVerificationURL = cfg.Origins[0] + "/device"
	}

	auth, err := webauthn.New(&webauthn.Config{
		RPID: cfg.RPID, RPDisplayName: "Chirp", RPOrigins: cfg.Origins,
		AttestationPreference:  protocol.PreferNoAttestation,
		AuthenticatorSelection: protocol.AuthenticatorSelection{ResidentKey: protocol.ResidentKeyRequirementRequired, UserVerification: protocol.VerificationRequired},
	})
	if err != nil {
		return nil, err
	}
	s := &Server{db: db, auth: auth, config: cfg, logger: logger}
	assets, err := fs.Sub(files, "web")
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) { http.ServeFileFS(w, r, assets, "index.html") })
	mux.HandleFunc("GET /register", func(w http.ResponseWriter, r *http.Request) { http.ServeFileFS(w, r, assets, "register.html") })
	mux.HandleFunc("GET /device", func(w http.ResponseWriter, r *http.Request) { http.ServeFileFS(w, r, assets, "device.html") })
	webui.RegisterAssets(mux)
	for _, path := range []string{"app.js", "native-login.js", "styles.css"} {
		mux.Handle("GET /assets/"+path, http.StripPrefix("/assets/", http.FileServerFS(assets)))
	}
	mux.HandleFunc("GET /healthz", httpresponse.Health(db, "passkey"))
	mux.HandleFunc("POST /api/auth/register/begin", s.registerBegin)
	mux.HandleFunc("POST /api/auth/register/finish", s.registerFinish)
	mux.HandleFunc("POST /api/auth/login/begin", s.loginBegin)
	mux.HandleFunc("POST /api/auth/login/finish", s.loginFinish)
	mux.HandleFunc("POST /api/auth/login/windows-handoff", s.windowsLoginHandoff)
	mux.HandleFunc("GET /api/session", s.session)
	mux.HandleFunc("POST /api/client/exchange", s.clientExchange)
	mux.HandleFunc("POST /api/client/identity/challenge", s.identityChallenge)
	mux.HandleFunc("POST /api/client/identity/complete", s.identityComplete)
	mux.HandleFunc("POST /api/client/identity/pairing/start", s.pairingStart)
	mux.HandleFunc("POST /api/client/identity/pairing/action", s.pairingAction)
	mux.HandleFunc("POST /api/client/device/start", s.deviceStart)
	mux.HandleFunc("POST /api/client/device/poll", s.devicePoll)
	mux.HandleFunc("POST /api/client/device/cancel", s.deviceCancel)
	mux.HandleFunc("POST /api/auth/logout", s.logout)
	protected := http.NewCrossOriginProtection().Handler(mux)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
		if r.Method == http.MethodPost {
			if !slices.Contains(cfg.Origins, r.Header.Get("Origin")) && !(nativeClientEndpoint(r.URL.Path) && r.Header.Get("Origin") == "") {
				httpresponse.Error(w, 403, "ORIGIN_NOT_ALLOWED", "请从登记的 Passkey 网页入口操作")
				return
			}
			contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil || contentType != "application/json" {
				httpresponse.Error(w, 415, "JSON_REQUIRED", "请使用 JSON 提交")
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
		}
		protected.ServeHTTP(w, r)
	}), nil
}

func readJSON(w http.ResponseWriter, r *http.Request, target any) bool {
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		httpresponse.Error(w, 400, "BAD_REQUEST", "请提交有效的登记信息")
		return false
	}
	if err := d.Decode(new(any)); err != io.EOF {
		httpresponse.Error(w, 400, "BAD_REQUEST", "只允许一个 JSON 对象")
		return false
	}
	return true
}

func cookieValue(r *http.Request, name string) string {
	cookie, err := r.Cookie(name)
	if err != nil || len(cookie.Value) != 43 {
		return ""
	}
	return cookie.Value
}

func randomToken() (string, error) {
	var data [32]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data[:]), nil
}

func (s *Server) cookie(w http.ResponseWriter, name, value string, ttl time.Duration) {
	path := "/"
	if name == ceremonyCookie {
		path = "/api/auth"
	}
	maxAge := int(ttl.Seconds())
	if ttl < 0 {
		maxAge = -1
	}
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: path, HttpOnly: true, Secure: s.config.SecureCookies, SameSite: http.SameSiteStrictMode, MaxAge: maxAge})
}

func (s *Server) saveCeremony(w http.ResponseWriter, r *http.Request, kind string, value ceremony) bool {
	payload, err := json.Marshal(value)
	if err != nil {
		s.fail(w, r, err)
		return false
	}
	token, err := randomToken()
	if err == nil {
		err = s.db.SavePasskeyCeremony(r.Context(), token, cookieValue(r, ceremonyCookie), kind, payload, time.Now().Add(ceremonyTTL))
	}
	if err != nil {
		s.fail(w, r, err)
		return false
	}
	s.cookie(w, ceremonyCookie, token, ceremonyTTL)
	return true
}

func (s *Server) consumeCeremony(w http.ResponseWriter, r *http.Request, kind string) (ceremony, bool) {
	var result ceremony
	token := cookieValue(r, ceremonyCookie)
	s.cookie(w, ceremonyCookie, "", -time.Second)
	payload, err := s.db.ConsumePasskeyCeremony(r.Context(), token, kind)
	if errors.Is(err, store.ErrNotFound) {
		httpresponse.Error(w, 400, "CEREMONY_EXPIRED", "本次操作已失效，请重新开始")
		return result, false
	}
	if err != nil {
		s.fail(w, r, err)
		return result, false
	}
	if err = json.Unmarshal(payload, &result); err != nil {
		s.fail(w, r, err)
		return result, false
	}
	return result, true
}

func (s *Server) registerBegin(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Nickname string `json:"nickname"`
	}
	if !readJSON(w, r, &request) {
		return
	}
	closed, err := s.db.RegistrationClosed(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if closed {
		s.fail(w, r, store.ErrRegistrationClosed)
		return
	}
	if err := s.db.CheckRegistrationName(r.Context(), request.Nickname); err != nil {
		s.fail(w, r, err)
		return
	}
	id, err := store.NewPasskeyID()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	u := user{ID: id, Nickname: request.Nickname}
	options, session, err := s.auth.BeginRegistration(u)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if !s.saveCeremony(w, r, "register", ceremony{Session: *session, User: u}) {
		return
	}
	httpresponse.JSON(w, 200, options)
}

func (s *Server) registerFinish(w http.ResponseWriter, r *http.Request) {
	value, ok := s.consumeCeremony(w, r, "register")
	if !ok {
		return
	}
	credential, err := s.auth.FinishRegistration(value.User, value.Session, r)
	if err != nil {
		logging.Annotate(r.Context(), "auth_stage", "registration_verification", "reason", "invalid_passkey")
		httpresponse.Error(w, 400, "PASSKEY_INVALID", "通行密钥登记未完成，请重新开始")
		return
	}
	data, err := json.Marshal(credential)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	request, err := s.db.RegisterPasskey(r.Context(), store.PasskeyAccount{ID: value.User.ID, Nickname: value.User.Nickname, CredentialID: credential.ID, CredentialJSON: data})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	// The receipt is shown only here. There is deliberately no public lookup or recovery endpoint.
	logging.Request(r, s.logger).Info("Passkey registration received", "event", "auth.registration_created", "account_id", value.User.ID)
	httpresponse.JSON(w, 201, map[string]string{"request_id": request.RequestID})
}

func (s *Server) loginBegin(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Client        *store.ClientAuthorization `json:"client,omitempty"`
		DeviceRequest string                     `json:"device_request,omitempty"`
	}
	if !readJSON(w, r, &request) {
		return
	}
	if request.Client != nil && (!request.Client.Valid() || request.DeviceRequest != "") {
		httpresponse.Error(w, 400, "INVALID_AUTHORIZATION", "客户端登录请求无效，请从客户端重新登录")
		return
	}
	if request.DeviceRequest != "" {
		if err := s.db.DeviceAuthorizationPending(r.Context(), request.DeviceRequest); err != nil {
			s.fail(w, r, err)
			return
		}
	}
	options, session, err := s.auth.BeginDiscoverableLogin()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if !s.saveCeremony(w, r, "login", ceremony{Session: *session, Client: request.Client, DeviceRequest: request.DeviceRequest}) {
		return
	}
	httpresponse.JSON(w, 200, options)
}

func (s *Server) loginFinish(w http.ResponseWriter, r *http.Request) {
	value, ok := s.consumeCeremony(w, r, "login")
	if !ok {
		return
	}
	var account store.PasskeyAccount
	_, credential, err := s.auth.FinishPasskeyLogin(func(rawID, handle []byte) (webauthn.User, error) {
		var err error
		account, err = s.db.PasskeyByCredential(r.Context(), rawID, handle)
		if err != nil {
			return nil, err
		}
		var stored webauthn.Credential
		if err = json.Unmarshal(account.CredentialJSON, &stored); err != nil {
			return nil, err
		}
		return user{ID: account.ID, Nickname: account.Nickname, Credentials: []webauthn.Credential{stored}}, nil
	}, value.Session, r)
	if err != nil {
		httpresponse.Error(w, 400, "PASSKEY_INVALID", "无法使用这把通行密钥登录，请重新选择")
		logging.Annotate(r.Context(), "auth_stage", "login_verification", "reason", "invalid_passkey")
		return
	}
	if account.Blacklisted {
		s.fail(w, r, store.ErrBlacklisted)
		return
	}
	if account.Rejected {
		s.fail(w, r, store.ErrRegistrationRejected)
		return
	}
	if credential.Authenticator.CloneWarning {
		logging.Annotate(r.Context(), "auth_stage", "login_verification", "reason", "authenticator_clone_warning")
		httpresponse.Error(w, 403, "PASSKEY_INVALID", "通行密钥验证失败，请联系管理员")
		return
	}
	data, err := json.Marshal(credential)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if value.DeviceRequest != "" {
		if err = s.db.ApproveDeviceAuthorization(r.Context(), value.DeviceRequest, account, data); err != nil {
			s.fail(w, r, err)
			return
		}
		logging.Request(r, s.logger).Info("Device login approved", "event", "auth.device_approved", "account_id", account.ID)
		httpresponse.JSON(w, http.StatusOK, map[string]string{"status": "approved"})
		return
	}
	if value.Client != nil {
		code, err := s.db.CreateClientAuthorization(r.Context(), account, data, *value.Client)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		callback, _ := url.Parse(value.Client.RedirectURI)
		query := url.Values{"code": {code}, "state": {value.Client.State}}
		callback.RawQuery = query.Encode()
		logging.Request(r, s.logger).Info("Client authorization issued", "event", "auth.client_authorized", "account_id", account.ID)
		httpresponse.JSON(w, 200, map[string]string{"redirect_url": callback.String()})
		return
	}
	token, err := randomToken()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	member, err := s.db.FinishPasskeyLogin(r.Context(), account, data, token, time.Now().Add(sessionTTL))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if previous := cookieValue(r, sessionCookie); previous != "" {
		if err = s.db.DeletePasskeySession(r.Context(), previous); err != nil {
			s.fail(w, r, err)
			return
		}
	}
	s.cookie(w, sessionCookie, token, sessionTTL)
	logging.Request(r, s.logger).Info("Browser login completed", "event", "auth.browser_login", "member_id", member.ID)
	httpresponse.JSON(w, 200, member)
}

func (s *Server) windowsLoginHandoff(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Code string `json:"code"`
	}
	if !readJSON(w, r, &request) {
		return
	}
	received, err := s.db.WindowsLoginReceived(r.Context(), request.Code)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, map[string]bool{"received": received})
}

func (s *Server) session(w http.ResponseWriter, r *http.Request) {
	member, expires, err := s.db.PasskeySession(r.Context(), cookieValue(r, sessionCookie))
	if errors.Is(err, store.ErrNotFound) || (err == nil && !member.Enabled) {
		s.cookie(w, sessionCookie, "", -time.Second)
		httpresponse.JSON(w, 200, map[string]any{"member": nil})
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, 200, struct {
		Member    store.Member `json:"member"`
		ExpiresAt int64        `json:"expires_at"`
	}{member, expires})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	if !readJSON(w, r, &struct{}{}) {
		return
	}
	if err := s.db.DeletePasskeySession(r.Context(), cookieValue(r, sessionCookie)); err != nil {
		s.fail(w, r, err)
		return
	}
	s.cookie(w, sessionCookie, "", -time.Second)
	logging.Request(r, s.logger).Info("Browser session revoked", "event", "auth.browser_logout")
	w.WriteHeader(204)
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	if clienthttp.WriteError(w, err) {
		return
	}
	switch {
	case errors.Is(err, store.ErrDevicePairing):
		httpresponse.Error(w, 409, "DEVICE_PAIRING_INVALID", "设备配对已失效、取消或发生冲突，请重新生成二维码")
	case errors.Is(err, store.ErrBlacklisted):
		httpresponse.Error(w, 403, "IDENTITY_BLACKLISTED", "此账号或设备已被永久撤销")
	case errors.Is(err, store.ErrIdentityConflict):
		httpresponse.Error(w, 409, "IDENTITY_CONFLICT", "此账号已有不同的根身份，请使用已有设备授权或恢复文件")
	case errors.Is(err, store.ErrDeviceIdentity):
		httpresponse.Error(w, 403, "DEVICE_IDENTITY_REQUIRED", "请先由可信旧设备授权新设备；当前登录尚未切换")
	case errors.Is(err, store.ErrInvalidDeviceAuthorization):
		httpresponse.Error(w, 400, "DEVICE_AUTHORIZATION_EXPIRED", "授权请求已过期、取消或已使用，请在 Chirp 客户端重试")
	case errors.Is(err, store.ErrInvalidAuthorization):
		httpresponse.Error(w, 400, "INVALID_AUTHORIZATION", "本次客户端登录已失效，请重新登录")
	case errors.Is(err, store.ErrInvalidNickname):
		httpresponse.Error(w, 400, "INVALID_NICKNAME", "昵称须为 3–15 位纯英文字母")
	case errors.Is(err, store.ErrRegistrationClosed):
		httpresponse.Error(w, http.StatusForbidden, "REGISTRATION_CLOSED", "注册暂时关闭，请在重新开放后申请")
	case errors.Is(err, store.ErrRegistrationExists):
		httpresponse.Error(w, 409, "REGISTRATION_EXISTS", "这个昵称已有登记；如需重新登记，请联系管理员删除原申请")
	case errors.Is(err, store.ErrRegistrationRejected):
		httpresponse.Error(w, 403, "REGISTRATION_REJECTED", "注册申请已被拒绝或删除，请重新申请")
	case errors.Is(err, store.ErrNotApproved):
		httpresponse.Error(w, 403, "REGISTRATION_PENDING", "注册申请尚未获得管理员批准")
	case errors.Is(err, store.ErrMemberDisabled):
		httpresponse.Error(w, 403, "MEMBER_DISABLED", "此账号已停用")
	case errors.Is(err, store.ErrPasskeyChanged):
		httpresponse.Error(w, 409, "RETRY_LOGIN", "登录信息已更新，请重新登录")
	case errors.Is(err, store.ErrRegistrationCapacity), errors.Is(err, store.ErrCeremonyCapacity):
		httpresponse.Error(w, 503, "TRY_LATER", "暂时无法接收新操作，请稍后重试")
	default:
		logging.Request(r, s.logger).Error("Passkey operation failed", "event", "auth.operation_failed", "error", err)
		httpresponse.Error(w, 500, "INTERNAL_ERROR", "服务暂时出现错误，请稍后重试")
	}
}

func (s *Server) clientExchange(w http.ResponseWriter, r *http.Request) {
	client, err := clienthttp.Identity(r)
	if err != nil {
		clienthttp.WriteError(w, err)
		return
	}
	var request struct {
		Code        string `json:"code"`
		Verifier    string `json:"code_verifier"`
		ClientID    string `json:"client_id"`
		RedirectURI string `json:"redirect_uri"`
	}
	if !readJSON(w, r, &request) {
		return
	}
	if !store.ValidClientRedirect(request.ClientID, request.RedirectURI) {
		s.fail(w, r, store.ErrInvalidAuthorization)
		return
	}
	setup, err := s.db.BeginIdentitySetup(r.Context(), request.Code, request.Verifier, request.ClientID, s.setupOrigin(), client, false)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	httpresponse.JSON(w, http.StatusOK, setup)
}
