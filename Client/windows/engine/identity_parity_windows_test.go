package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/group"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

// Keep the fixture's real stores and handlers. Individual tests can temporarily
// take just the affected endpoint offline without disabling the other client.
func interruptEndpoint(f fixture, path string) *atomic.Bool {
	next, _ := f.mux.Handler(&http.Request{URL: &url.URL{Path: path}})
	offline := new(atomic.Bool)
	f.mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
		if offline.Load() {
			http.Error(w, "temporarily unavailable", 503)
			return
		}
		next.ServeHTTP(w, r)
	})
	return offline
}

func TestImportedPairingWithSignedOutIssuer(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	a := f.account(t, "Maple")
	old, _ := f.client(t)
	f.enroll(t, old, a, false)
	member := old.session.Member.ID
	_, err := old.handle(f.ctx, command{Op: "logout"})
	ok(t, err)
	if old.session != nil || len(old.savedIssuers()) != 1 || old.savedIssuers()[0]["id"] != member {
		t.Fatal("saved approving identity unavailable")
	}
	start := func() (*engine, string) {
		fresh, _ := f.client(t)
		if f.exchange(t, fresh, a, false)["step"] != "recover" {
			t.Fatal("expected enrollment")
		}
		s, err := fresh.devicePair(f.ctx, "pairNew", args{})
		ok(t, err)
		if s.(obj)["expires"] != fresh.pairing.req.ExpiresAt {
			t.Fatal("the pairing countdown must use the signed request's expiration")
		}
		qr := s.(obj)["code"].(string)
		for _, check := range []struct {
			origin string
			offset time.Duration
			want   string
		}{
			{f.origin, -time.Minute, "DEVICE_PAIRING_EXPIRED"},
			{f.origin, 6 * time.Minute, "PAIRING_CLOCK_MISMATCH"},
			{"https://other.test:443", time.Minute, "PAIRING_SERVER_MISMATCH"},
		} {
			request := fresh.pairing.req
			request.Origin = check.origin
			request.ExpiresAt = time.Now().Add(check.offset).Unix()
			request.Signature = fresh.pairing.key.sign(request.Message())
			encoded, err := json.Marshal(request)
			ok(t, err)
			_, err = old.devicePair(f.ctx, "pairOld", args{ID: member, Code: "chirp-device-pair-v1:" + b64(encoded), Action: "import"})
			if err == nil || err.Error() != check.want || old.pairing != nil {
				t.Fatalf("rejected pairing request: want %s, got %v", check.want, err)
			}
		}
		if _, err = old.devicePair(f.ctx, "pairOld", args{ID: "other", Code: qr, Action: "import"}); err == nil || err.Error() != "PAIRING_ACCOUNT_MISMATCH" {
			t.Fatalf("wrong saved account: %v", err)
		}
		_, err = old.devicePair(f.ctx, "pairOld", args{ID: member, Code: qr, Action: "import"})
		ok(t, err)
		s, err = fresh.devicePair(f.ctx, "pairPoll", args{})
		ok(t, err)
		d := s.(obj)["digits"].([]int)
		s, err = old.devicePair(f.ctx, "pairPoll", args{})
		ok(t, err)
		if _, leaked := s.(obj)["digits"]; leaked || s.(obj)["ready"] != true {
			t.Fatal("imported request exposed the expected digits or failed to become ready")
		}
		if s.(obj)["expires"] != fresh.pairing.req.ExpiresAt {
			t.Fatal("the approving device must show the same expiration")
		}
		return fresh, fmt.Sprintf("%04d-%04d %04d", d[0], d[1], d[2])
	}
	fresh, correct := start()
	for range 2 {
		if _, err = old.devicePair(f.ctx, "pairCheckCode", args{Code: "000"}); err == nil || err.Error() != "PAIRING_CODE_MISMATCH" {
			t.Fatal(err)
		}
	}
	_, err = old.devicePair(f.ctx, "pairCheckCode", args{Code: correct})
	ok(t, err)
	if old.pairing.local {
		t.Fatal("checking the numbers confirmed the old device before user consent")
	}
	_, err = fresh.devicePair(f.ctx, "pairConfirm", args{})
	ok(t, err)
	_, err = old.devicePair(f.ctx, "pairConfirm", args{Enabled: true})
	ok(t, err)
	last, err := fresh.devicePair(f.ctx, "pairPoll", args{})
	ok(t, err)
	if last.(obj)["step"] != "signedIn" || old.session != nil {
		t.Fatal("the saved issuer did not complete pairing while signed out")
	}
	other, _ := start()
	for range 3 {
		_, err = old.devicePair(f.ctx, "pairCheckCode", args{Code: "１２３４"})
	}
	if err == nil || err.Error() != "PAIRING_ATTEMPTS_EXHAUSTED" || old.pairing != nil {
		t.Fatal("three mismatches did not end the request", err)
	}
	if _, err = other.devicePair(f.ctx, "pairPoll", args{}); err == nil {
		t.Fatal("the new device still accepted the cancelled request")
	}
	expired, _ := start()
	expired.pairing.until = ticks()
	if _, err = expired.devicePair(f.ctx, "pairPoll", args{}); err == nil || err.Error() != "DEVICE_PAIRING_EXPIRED" {
		t.Fatal("an expired request must be distinguishable from a mismatched code", err)
	}
}

