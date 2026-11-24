package config

import (
	"fmt"
	"path/filepath"
	"strings"
)

func authorizationPaths(database string) (string, string, error) {
	paths := []string{
		env("CHIRP_AUTHORIZATION_DATABASE_PATH", filepath.Join(filepath.Dir(database), "authorization.db")),
		env("CHIRP_AUTHORIZATION_KEY_FILE", filepath.Join(filepath.Dir(database), "authorization-key")),
	}
	for i, path := range paths {
		if strings.TrimSpace(path) == "" || strings.ContainsRune(path, '\x00') || path == ":memory:" || strings.HasPrefix(path, "file:") {
			return "", "", fmt.Errorf("authorization database and key must be local file paths")
		}
		absolute, err := filepath.Abs(path)
		if err != nil {
			return "", "", err
		}
		paths[i] = absolute
	}
	if paths[0] == database || paths[1] == database || paths[0] == paths[1] {
		return "", "", fmt.Errorf("business database, authorization database and signing key must be separate files")
	}
	return paths[0], paths[1], nil
}
