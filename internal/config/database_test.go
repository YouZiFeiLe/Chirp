package config

import (
	"path/filepath"
	"strings"
	"testing"
)

func setDatabaseEnv(t *testing.T) {
	t.Helper()
	t.Setenv("CHIRP_DATABASE_PATH", filepath.Join(t.TempDir(), "shared SQLite #?.db"))
}

func TestSharedDatabaseConfiguration(t *testing.T) {
	setDatabaseEnv(t)
	api, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(api.DatabasePath) || filepath.Base(api.DatabasePath) != "shared SQLite #?.db" {
		t.Fatal("database path was not preserved", api.DatabasePath)
	}
	t.Setenv("CHIRP_DATABASE_PATH", "")
	path, err := DatabasePath()
	want, _ := filepath.Abs("data/chirp.db")
	if err != nil || path != want {
		t.Fatal("default database path", path, err)
	}
}

func TestInvalidDatabaseConfiguration(t *testing.T) {
	for _, value := range []string{" ", ":memory:", "file:/tmp/chirp.db?mode=memory"} {
		t.Setenv("CHIRP_DATABASE_PATH", value)
		if _, err := DatabasePath(); err == nil || !strings.Contains(err.Error(), "CHIRP_DATABASE_PATH") {
			t.Fatal("invalid configuration was accepted", value, err)
		}
	}
}