func TestIdentityClearFromCorruptAndSignedInStates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "identities.v5")
	ok(t, os.WriteFile(path, []byte("damaged"), 0600))
	e := &engine{vault: openIdentityVault(dir), cache: t.TempDir()}
	ctx := context.Background()
	if _, err := e.handle(ctx, command{Op: "restoreConnection"}); err == nil || err.Error() != "IDENTITY_STORE_UNAVAILABLE" {
		t.Fatal("corrupt storage allowed normal use", err)
	}
	_, err := e.handle(ctx, command{Op: "clearLocalData"})
	ok(t, err)
	if openIdentityVault(dir).unavailable || e.vault.unavailable {
		t.Fatal("the running engine did not recover")
	}
	f := service(t, "ws://127.0.0.1:9000")
	signed, _ := f.client(t)
	f.enroll(t, signed, f.account(t, "Moss"), false)
	_, err = signed.handle(f.ctx, command{Op: "clearLocalData"})
	ok(t, err)
	if signed.session != nil || signed.account != nil || signed.conn != nil || len(signed.vault.Accounts) != 0 || signed.vault.Connection != nil {
		t.Fatal("signed-in reset left account or connection state")
	}
	if _, err = os.Stat(signed.vault.path); !os.IsNotExist(err) {
		t.Fatal("identity file survived reset", err)
	}
}

func TestOfflineUntrustRebasesOnConcurrentSignedHistory(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	a := f.account(t, "Elm")
	first, _ := f.client(t)
	backup := f.enroll(t, first, a, false)
	second, _ := f.client(t)
	f.exchange(t, second, a, false)
	_, err := second.recover(f.ctx, backup, password, false)
	ok(t, err)
	root, peerKey := b64(random(32)), b64(random(32))
	ok(t, second.social(f.ctx, "trust", "member_peer", root, peerKey, "Peer"))
	own := second.auth.states[second.session.Device.AccountKey]
	offline := interruptEndpoint(f, "/authorization/v5/snapshot")
	offline.Store(true)
	_, err = second.handle(f.ctx, command{Op: "untrust", Args: args{ID: "member_peer", Root: root, Key: peerKey}})
	ok(t, err)
	pending := second.account.Pending
	if pending == nil || len(second.auth.friends[0].Devices) != 0 {
		t.Fatal("offline removal was not immediately effective")
	}
	reopened, err := loadVault(filepath.Dir(second.vault.path))
	ok(t, err)
	stored := reopened.Accounts[f.origin+"|"+second.session.Member.ID]
	if stored.Pending == nil || len(stored.Friends[0].Devices) != 0 {
		t.Fatal("offline removal did not survive reopening the vault")
	}
	// The other enrolled device signs and commits a change on the same head.
	ev := identity.SocialEvent{Origin: f.origin, AccountID: first.session.Member.ID, Version: pending.Version, PreviousHash: pending.PreviousHash, Operation: "friend", FriendID: "member_third", FriendKey: b64(random(32)), Name: "Third", Signer: first.session.Device}
	ev.Signature = first.account.Active.sign(ev.Message())
	ok(t, first.appendEvent(f.ctx, own, "social", "", &ev))
	offline.Store(false)
	ok(t, second.refreshAmbient(f.ctx))
	if second.account.Pending != nil || second.account.SocialHead.Version != 3 || len(second.auth.friends) != 2 || len(second.auth.friends[0].Devices) != 0 {
		t.Fatal("did not reconcile the concurrent change and revocation")
	}
	confirmed := second.auth.states[second.session.Device.AccountKey].Social[2]
	if confirmed.PreviousHash != ev.Hash() || confirmed.Operation != "untrust" || confirmed.Validate(time.Now()) != nil {
		t.Fatal("pending operation was not re-signed on the new head")
	}
	offline.Store(true)
	_, err = second.handle(f.ctx, command{Op: "removeFriend", Args: args{ID: "member_peer", Root: root}})
	ok(t, err)
	if len(second.auth.friends) != 1 || second.account.Pending.Operation != "remove_friend" {
		t.Fatal("offline friend removal was not applied")
	}
	offline.Store(false)
	ok(t, second.refreshAmbient(f.ctx))
}

