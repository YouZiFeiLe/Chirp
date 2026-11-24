package identity

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestDevicePairingGoSwiftSignatureVector(t *testing.T) {
	data, err := os.ReadFile("testdata/device-pairing-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Request        DevicePairingRequest `json:"request"`
		Action         DevicePairingAction  `json:"action"`
		Context        string               `json:"context"`
		RequestMessage string               `json:"request_message"`
		RequestDigest  string               `json:"request_digest"`
		ActionMessage  string               `json:"action_message"`
	}
	if err = json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1700000010, 0)
	if v.Request.Validate(now) != nil || v.Action.Validate(v.Request, now) != nil {
		t.Fatal("fixture signatures rejected")
	}
	if v.Request.Context() != v.Context || v.Request.Hash() != v.RequestDigest || base64.StdEncoding.EncodeToString(v.Request.Message()) != v.RequestMessage || base64.StdEncoding.EncodeToString(v.Action.Message()) != v.ActionMessage {
		t.Fatal("Go/Swift signing format changed")
	}
	for _, change := range []string{"origin", "account", "root", "device", "nonce", "commitment", "expiry"} {
		t.Run(change, func(t *testing.T) {
			r := v.Request
			switch change {
			case "origin":
				r.Origin = "https://other.test:443"
			case "account":
				r.AccountID = "other-account"
			case "root":
				r.AccountKey = Hash([]byte("another root"))
			case "device":
				r.DeviceKey = Hash([]byte("another device"))
			case "nonce":
				r.Nonce = Hash([]byte("another nonce"))
			case "commitment":
				r.Commitment = Hash([]byte("another commitment"))
			case "expiry":
				r.ExpiresAt++
			}
			if r.Validate(now) == nil {
				t.Fatal("changed signed field accepted")
			}
		})
	}
}
