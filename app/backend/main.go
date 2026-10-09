// Backend REST API.
//
//	GET  /healthz        liveness  — is the process alive?
//	GET  /readyz         readiness — are all three databases reachable?
//	GET  /metrics        Prometheus metrics (not routed publicly)
//	GET  /api/status     service info, dependency health and counters
//	GET  /api/messages   latest messages
//	POST /api/messages   create a message
//
// Each database does the job it is suited to:
//
//	PostgreSQL  system of record for messages (relational, transactional)
//	MongoDB     append-only audit events (schemaless documents)
//	Valkey      visit counter (atomic in-memory increment)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// version is set at build time with -ldflags "-X main.version=<git sha>", so a
// running pod can always be traced back to the commit that produced it.
var version = "dev"

type server struct {
	store *store
}

func main() {
	addr := ":" + getenv("PORT", "8080")

	// Kubernetes sends SIGTERM before killing a pod. Catch it and drain in-flight
	// requests instead of dropping them mid-response during a rolling update.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	st, err := newStore(ctx)
	if err != nil {
		log.Fatalf("configure stores: %v", err)
	}
	defer st.close()
	s := &server{store: st}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("GET /api/status", s.status)
	mux.HandleFunc("GET /api/messages", s.listMessages)
	mux.HandleFunc("POST /api/messages", s.createMessage)

	srv := &http.Server{
		Addr:    addr,
		Handler: instrument(mux),
		// Bound how long a client may take to send headers, so slow or stalled
		// connections cannot pin goroutines forever (Slowloris).
		ReadHeaderTimeout: 5 * time.Second,
	}

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
func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz is where dependency checks belong: failing it removes the pod from the
// Service endpoints without restarting it, and it rejoins once they recover.
func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	deps := s.store.check(r.Context())
	code := http.StatusOK
	for _, state := range deps {
		if state != "ok" {
			code = http.StatusServiceUnavailable
		}
	}
	writeJSON(w, code, deps)
}

func (s *server) status(w http.ResponseWriter, r *http.Request) {
	// In a pod the hostname is the pod name, so repeated calls show requests
	// being spread across replicas.
	host, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]any{
		"service":      "backend",
		"version":      version,
		"hostname":     host,
		"time":         time.Now().UTC().Format(time.RFC3339),
		"dependencies": s.store.check(r.Context()),
		"counters":     s.store.counters(r.Context()),
	})
}

func (s *server) listMessages(w http.ResponseWriter, r *http.Request) {
	msgs, err := s.store.listMessages(r.Context())
	if err != nil {
		log.Printf("list messages: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "database unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, msgs)
}

func (s *server) createMessage(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Text string `json:"text"`
	}
	// Cap the body so a client cannot make the server buffer an arbitrarily
	// large request.
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	in.Text = strings.TrimSpace(in.Text)
	if in.Text == "" || len(in.Text) > 280 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "text must be 1-280 characters"})
		return
	}
	msg, err := s.store.createMessage(r.Context(), in.Text)
	if err != nil {
		log.Printf("create message: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "database unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, msg)
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
