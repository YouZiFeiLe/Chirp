package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type loginFlow struct {
	verifier, state, requestID string
	phone                      bool
	backupUnlocked             bool
	deviceRejected             bool
	rootSeed                   []byte
	newDevice                  *deviceKey
	expires                    int64
	setup                      store.IdentitySetup
}
type session struct {
	Member struct {
		ID   string `json:"id"`
		Name string `json:"display_name"`
	}
	Credential string
	Expires    int64           `json:"expires_at"`
	Identity   string          `json:"participant_identity"`
	Device     identity.Device `json:"device_identity"`
}

var errSessionExpired = errors.New("CLIENT_LOGIN_EXPIRED")
var errDeviceRevoked = errors.New("DEVICE_REVOKED")

func signedOutReason(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, errSessionExpired) {
		return errSessionExpired.Error()
	}
	if errors.Is(err, errDeviceRevoked) {
		return errDeviceRevoked.Error()
	}
	// A rejected setup, pairing or authorization-service request does not
	// invalidate the business credential used by the current login.
	var remote *apiError
	if errors.As(err, &remote) && remote.authenticated {
		if remote.status == 401 {
			return "UNAUTHORIZED"
		}
		if remote.status == 403 && (remote.code == "MEMBER_DISABLED" || remote.code == "IDENTITY_BLACKLISTED") {
			return remote.code
		}
	}
	return ""
}

func signedOutError(err error) bool { return signedOutReason(err) != "" }

// Reading the business session does not reserve an admission sequence.
func (s *session) joinSequence(ctx context.Context, endpoint string) (int64, error) {
	if time.Now().Unix() >= s.Expires {
		return 0, errSessionExpired
	}
	var state struct {
		Sequence *int64 `json:"join_sequence"`
	}
	status, err := request(ctx, "session", "GET", endpoint, nil, s.Credential, nil, &state, 65536)
	if err != nil {
		return 0, err
	}
	if status != 200 || state.Sequence == nil || *state.Sequence < 0 || *state.Sequence == math.MaxInt64 {
		return 0, invalid
	}
	return *state.Sequence, nil
}

// Directory visibility, authorization snapshots and room heartbeats can all
// stop independently. Keep checking the business credential until it expires.
func (s *session) watch(ctx context.Context, endpoint string, interval time.Duration) string {
	untilExpiry, cancel := context.WithDeadline(ctx, time.Unix(s.Expires, 0))
	defer cancel()
	for ctx.Err() == nil {
		_, err := s.joinSequence(untilExpiry, endpoint)
		reason := signedOutReason(err)
		if untilExpiry.Err() == context.DeadlineExceeded {
			reason = "CLIENT_LOGIN_EXPIRED"
		}
		if reason != "" {
			return reason
		}
		select {
		case <-untilExpiry.Done():
		case <-time.After(interval):
		}
	}
	return ""
}

func (e *engine) watchLogin(root context.Context, interval time.Duration) {
	lifetime, cancel := context.WithCancelCause(root)
	e.loginLifetime, e.stopLoginWatch = lifetime, cancel
	owner, endpoint := e.session, e.conn.api("v1/session")
	go func() {
		if reason := owner.watch(lifetime, endpoint, interval); reason != "" {
			cancel(errors.New(reason))
		}
	}()
}

func (e *engine) cancelLogin(ctx context.Context) {
	f := e.flow
	e.flow = nil
	if f != nil {
		clear(f.rootSeed)
		if e.conn != nil && f.requestID != "" {
			_, _ = request(ctx, "cancelPhoneLogin", "POST", e.conn.endpoints.DeviceCancelURL, obj{"request_id": f.requestID, "code_verifier": f.verifier}, "", nil, nil, 4096)
		}
	}
	e.endPairing(ctx)
}

