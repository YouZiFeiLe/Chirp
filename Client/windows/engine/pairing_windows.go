package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

var (
	errInvalidPairingRequest = errors.New("INVALID_PAIRING_REQUEST")
	errPairingExpired        = errors.New("DEVICE_PAIRING_EXPIRED")
)

type pairing struct {
	req                                   identity.DevicePairingRequest
	issuer                                identity.Device
	new                                   bool
	n                                     *native
	key                                   *deviceKey
	seen                                  map[string]string
	out                                   []identity.DevicePairingAction
	digits                                []int
	local, peer, complete, issued, permit bool
	imported, checked                     bool
	deferLogin, approved                  bool
	mismatches                            int
	until                                 int64
}

func (p *pairing) sas(action string, extra obj) (sasResult, error) {
	extra["action"] = action
	extra["id"] = p.req.Nonce
	var v sasResult
	err := p.n.request(obj{"operation": "security", "security": extra}, &v)
	if len(v.Decimals) != 0 {
		if len(v.Decimals) != 3 || len(p.digits) > 0 && !slices.Equal(v.Decimals, p.digits) {
			return v, invalid
		}
		p.digits = v.Decimals
	}
	p.complete = p.complete || v.Complete
	return v, err
}
func (p *pairing) action(op, payload string) identity.DevicePairingAction {
	a := identity.DevicePairingAction{RequestID: p.req.Hash(), Action: op, Issuer: p.issuer, Payload: payload, Nonce: b64(random(32)), CreatedAt: time.Now().Unix()}
	a.Signature = p.key.sign(a.Message())
	return a
}
func (e *engine) endPairing(ctx context.Context) {
	p := e.pairing
	if p == nil {
		return
	}
	e.pairing = nil
	p.n.close()
	op := "cancel-old"
	if p.new {
		op = "cancel-new"
	}
	if e.conn != nil && p.req.Origin == e.conn.origin && p.key != nil && p.req.Validate(time.Now()) == nil {
		_, _ = request(ctx, "pairingAction", "POST", e.conn.origin+"/api/client/identity/pairing/action", p.action(op, ""), "", nil, nil, 65536)
	}
}
func (e *engine) savedIssuer(scope string) *deviceKey {
	if e.conn == nil || !strings.HasPrefix(scope, e.conn.origin+"|") {
		return nil
	}
	account := e.vault.Accounts[scope]
	if account == nil || account.Active == nil {
		return nil
	}
	d := account.Active.Device
	if d.Validate(time.Now()) != nil || len(d.Certificates) >= identity.MaxChain || !d.Certificates[len(d.Certificates)-1].CanEnroll || account.Denied[d.LeafKey()] {
		return nil
	}
	id := strings.TrimPrefix(scope, e.conn.origin+"|")
	for _, b := range e.vault.Blacklists[e.conn.origin] {
		if b.Kind == "device" && b.Subject == d.LeafKey() || b.Kind == "account" && (b.Subject == id || b.AccountKey == d.AccountKey) {
			return nil
		}
	}
	return account.Active
}
func (e *engine) savedIssuers() []obj {
	list := []obj{}
	if e.conn == nil {
		return list
	}
	for scope := range e.vault.Accounts {
		if d := e.savedIssuer(scope); d != nil {
			list = append(list, obj{"id": strings.TrimPrefix(scope, e.conn.origin+"|"), "root": d.Device.AccountKey, "key": d.Device.LeafKey()})
		}
	}
	slices.SortFunc(list, func(a, b obj) int { return strings.Compare(a["id"].(string), b["id"].(string)) })
	return list
}

