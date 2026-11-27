package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

var errSavedLoginInvalid = errors.New("CLIENT_INVALID_LOGIN_SESSION")

// The index exposes only a deadline and ciphertext, including the data key
// wrapped for Windows Hello. The bearer is never part of either disk format.
type sealedLogin struct {
	Expires    int64  `json:"expires"`
	WrappedKey []byte `json:"wrappedKey"`
	Ciphertext []byte `json:"ciphertext"`
}

type savedLogin struct {
	Token, Account, Participant, DeviceDigest string
	Discovery, Origin, API, Group             string
	Expires                                   int64
}

func validNonce(s string) bool {
	if !tokenRE.MatchString(s) {
		return false
	}
	_, err := base64.RawURLEncoding.Strict().DecodeString(s)
	return err == nil
}

func validGrant(token string) bool {
	raw, ok := strings.CutPrefix(token, identity.ResumptionTokenPrefix)
	return ok && validNonce(raw)
}

func loginWrappingKey(der []byte) *rsa.PublicKey {
	k, err := x509.ParsePKIXPublicKey(der)
	key, ok := k.(*rsa.PublicKey)
	if err != nil || !ok || key.N.BitLen() != 2048 || key.E != 65537 {
		return nil
	}
	return key
}

func loginCipher(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errSavedLoginInvalid
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCMWithRandomNonce(block)
}

func (s savedLogin) seal(pub *rsa.PublicKey) ([]byte, error) {
	key := random(32)
	defer clear(key)
	// Passport KSP supports RSAES-PKCS1-v1_5 for a local Hello-gated decrypt.
	// Only this random AES key is wrapped; all record fields are AEAD-protected.
	wrapped, err := rsa.EncryptPKCS1v15(rand.Reader, pub, key)
	if err != nil {
		return nil, err
	}
	aead, err := loginCipher(key)
	if err != nil {
		return nil, err
	}
	plain, err := json.Marshal(s)
	if err != nil {
		return nil, err
	}
	defer clear(plain)
	return json.Marshal(sealedLogin{s.Expires, wrapped, aead.Seal(nil, nil, plain, nil)})
}

func (s sealedLogin) open(key []byte) (savedLogin, error) {
	var record savedLogin
	aead, err := loginCipher(key)
	if err != nil {
		return record, err
	}
	plain, err := aead.Open(nil, nil, s.Ciphertext, nil)
	if err != nil {
		return record, errSavedLoginInvalid
	}
	defer clear(plain)
	if json.Unmarshal(plain, &record) != nil || record.Expires != s.Expires || !validGrant(record.Token) ||
		record.Account == "" || !strings.HasPrefix(record.Participant, record.Account+".login_") {
		return record, errSavedLoginInvalid
	}
	return record, nil
}

func (e *engine) forgetSavedLogin() error {
	if e.loginPath != "" {
		if err := os.Remove(e.loginPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return errors.New("LOGIN_STORAGE_UNAVAILABLE")
		}
	}
	return nil
}

func (f *loginFlow) setResumption(a args) {
	f.offerResumption = a.Enabled
	f.wrappingKey = loginWrappingKey(a.File)
}

// A new installation can opt in from Settings during this login. Until then
// the optional grant stays in the engine, and a restart still requires Passkey.
func (e *engine) receiveLoginGrant(f *loginFlow, raw json.RawMessage) string {
	e.pendingLoginGrant = ""
	_ = e.forgetSavedLogin()
	if !f.offerResumption || e.loginPath == "" {
		return "unavailable"
	}
	var token string
	if json.Unmarshal(raw, &token) != nil || !validGrant(token) {
		installationLog.finish(installationLog.begin(), logOp{"account", "loginWithoutResumptionGrant"}, errSavedLoginInvalid, 0)
		return "unavailable"
	}
	e.pendingLoginGrant = token
	if f.wrappingKey != nil && e.saveLoginForRelaunch(e.session.Identity, f.wrappingKey) == nil {
		return "enabled"
	}
	return "available"
}

func (e *engine) saveLoginForRelaunch(id string, key *rsa.PublicKey) error {
	s := e.session
	if s == nil || s.Identity != id || e.pendingLoginGrant == "" {
		return errors.New("LOGIN_REQUIRED")
	}
	if s.Expires <= time.Now().Unix() {
		e.pendingLoginGrant = ""
		return errSessionExpired
	}
	if key == nil {
		return errors.New("HELLO_KEY_UNAVAILABLE")
	}
	span := installationLog.begin()
	c := e.conn
	record := savedLogin{Token: e.pendingLoginGrant, Account: s.Member.ID, Participant: s.Identity, DeviceDigest: s.Device.Hash(),
		Discovery: c.discovery, Origin: c.origin, API: c.endpoints.APIBaseURL, Group: c.endpoints.GroupBaseURL, Expires: s.Expires}
	data, err := record.seal(key)
	if err == nil {
		err = writePrivateFile(e.loginPath, ".login-*", data)
	}
	installationLog.finish(span, logOp{"account", "saveLoginForRelaunch"}, err, 0)
	if err != nil {
		return errors.New("LOGIN_STORAGE_UNAVAILABLE")
	}
	e.pendingLoginGrant = ""
	return nil
}

