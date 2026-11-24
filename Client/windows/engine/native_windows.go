package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var dll = sync.OnceValues(func() (*windows.DLL, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	return windows.LoadDLL(filepath.Join(filepath.Dir(exe), "chirp_mls_native.dll"))
})

type native struct {
	mu                                              sync.Mutex
	handle                                          uintptr
	call, release, freeString, export, exportStaged *windows.Proc
}

func newNative(name string) (*native, error) {
	library, err := dll()
	if err != nil {
		return nil, err
	}
	var procs []*windows.Proc
	for _, symbol := range []string{"chirp_mls_new", "chirp_mls_call", "chirp_mls_free", "chirp_mls_string_free", "chirp_mls_media_key", "chirp_mls_staged_media_key"} {
		p, err := library.FindProc(symbol)
		if err != nil {
			return nil, err
		}
		procs = append(procs, p)
	}
	s, err := windows.BytePtrFromString(name)
	if err != nil {
		return nil, err
	}
	h, _, _ := procs[0].Call(uintptr(unsafe.Pointer(s)))
	runtime.KeepAlive(s)
	if h == 0 {
		return nil, errors.New("MLS initialization failed")
	}
	return &native{handle: h, call: procs[1], release: procs[2], freeString: procs[3], export: procs[4], exportStaged: procs[5]}, nil
}

func (n *native) request(body any, result any) (resultErr error) {
	if span := installationLog.begin(); span.generation != 0 {
		if object, ok := body.(obj); ok {
			op, _ := object["operation"].(string)
			if name := nativeLogNames[op]; name != "" {
				defer func() { installationLog.finish(span, logOp{"crypto", name}, resultErr, 0) }()
			}
		}
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.handle == 0 {
		return errors.New("MLS unavailable")
	}
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	data = append(data, 0)
	defer clear(data)
	ptr, _, _ := n.call.Call(n.handle, uintptr(unsafe.Pointer(&data[0])))
	runtime.KeepAlive(data)
	if ptr == 0 {
		return errors.New("MLS unavailable")
	}
	defer n.freeString.Call(ptr)
	// The ABI returns a borrowed C string in the pointer-sized result slot.
	cString := *(**byte)(unsafe.Pointer(&ptr))
	raw := []byte(windows.BytePtrToString(cString))
	defer clear(raw)
	var failure struct{ Error string }
	if err = json.Unmarshal(raw, &failure); err != nil {
		return err
	}
	if failure.Error != "" {
		return errors.New(failure.Error)
	}
	if result == nil {
		return nil
	}
	return json.Unmarshal(raw, result)
}
func (n *native) key(id string, staged bool) ([]byte, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.handle == 0 {
		return nil, errors.New("MLS unavailable")
	}
	name, err := windows.BytePtrFromString(id)
	if err != nil {
		return nil, err
	}
	key := make([]byte, 32)
	export := n.export
	if staged {
		export = n.exportStaged
	}
	code, _, _ := export.Call(n.handle, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&key[0])))
	runtime.KeepAlive(name)
	if int32(code) != 0 {
		clear(key)
		return nil, errors.New("MLS key expired")
	}
	return key, nil
}
func (n *native) keyDeadline(staged bool) (int64, error) {
	operation := "lifetime"
	if staged {
		operation = "staged_lifetime"
	}
	started := ticks()
	var result struct{ Milliseconds string }
	if err := n.request(obj{"operation": operation}, &result); err != nil {
		return 0, err
	}
	ms, err := strconv.ParseInt(result.Milliseconds, 10, 64)
	if err != nil || ms <= 0 || ms > 120000 {
		return 0, errGroupUpdate
	}
	return started + ms, nil
}
func (n *native) close() {
	if n == nil {
		return
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.handle != 0 {
		n.release.Call(n.handle)
		n.handle = 0
	}
}

var interruptTime = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetTickCount64")

func ticks() int64 {
	value, _, _ := interruptTime.Call()
	return int64(value)
}
