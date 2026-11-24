package adminhttp

import (
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestAdministratorEditsPlatformVersionRequirements(t *testing.T) {
	db, _, handler := newAdminTestServer(t)
	listed := adminRequest(t, handler, "GET", "/admin/api/client-versions", "", 200)
	policies := decodeAdmin[struct {
		Platforms []store.ClientVersionPolicy `json:"platforms"`
	}](t, listed)
	before := make(map[string]store.ClientVersionPolicy)
	for _, p := range policies.Platforms {
		before[p.Platform] = p
	}
	for _, platform := range []string{"ios", "macos", "windows", "android"} {
		if _, ok := before[platform]; !ok {
			t.Fatal("missing platform policy", platform)
		}
	}
	saved := decodeAdmin[store.ClientVersionPolicy](t, adminRequest(t, handler, "PUT", "/admin/api/client-versions/ios", `{"latest_version":"0.15.0","latest_build":18,"minimum_version":"0.15.0", "minimum_build":16}`, 200))
	if saved.Platform != "ios" || saved.LatestVersion != "0.15.0" || saved.LatestBuild != 18 || saved.MinimumBuild != 16 {
		t.Fatal(saved)
	}
	mac := before["macos"]
	got, err := db.CheckClientVersion(t.Context(), store.ClientIdentity{Platform: mac.Platform, Version: mac.MinimumVersion, Build: mac.MinimumBuild})
	if err != nil || got != mac {
		t.Fatal("platform edit changed macOS policy", got, err)
	}
	for _, body := range []string{`{"latest_version":"0.12","latest_build":18,"minimum_version":"0.15.0", "minimum_build":16}`, `{"latest_version":"0.15.0","latest_build":18,"minimum_version":"0.15.0", "minimum_build":19}`, `{"latest_version":"0.15.0","latest_build":18.5,"minimum_version":"0.15.0", "minimum_build":16}`, `{"latest_version":"0.15.0","latest_build":18,"minimum_version":"0.15.0", "minimum_build":16,"platform":"macos"}`} {
		adminRequest(t, handler, "PUT", "/admin/api/client-versions/ios", body, 400)
	}
	windows := decodeAdmin[store.ClientVersionPolicy](t, adminRequest(t, handler, "PUT", "/admin/api/client-versions/windows", `{"latest_version":"0.1.0","latest_build":3,"minimum_version":"0.1.0","minimum_build":2}`, 200))
	if windows.Platform != "windows" || windows.LatestBuild != 3 || windows.MinimumBuild != 2 {
		t.Fatal(windows)
	}
	adminRequest(t, handler, "PUT", "/admin/api/client-versions/unknown", `{"latest_version":"0.1.0","latest_build":1,"minimum_version":"0.1.0","minimum_build":1}`, 400)
	reset := decodeAdmin[store.ClientVersionPolicy](t, adminRequest(t, handler, "PUT", "/admin/api/client-versions/ios", `{"latest_version":"0.14.1","latest_build":1,"minimum_version":"0.14.0","minimum_build":14}`, 200))
	if reset.MinimumVersion != "0.14.0" || reset.MinimumBuild != 14 || reset.LatestBuild != 1 {
		t.Fatal(reset)
	}
	for _, body := range []string{
		`{"latest_version":"0.14.1","latest_build":1,"minimum_build":1}`,
		`{"latest_version":"0.14.1","latest_build":1,"minimum_version":"0.14.2","minimum_build":1}`,
		`{"latest_version":"0.14.1","latest_build":1,"minimum_version":"0.14.1","minimum_build":2}`,
		`{"latest_version":"0.14.1","latest_build":1,"minimum_version":"0.11","minimum_build":1}`,
	} {
		adminRequest(t, handler, "PUT", "/admin/api/client-versions/ios", body, 400)
	}
}
