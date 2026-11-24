// Package webui provides the shared Chirp visual language for browser surfaces.
package webui

import (
	"embed"
	"net/http"
)

//go:embed theme.css icon.svg i18n.js client-version.js locales/*.js
var assets embed.FS

// RegisterAssets shares the theme and translations between browser surfaces.
func RegisterAssets(mux *http.ServeMux) {
	pages := http.StripPrefix("/assets/", http.FileServerFS(assets))
	for _, name := range []string{"theme.css", "icon.svg", "i18n.js", "client-version.js", "locales/zh-CN.js", "locales/en.js"} {
		mux.Handle("GET /assets/"+name, pages)
	}
}
