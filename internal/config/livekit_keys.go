package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// The public Compose stack shares one JSON key map with LiveKit's YAML key_file reader.
func liveKitFileSecret(path, key string) (string, error) {
	if key == "" {
		return "", errors.New("LIVEKIT_API_KEY is required for the LiveKit key file")
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := createLiveKitKeyFile(path, key); err != nil {
			return "", err
		}
		data, err = os.ReadFile(path)
	}
	if err != nil {
		return "", fmt.Errorf("read LiveKit key file: %w", err)
	}
	var keys map[string]string
	if json.Unmarshal(data, &keys) != nil || len(keys[key]) < 32 {
		return "", errors.New("LiveKit key file needs a secret of at least 32 bytes for the configured API key")
	}
	return keys[key], nil
}

func createLiveKitKeyFile(path, key string) error {
	var secret [32]byte
	rand.Read(secret[:])
	file, err := os.CreateTemp(filepath.Dir(path), ".livekit-keys-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	writeErr := json.NewEncoder(file).Encode(map[string]string{key: hex.EncodeToString(secret[:])})
	if err := errors.Join(writeErr, file.Sync(), file.Close()); err != nil {
		return err
	}
	// Concurrent starts may race. Publish only a complete file and reuse the winner.
	if err := os.Link(file.Name(), path); err != nil && !errors.Is(err, os.ErrExist) {
		return fmt.Errorf("install LiveKit key file: %w", err)
	}
	return nil
}