func TestDeviceListAndRevocationUseSignedHistory(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	a := f.account(t, "Birch")
	one, _ := f.client(t)
	backup := f.enroll(t, one, a, false)
	two, _ := f.client(t)
	f.exchange(t, two, a, false)
	_, err := two.recover(f.ctx, backup, password, false)
	ok(t, err)
	key := one.session.Device.LeafKey()
	f.mux.HandleFunc("/v1/identity/devices", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]store.RegisteredDevice{{AccountID: two.session.Member.ID, Device: one.session.Device, Name: "Old PC", Revoked: true}, {DeviceKey: b64(random(32)), Name: "Unsigned device"}})
	})
	list, err := two.registeredDevices(f.ctx)
	ok(t, err)
	devices := list["devices"].([]store.RegisteredDevice)
	index := slices.IndexFunc(devices, func(d store.RegisteredDevice) bool { return d.DeviceKey == key })
	if len(devices) != 2 || index < 0 || devices[index].Revoked || devices[index].Name != "Old PC" {
		t.Fatal("unsigned labels changed signed device membership or status", devices)
	}
	offline := interruptEndpoint(f, "/authorization/v5/append")
	offline.Store(true)
	if _, err = two.handle(f.ctx, command{Op: "revoke", Args: args{Key: key}}); err == nil || err.Error() != "REVOCATION_PENDING" {
		t.Fatal(err)
	}
	reopened, err := loadVault(filepath.Dir(two.vault.path))
	ok(t, err)
	old := reopened.Accounts[f.origin+"|"+two.session.Member.ID]
	if old.PendingRevocation != key || !old.Denied[key] {
		t.Fatal("missing durable revocation")
	}
	offline.Store(false)
	ok(t, two.refreshAmbient(f.ctx))
	if two.account.PendingRevocation != "" || !two.auth.states[two.session.Device.AccountKey].Revoked[key] {
		t.Fatal("revocation was not confirmed by the signed snapshot")
	}
	_, err = two.handle(f.ctx, command{Op: "renameDevice", Args: args{Key: key, Name: "Archived PC"}})
	ok(t, err)
	registered, err := f.db.Devices(f.ctx, two.session.Member.ID)
	ok(t, err)
	if !slices.ContainsFunc(registered, func(d store.RegisteredDevice) bool { return d.DeviceKey == key && d.Name == "Archived PC" && d.Revoked }) {
		t.Fatal("renaming a permanently revoked device changed its binding or revocation")
	}
	if err = one.refreshAmbient(f.ctx); err == nil || err.Error() != "DEVICE_REVOKED" || !signedOutError(err) {
		t.Fatal("out-of-room revocation went undetected", err)
	}
	one.reset(f.ctx)
	if len(one.savedIssuers()) != 0 {
		t.Fatal("a revoked local identity was still offered for pairing")
	}
}

func TestResumeUsesConfirmedCandidateBeforeOldDevice(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	a := f.account(t, "Alder")
	old, _ := f.client(t)
	backup := f.enroll(t, old, a, false)
	recovered, _ := f.client(t)
	f.exchange(t, recovered, a, false)
	_, err := recovered.recover(f.ctx, backup, password, false)
	ok(t, err)
	candidate := recovered.account.Active
	old.account.Candidate = candidate
	ok(t, old.vault.save())
	old.reset(f.ctx)
	if f.exchange(t, old, a, false)["step"] != "signedIn" || old.account.Active.Device.Hash() != candidate.Device.Hash() || old.account.Candidate != nil {
		t.Fatal("did not resume the candidate")
	}
}