func (e *engine) begin(ctx context.Context, phone bool) (obj, error) {
	if e.conn == nil || e.session != nil {
		return nil, invalid
	}
	c, err := e.refreshConnection(ctx)
	if err != nil {
		return nil, err
	}
	if phone && !c.phone {
		return nil, invalid
	}
	e.cancelLogin(ctx)
	f := &loginFlow{verifier: rawURL(random(32)), state: rawURL(random(32)), phone: phone, expires: time.Now().Add(5 * time.Minute).Unix()}
	e.flow = f
	if !phone {
		q := url.Values{"client_id": {store.WindowsClientID}, "redirect_uri": {store.WindowsClientRedirectURI}, "state": {f.state}, "code_challenge": {challenge(f.verifier)}, "code_challenge_method": {"S256"}}
		return obj{"url": c.endpoints.AuthorizationURL + "?" + q.Encode()}, nil
	}
	var r struct {
		ID       string `json:"request_id"`
		URL      string `json:"verification_uri"`
		Expires  int64  `json:"expires_at"`
		Interval int
	}
	_, err = request(ctx, "startPhoneLogin", "POST", c.endpoints.DeviceStartURL, obj{"client_id": store.WindowsClientID, "code_challenge": challenge(f.verifier), "code_challenge_method": "S256"}, "", nil, &r, 65536)
	if err != nil {
		return nil, err
	}
	u, err := url.Parse(r.URL)
	if err != nil {
		return nil, invalid
	}
	q, err := url.ParseQuery(u.RawQuery)
	u.RawQuery = ""
	if err != nil || !tokenRE.MatchString(r.ID) || u.String() != c.endpoints.DeviceVerificationURL || len(q) != 1 || len(q["request"]) != 1 || q.Get("request") != r.ID || r.Expires <= time.Now().Unix() || r.Expires > time.Now().Unix()+240 || r.Interval < 1 || r.Interval > 30 {
		return nil, invalid
	}
	f.requestID = r.ID
	f.expires = r.Expires
	return obj{"url": r.URL, "interval": r.Interval, "expires": r.Expires, "id": f.state}, nil
}
func (e *engine) exchange(ctx context.Context, callback string) (obj, error) {
	return e.claim(ctx, callback, false)
}
func (e *engine) claim(ctx context.Context, callback string, deferred bool) (obj, error) {
	f := e.flow
	if f == nil || e.conn == nil || e.session != nil || f.expires <= time.Now().Unix() {
		return nil, errors.New("LOGIN_EXPIRED")
	}
	if deferred && f.phone && f.setup.AccountID != "" {
		return obj{"step": "claimed"}, nil
	}
	operation := "exchangeLogin"
	var ep string
	var body obj
	if f.requestID != "" {
		if callback != "" {
			return nil, invalid
		}
		operation = "pollPhoneLogin"
		ep = e.conn.endpoints.DevicePollURL
		body = obj{"request_id": f.requestID, "code_verifier": f.verifier}
	} else {
		u, err := url.Parse(callback)
		if err != nil {
			return nil, invalid
		}
		q, err := url.ParseQuery(u.RawQuery)
		u.RawQuery = ""
		if err != nil || u.String() != store.WindowsClientRedirectURI || len(q) != 2 || len(q["state"]) != 1 || len(q["code"]) != 1 || q.Get("state") != f.state || !tokenRE.MatchString(q.Get("code")) {
			return nil, errors.New("INVALID_LOGIN_CALLBACK")
		}
		ep = e.conn.endpoints.TokenURL
		body = obj{"client_id": store.WindowsClientID, "redirect_uri": store.WindowsClientRedirectURI, "code_verifier": f.verifier, "code": q.Get("code")}
	}
	var setup store.IdentitySetup
	status, err := request(ctx, operation, "POST", ep, body, "", nil, &setup, 65536)
	if err != nil {
		return nil, err
	}
	if status == 202 {
		return obj{"step": "waiting"}, nil
	}
	if setup.Origin != e.conn.origin || setup.AccountID == "" || setup.Token == "" || setup.ExpiresAt <= time.Now().Unix() || setup.ExpiresAt > time.Now().Unix()+301 {
		return nil, invalid
	}
	f.setup = setup
	f.expires = setup.ExpiresAt
	f.requestID = ""
	if deferred {
		return obj{"step": "claimed"}, nil
	}
	return e.continueSetup(ctx)
}
func (e *engine) continueSetup(ctx context.Context) (obj, error) {
	f := e.flow
	if f == nil || f.expires <= time.Now().Unix() {
		return nil, errors.New("LOGIN_EXPIRED")
	}
	setup := f.setup
	e.account = e.vault.Accounts[setup.Origin+"|"+setup.AccountID]
	if e.account == nil {
		e.account = &storedAccount{}
		e.vault.Accounts[setup.Origin+"|"+setup.AccountID] = e.account
	}
	if len(e.account.Backup) > 0 {
		root := e.account.pendingRoot()
		if setup.AccountKey != "" && root != "" && root != setup.AccountKey {
			return obj{"step": "recover", "username": setup.Username, "conflict": true, "id": f.state}, nil
		}
		return e.backupView("resumeBackup"), nil
	}
	if setup.AccountKey != "" {
		if _, ok := identity.Bytes(setup.AccountKey, 32); !ok {
			return nil, invalid
		}
		for _, d := range []*deviceKey{e.account.Candidate, e.account.Active} {
			if e.canResumeDevice(d, setup.AccountKey) {
				res, err := e.activate(ctx, d)
				if err == nil {
					return res, nil
				}
				if temporarilyUnavailable(err) || e.flow == nil {
					return nil, err
				}
				var status *apiError
				f.deviceRejected = errors.As(err, &status) && (status.code == "IDENTITY_BLACKLISTED" || status.code == "DEVICE_IDENTITY_REQUIRED")
				break
			}
		}
		return obj{"step": "recover", "username": setup.Username, "id": f.state}, nil
	}
	if f.newDevice == nil {
		f.rootSeed = random(ed25519.SeedSize)
		root := ed25519.NewKeyFromSeed(f.rootSeed)
		f.newDevice = issueKey(root)
		clear(root)
	}
	if _, err := e.deviceChallenge(ctx, f.newDevice); err != nil {
		return nil, err
	}
	return obj{"step": "backup", "username": setup.Username, "id": f.state}, nil
}
func (e *engine) canResumeDevice(d *deviceKey, root string) bool {
	return d != nil && d.Device.AccountKey == root && !e.account.Denied[d.Device.LeafKey()] && d.Device.Validate(time.Now()) == nil
}
func issueKey(root ed25519.PrivateKey) *deviceKey {
	seed := random(32)
	leaf := ed25519.NewKeyFromSeed(seed)
	defer clear(leaf)
	now := time.Now()
	rootKey := b64(root.Public().(ed25519.PublicKey))
	cert := identity.Certificate{AccountKey: rootKey, IssuerKey: rootKey, DeviceKey: b64(leaf.Public().(ed25519.PublicKey)), Serial: b64(random(16)), CanEnroll: true, NotBefore: now.Unix(), NotAfter: now.Add(identity.MaxDeviceLifetime).Unix()}
	cert.Signature = identity.Sign(root, cert.Message())
	return &deviceKey{Seed: seed, Device: identity.Device{AccountKey: rootKey, Certificates: []identity.Certificate{cert}}}
}
func (e *engine) backup(password string) (obj, error) {
	if e.flow == nil || e.flow.expires <= time.Now().Unix() || e.flow.setup.AccountID == "" || e.flow.setup.AccountKey != "" {
		return nil, invalid
	}
	if !utf8.ValidString(password) || utf8.RuneCountInString(password) < 16 || len(password) > 1024 {
		return nil, errors.New("INVALID_RECOVERY_PASSWORD")
	}
	if len(e.account.Backup) != 0 {
		return nil, errors.New("RECOVERY_EXPORT_PENDING")
	}
	n, err := newNative("recovery-file")
	if err != nil {
		return nil, err
	}
	defer n.close()
	seed, d := e.flow.rootSeed, e.flow.newDevice
	if len(seed) != ed25519.SeedSize || d == nil {
		return nil, invalid
	}
	s := e.flow.setup
	payload, err := json.Marshal(obj{"payload_version": 1, "identity_protocol": identity.Protocol, "root_algorithm": "Ed25519", "root_seed": b64(seed), "root_public_key": d.Device.AccountKey, "service_origin": s.Origin, "account_id": s.AccountID, "username": s.Username, "created_at": time.Now().UTC().Format(time.RFC3339), "source_platform": "Windows"})
	if err != nil {
		return nil, err
	}
	defer clear(payload)
	var res struct{ File []byte }
	span := installationLog.begin()
	err = n.request(obj{"operation": "security", "security": obj{"action": "encrypt", "password": password, "payload": string(payload)}}, &res)
	installationLog.finish(span, logOp{"crypto", "recoveryEncrypt"}, err, 0)
	if err != nil {
		return nil, err
	}
	before := *e.account
	e.account.Candidate = d
	e.account.Backup = res.File
	e.account.BackupRoot = d.Device.AccountKey
	e.account.BackupExported = false
	e.account.BackupConfirmed = false
	if err = e.vault.save(); err != nil {
		*e.account = before
		return nil, err
	}
	e.flow.backupUnlocked = true
	clear(seed)
	e.flow.rootSeed, e.flow.newDevice = nil, nil
	return e.backupView("savedBackup"), nil
}
func (a *storedAccount) pendingRoot() string {
	if a.BackupRoot != "" {
		return a.BackupRoot
	}
	if a.Candidate != nil {
		return a.Candidate.Device.AccountKey
	}
	return ""
}
func (e *engine) backupView(step string) obj {
	return obj{"step": step, "username": e.flow.setup.Username, "id": e.flow.state, "key": identity.Hash(e.account.Backup), "file": e.account.Backup, "exported": e.account.BackupExported || e.account.BackupConfirmed}
}

