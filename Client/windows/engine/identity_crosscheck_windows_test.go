package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestPairingRequestClockWithGoSwiftVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("internal", "identity", "testdata", "device-pairing-v1.json"))
	ok(t, err)
	var vector struct{ Request identity.DevicePairingRequest }
	ok(t, json.Unmarshal(raw, &vector))
	deadline := time.Unix(vector.Request.ExpiresAt, 0)
	for _, test := range []struct {
		name   string
		offset time.Duration
		want   string
	}{
		{"before the window", -identity.DevicePairingLifetime - time.Second, "PAIRING_CLOCK_MISMATCH"},
		{"start of the window", -identity.DevicePairingLifetime, ""},
		{"last valid second", -time.Second, ""},
		{"at the deadline", 0, "DEVICE_PAIRING_EXPIRED"},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := validatePairingRequest(vector.Request, deadline.Add(test.offset))
			if test.want == "" {
				ok(t, err)
			} else if err == nil || err.Error() != test.want {
				t.Fatalf("want %s, got %v", test.want, err)
			}
		})
	}
	changed := vector.Request
	changed.ExpiresAt++
	for _, when := range []time.Time{deadline, deadline.Add(time.Minute)} {
		if err := validatePairingRequest(changed, when); err != errInvalidPairingRequest {
			t.Fatalf("expected an invalid request for a changed signed deadline, got %v", err)
		}
	}
}

func TestRecoveryExportAndInterruptedSetup(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	e, _ := f.client(t)
	for _, resume := range []bool{false, true} {
		name := "NoVerification"
		if resume {
			name = "Restored"
		}
		t.Run(name, func(t *testing.T) {
			a := f.account(t, name)
			f.exchange(t, e, a, false)
			b, err := e.backup(password)
			ok(t, err)
			arg := args{ID: e.flow.state, Key: b["key"].(string)}
			call := func(op string, args args) (any, error) {
				return e.handle(f.ctx, command{Op: op, Args: args})
			}
			if _, err := call("finishBackup", arg); err == nil || e.session != nil {
				t.Fatal("activated before export")
			}
			wrong := arg
			wrong.ID += "old"
			wrong.Enabled = true
			if _, err := call("backupExported", wrong); err == nil || e.account.BackupExported {
				t.Fatal("accepted export from an old login")
			}
			wrong.ID, wrong.Key = arg.ID, "wrong"
			if _, err := call("backupExported", wrong); err == nil || e.account.BackupExported {
				t.Fatal("accepted export for a different recovery file")
			}
			arg.Enabled = true
			_, err = call("backupExported", arg)
			ok(t, err)
			if resume {
				previous := e.account.Candidate.Device
				e.account.Candidate = nil
				ok(t, e.vault.save())
				e.vault, err = loadVault(filepath.Dir(e.vault.path))
				ok(t, err)
				b = f.exchange(t, e, a, false)
				if b["step"] != "resumeBackup" || b["exported"] != true {
					t.Fatal("lost interrupted export", b["step"])
				}
				arg.ID = e.flow.state
				if _, err := call("finishBackup", arg); err == nil {
					t.Fatal("a new login skipped unlocking the pending file")
				}
				arg.Password = "incorrect"
				if _, err := call("unlockBackup", arg); err == nil || e.account.Candidate != nil {
					t.Fatal("incorrect password reconstructed a device")
				}
				arg.Password = password
				_, err = call("unlockBackup", arg)
				ok(t, err)
				if e.account.Candidate.Device.AccountKey != previous.AccountKey || e.account.Candidate.Device.LeafKey() == previous.LeafKey() {
					t.Fatal("did not rebuild the missing device under the saved root")
				}
				n, err := newNative("recovery-copy-test")
				ok(t, err)
				defer n.close()
				var result struct{ Payload string }
				ok(t, n.request(obj{"operation": "security", "security": obj{"action": "decrypt", "password": password, "file": b64(e.account.Backup)}}, &result))
				var encrypted struct{ File []byte }
				ok(t, n.request(obj{"operation": "security", "security": obj{"action": "encrypt", "password": password, "payload": result.Payload}}, &encrypted))
				if bytes.Equal(encrypted.File, e.account.Backup) {
					t.Fatal("test requires different encrypted files for the same account root")
				}
				arg.File = encrypted.File
				_, err = call("verifyBackup", arg)
				ok(t, err)
				if e.account.BackupConfirmed || e.session != nil {
					t.Fatal("optional verification activated the device")
				}
			}
			res, err := call("finishBackup", arg)
			ok(t, err)
			if res.(obj)["step"] != "signedIn" || e.account.Backup != nil {
				t.Fatal("confirmed export did not finish activation")
			}
			e.reset(f.ctx)
		})
	}
}

