package webui

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSharedAssets(t *testing.T) {
	mux := http.NewServeMux()
	RegisterAssets(mux)
	for _, name := range []string{"theme.css", "icon.svg", "i18n.js", "client-version.js", "locales/zh-CN.js", "locales/en.js"} {
		t.Run(name, func(t *testing.T) {
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, httptest.NewRequest("GET", "/assets/"+name, nil))
			if w.Code != http.StatusOK || w.Body.Len() == 0 {
				t.Fatalf("shared asset missing: status %d", w.Code)
			}
			if strings.HasSuffix(name, ".js") && !strings.Contains(w.Header().Get("Content-Type"), "javascript") {
				t.Fatal("module must be served as JavaScript")
			}
		})
	}
	for _, path := range []string{"/assets/locales/missing.js", "/assets/assets.go", "/assets/i18n_test.mjs"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != http.StatusNotFound {
			t.Fatalf("unexpected public asset: %s", path)
		}
	}
}
