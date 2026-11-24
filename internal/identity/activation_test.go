package identity

import "testing"

func TestNormalizeOrigin(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"default port", "https://EXAMPLE.test/", "https://example.test:443"},
		{"explicit port", "https://example.test:8443", "https://example.test:8443"},
		{"loopback", "http://127.0.0.1:8080", "http://127.0.0.1:8080"},
		{"ipv6", "http://[::1]:8080", "http://[::1]:8080"},
		{"userinfo rejected", "https://user:secret@example.test", ""},
		{"path rejected", "https://example.test/api", ""},
		{"query rejected", "https://example.test?root=x", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeOrigin(tc.input)
			if tc.want == "" {
				if err == nil {
					t.Fatal("invalid origin accepted")
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatal(got, err)
			}
		})
	}
}