func TestRecoveryFileValidatesAppleMetadata(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("internal", "identity", "testdata", "recovery-v1.json"))
	ok(t, err)
	var vector struct{ Payload string }
	ok(t, json.Unmarshal(raw, &vector))
	var valid recoveryPayload
	ok(t, json.Unmarshal([]byte(vector.Payload), &valid))
	key, err := valid.rootKey(valid.Origin, valid.Account, valid.Root)
	ok(t, err)
	clear(key)
	for name, change := range map[string]func(*recoveryPayload){
		"version":     func(v *recoveryPayload) { v.Version++ },
		"algorithm":   func(v *recoveryPayload) { v.Algorithm = "other" },
		"protocol":    func(v *recoveryPayload) { v.Protocol = "" },
		"platform":    func(v *recoveryPayload) { v.Platform = "other" },
		"name":        func(v *recoveryPayload) { v.Username = nil },
		"UTC":         func(v *recoveryPayload) { v.Created = "2026-11-19T04:10:00+08:00" },
		"date":        func(v *recoveryPayload) { v.Created = "badZ" },
		"seed":        func(v *recoveryPayload) { v.Seed = b64(random(ed25519.SeedSize)) },
		"origin path": func(v *recoveryPayload) { v.Origin += "/" },
	} {
		v := valid
		change(&v)
		if _, err := v.rootKey(v.Origin, valid.Account, valid.Root); err == nil {
			t.Error("accepted invalid recovery metadata", name)
		}
	}
}

func TestDiscoveryEditsInvalidateLiveLoginAndStagedAddress(t *testing.T) {
	first := service(t, "ws://127.0.0.1:9000")
	second := service(t, "ws://127.0.0.1:9000")
	e, _ := first.client(t)
	_, err := e.begin(first.ctx, false)
	ok(t, err)
	call := func(op string, a args) (any, error) { return e.handle(first.ctx, command{Op: op, Args: a}) }
	_, err = call("invalidateConnection", args{})
	ok(t, err)
	if e.conn != nil || e.flow != nil {
		t.Fatal("edited server address retained a live login")
	}
	_, err = call("discover", args{Address: second.origin, Action: "stage", ID: "check-1"})
	ok(t, err)
	if e.conn != nil || e.vault.Connection.Origin != first.origin {
		t.Fatal("unconfirmed discovery replaced the saved server")
	}
	_, err = call("invalidateConnection", args{})
	ok(t, err)
	if _, err = call("confirmConnection", args{ID: "check-1"}); err == nil {
		t.Fatal("late discovery accepted after address edit")
	}
	_, err = call("restoreConnection", args{})
	ok(t, err)
	if e.conn.origin != first.origin {
		t.Fatal("restart lost the last confirmed address")
	}
	_, err = call("discover", args{Address: second.origin, Action: "stage", ID: "check-2"})
	ok(t, err)
	_, err = call("confirmConnection", args{ID: "check-2"})
	ok(t, err)
	reopened, err := loadVault(filepath.Dir(e.vault.path))
	ok(t, err)
	if reopened.Connection.Origin != second.origin {
		t.Fatal("accepted address was not persisted")
	}
	reopened.Connection.Endpoints.RegistrationURL = first.origin + "/register"
	if _, err := (&engine{vault: reopened, local: true}).restoreConnection(); err == nil {
		t.Fatal("restored an authentication endpoint on a different origin")
	}
	minimum := store.ClientVersionPolicy{Platform: "windows", MinimumVersion: "2027.1.1", LatestVersion: "2027.1.1", MinimumBuild: 1, LatestBuild: 1}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(obj{"service": "chirp", "protocol_version": 5, "client_policy": minimum, "endpoints": 42})
	}))
	defer server.Close()
	_, err = detect(first.ctx, server.URL, true)
	if err == nil || err.Error() != "CLIENT_UPDATE_REQUIRED" {
		t.Fatal("a newer configuration shape hid the mandatory update", err)
	}
}

