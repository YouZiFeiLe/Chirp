package identity_test

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
	"time"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

// Each implementation verifies its local copy of the immutable V5 vector.
// Apple project checks compare the copies without coupling server tests to Client/.
func TestV5CrossLanguageVectors(t *testing.T) {
	data, err := os.ReadFile("testdata/v5.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Now              int64
		Device           identity.Device
		Policy           identity.RoomPolicy
		Binding          identity.EntryBinding
		Offer            identity.RoundProof
		Ready            identity.ReadyProof
		Login            identity.LoginProof
		Messages, Hashes map[string]string
	}
	if err = json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(v.Now, 0)
	if v.Device.Validate(now) != nil || v.Policy.Validate(now) != nil || v.Binding.Validate(v.Policy, now) != nil || v.Login.Validate("chirp-apple", "authorization-vector", "pkce-verifier-vector", now) != nil {
		t.Fatal("vector signature invalid")
	}
	// Shared with the native login resumption integration guide.
	resume := identity.ResumptionMessage("https://keys.example.test:443", "android", "member_fixture.login_fixture",
		"resume-v1_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8", v.Device)
	if got := identity.Hash(resume); got != "nOrZz5uNpOPV7sgnW/wGZ26KFdcd0z3Z4+6I2reXpr8=" {
		t.Fatalf("login resumption vector digest = %s", got)
	}
	for name, message := range map[string][]byte{"certificate": v.Device.Certificates[0].Message(), "policy": v.Policy.Message(), "binding": v.Binding.Message(), "offer": v.Offer.Message(), "ready": v.Ready.Message(), "login": v.Login.Message("chirp-apple", "authorization-vector", "pkce-verifier-vector")} {
		if base64.StdEncoding.EncodeToString(message) != v.Messages[name] {
			t.Fatal("canonical message differs", name)
		}
	}
	for name, hash := range map[string]string{"certificate": v.Device.Certificates[0].Hash(), "device": v.Device.Hash(), "policy": v.Policy.Hash(), "binding": v.Binding.Hash(), "roster": identity.RosterHash([]identity.EntryBinding{v.Binding})} {
		if hash != v.Hashes[name] {
			t.Fatal("canonical hash differs", name)
		}
	}
	if !identity.Verify(v.Binding.MLSKey, v.Offer.Signature, v.Offer.Message()) || !identity.Verify(v.Binding.MLSKey, v.Ready.Signature, v.Ready.Message()) {
		t.Fatal("round proof invalid")
	}
}
