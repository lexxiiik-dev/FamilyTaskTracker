package todo

import (
	"embed"
	"io/fs"
	"net/http"
	"path"
	"strings"
)

// Веб-клиент (сборка Flutter) встроен в бинарник: tools/build-web.ps1 кладёт его в server/web.
//
//go:embed all:web
var webFS embed.FS

// WebHandler отдаёт веб-клиент. Неизвестные пути ведут на index.html (одностраничное приложение).
func WebHandler() http.Handler {
	sub, _ := fs.Sub(webFS, "web")
	files := http.FileServer(http.FS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
		if p == "" {
			p = "index.html"
		}
		if _, err := fs.Stat(sub, p); err != nil {
			p = "index.html"
			r = r.Clone(r.Context())
			r.URL.Path = "/"
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if p == "index.html" || p == "sw.js" || p == "manifest.json" || strings.HasSuffix(p, ".json") {
			w.Header().Set("Cache-Control", "no-cache")
		} else {
			w.Header().Set("Cache-Control", "public, max-age=3600")
		}
		files.ServeHTTP(w, r)
	})
}
