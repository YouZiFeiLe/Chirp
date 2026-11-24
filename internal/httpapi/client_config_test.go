package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/room"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testclient"
	"gitlab.youzifeile.cn/chirp/chirp-go/internal/testdb"
)

func TestClientConfigIsPublicAndUsesConfiguredOrigin(t *testing.T) {
	db := configTestStore(t)
	handler := New(db, &fakeMedia{}, room.Issuer{APISecret: "must-not-be-public"}, "wss://rtc.example.test", "https://keys.example.test:8443/", slog.New(slog.NewTextHandler(io.Discard, nil)))
	r := httptest.NewRequest("GET", "https://untrusted-host.test/v1/client-config", nil)
	r.Header.Set("X-Forwarded-Host", "untrusted-forwarded.test")
	testclient.SetHeaders(r, testclient.MustLatest(t, db, "macos"))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" || !strings.HasPrefix(w.Header().Get("Content-Type"), "application/json") {
		t.Fatal("configuration requires authentication or is cacheable", w.Code, w.Header())
	}
	var value map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	if len(value) != 7 || value["service"] != "chirp" || value["protocol_version"] != float64(5) ||
		value["passkey_origin"] != "https://keys.example.test:8443" || value["default_room_id"] != "friends" {
		t.Fatal("incorrect public contract", value)
	}
	endpoints := value["endpoints"].(map[string]any)
	capabilities := value["capabilities"].(map[string]any)
	if len(endpoints) != 10 || endpoints["registration_url"] != "https://keys.example.test:8443/register" || endpoints["api_base_url"] != "https://keys.example.test:8443/" ||
		capabilities["max_members"] != float64(0) || capabilities["dynamic_rooms"] != true || capabilities["registration"] != true {
		t.Fatal("missing endpoint discovery or dynamic capacity", value)
	}
	if strings.Contains(w.Body.String(), "must-not-be-public") || strings.Contains(w.Body.String(), "untrusted") {
		t.Fatal("configuration leaked secrets or trusted request host headers")
	}
}

func TestClientConfigReportsCurrentRegistrationSetting(t *testing.T) {
	db := configTestStore(t)
	handler := New(db, &fakeMedia{}, room.Issuer{}, "", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	for _, closed := range []bool{true, false} {
		if err := db.SetRegistrationClosed(t.Context(), closed); err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("GET", "/v1/client-config", nil)
		testclient.SetHeaders(r, testclient.MustLatest(t, db, "macos"))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		var manifest struct {
			Capabilities struct {
				Registration *bool `json:"registration"`
			} `json:"capabilities"`
		}
		if w.Code != 200 {
			t.Fatalf("client config returned %d: %s", w.Code, w.Body.String())
		}
		if err := json.Unmarshal(w.Body.Bytes(), &manifest); err != nil {
			t.Fatal(err)
		}
		if registration := manifest.Capabilities.Registration; registration == nil || *registration == closed {
			t.Fatalf("client config did not reflect closed=%t: %s", closed, w.Body.String())
		}
	}
}

func TestClientConfigRejectsMissingOrUnsafeOrigins(t *testing.T) {
	db := configTestStore(t)
	for _, origin := range []string{"", "http://keys.example.test", "https://keys.example.test/private", "https://user:password@keys.example.test"} {
		handler := New(db, &fakeMedia{}, room.Issuer{}, "", origin, slog.New(slog.NewTextHandler(io.Discard, nil)))
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/v1/client-config", nil)
		testclient.SetHeaders(r, testclient.MustLatest(t, db, "macos"))
		handler.ServeHTTP(w, r)
		if w.Code != 503 || !strings.Contains(w.Body.String(), "CLIENT_CONFIG_UNAVAILABLE") {
			t.Fatalf("unsafe origin %q: %d %s", origin, w.Code, w.Body.String())
		}
	}
}

func configTestStore(t *testing.T) *store.Store {
	t.Helper()
	db, err := store.Open(context.Background(), testdb.Path(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestOutdatedClientsReceiveOnlyUpgradeDetails(t *testing.T) {
	db := configTestStore(t)
	handler := New(db, &fakeMedia{}, room.Issuer{}, "", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	policy, err := db.UpdateClientVersionPolicy(t.Context(), store.ClientVersionPolicy{
		Platform: "macos", LatestVersion: "2026.11.22", LatestBuild: 3, MinimumVersion: "2026.11.22", MinimumBuild: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ build, want int }{{0, 400}, {1, 403}, {2, 200}, {3, 200}} {
		r := httptest.NewRequest("GET", "/v1/client-config", nil)
		if tc.build != 0 {
			testclient.SetHeaders(r, store.ClientIdentity{Platform: policy.Platform, Version: policy.MinimumVersion, Build: tc.build})
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatalf("build %d: %d %s", tc.build, w.Code, w.Body.String())
		}
		if tc.want != 200 && strings.Contains(w.Body.String(), `"endpoints"`) {
			t.Fatal("rejected client received configuration")
		}
		if tc.want == 403 {
			var rejection struct {
				Error  struct{ Code string }     `json:"error"`
				Policy store.ClientVersionPolicy `json:"client_policy"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &rejection); err != nil || rejection.Error.Code != "CLIENT_UPDATE_REQUIRED" || rejection.Policy != policy {
				t.Fatal("incorrect upgrade guidance", w.Body.String(), err)
			}
		}
	}
}

func TestDiscoveryHasIndependentPlatformPolicies(t *testing.T) {
	db := configTestStore(t)
	handler := New(db, &fakeMedia{}, room.Issuer{}, "", "https://keys.example.test", slog.New(slog.NewTextHandler(io.Discard, nil)))
	policies, err := db.ClientVersionPolicies(t.Context())
	if err != nil || len(policies) != 4 {
		t.Fatal(policies, err)
	}
	for _, policy := range policies {
		r := httptest.NewRequest("GET", "/v1/client-config", nil)
		testclient.SetHeaders(r, store.ClientIdentity{Platform: policy.Platform, Version: policy.LatestVersion, Build: policy.LatestBuild})
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		var manifest struct {
			Policy       store.ClientVersionPolicy `json:"client_policy"`
			Capabilities struct {
				DeviceLogin        bool `json:"device_login"`
				AndroidNativeLogin bool `json:"android_native_login"`
			} `json:"capabilities"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &manifest) != nil || manifest.Policy != policy ||
			!manifest.Capabilities.DeviceLogin || !manifest.Capabilities.AndroidNativeLogin {
			t.Fatalf("%s: %d %s", policy.Platform, w.Code, w.Body.String())
		}
	}
}
