package config

import (
	"errors"
	"path/filepath"
	"strings"
)

// The unified application and its local CLI share this database path.
func DatabasePath() (string, error) {
	path := env("CHIRP_DATABASE_PATH", "data/chirp.db")
	if strings.TrimSpace(path) == "" || strings.ContainsRune(path, '\x00') || path == ":memory:" || strings.HasPrefix(path, "file:") {
		return "", errors.New("CHIRP_DATABASE_PATH must be a local database file path, not a SQLite URI or in-memory database")
	}
	return filepath.Abs(path)
}
