package config

import (
	"path/filepath"
	"testing"
)

func TestAuthorizationPathsPreserveSeparateState(t *testing.T) {
	setDatabaseEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AuthorizationDatabasePath != filepath.Join(filepath.Dir(cfg.DatabasePath), "authorization.db") || cfg.AuthorizationKeyFile != filepath.Join(filepath.Dir(cfg.DatabasePath), "authorization-key") {
		t.Fatal("unexpected authorization file defaults")
	}
	for _, key := range []string{"CHIRP_AUTHORIZATION_DATABASE_PATH", "CHIRP_AUTHORIZATION_KEY_FILE"} {
		for _, path := range []string{":memory:", "file:authorization.db", " ", cfg.DatabasePath} {
			t.Run(key+"/"+path, func(t *testing.T) {
				t.Setenv(key, path)
				if _, err := Load(); err == nil {
					t.Fatal("unsafe or overlapping authorization path accepted")
				}
			})
		}
	}
}
