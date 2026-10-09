package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// The three signals the application dashboard and alerts are built on:
// request rate and error rate (from the counter) and latency (from the
// histogram).
var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests handled, by method, route and status code.",
	}, []string{"method", "route", "code"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency, by method and route.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "route"})

	dependencyUp = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "backend_dependency_up",
		Help: "1 if the dependency answered its last health check, else 0.",
	}, []string{"dependency"})
)

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument records every request. The route label is the registered pattern
// (e.g. "GET /api/messages"), never the raw URL: labelling by raw path would
// let any client create unlimited time series by requesting random URLs.
func instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)

		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}
		httpRequests.WithLabelValues(r.Method, route, strconv.Itoa(rec.code)).Inc()
		httpDuration.WithLabelValues(r.Method, route).Observe(time.Since(start).Seconds())
	})
}
