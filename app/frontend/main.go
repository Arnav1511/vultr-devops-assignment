// Frontend web server: serves the static UI embedded in this binary.
//
// Why a small Go server instead of nginx: the files are compiled into the
// binary, so the image is `scratch` with one executable. It needs no writable
// directories (nginx needs /tmp and a cache dir, which fight
// readOnlyRootFilesystem) and carries no OS packages for a scanner to flag.
//
// The UI calls the API at the relative path /api/..., so the browser talks to a
// single origin and the Gateway's HTTPRoute sends /api to the backend. That
// avoids CORS entirely and keeps the backend address out of the frontend build.
package main

import (
	"context"
	"embed"
	"errors"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

//go:embed static
var staticFiles embed.FS

func main() {
	addr := ":" + getenv("PORT", "8080")

	// Strip the "static/" prefix so static/index.html is served at "/".
	content, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatalf("embed: %v", err)
	}

	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServerFS(content))
	// One endpoint serves all three probes: this process has no dependencies,
	// so "alive" and "ready" are the same condition.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Same SIGTERM drain as the backend; see app/backend/main.go.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	go func() {
		log.Printf("frontend listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
