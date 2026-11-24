package config

import "testing"

func TestLogServerIsOptionalAndRequiresAnExplicitValidAddress(t *testing.T) {
	t.Setenv("CHIRP_LOG_SERVER_ENABLED", "")
	t.Setenv("CHIRP_LOG_SERVER_URL", "invalid-but-unused")
	if enabled, address, err := LogServer(); err != nil || enabled || address != "" {
		t.Fatal("remote logging enabled by default", enabled, address, err)
	}
	t.Setenv("CHIRP_LOG_SERVER_ENABLED", "true")
	for _, raw := range []string{"", "file:///tmp/log", "https://", "https://user:secret@logs.test", "https://logs.test?token=secret", "https://logs.test?", "https://logs.test#", "https://logs.test/#fragment", "https://logs.test:0", "https://logs.test:65536"} {
		t.Setenv("CHIRP_LOG_SERVER_URL", raw)
		if _, _, err := LogServer(); err == nil {
			t.Fatalf("invalid log server accepted: %q", raw)
		}
	}
	for raw, want := range map[string]string{"https://logs.youzifeile.cn/": "https://logs.youzifeile.cn", "http://127.0.0.1:9428/": "http://127.0.0.1:9428", "https://logs.test/prefix/": "https://logs.test/prefix"} {
		t.Setenv("CHIRP_LOG_SERVER_URL", raw)
		if enabled, address, err := LogServer(); err != nil || !enabled || address != want {
			t.Fatal("valid server rejected", enabled, address, err)
		}
	}
	t.Setenv("CHIRP_LOG_SERVER_ENABLED", "perhaps")
	if _, _, err := LogServer(); err == nil {
		t.Fatal("invalid switch accepted")
	}
}
