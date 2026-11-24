package testfs

import (
	"errors"
	"os"
	"runtime"
	"syscall"
	"testing"
)

const windowsPrivilegeNotHeld = syscall.Errno(1314)

func Symlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		if runtime.GOOS == "windows" && errors.Is(err, windowsPrivilegeNotHeld) {
			t.Skip("Windows did not grant the privilege to create symbolic links")
		}
		t.Fatal(err)
	}
}
