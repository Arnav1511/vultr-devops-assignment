package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

// These tests cover the logic that needs no database: liveness, input
// validation (which must reject bad input before any store call) and the
// metrics middleware. Database behaviour is covered by the pipeline's smoke
// tests against the real services.

func TestHealthzNeedsNoDependencies(t *testing.T) {
	// A server with no store at all: liveness must still answer, because it
	// must never depend on a database.
	s := &server{}
	rec := httptest.NewRecorder()
	s.healthz(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestCreateMessageRejectsInvalidInput(t *testing.T) {
	// No store: if validation let any of these through, the handler would
	// panic on the nil store and the test would fail.
	s := &server{}
	tests := []struct {
		name string
		body string
	}{
		{"not JSON", "hello"},
		{"empty text", `{"text":""}`},
		{"whitespace only", `{"text":"   "}`},
		{"too long", `{"text":"` + strings.Repeat("a", 281) + `"}`},
		{"body over size cap", `{"text":"` + strings.Repeat("a", 5000) + `"}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/api/messages", strings.NewReader(tc.body))
			s.createMessage(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", rec.Code)
			}
		})
	}
}

func TestInstrumentLabelsByRoutePattern(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/thing", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})
	h := instrument(mux)

	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/thing", nil))
	// Two different unknown URLs must land in ONE "unmatched" series, not
	// create a series each — that is what keeps cardinality bounded.
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/random-1", nil))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/random-2", nil))

	if got := testutil.ToFloat64(httpRequests.WithLabelValues("GET", "GET /api/thing", "418")); got != 1 {
		t.Errorf("matched route counter = %v, want 1", got)
	}
	if got := testutil.ToFloat64(httpRequests.WithLabelValues("GET", "unmatched", "404")); got != 2 {
		t.Errorf("unmatched counter = %v, want 2", got)
	}
}