func TestPhoneClaimRetriesAndIgnoresSupersededAttempts(t *testing.T) {
	f := service(t, "ws://127.0.0.1:9000")
	a := f.account(t, "Willow")
	e, _ := f.client(t)
	start, err := e.begin(f.ctx, true)
	ok(t, err)
	id := start["id"].(string)
	if start["expires"] != e.flow.expires || id == "" {
		t.Fatal("missing countdown or attempt identifier")
	}
	c := command{Op: "pollPhone", Args: args{ID: id}}
	pollURL, err := url.Parse(e.conn.endpoints.DevicePollURL)
	ok(t, err)
	offline := interruptEndpoint(f, pollURL.Path)
	offline.Store(true)
	if _, err = e.handle(f.ctx, c); !temporarilyUnavailable(err) || e.flow.state != id {
		t.Fatal("transient poll ended the attempt", err)
	}
	offline.Store(false)
	pending, err := e.handle(f.ctx, c)
	ok(t, err)
	if pending.(obj)["step"] != "waiting" {
		t.Fatal("phone request prematurely completed")
	}
	ok(t, f.db.ApproveDeviceAuthorization(f.ctx, e.flow.requestID, a, a.CredentialJSON))
	claimed, err := e.handle(f.ctx, c)
	ok(t, err)
	if claimed.(obj)["step"] != "claimed" || e.session != nil || e.account != nil {
		t.Fatal("a poll activated a login before the initiating dialog accepted it")
	}
	_, err = e.handle(f.ctx, command{Op: "cancelLogin", Args: args{ID: id}})
	ok(t, err)
	newRequest, err := e.begin(f.ctx, true)
	ok(t, err)
	newID := newRequest["id"].(string)
	if _, err = e.handle(f.ctx, command{Op: "finishPhone", Args: args{ID: id}}); err == nil {
		t.Fatal("stale claimed login taken over by the new attempt")
	}
	_, err = e.handle(f.ctx, command{Op: "cancelLogin", Args: args{ID: id}})
	ok(t, err)
	if e.flow == nil || e.flow.state != newID || newID == id {
		t.Fatal("late cancellation removed the refreshed QR")
	}
	ok(t, f.db.ApproveDeviceAuthorization(f.ctx, e.flow.requestID, a, a.CredentialJSON))
	_, err = e.handle(f.ctx, command{Op: "pollPhone", Args: args{ID: newID}})
	ok(t, err)
	result, err := e.handle(f.ctx, command{Op: "finishPhone", Args: args{ID: newID}})
	ok(t, err)
	if result.(obj)["step"] != "backup" {
		t.Fatal("the current attempt did not proceed to account setup")
	}
}

func TestRestoredConnectionRegistrationAndDetailedErrors(t *testing.T) {
	f := service(t, "ws://127.0.0.1:9000")
	original, _ := f.client(t)
	v, err := loadVault(filepath.Dir(original.vault.path))
	ok(t, err)
	e := &engine{vault: v, local: true}
	saved, err := e.handle(f.ctx, command{Op: "restoreConnection"})
	ok(t, err)
	if saved.(obj)["origin"] != f.origin || e.conn.endpoints != original.conn.endpoints {
		t.Fatal("confirmed connection did not survive restart")
	}
	if _, err = (&engine{vault: v, local: false}).restoreConnection(); err == nil {
		t.Fatal("release accepted a development HTTP origin from storage")
	}
	configPath := "/v1/client-config"
	base, _ := f.mux.Handler(&http.Request{URL: &url.URL{Path: configPath}})
	change := ""
	f.mux.HandleFunc(configPath, func(w http.ResponseWriter, r *http.Request) {
		resp := httptest.NewRecorder()
		base.ServeHTTP(resp, r)
		var c map[string]any
		_ = json.Unmarshal(resp.Body.Bytes(), &c)
		if change == "api" {
			c["endpoints"].(map[string]any)["api_base_url"] = "http://127.0.0.1:29491"
		}
		if change == "group" {
			c["endpoints"].(map[string]any)["group_base_url"] = "https://groups.example.test/v1/group"
		}
		if change == "passkey" {
			c["passkey_origin"] = "http://127.0.0.1:29491"
			endpoints := c["endpoints"].(map[string]any)
			for k, v := range endpoints {
				if k != "health_url" && k != "api_base_url" && k != "group_base_url" {
					endpoints[k] = strings.Replace(v.(string), f.origin, "http://127.0.0.1:29491", 1)
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(c)
	})
	reg, err := e.handle(f.ctx, command{Op: "register"})
	ok(t, err)
	if reg.(obj)["url"] != e.conn.endpoints.RegistrationURL {
		t.Fatal("incorrect registration endpoint")
	}
	for _, origin := range []string{"api", "passkey", "group"} {
		change = origin
		if _, err = e.handle(f.ctx, command{Op: "register"}); err == nil || err.Error() != "SERVER_CONFIGURATION_CHANGED" {
			t.Fatal(origin, err)
		}
		if e.vault.Connection.Origin != f.origin || e.conn.endpoints != original.conn.endpoints {
			t.Fatal("failed discovery replaced confirmed connection")
		}
	}
	policy := store.ClientVersionPolicy{Platform: "windows", MinimumVersion: "2026.11.21", MinimumBuild: 7, LatestVersion: "2026.11.22", LatestBuild: 8}
	rejected := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "12")
		w.WriteHeader(403)
		_ = json.NewEncoder(w).Encode(obj{"error": obj{"code": "CLIENT_UPDATE_REQUIRED"}, "client_policy": policy})
	}))
	defer rejected.Close()
	_, err = request(f.ctx, "request", "GET", rejected.URL, nil, "", nil, nil, 8192)
	reply := clientErrorReply(41, err)
	if reply["minimumVersion"] != policy.MinimumVersion || reply["minimumBuild"] != 7 || reply["retryAfter"] != int64(12) {
		t.Fatal("reply lost server details", reply)
	}
	after := parseRetryAfter(time.Now().UTC().Add(20 * time.Second).Format(http.TimeFormat))
	if after < 18*time.Second || after > 20*time.Second || parseRetryAfter("invalid") != 0 || parseRetryAfter("-3") != 0 {
		t.Fatal("invalid Retry-After parsing", after)
	}
}

