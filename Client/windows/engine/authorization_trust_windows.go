package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

// The sole trust input is installed beside the protocol executable. Discovery
// supplies connection information and never selects a snapshot verification key.
func bundledAuthorizationKey(applicationDir string) (string, error) {
	file, err := os.Open(filepath.Join(applicationDir, "AuthorizationTrust.json"))
	if err != nil {
		return "", err
	}
	defer file.Close()
	const limit = 65536
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return "", err
	}
	if len(data) > limit {
		return "", invalid
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	open, err := decoder.Token()
	if err != nil || open != json.Delim('{') {
		return "", invalid
	}
	name, err := decoder.Token()
	if err != nil || name != "public_key" {
		return "", invalid
	}
	var key string
	if err := decoder.Decode(&key); err != nil || decoder.More() {
		return "", invalid
	}
	if _, err := decoder.Token(); err != nil {
		return "", invalid
	}
	if _, err := decoder.Token(); err != io.EOF {
		return "", invalid
	}
	if _, valid := identity.Bytes(key, ed25519.PublicKeySize); !valid {
		return "", invalid
	}
	return key, nil
}

func (c *connection) authorizationEndpoint(operation string) string {
	origin := c.origin
	if strings.HasPrefix(origin, "https://") {
		origin = strings.TrimSuffix(origin, ":443")
	} else if strings.HasPrefix(origin, "http://") {
		origin = strings.TrimSuffix(origin, ":80")
	}
	return origin + "/authorization/v5/" + operation
}

func verifiedSnapshot(envelope authorization.Envelope, key string, req authorization.SnapshotRequest) (authorization.Snapshot, error) {
	var snap authorization.Snapshot
	raw, err := base64.StdEncoding.Strict().DecodeString(envelope.Payload)
	if err != nil || len(raw) > 6<<20 || b64(raw) != envelope.Payload ||
		!identity.Verify(key, envelope.Signature, authorization.SnapshotMessage(req.Origin, req.Nonce, raw)) {
		return snap, invalid
	}
	if json.Unmarshal(raw, &snap) != nil || snap.Protocol != 5 || snap.Origin != req.Origin || snap.Nonce != req.Nonce ||
		snap.IssuedAt <= 0 || len(snap.Accounts) != len(req.Roots) {
		return snap, invalid
	}
	return snap, nil
}