func (e *engine) savedAccounts() []obj {
	list := []obj{}
	for scope, account := range e.vault.Accounts {
		d := account.Active
		if d == nil {
			d = account.Candidate
		}
		origin, id, ok := strings.Cut(scope, "|")
		if !ok || d == nil {
			continue
		}
		list = append(list, obj{"origin": origin, "id": id, "root": d.Device.AccountKey, "key": d.Device.LeafKey(), "canApprove": e.savedIssuer(scope) != nil})
	}
	slices.SortFunc(list, func(a, b obj) int {
		if byOrigin := strings.Compare(a["origin"].(string), b["origin"].(string)); byOrigin != 0 {
			return byOrigin
		}
		return strings.Compare(a["id"].(string), b["id"].(string))
	})
	return list
}
func pairingCodeMatches(code string, digits []int) bool {
	if len(digits) != 3 {
		return false
	}
	var actual strings.Builder
	for _, v := range code {
		switch {
		case v >= '0' && v <= '9':
			actual.WriteRune(v)
		case v == ' ' || v == '-' || v == '\t' || v == '\n' || v == '\r':
		default:
			return false
		}
	}
	return actual.String() == fmt.Sprintf("%04d%04d%04d", digits[0], digits[1], digits[2])
}

func validatePairingRequest(req identity.DevicePairingRequest, now time.Time) error {
	if req.Validate(now) == nil {
		return nil
	}
	expired := req.ExpiresAt > 0 && req.ExpiresAt <= now.Unix()
	tooEarly := req.ExpiresAt > now.Add(identity.DevicePairingLifetime).Unix()
	// A clock diagnostic requires the candidate's signature over the deadline.
	if (expired || tooEarly) && identity.Verify(req.DeviceKey, req.Signature, req.Message()) {
		if expired {
			return errPairingExpired
		}
		return errors.New("PAIRING_CLOCK_MISMATCH")
	}
	return errInvalidPairingRequest
}