type recoveryPayload struct {
	Version   int     `json:"payload_version"`
	Protocol  string  `json:"identity_protocol"`
	Algorithm string  `json:"root_algorithm"`
	Seed      string  `json:"root_seed"`
	Root      string  `json:"root_public_key"`
	Account   string  `json:"account_id"`
	Origin    string  `json:"service_origin"`
	Username  *string `json:"username"`
	Created   string  `json:"created_at"`
	Platform  string  `json:"source_platform"`
}

func (p recoveryPayload) rootKey(origin, account, expectedRoot string) (ed25519.PrivateKey, error) {
	normalized, err := identity.NormalizeOrigin(p.Origin)
	_, dateErr := time.Parse(time.RFC3339Nano, p.Created)
	if err != nil || normalized != p.Origin || p.Origin != origin || p.Account != account || (expectedRoot != "" && p.Root != expectedRoot) ||
		p.Username == nil || p.Version != 1 || p.Protocol != identity.Protocol || p.Algorithm != "Ed25519" ||
		len(p.Created) > 64 || dateErr != nil || !(strings.HasSuffix(p.Created, "Z") || strings.HasSuffix(p.Created, "+00:00")) {
		return nil, errors.New("RECOVERY_IDENTITY_MISMATCH")
	}
	switch p.Platform {
	case "macOS", "iOS", "Windows", "Android":
	default:
		return nil, errors.New("RECOVERY_IDENTITY_MISMATCH")
	}
	seed, ok := identity.Bytes(p.Seed, ed25519.SeedSize)
	if !ok {
		return nil, errors.New("RECOVERY_IDENTITY_MISMATCH")
	}
	defer clear(seed)
	root := ed25519.NewKeyFromSeed(seed)
	if p.Root != b64(root.Public().(ed25519.PublicKey)) {
		clear(root)
		return nil, errors.New("RECOVERY_IDENTITY_MISMATCH")
	}
	return root, nil
}

