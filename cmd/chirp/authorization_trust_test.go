package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestTrustExportContainsOnlyPublicKeyAndPinMustAgree(t *testing.T) {
	public := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize)).Public().(ed25519.PublicKey)
	var output bytes.Buffer
	if err := manageTrust(public, "", true, &output); err != nil {
		t.Fatal(err)
	}
	var entry map[string]string
	if err := json.Unmarshal(output.Bytes(), &entry); err != nil || len(entry) != 1 || entry["public_key"] != base64.StdEncoding.EncodeToString(public) {
		t.Fatalf("public export must contain only the public key: %v", err)
	}
	path := filepath.Join(t.TempDir(), "trust.json")
	for _, test := range []struct {
		name string
		data string
		ok   bool
	}{
		{"matching", output.String(), true},
		{"missing", "{}", false},
		{"list", "[" + output.String() + "]", false},
		{"other key", `{"public_key":"invalid"}`, false},
		{"trailing", output.String() + "{}", false},
		{"unknown fields", `{"seed":"must not be accepted"}`, false},
		{"address fields", `{"public_key":"` + entry["public_key"] + `","origin":"https://untrusted.test"}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(test.data), 0600); err != nil {
				t.Fatal(err)
			}
			err := manageTrust(public, path, false, &bytes.Buffer{})
			if (err == nil) != test.ok {
				t.Fatalf("verification error: %v", err)
			}
		})
	}
}
