package authorization

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestSeedFileIsOwnerOnlyAndRegular(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "key")
	data := []byte(base64.StdEncoding.EncodeToString(make([]byte, 32)))
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, mode := range []os.FileMode{0400, 0600, 0644, 0640, 0444, 0700} {
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		_, err := ReadKeyFile(path)
		if (err == nil) != (mode == 0400 || mode == 0600) {
			t.Errorf("mode %o: %v", mode, err)
		}
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	link := path + ".link"
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKeyFile(link); err == nil {
		t.Fatal("symlink accepted")
	}
	if err := os.WriteFile(path, append(data, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadKeyFile(path); err == nil {
		t.Fatal("noncanonical seed accepted")
	}
}
