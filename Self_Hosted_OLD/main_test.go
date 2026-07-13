package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeMetricStore struct {
	pingErr   error
	insertErr error
	inserted  []metricItem
}

func (s *fakeMetricStore) Ping(context.Context) error { return s.pingErr }

func (s *fakeMetricStore) Insert(_ context.Context, items []metricItem) error {
	s.inserted = append(s.inserted, items...)
	return s.insertErr
}

func (s *fakeMetricStore) Close() error { return nil }

func testServer(store *fakeMetricStore) *server {
	return &server{
		cfg:   config{legacyLocation: time.UTC},
		store: store,
	}
}

func TestLegacyClientDataURLContract(t *testing.T) {
	store := &fakeMetricStore{}
	srv := testServer(store)
	request := httptest.NewRequest(
		http.MethodPost,
		"http://metrics.example/data",
		strings.NewReader(`{"room":"Langdon 100","time":"2026-07-13T09:30:00","metric":"System On","action":"Started"}`),
	)
	response := httptest.NewRecorder()

	srv.routes().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusOK, response.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if body["message"] != "200" {
		t.Fatalf("message = %q, want 200", body["message"])
	}
	if len(store.inserted) != 1 {
		t.Fatalf("inserted count = %d, want 1", len(store.inserted))
	}
	item := store.inserted[0]
	if item.ClientName != "Langdon 100" || item.Metric != "System On" || item.Action != "Started" {
		t.Fatalf("inserted item = %#v", item)
	}
	if got := item.EventTimestamp.Format(time.RFC3339); got != "2026-07-13T09:30:00Z" {
		t.Fatalf("event timestamp = %s, want UTC legacy timestamp", got)
	}
}

func TestLegacyClientBareBaseURLContract(t *testing.T) {
	store := &fakeMetricStore{}
	srv := testServer(store)
	request := httptest.NewRequest(
		http.MethodPost,
		"http://metrics.example/",
		strings.NewReader(`{"room":"Room 1","time":"2026-07-13T09:30:00","metric":"PC","action":"Stopped"}`),
	)
	response := httptest.NewRecorder()

	srv.routes().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", response.Code, http.StatusOK, response.Body.String())
	}
	if len(store.inserted) != 1 {
		t.Fatalf("inserted count = %d, want 1", len(store.inserted))
	}
}

func TestLegacyServerProcessorAlias(t *testing.T) {
	item, validationMessage, err := buildLegacyItem(map[string]any{
		"processor": "Room 2",
		"time":      "2026-07-13T09:30:00Z",
		"metric":    "Display",
		"action":    "Started",
	}, "192.0.2.10", time.UTC)
	if err != nil {
		t.Fatalf("buildLegacyItem returned error: %v", err)
	}
	if validationMessage != "" {
		t.Fatalf("validation message = %q, want empty", validationMessage)
	}
	if item.ClientName != "Room 2" {
		t.Fatalf("client name = %q, want processor alias", item.ClientName)
	}
}

func TestGlobalEnableWorksWithBothBaseURLForms(t *testing.T) {
	for _, path := range []string{"/global/enable", "/data/global/enable"} {
		t.Run(path, func(t *testing.T) {
			srv := testServer(&fakeMetricStore{})
			request := httptest.NewRequest(http.MethodGet, "http://metrics.example"+path, nil)
			response := httptest.NewRecorder()

			srv.routes().ServeHTTP(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
			}
			var enabled string
			if err := json.Unmarshal(response.Body.Bytes(), &enabled); err != nil {
				t.Fatalf("response is not a JSON string: %v", err)
			}
			if enabled != "True" {
				t.Fatalf("enabled = %q, want True", enabled)
			}
		})
	}
}

func TestGlobalEnableReturnsFalseWhenDatabaseIsUnavailable(t *testing.T) {
	srv := testServer(&fakeMetricStore{pingErr: errors.New("database unavailable")})
	request := httptest.NewRequest(http.MethodGet, "http://metrics.example/data/global/enable", nil)
	response := httptest.NewRecorder()

	srv.routes().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	var enabled string
	if err := json.Unmarshal(response.Body.Bytes(), &enabled); err != nil {
		t.Fatalf("response is not a JSON string: %v", err)
	}
	if enabled != "False" {
		t.Fatalf("enabled = %q, want False", enabled)
	}
}

func TestLegacyTimezoneConvertsNaiveTimestampToUTC(t *testing.T) {
	location, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	parsed, ok := parseTimestamp("2026-07-13T09:30:00", location)
	if !ok {
		t.Fatal("parseTimestamp returned false")
	}
	if got := parsed.Format(time.RFC3339); got != "2026-07-13T16:30:00Z" {
		t.Fatalf("timestamp = %s, want 2026-07-13T16:30:00Z", got)
	}
}

func TestLegacyTimestampWithOffsetIgnoresConfiguredTimezone(t *testing.T) {
	location, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	parsed, ok := parseTimestamp("2026-07-13T09:30:00-04:00", location)
	if !ok {
		t.Fatal("parseTimestamp returned false")
	}
	if got := parsed.Format(time.RFC3339); got != "2026-07-13T13:30:00Z" {
		t.Fatalf("timestamp = %s, want 2026-07-13T13:30:00Z", got)
	}
}

func TestAllowedNetRejectsOtherSources(t *testing.T) {
	_, allowedNet, err := net.ParseCIDR("192.0.2.0/24")
	if err != nil {
		t.Fatal(err)
	}
	store := &fakeMetricStore{}
	srv := testServer(store)
	srv.cfg.allowedNet = allowedNet
	request := httptest.NewRequest(
		http.MethodPost,
		"http://metrics.example/data",
		strings.NewReader(`{"room":"Room 1","time":"2026-07-13T09:30:00","metric":"PC","action":"Started"}`),
	)
	request.RemoteAddr = "198.51.100.10:12345"
	response := httptest.NewRecorder()

	srv.routes().ServeHTTP(response, request)

	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusForbidden)
	}
	if len(store.inserted) != 0 {
		t.Fatalf("inserted count = %d, want 0", len(store.inserted))
	}
}

func TestLoadConfigValidatesLegacyTimezone(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://metrics_user:real_password@postgres:5432/metrics?sslmode=disable")
	t.Setenv("ALLOWED_NET", "")
	t.Setenv("LEGACY_TIMEZONE", "not/a-zone")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "LEGACY_TIMEZONE") {
		t.Fatalf("loadConfig error = %v, want invalid time zone error", err)
	}
}

func TestLoadConfigRejectsExamplePostgresPassword(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://metrics_user:"+examplePostgresPassword+"@postgres:5432/metrics?sslmode=disable")
	t.Setenv("ALLOWED_NET", "")
	t.Setenv("LEGACY_TIMEZONE", "UTC")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "POSTGRES_PASSWORD must be changed") {
		t.Fatalf("loadConfig error = %v, want example password rejection", err)
	}
}

func TestHealthcheckURLFromAddr(t *testing.T) {
	tests := map[string]string{
		":8080":          "http://127.0.0.1:8080/health",
		"0.0.0.0:9090":   "http://127.0.0.1:9090/health",
		"127.0.0.1:8081": "http://127.0.0.1:8081/health",
		"[::1]:8082":     "http://[::1]:8082/health",
		"invalid":        "http://127.0.0.1:8080/health",
	}
	for input, want := range tests {
		if got := healthcheckURLFromAddr(input); got != want {
			t.Errorf("healthcheckURLFromAddr(%q) = %q, want %q", input, got, want)
		}
	}
}
