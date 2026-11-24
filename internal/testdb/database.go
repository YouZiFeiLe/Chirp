// Package testdb creates an isolated, on-disk SQLite database per test.
package testdb

import (
	"database/sql"
	"net/url"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func Path(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "chirp.db")
}

// SeedRooms supplies explicit multi-room fixtures; production initializes only
// the default room. Call after store.Open has initialized the test schema.
func SeedRooms(t *testing.T, path string) {
	t.Helper()
	u := url.URL{Scheme: "file", Host: "localhost", Path: filepath.ToSlash(path), RawQuery: "_pragma=busy_timeout(10000)&_pragma=foreign_keys(ON)"}
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, id := range []string{"room-2", "room-3", "room-4", "room-5"} {
		if _, err := db.Exec("INSERT INTO room_settings(room_id,display_name) VALUES(?,?) ON CONFLICT(room_id) DO NOTHING", id, id); err != nil {
			t.Fatal(err)
		}
	}
}