func (e *engine) openRecovery(file []byte, password, expectedRoot string) (ed25519.PrivateKey, error) {
	if e.flow == nil || e.flow.expires <= time.Now().Unix() || e.flow.setup.AccountID == "" || len(file) == 0 || len(file) > 65606 {
		return nil, invalid
	}
	n, err := newNative("recovery-file")
	if err != nil {
		return nil, err
	}
	defer n.close()
	var r struct{ Payload string }
	span := installationLog.begin()
	err = n.request(obj{"operation": "security", "security": obj{"action": "decrypt", "password": password, "file": b64(file)}}, &r)
	installationLog.finish(span, logOp{"crypto", "recoveryDecrypt"}, err, 0)
	if err != nil {
		return nil, err
	}
	var p recoveryPayload
	if json.Unmarshal([]byte(r.Payload), &p) != nil {
		return nil, invalid
	}
	return p.rootKey(e.flow.setup.Origin, e.flow.setup.AccountID, expectedRoot)
}

func (e *engine) backupAction(ctx context.Context, op string, a args) (obj, error) {
	if e.flow == nil || e.flow.state != a.ID || e.flow.expires <= time.Now().Unix() || e.account == nil || len(e.account.Backup) == 0 || identity.Hash(e.account.Backup) != a.Key {
		return nil, errors.New("LOGIN_EXPIRED")
	}
	expected := e.account.pendingRoot()
	if bound := e.flow.setup.AccountKey; bound != "" {
		if expected != "" && bound != expected {
			return nil, errors.New("RECOVERY_IDENTITY_MISMATCH")
		}
		expected = bound
	}
	before := *e.account
	switch op {
	case "unlockBackup", "verifyBackup":
		file := e.account.Backup
		if op == "verifyBackup" {
			if !e.flow.backupUnlocked || expected == "" {
				return nil, invalid
			}
			file = a.File
		}
		root, err := e.openRecovery(file, a.Password, expected)
		if err != nil {
			return nil, err
		}
		defer clear(root)
		if op == "verifyBackup" {
			return e.backupView("savedBackup"), nil
		}
		e.account.BackupRoot = b64(root.Public().(ed25519.PublicKey))
		if !e.canResumeDevice(e.account.Candidate, e.account.BackupRoot) {
			e.account.Candidate = issueKey(root)
		}
	case "backupExported", "finishBackup":
		if !e.flow.backupUnlocked || !e.canResumeDevice(e.account.Candidate, expected) {
			return nil, invalid
		}
		if op == "backupExported" {
			e.account.BackupExported, e.account.BackupConfirmed = a.Enabled, false
		} else {
			if !e.account.BackupExported {
				return nil, invalid
			}
			e.account.BackupConfirmed = true
		}
	default:
		return nil, invalid
	}
	if err := e.vault.save(); err != nil {
		*e.account = before
		return nil, err
	}
	if op == "unlockBackup" {
		if _, err := e.deviceChallenge(ctx, e.account.Candidate); err != nil {
			return nil, err
		}
		e.flow.backupUnlocked = true
	}
	if e.account.BackupConfirmed {
		return e.activate(ctx, e.account.Candidate)
	}
	return e.backupView("savedBackup"), nil
}