func TestOriginWideBansCheckpointsAndSignedFriendNames(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	e, _ := f.client(t)
	f.enroll(t, e, f.account(t, "Aspen"), false)
	firstID, root := e.session.Member.ID, e.session.Device.AccountKey
	firstLeaf := e.session.Device.LeafKey()
	peerRoot, peerDevice := b64(random(32)), b64(random(32))
	ok(t, e.social(f.ctx, "friend", "member_peer", peerRoot, "", "Signed name"))
	ok(t, e.social(f.ctx, "trust", "member_peer", peerRoot, peerDevice, "Directory name"))
	if len(e.auth.friends) != 1 || e.auth.friends[0].Name != "Signed name" || !slices.Contains(e.auth.friends[0].Devices, peerDevice) {
		t.Fatal("device verification replaced the signed friend name")
	}
	head := e.account.Heads[root]
	e.reset(f.ctx)
	f.enroll(t, e, f.account(t, "Spruce"), false)
	previous, err := e.vault.knownHead(f.origin, root)
	ok(t, err)
	if head.Version < 3 || previous != head {
		t.Fatal("a different account lost the previously verified service checkpoint")
	}
	ban := store.BlacklistEntry{Sequence: 1, Kind: "device", Subject: firstLeaf, AccountID: firstID, AccountKey: root}
	f.mux.HandleFunc("/v1/identity/blacklist", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]store.BlacklistEntry{ban})
	})
	_, err = e.handle(f.ctx, command{Op: "blacklist"})
	ok(t, err)
	changed := ban
	changed.Subject = peerDevice
	if e.vault.acceptBlacklist(f.origin, []store.BlacklistEntry{changed, changed}) || e.vault.acceptBlacklist(f.origin, []store.BlacklistEntry{changed}) {
		t.Fatal("accepted conflicting or duplicated permanent blacklist records")
	}
	reopened, err := loadVault(filepath.Dir(e.vault.path))
	ok(t, err)
	e.vault = reopened
	if !e.blocked(firstID, root, firstLeaf) || e.savedIssuer(f.origin+"|"+firstID) != nil {
		t.Fatal("other account or signed-out pairing ignored an observed server ban")
	}
	e.conn = nil
	identities, err := e.handle(f.ctx, command{Op: "savedAccounts"})
	ok(t, err)
	if view := identities.([]obj); len(view) != 2 || !slices.ContainsFunc(view, func(v obj) bool {
		return v["id"] == firstID && v["root"] == root && v["key"] == firstLeaf && v["canApprove"] == false
	}) {
		t.Fatal("saved fingerprints disappeared without an active server connection")
	}
	_, err = e.restoreConnection()
	ok(t, err)
	offline := interruptEndpoint(f, "/authorization/v5/snapshot")
	offline.Store(true)
	list, err := e.handle(f.ctx, command{Op: "blacklist"})
	ok(t, err)
	if !slices.Equal(list.([]store.BlacklistEntry), []store.BlacklistEntry{ban}) {
		t.Fatal("lost cached blacklist while offline")
	}
}

func TestSASSignalIDsDeduplicatedPerAdmission(t *testing.T) {
	r := &activeRoom{}
	id := b64(random(32))
	if !r.acceptSignal(id) || r.acceptSignal(id) || !new(activeRoom).acceptSignal(id) {
		t.Fatal("a signed signal must be applied only once per admission")
	}
}

func TestPairingWaitsForTheCurrentWindowToAccept(t *testing.T) {
	requireNative(t)
	f := service(t, "ws://127.0.0.1:9000")
	old, _ := f.client(t)
	account := f.account(t, "Hickory")
	f.enroll(t, old, account, false)
	for _, finish := range []bool{false, true} {
		fresh, _ := f.client(t)
		f.exchange(t, fresh, account, false)
		call := func(e *engine, op string, a args) obj {
			t.Helper()
			result, err := e.handle(f.ctx, command{Op: op, Args: a})
			ok(t, err)
			state, _ := result.(obj)
			return state
		}
		begin := call(fresh, "pairNew", args{Action: "deferLogin"})
		initialKey := fresh.pairing.req.DeviceKey
		call(fresh, "pairCancel", args{ID: begin["id"].(string)})
		begin = call(fresh, "pairNew", args{Action: "deferLogin"})
		if fresh.pairing.req.DeviceKey != initialKey {
			t.Fatal("restarting this unfinished pairing replaced its pending device key")
		}
		id := begin["id"].(string)
		call(old, "pairOld", args{Code: begin["code"].(string), Action: "import"})
		digits := call(fresh, "pairPoll", args{ID: id})["digits"].([]int)
		call(old, "pairPoll", args{})
		call(old, "pairCheckCode", args{Code: fmt.Sprintf("%04d%04d%04d", digits[0], digits[1], digits[2])})
		call(fresh, "pairConfirm", args{ID: id})
		call(old, "pairConfirm", args{Enabled: true})
		result := call(fresh, "pairPoll", args{ID: id})
		if result["step"] != "paired" || fresh.session != nil || fresh.account.Candidate != nil {
			t.Fatal("late pairing response activated the device before its window accepted")
		}
		if finish {
			result = call(fresh, "finishPair", args{ID: id})
			if result["step"] != "signedIn" || fresh.session == nil {
				t.Fatal("current pairing window could not complete the activation")
			}
		} else {
			call(fresh, "pairCancel", args{ID: id})
			_, err := fresh.handle(f.ctx, command{Op: "finishPair", Args: args{ID: id}})
			if err == nil || fresh.session != nil || fresh.account.Candidate != nil {
				t.Fatal("closing a pairing sheet accepted a delayed approval")
			}
		}
	}
}