func TestVerificationPresentationTrustRetryAndRoomChange(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	me, _ := f.client(t)
	other, _ := f.client(t)
	f.enroll(t, me, f.account(t, "Pine"), false)
	f.enroll(t, other, f.account(t, "Cedar"), false)
	r := &activeRoom{media: &mediaSession{}}
	r.join.Identity = me.session.Identity
	peer := group.Member{Identity: other.session.Identity, Name: "Cedar", Binding: &identity.EntryBinding{Device: other.session.Device}}
	r.snap.Members = []group.Member{{Identity: r.join.Identity, Binding: &identity.EntryBinding{Device: me.session.Device}}, peer}
	v := &verification{ID: b64(random(32)), Peer: peer.Identity, Name: peer.Name, Step: "confirmed", Decimals: []int{1234, 2345, 3456}, deviceHash: peer.Binding.Device.Hash()}
	r.verification = v
	me.room = r
	defer func() { me.room = nil }()
	offline := interruptEndpoint(f, "/authorization/v5/append")
	offline.Store(true)
	ok(t, me.saveVerifiedTrust(f.ctx, r, &peer, false))
	if v.Step != "trustPending" || me.account.Pending == nil || len(v.Decimals) != 3 {
		t.Fatal("lost verified numbers or pending trust after network failure")
	}
	offline.Store(false)
	ok(t, me.verify(f.ctx, "retryTrust", peer.Identity, v.ID))
	if v.Step != "completed" || !me.trusted(peer) {
		t.Fatal("retry did not confirm trust")
	}
	ok(t, me.verify(f.ctx, "dismiss", peer.Identity, v.ID))
	if r.verification != nil {
		t.Fatal("completed verification could not be dismissed")
	}
	for _, action := range []string{"mismatch", "timedOut", "cancel"} {
		v.Step = "confirmed"
		r.verification = v
		ok(t, me.verify(f.ctx, action, peer.Identity, v.ID))
		if v.active() || r.verification == nil {
			t.Fatal("ended verification did not retain its outcome", action)
		}
	}
	v.Step = "compare"
	r.verificationChanged()
	if v.Step != "roomChanged" {
		t.Fatal("membership change lost the verification result")
	}
	data, err := json.Marshal(v)
	ok(t, err)
	if !bytes.Contains(data, []byte("roomChanged")) {
		t.Fatal("the reason was not exported for WinUI")
	}
	if !me.canRetryVerification(r) {
		t.Fatal("the same authorized device is still present")
	}
	if err := me.verify(f.ctx, "retry", peer.Identity, "superseded"); err == nil {
		t.Fatal("an old result restarted the current transaction")
	}
	r.snap.Members[1].Binding = r.snap.Members[0].Binding
	if me.canRetryVerification(r) || me.verify(f.ctx, "retry", peer.Identity, v.ID) == nil {
		t.Fatal("verification was transferable to a different device")
	}
	r.snap.Members = r.snap.Members[:1]
	if me.canRetryVerification(r) || me.verify(f.ctx, "retry", peer.Identity, v.ID) == nil {
		t.Fatal("a departed peer could restart verification")
	}
}

