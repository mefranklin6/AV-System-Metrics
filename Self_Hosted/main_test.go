package main

import (
	"strings"
	"testing"
	"time"
)

func TestLoadConfigRejectsExampleBearerToken(t *testing.T) {
	t.Setenv("BEARER_TOKEN", exampleBearerToken)
	t.Setenv("DATABASE_URL", "postgres://metrics_user:real_database_password@postgres:5432/metrics?sslmode=disable")
	t.Setenv("ALLOWED_NET", "")

	_, err := loadConfig()
	if err == nil {
		t.Fatal("loadConfig returned nil error, want example bearer token rejection")
	}
	if !strings.Contains(err.Error(), "BEARER_TOKEN must be changed") {
		t.Fatalf("loadConfig error = %q, want BEARER_TOKEN rejection", err.Error())
	}
}

func TestLoadConfigRejectsExamplePostgresPassword(t *testing.T) {
	t.Setenv("BEARER_TOKEN", "real-bearer-token")
	t.Setenv("DATABASE_URL", "postgres://metrics_user:"+examplePostgresPassword+"@postgres:5432/metrics?sslmode=disable")
	t.Setenv("ALLOWED_NET", "")

	_, err := loadConfig()
	if err == nil {
		t.Fatal("loadConfig returned nil error, want example Postgres password rejection")
	}
	if !strings.Contains(err.Error(), "POSTGRES_PASSWORD must be changed") {
		t.Fatalf("loadConfig error = %q, want POSTGRES_PASSWORD rejection", err.Error())
	}
}

func TestLoadConfigAcceptsChangedSecrets(t *testing.T) {
	t.Setenv("BEARER_TOKEN", "real-bearer-token")
	t.Setenv("DATABASE_URL", "postgres://metrics_user:real_database_password@postgres:5432/metrics?sslmode=disable")
	t.Setenv("ALLOWED_NET", "")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig returned error: %v", err)
	}
	if cfg.bearerToken != "real-bearer-token" {
		t.Fatalf("bearerToken = %q, want changed token", cfg.bearerToken)
	}
}

func TestRejectExampleSecretAllowsOtherValues(t *testing.T) {
	if err := rejectExampleSecret("BEARER_TOKEN", "real-bearer-token", exampleBearerToken); err != nil {
		t.Fatalf("rejectExampleSecret returned error for changed value: %v", err)
	}
}

func TestRejectExampleSecretRejectsExactExampleValue(t *testing.T) {
	err := rejectExampleSecret("BEARER_TOKEN", exampleBearerToken, exampleBearerToken)
	if err == nil {
		t.Fatal("rejectExampleSecret returned nil error, want rejection")
	}
	if !strings.Contains(err.Error(), "BEARER_TOKEN must be changed") {
		t.Fatalf("rejectExampleSecret error = %q, want BEARER_TOKEN rejection", err.Error())
	}
}

func TestParseTimestampNormalizesToUTC(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "utc rfc3339",
			in:   "2026-06-16T21:00:00Z",
			want: "2026-06-16T21:00:00Z",
		},
		{
			name: "offset rfc3339",
			in:   "2026-06-16T21:00:00-07:00",
			want: "2026-06-17T04:00:00Z",
		},
		{
			name: "timezone-less timestamp is treated as utc",
			in:   "2026-06-16T21:00:00",
			want: "2026-06-16T21:00:00Z",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := parseTimestamp(tt.in)
			if !ok {
				t.Fatalf("parseTimestamp(%q) returned false", tt.in)
			}

			if got.Format(time.RFC3339Nano) != tt.want {
				t.Fatalf("parseTimestamp(%q) = %s, want %s", tt.in, got.Format(time.RFC3339Nano), tt.want)
			}

			if got.Location() != time.UTC {
				t.Fatalf("parseTimestamp(%q) location = %s, want UTC", tt.in, got.Location())
			}
		})
	}
}

func TestBuildItemUsesUTCTimestamp(t *testing.T) {
	item, validationMessage, err := buildItem(map[string]any{
		"clientname": "workstation",
		"metric":     "trace",
		"action":     "testing",
		"timestamp":  "2026-06-16T21:00:00-07:00",
	}, "192.0.2.10")
	if err != nil {
		t.Fatalf("buildItem returned error: %v", err)
	}
	if validationMessage != "" {
		t.Fatalf("buildItem validation message = %q, want empty", validationMessage)
	}

	want := "2026-06-17T04:00:00Z"
	if item.EventTimestamp.Format(time.RFC3339Nano) != want {
		t.Fatalf("EventTimestamp = %s, want %s", item.EventTimestamp.Format(time.RFC3339Nano), want)
	}

	if !strings.HasPrefix(item.SortKey, "2026-06-17T04:00:00.000000000Z#") {
		t.Fatalf("SortKey = %q, want UTC fixed-width timestamp prefix", item.SortKey)
	}
}

func TestHealthcheckURLFromAddr(t *testing.T) {
	tests := []struct {
		name string
		addr string
		want string
	}{
		{
			name: "default wildcard bind",
			addr: ":8080",
			want: "http://127.0.0.1:8080/health",
		},
		{
			name: "ipv4 wildcard bind",
			addr: "0.0.0.0:9090",
			want: "http://127.0.0.1:9090/health",
		},
		{
			name: "localhost bind",
			addr: "127.0.0.1:8081",
			want: "http://127.0.0.1:8081/health",
		},
		{
			name: "ipv6 localhost bind",
			addr: "[::1]:8082",
			want: "http://[::1]:8082/health",
		},
		{
			name: "invalid bind",
			addr: "8080",
			want: "http://127.0.0.1:8080/health",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := healthcheckURLFromAddr(tt.addr)
			if got != tt.want {
				t.Fatalf("healthcheckURLFromAddr(%q) = %q, want %q", tt.addr, got, tt.want)
			}
		})
	}
}
