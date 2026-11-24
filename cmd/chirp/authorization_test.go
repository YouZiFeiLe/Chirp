package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestAuthorizationMaintenanceUsesUnifiedBinaryWithoutMediaConfig(t *testing.T) {
	t.Setenv("LIVEKIT_API_SECRET", "")
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "not-required-to-export-public-key")
	key := filepath.Join(t.TempDir(), "key")
	var output bytes.Buffer
	if err := run([]string{"authorization", "-generate-key", "-key-file", key}, &output); err != nil {
		t.Fatal(err)
	}
	if public, err := base64.StdEncoding.DecodeString(output.String()[:output.Len()-1]); err != nil || len(public) != 32 {
		t.Fatal("invalid public key output", err)
	}
	before, err := os.ReadFile(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"authorization", "-generate-key", "-key-file", key}, &output); err == nil {
		t.Fatal("existing key replaced")
	}
	after, _ := os.ReadFile(key)
	if !bytes.Equal(before, after) {
		t.Fatal("existing key changed")
	}
	output.Reset()
	t.Setenv("CHIRP_AUTHORIZATION_KEY_FILE", key)
	args := []string{"authorization"}
	if err := run(append(args, "-export-trust"), &output); err != nil {
		t.Fatal(err)
	}
	pin := filepath.Join(t.TempDir(), "trust.json")
	if err := os.WriteFile(pin, output.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(append(args, "-verify-trust", pin), &output); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"authorization"}, {"authorization", "-generate-key", "-export-trust"}, {"authorization", "serve"}} {
		if err := run(args, &output); err == nil {
			t.Fatal("invalid authorization command accepted", args)
		}
	}
}