func TestBackgroundLoginMonitor(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	me, events := f.client(t)
	f.enroll(t, me, f.account(t, "Larch"), false)
	owner := me.session
	_, stale := me.handle(f.ctx, command{Op: "finishPhone", Args: args{ID: "previous-sign-in"}})
	if stale == nil || me.endLogin(f.ctx, owner, signedOutReason(stale)) {
		t.Fatal("an expired sign-in form ended the active login")
	}
	if signedOutError(&apiError{code: "IDENTITY_BLACKLISTED", status: 403}) {
		t.Fatal("rejected pairing credentials ended the issuer's business login")
	}
	endpoint := me.conn.api("v1/session")
	seq, err := owner.joinSequence(f.ctx, endpoint)
	ok(t, err)
	if seq != 0 {
		t.Fatal("checking an idle login reserved an admission")
	}
	offline := interruptEndpoint(f, "/authorization/v5/snapshot")
	offline.Store(true)
	me.watchLogin(f.ctx, 10*time.Millisecond)
	lifetime := me.loginLifetime
	started := make(chan struct{})
	f.mux.HandleFunc("GET /v1/me", func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	})
	go func() {
		select {
		case <-started:
			if err := f.db.RevokeClientCredential(f.ctx, owner.Credential); err != nil {
				t.Error(err)
			}
		case <-lifetime.Done():
		}
	}()
	_, err = me.handle(lifetime, command{Op: "profile"})
	if !errors.Is(err, context.Canceled) {
		t.Fatal("a slow profile request held the revoked login open", err)
	}
	select {
	case <-lifetime.Done():
		reason := context.Cause(lifetime).Error()
		if reason != "UNAUTHORIZED" {
			t.Fatal("unexpected sign-out", reason)
		}
		if me.endLogin(f.ctx, &session{}, reason) || me.session != owner {
			t.Fatal("a delayed result affected a newer login")
		}
		if !me.endLogin(f.ctx, owner, reason) || me.session != nil || me.account != nil {
			t.Fatal("revoked background login was retained")
		}
		select {
		case notice := <-events:
			if notice.name != "signedOut" || notice.data != "UNAUTHORIZED" {
				t.Fatal("missing localized sign-out reason", notice)
			}
		default:
			t.Fatal("WinUI did not receive the sign-out")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("monitor waited for a room, directory or authority refresh")
	}
}

func TestLoginMonitorTransientFailureCancellationAndExpiry(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch attempts.Add(1) {
		case 1:
			w.WriteHeader(http.StatusServiceUnavailable)
		case 2:
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprint(w, `{"error":{"code":"CLIENT_UPDATE_REQUIRED"}}`)
		case 3:
			fmt.Fprint(w, `{"join_sequence":3}`)
		default:
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprint(w, `{"error":{"code":"MEMBER_DISABLED"}}`)
		}
	}))
	defer srv.Close()
	s := &session{Expires: time.Now().Add(time.Minute).Unix(), Credential: "test-session"}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	if reason := s.watch(ctx, srv.URL, time.Millisecond); reason != "MEMBER_DISABLED" || attempts.Load() != 4 {
		t.Fatal("transient failure revoked login or disabled member stayed signed in", reason, attempts.Load())
	}
	blocked := make(chan struct{}, 2)
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		blocked <- struct{}{}
		<-r.Context().Done()
	}))
	defer slow.Close()
	ctx, stop := context.WithCancel(t.Context())
	outcome := make(chan string, 1)
	go func() { outcome <- s.watch(ctx, slow.URL, time.Minute) }()
	<-blocked
	stop()
	select {
	case reason := <-outcome:
		if reason != "" {
			t.Fatal("cancelling the monitor signed out a new login", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("retired login kept its pending request")
	}
	s.Expires = time.Now().Add(1500 * time.Millisecond).Unix()
	go func() { outcome <- s.watch(t.Context(), slow.URL, time.Minute) }()
	select {
	case reason := <-outcome:
		if reason != "CLIENT_LOGIN_EXPIRED" {
			t.Fatal("expired login lost its reason", reason)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("a slow request extended the local login lifetime")
	}
}
