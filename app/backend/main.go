// Backend REST API.
//
// Stage A: standard library only, no database yet. Endpoints:
//
//	GET /healthz     liveness  — is the process alive?
//	GET /readyz      readiness — can it serve traffic right now?
//	GET /api/status  JSON status consumed by the frontend
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version is set at build time with -ldflags "-X main.version=<git sha>", so a
// running pod can always be traced back to the commit that produced it.
var version = "dev"

func main() {
	addr := ":" + getenv("PORT", "8080")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", readyz)
	mux.HandleFunc("GET /api/status", status)

	srv := &http.Server{
		Addr:    addr,
		Handler: mux,
		// Bound how long a client may take to send headers, so slow or stalled
		// connections cannot pin goroutines forever (Slowloris).
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Kubernetes sends SIGTERM before killing a pod. Catch it and drain in-flight
	// requests instead of dropping them mid-response during a rolling update.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	go func() {
		log.Printf("backend %s listening on %s", version, addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Print("shutdown signal received, draining")

	// Must be shorter than the pod's terminationGracePeriodSeconds (default 30s),
	// otherwise the kubelet SIGKILLs the process before the drain finishes.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
}

// healthz deliberately checks nothing external. If liveness depended on a
// database, a database outage would make Kubernetes restart every healthy
// backend pod, turning one failure into two.
func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is where dependency checks belong: failing it removes the pod from the
// Service endpoints without restarting it. Database pings are added in Stage B.
func readyz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func status(w http.ResponseWriter, _ *http.Request) {
	// In a pod the hostname is the pod name, so repeated calls show requests
	// being spread across replicas.
	host, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]string{
		"service":  "backend",
		"version":  version,
		"hostname": host,
		"time":     time.Now().UTC().Format(time.RFC3339),
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
