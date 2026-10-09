package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRoutes(t *testing.T) {
	mux, err := newMux()
	if err != nil {
		t.Fatalf("newMux: %v", err)
	}

	tests := []struct {
		name     string
		path     string
		wantCode int
		wantBody string
	}{
		{"index page is embedded and served", "/", http.StatusOK, "<title>"},
		{"health endpoint", "/healthz", http.StatusOK, "ok"},
		{"unknown path", "/missing", http.StatusNotFound, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if rec.Code != tc.wantCode {
				t.Errorf("status = %d, want %d", rec.Code, tc.wantCode)
			}
			if !strings.Contains(rec.Body.String(), tc.wantBody) {
				t.Errorf("body does not contain %q", tc.wantBody)
			}
		})
	}
}