func (e *engine) recover(ctx context.Context, file []byte, password string, verify bool) (obj, error) {
	if e.flow == nil || e.account == nil {
		return nil, invalid
	}
	bound := e.flow.setup.AccountKey
	if verify {
		if len(e.account.Backup) == 0 || identity.Hash(file) != identity.Hash(e.account.Backup) {
			return nil, invalid
		}
		if bound != "" && e.account.pendingRoot() != "" && bound != e.account.pendingRoot() {
			return nil, errors.New("RECOVERY_IDENTITY_MISMATCH")
		}
		if bound == "" {
			bound = e.account.pendingRoot()
		}
	} else if bound == "" {
		return nil, invalid
	}
	root, err := e.openRecovery(file, password, bound)
	if err != nil {
		return nil, err
	}
	defer clear(root)
	bound = b64(root.Public().(ed25519.PublicKey))
	before := *e.account
	if !e.canResumeDevice(e.account.Candidate, bound) || e.flow.deviceRejected {
		if !verify && !e.flow.deviceRejected && e.canResumeDevice(e.account.Active, bound) {
			return e.activate(ctx, e.account.Active)
		}
		e.account.Candidate = issueKey(root)
	}
	if verify {
		e.account.BackupRoot, e.account.BackupExported, e.account.BackupConfirmed = bound, true, true
	}
	if err = e.vault.save(); err != nil {
		*e.account = before
		return nil, err
	}
	e.flow.deviceRejected = false
	return e.activate(ctx, e.account.Candidate)
}
func (e *engine) deviceChallenge(ctx context.Context, d *deviceKey) (string, error) {
	s := e.flow.setup
	if err := d.Device.Validate(time.Now()); err != nil {
		return "", err
	}
	body := obj{"setup_token": s.Token, "code_verifier": e.flow.verifier, "device": d.Device}
	var r struct{ Challenge string }
	if _, err := request(ctx, "identityChallenge", "POST", e.conn.origin+"/api/client/identity/challenge", body, "", nil, &r, 65536); err != nil {
		return "", err
	}
	if !tokenRE.MatchString(r.Challenge) {
		return "", invalid
	}
	return r.Challenge, nil
}
func (e *engine) activate(ctx context.Context, d *deviceKey) (obj, error) {
	epoch := installationLog.epoch()
	s := e.flow.setup
	challenge, err := e.deviceChallenge(ctx, d)
	if err != nil {
		return nil, err
	}
	body := obj{"setup_token": s.Token, "code_verifier": e.flow.verifier, "device": d.Device}
	body["signature"] = d.sign(identity.ActivationMessage(s.Origin, s.AccountID, store.WindowsClientID, s.Token, e.flow.verifier, challenge, d.Device))
	body["device_name"] = "Windows"
	var result session
	if _, err := request(ctx, "completeIdentity", "POST", e.conn.origin+"/api/client/identity/complete", body, "", nil, &result, 65536); err != nil {
		return nil, err
	}
	if result.Member.ID != s.AccountID || result.Device.Hash() != d.Device.Hash() || !strings.HasPrefix(result.Identity, s.AccountID+".login_") || len(result.Credential) != 49 || !strings.HasPrefix(result.Credential, "chirp_") || result.Expires <= time.Now().Unix() || result.Expires > time.Now().Add(20*time.Hour+time.Minute).Unix() {
		return nil, invalid
	}
	before := *e.account
	e.account.Active = d
	e.account.Candidate = nil
	e.account.Backup = nil
	e.account.BackupRoot = ""
	e.account.BackupExported = false
	e.account.BackupConfirmed = false
	e.account.PairSeed = nil
	if err := e.vault.save(); err != nil {
		*e.account = before
		return nil, err
	}
	e.flow = nil
	e.session = &result
	installationLog.record(epoch, logEntry{op: logOp{"account", "loginAccepted"}, outcome: "succeeded"})
	e.auth = authority{friends: e.account.Friends}
	return obj{"step": "signedIn", "member": result.Member, "canEnroll": e.canEnroll()}, nil
}
func routeKey(value string) (string, error) {
	b, ok := identity.Bytes(value, 32)
	if !ok {
		return "", invalid
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
