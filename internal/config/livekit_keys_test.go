package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestComposeLiveKitKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "keys.json")
	setDatabaseEnv(t)
	t.Setenv("LIVEKIT_API_KEY", "chirp")
	t.Setenv("LIVEKIT_API_SECRET", "")
	t.Setenv("CHIRP_LIVEKIT_KEYS_FILE", path)

	// Two simultaneous starts must use the same complete key map.
	type result struct {
		secret string
		err    error
	}
	starts := make(chan result, 2)
	for range 2 {
		go func() {
			cfg, err := Load()
			starts <- result{cfg.LiveKitAPISecret, err}
		}()
	}
	first, second := <-starts, <-starts
	if first.err != nil || second.err != nil || len(first.secret) != 64 || first.secret != second.secret {
		t.Fatalf("concurrent starts did not share a key: %v, %v", first.err, second.err)
	}
	data, err := os.ReadFile(path)
	var keys map[string]string
	if err != nil || json.Unmarshal(data, &keys) != nil || keys["chirp"] != first.secret {
		t.Fatal("the persisted LiveKit key map differs from the app credential")
	}
	if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(); err == nil {
		t.Fatal("an invalid existing key file was accepted")
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "{}" {
		t.Fatal("an invalid existing key file was replaced")
	}
}