func (e *engine) readSavedLogin() (*sealedLogin, error) {
	file, err := os.Open(e.loginPath)
	if errors.Is(err, os.ErrNotExist) || e.loginPath == "" {
		return nil, nil
	}
	if err != nil {
		return nil, errors.New("LOGIN_STORAGE_UNAVAILABLE")
	}
	data, err := io.ReadAll(io.LimitReader(file, 32769))
	file.Close()
	if err != nil {
		return nil, errors.New("LOGIN_STORAGE_UNAVAILABLE")
	}
	var sealed sealedLogin
	if len(data) > 32768 || json.Unmarshal(data, &sealed) != nil || len(sealed.WrappedKey) != 256 || len(sealed.Ciphertext) < 28 ||
		sealed.Expires <= time.Now().Unix() || sealed.Expires > 253402300799 { // Last Unix second representable by WinUI.
		return nil, e.forgetSavedLogin()
	}
	return &sealed, nil
}

func (s savedLogin) matches(c *connection) bool {
	return c != nil && c.discovery == s.Discovery && c.origin == s.Origin && c.endpoints.APIBaseURL == s.API && c.endpoints.GroupBaseURL == s.Group
}

func (s savedLogin) device(e *engine, now time.Time) (*storedAccount, error) {
	if s.Expires <= now.Unix() {
		return nil, errSessionExpired
	}
	a := e.vault.Accounts[s.Origin+"|"+s.Account]
	if a == nil || a.Active == nil {
		return nil, errSavedLoginInvalid
	}
	d := a.Active.Device
	if d.Validate(now) != nil || d.Hash() != s.DeviceDigest || s.Expires > d.Certificates[len(d.Certificates)-1].NotAfter ||
		a.Denied[d.LeafKey()] || e.vault.blacklisted(s.Origin, s.Account, d.AccountKey, d.LeafKey()) {
		return nil, errSavedLoginInvalid
	}
	return a, nil
}

type resumeAttempt struct {
	id     string
	ctx    context.Context
	cancel context.CancelFunc
}

type pendingResume struct {
	attempt *resumeAttempt
	record  savedLogin
	conn    *connection
	login   session
}

// The pipe reader cancels network I/O even while the engine actor is waiting
// for a response. Only the actor may publish a session.
func (e *engine) beginResume(ctx context.Context, id string) *resumeAttempt {
	ctx, cancel := context.WithCancel(ctx)
	a := &resumeAttempt{id, ctx, cancel}
	if previous := e.resuming.Swap(a); previous != nil {
		previous.cancel()
	}
	return a
}

func (e *engine) stopResume(id string) {
	if a := e.resuming.Load(); a != nil && (id == "" || a.id == id) {
		a.cancel()
	}
}

func endsSavedLogin(err error) bool {
	switch err.Error() {
	case "CLIENT_LOGIN_EXPIRED", "CLIENT_INVALID_LOGIN_SESSION", "INVALID_AUTHORIZATION", "MEMBER_DISABLED", "IDENTITY_BLACKLISTED",
		"UNAUTHORIZED", "DEVICE_IDENTITY_REQUIRED", "DEVICE_REVOKED", "SERVER_CONFIGURATION_CHANGED", "CLIENT_UPDATE_REQUIRED":
		return true
	}
	return false
}

func (e *engine) prepareResume(a *resumeAttempt, key []byte) (err error) {
	defer clear(key)
	if a == nil || a.id == "" || e.session != nil || e.flow != nil {
		return invalid
	}
	e.pendingResume = nil
	defer func() {
		if err != nil {
			a.cancel()
			if endsSavedLogin(err) {
				_ = e.forgetSavedLogin()
			}
		}
	}()
	if err := a.ctx.Err(); err != nil {
		return err
	}
	sealed, err := e.readSavedLogin()
	if err != nil {
		return err
	}
	if sealed == nil {
		return errSessionExpired
	}
	r, err := sealed.open(key)
	clear(key)
	if err != nil {
		return err
	}
	if !r.matches(e.conn) {
		return errors.New("SERVER_CONFIGURATION_CHANGED")
	}
	ctx, cancel := context.WithDeadline(a.ctx, time.Unix(r.Expires, 0))
	defer cancel()
	c, err := detect(ctx, r.Discovery, e.local)
	if err != nil {
		return err
	}
	if !r.matches(c) {
		return errors.New("SERVER_CONFIGURATION_CHANGED")
	}
	account, err := r.device(e, time.Now())
	if err != nil {
		return err
	}
	headers := http.Header{"Cache-Control": {"no-store"}}
	base := c.origin + "/api/client/resume/"
	body := obj{"resume_token": r.Token}
	var proof struct{ Challenge string }
	if _, err = request(ctx, "resumeChallenge", "POST", base+"challenge", body, "", headers, &proof, 65536); err != nil {
		return err
	}
	if !validNonce(proof.Challenge) {
		return invalid
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	d := account.Active
	body["signature"] = d.sign(identity.ResumptionMessage(c.origin, "windows", r.Participant, r.Token, proof.Challenge, d.Device))
	var s session
	if _, err = request(ctx, "resumeComplete", "POST", base+"complete", body, "", headers, &s, 65536); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if !s.validFor(r.Account, d.Device, time.Now()) || s.Identity != r.Participant || s.Expires != r.Expires {
		return errSavedLoginInvalid
	}
	r.Token = ""
	e.pendingResume = &pendingResume{a, r, c, s}
	return nil
}

func (e *engine) commitResume(id string) (obj, error) {
	p := e.pendingResume
	if p == nil || p.attempt.id != id || e.session != nil {
		return nil, context.Canceled
	}
	e.pendingResume = nil
	defer p.attempt.cancel()
	if err := p.attempt.ctx.Err(); err != nil {
		return nil, err
	}
	account, err := p.record.device(e, time.Now())
	if err != nil {
		_ = e.forgetSavedLogin()
		return nil, err
	}
	e.account, e.conn, e.resumedID = account, p.conn, id
	online := e.acceptLogin(&p.login)
	online["resumption"] = "enabled"
	return online, nil
}
