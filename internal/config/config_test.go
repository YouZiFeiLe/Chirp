package config

import "testing"

func TestPublicPasskeyOrigin(t *testing.T) {
	for _, tc := range []struct{ raw, want string }{
		{"https://keys.example.test", "https://keys.example.test"},
		{"https://keys.example.test:8443/", "https://keys.example.test:8443"},
		{"https://KEYS.example.test:443/", "https://keys.example.test"},
		{"http://localhost:18117", "http://localhost:18117"},
	} {
		if got, err := PublicPasskeyOrigin(tc.raw); err != nil || got != tc.want {
			t.Fatalf("origin %q: %q %v", tc.raw, got, err)
		}
	}
	for _, raw := range []string{"", "http://keys.example.test", "http://passkey:18117", "https://*.example.test", "https://user:secret@keys.example.test", "https://keys.example.test/api", "https://keys.example.test?", "https://keys.example.test#", "https://keys.example.test:65536", "https://keys.example.test:0"} {
		if _, err := PublicPasskeyOrigin(raw); err == nil {
			t.Fatalf("unsafe origin accepted: %q", raw)
		}
	}
}

func TestUnifiedPublicOrigin(t *testing.T) {
	setDatabaseEnv(t)
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "https://CHIRP.example.test:8443/")
	c, err := Load()
	if err != nil || c.PublicOrigin != "https://chirp.example.test:8443" || c.LiveKitWSURL != "wss://chirp.example.test:8443" {
		t.Fatal(c, err)
	}
	if c.ClientEndpoints.HealthURL != c.PublicOrigin+"/healthz" || c.Passkey().RPID != "chirp.example.test" {
		t.Fatal("public endpoints disagree")
	}
	t.Setenv("CHIRP_PUBLIC_ORIGIN", "http://passkey:18117")
	if _, err := Load(); err == nil {
		t.Fatal("internal origin accepted")
	}
}

func TestSelfHostedURLs(t *testing.T) {
	for _, tc := range []struct {
		raw              string
		websocket, valid bool
	}{
		{"wss://rtc.example.com", true, true},
		{"ws://127.0.0.1:7880", true, true},
		{"http://127.0.0.1:7880", false, true},
		{"http://10.0.0.3:7880", false, true},
		{"http://livekit:7880", false, true},
		{"ws://livekit:7880", true, false},
		{"http://livekit.example.com:7880", false, false},
		{"ws://rtc.example.com", true, false},
		{"wss://project.livekit.cloud", true, false},
		{"wss://project.livekit.cloud.", true, false},
		{"https://rtc.livekit.run", false, false},
		{"wss://user:secret@rtc.example.com", true, false},
		{"wss://rtc.example.com?token=secret", true, false},
		{"", true, false},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			if err := ValidateURL(tc.raw, tc.websocket); (err == nil) != tc.valid {
				t.Errorf("valid=%v, error=%v", tc.valid, err)
			}
		})
	}
}

func TestUnifiedListenAndPolicyValidation(t *testing.T) {
	setDatabaseEnv(t)
	for key, value := range map[string]string{"CHIRP_LISTEN_ADDR": "invalid", "CHIRP_TOKEN_TTL": "16m", "CHIRP_GROUP_ROTATION": "1s"} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, value)
			if _, err := Load(); err == nil {
				t.Fatal("invalid configuration accepted")
			}
		})
	}
}
