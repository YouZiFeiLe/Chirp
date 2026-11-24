package clienthttp

import (
	"net/http/httptest"
	"testing"
)

func TestMetadataRequiresOneValidValuePerHeader(t *testing.T) {
	for _, invalid := range []struct{ key, value string }{
		{"X-Chirp-Platform", "unknown"}, {"X-Chirp-Version", "0.11"}, {"X-Chirp-Version", "01.11.0"},
		{"X-Chirp-Build", "0"}, {"X-Chirp-Build", "025"}, {"X-Chirp-Build", "+14"}, {"X-Chirp-Build", "2147483648"},
		{"X-Chirp-Build", "14,15"}, {"X-Chirp-Build", ""},
	} {
		r := httptest.NewRequest("GET", "/v1/client-config", nil)
		r.Header.Set("X-Chirp-Platform", "macos")
		r.Header.Set("X-Chirp-Version", "0.14.0")
		r.Header.Set("X-Chirp-Build", "14")
		if c, err := Identity(r); err != nil || c.Build != 14 {
			t.Fatal(c, err)
		}
		r.Header.Set(invalid.key, invalid.value)
		if _, err := Identity(r); err == nil {
			t.Fatal("invalid metadata accepted", invalid)
		}
	}
	r := httptest.NewRequest("GET", "/v1/client-config", nil)
	if _, err := Identity(r); err == nil {
		t.Fatal("missing metadata accepted")
	}
	r.Header.Set("X-Chirp-Platform", "ios")
	r.Header.Set("X-Chirp-Version", "0.14.0")
	r.Header.Add("X-Chirp-Build", "14")
	r.Header.Add("X-Chirp-Build", "15")
	if _, err := Identity(r); err == nil {
		t.Fatal("duplicate header accepted")
	}
}
