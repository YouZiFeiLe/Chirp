package main

import "testing"

func TestParseServerAddress(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"domain", "chirp.example.com", "https://chirp.example.com"},
		{"trailing slash", "chirp.example.com/", "https://chirp.example.com"},
		{"custom port", "chirp.example.com:8443", "https://chirp.example.com:8443"},
		{"custom port and slash", "chirp.example.com:8443/", "https://chirp.example.com:8443"},
		{"explicit HTTPS", "https://chirp.example.com:8443/", "https://chirp.example.com:8443"},
		{"default port", "  CHIRP.example.com:443/  ", "https://chirp.example.com"},
		{"deployment path", "chirp.example.com:8443/chirp/", "https://chirp.example.com:8443/chirp"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base, err := parseServerAddress(tc.input, false)
			if err != nil {
				t.Fatal(err)
			}
			if got := base.String(); got != tc.want {
				t.Errorf("parseServerAddress(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestParseServerAddressRejectsInvalidInput(t *testing.T) {
	for _, input := range []string{"", "chirp.example.com:invalid/", "chirp.example.com:65536/",
		"https:/chirp.example.com", "http://chirp.example.com/", "ftp://chirp.example.com/"} {
		if _, err := parseServerAddress(input, false); err == nil || err.Error() != "INVALID_SERVER_ADDRESS" {
			t.Errorf("parseServerAddress(%q) returned error %v, want INVALID_SERVER_ADDRESS", input, err)
		}
	}
}