func (e *engine) devicePair(ctx context.Context, op string, a args) (result any, err error) {
	if e.conn == nil || op == "finishPair" && a.ID == "" {
		return nil, invalid
	}
	p := e.pairing
	if op != "pairNew" && op != "pairOld" && a.ID != "" && (p == nil || p.req.Nonce != a.ID) {
		if op == "pairCancel" {
			return nil, nil
		}
		return nil, invalid
	}
	if op == "pairCancel" {
		e.endPairing(ctx)
		return nil, nil
	}
	if op == "pairNew" || op == "pairOld" {
		e.endPairing(ctx)
		var n *native
		n, err = newNative("device-pairing")
		if err != nil {
			return nil, err
		}
		p = &pairing{n: n, new: op == "pairNew", deferLogin: a.Action == "deferLogin", seen: map[string]string{}, issuer: identity.Device{Certificates: []identity.Certificate{}}}
		e.pairing = p
		defer func() {
			if err != nil && e.pairing == p {
				e.endPairing(ctx)
			}
		}()
		if p.new {
			if e.flow == nil || e.account == nil || e.flow.setup.AccountKey == "" || a.ID != "" && a.ID != e.flow.state {
				return nil, invalid
			}
			s := e.flow.setup
			seed := e.account.PairSeed
			if len(seed) != ed25519.SeedSize || e.flow.deviceRejected || e.account.Candidate != nil {
				seed = random(ed25519.SeedSize)
			}
			p.key = &deviceKey{Seed: seed}
			previous := e.account.PairSeed
			e.account.PairSeed = seed
			if err = e.vault.save(); err != nil {
				e.account.PairSeed = previous
				return nil, err
			}
			priv := ed25519.NewKeyFromSeed(seed)
			defer clear(priv)
			p.req = identity.DevicePairingRequest{Version: 1, Origin: s.Origin, AccountID: s.AccountID, AccountKey: s.AccountKey, DeviceKey: b64(priv.Public().(ed25519.PublicKey)), Nonce: b64(random(32)), ExpiresAt: min(s.ExpiresAt-3, time.Now().Unix()+297)}
			v, err := p.sas("sas_start", obj{"context": p.req.Context()})
			if err != nil {
				return nil, err
			}
			var packet struct{ Commitment string }
			if json.Unmarshal([]byte(v.Message), &packet) != nil {
				return nil, invalid
			}
			p.req.Commitment = packet.Commitment
			p.req.Signature = p.key.sign(p.req.Message())
			if err = validatePairingRequest(p.req, time.Now()); err != nil {
				return nil, err
			}
			var state store.DevicePairingState
			_, err = request(ctx, "startPairing", "POST", e.conn.origin+"/api/client/identity/pairing/start", obj{"setup_token": s.Token, "code_verifier": e.flow.verifier, "request": p.req}, "", nil, &state, 65536)
			if err != nil {
				return nil, err
			}
			if state.Request != p.req {
				return nil, invalid
			}
		} else {
			prefix := "chirp-device-pair-v1:"
			if !strings.HasPrefix(a.Code, prefix) || len(a.Code) > 4096 {
				return nil, errInvalidPairingRequest
			}
			b, err := base64.StdEncoding.Strict().DecodeString(strings.TrimPrefix(a.Code, prefix))
			if err != nil || json.Unmarshal(b, &p.req) != nil {
				return nil, errInvalidPairingRequest
			}
			if err := validatePairingRequest(p.req, time.Now()); err != nil {
				return nil, err
			}
			id := a.ID
			if e.session != nil {
				id = e.session.Member.ID
				if err := e.refreshAuth(ctx, e.roomRoots(), true); err != nil {
					return nil, err
				}
			}
			if p.req.Origin != e.conn.origin {
				return nil, errors.New("PAIRING_SERVER_MISMATCH")
			}
			if id == "" || id != p.req.AccountID {
				return nil, errors.New("PAIRING_ACCOUNT_MISMATCH")
			}
			issuer := e.savedIssuer(e.conn.origin + "|" + id)
			if issuer == nil {
				return nil, errors.New("DEVICE_APPROVAL_NOT_ALLOWED")
			}
			if p.req.AccountKey != issuer.Device.AccountKey {
				return nil, errors.New("PAIRING_ACCOUNT_MISMATCH")
			}
			if p.req.DeviceKey == issuer.Device.LeafKey() {
				return nil, errInvalidPairingRequest
			}
			p.key, p.issuer = issuer, issuer.Device
			p.imported = a.Action != "camera"
			v, err := p.sas("sas_accept", obj{"commitment": p.req.Commitment, "context": p.req.Context()})
			if err != nil {
				return nil, err
			}
			p.out = append(p.out, p.action("offer", v.Message))
		}
		p.until = ticks() + max(int64(0), p.req.ExpiresAt*1000-time.Now().UnixMilli())
	}
	if p == nil || p.key == nil {
		return nil, invalid
	}
	if ticks() >= p.until {
		return nil, errPairingExpired
	}
	if err := validatePairingRequest(p.req, time.Now()); err != nil {
		return nil, err
	}
	if p.req.Origin != e.conn.origin || p.new && (e.flow == nil || p.req.AccountID != e.flow.setup.AccountID || p.req.AccountKey != e.flow.setup.AccountKey) {
		return nil, invalid
	}
	if p.approved {
		if op == "finishPair" {
			return e.finishPairedLogin(ctx, p)
		}
		return obj{"step": "paired", "id": p.req.Nonce}, nil
	}
	if op == "finishPair" {
		return nil, invalid
	}
	if op == "pairConfirm" || op == "pairCheckCode" {
		if len(p.digits) != 3 || p.local {
			return nil, invalid
		}
		if p.imported && (op == "pairCheckCode" || !p.checked) {
			if !pairingCodeMatches(a.Code, p.digits) {
				p.checked = false
				p.mismatches++
				if p.mismatches >= 3 {
					e.endPairing(ctx)
					return nil, errors.New("PAIRING_ATTEMPTS_EXHAUSTED")
				}
				return nil, errors.New("PAIRING_CODE_MISMATCH")
			}
			p.checked = true
		}
		if op == "pairCheckCode" {
			return nil, nil
		}
		v, err := p.sas("sas_confirm", obj{})
		if err != nil {
			return nil, err
		}
		p.local = true
		p.permit = a.Enabled
		kind := "old-confirm"
		if p.new {
			kind = "new-confirm"
		}
		p.out = append(p.out, p.action(kind, v.Message))
	}
	poll := "poll-old"
	if p.new {
		poll = "poll-new"
	}
	for loops := 0; loops < 6; loops++ {
		act := p.action(poll, "")
		queued := len(p.out) > 0
		if queued {
			act = p.out[0]
		}
		var state store.DevicePairingState
		if _, err := request(ctx, "pairingAction", "POST", e.conn.origin+"/api/client/identity/pairing/action", act, "", nil, &state, 65536); err != nil {
			return nil, err
		}
		if queued {
			p.out = p.out[1:]
		}
		if state.Request != p.req {
			return nil, invalid
		}
		if state.Cancelled {
			return nil, errors.New("DEVICE_PAIRING_INVALID")
		}
		for _, v := range []struct {
			name string
			a    *identity.DevicePairingAction
		}{{"offer", state.Offer}, {"reveal", state.Reveal}, {"new-confirm", state.NewConfirmation}, {"old-confirm", state.OldConfirmation}, {"approve", state.Approval}} {
			if v.a == nil {
				if p.seen[v.name] != "" {
					return nil, invalid
				}
				continue
			}
			if v.a.Action != v.name || v.a.Validate(p.req, time.Now()) != nil || state.Offer == nil || v.a.Issuer.Hash() != state.Offer.Issuer.Hash() || p.issuer.LeafKey() != "" && v.a.Issuer.Hash() != p.issuer.Hash() {
				return nil, invalid
			}
			if previous := p.seen[v.name]; previous != "" {
				if previous != v.a.Signature {
					return nil, invalid
				}
				continue
			}
			p.issuer = v.a.Issuer
			p.seen[v.name] = v.a.Signature
			if p.new && v.name == "offer" || !p.new && v.name == "reveal" || p.new && v.name == "old-confirm" || !p.new && v.name == "new-confirm" {
				out, err := p.sas("sas_receive", obj{"message": v.a.Payload})
				if err != nil {
					return nil, err
				}
				if v.name == "offer" {
					p.out = append(p.out, p.action("reveal", out.Message))
				}
				if strings.HasSuffix(v.name, "-confirm") {
					p.peer = true
				}
			}
			if v.name == "approve" {
				var result identity.DevicePairingApproval
				if !p.complete || !p.local || !p.peer || json.Unmarshal([]byte(v.a.Payload), &result) != nil || result.Validate(p.req, p.issuer, time.Now()) != nil {
					return nil, invalid
				}
				if p.new {
					p.key.Device = result.Device
					p.approved = true
					if p.deferLogin {
						return obj{"step": "paired", "id": p.req.Nonce}, nil
					}
					return e.finishPairedLogin(ctx, p)
				}
				p.n.close()
				e.pairing = nil
				return obj{"step": "complete"}, nil
			}
		}
		if !p.new && p.complete && p.local && p.peer && !p.issued {
			parent := p.issuer.Certificates[len(p.issuer.Certificates)-1]
			now := time.Now()
			cert := identity.Certificate{AccountKey: p.issuer.AccountKey, DeviceKey: p.req.DeviceKey, IssuerKey: p.issuer.LeafKey(), ParentHash: parent.Hash(), Serial: b64(random(16)), CanEnroll: p.permit, NotBefore: now.Unix(), NotAfter: min(parent.NotAfter, now.Add(identity.MaxDeviceLifetime).Unix())}
			cert.Signature = p.key.sign(cert.Message())
			d := identity.Device{AccountKey: p.issuer.AccountKey, Certificates: append(slices.Clone(p.issuer.Certificates), cert)}
			approval := identity.DevicePairingApproval{Device: d}
			if err := approval.Validate(p.req, p.issuer, now); err != nil {
				return nil, err
			}
			raw, _ := json.Marshal(approval)
			p.out = append(p.out, p.action("approve", string(raw)))
			p.issued = true
		}
		if len(p.out) == 0 {
			break
		}
	}
	b, _ := json.Marshal(p.req)
	state := obj{"step": "pair", "id": p.req.Nonce, "expires": p.req.ExpiresAt, "ready": len(p.digits) == 3, "confirmed": p.local, "new": p.new}
	if p.new {
		state["code"] = "chirp-device-pair-v1:" + b64(b)
	}
	if !p.imported {
		state["digits"] = p.digits
	}
	return state, nil
}

func (e *engine) finishPairedLogin(ctx context.Context, p *pairing) (obj, error) {
	previous := e.account.Candidate
	e.account.Candidate = p.key
	if err := e.vault.save(); err != nil {
		e.account.Candidate = previous
		return nil, err
	}
	result, err := e.activate(ctx, p.key)
	if err == nil {
		p.n.close()
		e.pairing = nil
	}
	return result, err
}
