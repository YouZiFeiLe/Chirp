package authorization

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/identity"
)

// GenerateKeyFile creates a signing seed exclusively. Existing keys are never replaced.
func GenerateKeyFile(path string) (ed25519.PublicKey, error) {
	public, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	_, writeErr := file.WriteString(base64.StdEncoding.EncodeToString(key.Seed()))
	syncErr := file.Sync()
	closeErr := file.Close()
	return public, errors.Join(writeErr, syncErr, closeErr)
}

// ReadKeyFile requires an owner-only, canonical Ed25519 seed. Startup never generates keys.
func ReadKeyFile(path string) (ed25519.PrivateKey, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || (info.Mode().Perm() != 0400 && info.Mode().Perm() != 0600) || info.Size() != 44 {
		return nil, errors.New("key file must be a 44-byte regular file readable only by its owner (0400 or 0600)")
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	defer clear(encoded)
	seed, ok := identity.Bytes(string(encoded), ed25519.SeedSize)
	if !ok {
		return nil, errors.New("key file must contain one canonical base64 Ed25519 seed without a newline")
	}
	defer clear(seed)
	return ed25519.NewKeyFromSeed(seed), nil
}
