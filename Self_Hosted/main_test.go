package main

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

type recordingExecer struct {
	query string
	args  []any
}

func (e *recordingExecer) ExecContext(_ context.Context, query string, args ...any) (sql.Result, error) {
	e.query = query
	e.args = args
	return fixedResult(3), nil
}

type fixedResult int64

func (r fixedResult) LastInsertId() (int64, error) { return 0, nil }
func (r fixedResult) RowsAffected() (int64, error) { return int64(r), nil }

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
	if !cfg.purgeHeartbeat {
		t.Fatal("purgeHeartbeat = false, want default true")
	}
	if cfg.heartbeatRetentionDays != 30 {
		t.Fatalf("heartbeatRetentionDays = %d, want default 30", cfg.heartbeatRetentionDays)
	}
}

func TestLoadConfigAppliesHeartbeatPurgeSettings(t *testing.T) {
	t.Setenv("BEARER_TOKEN", "real-bearer-token")
	t.Setenv("DATABASE_URL", "postgres://metrics_user:real_database_password@postgres:5432/metrics?sslmode=disable")
	t.Setenv("ALLOWED_NET", "")
	t.Setenv("PURGE_HEARTBEAT", "false")
	t.Setenv("HEARTBEAT_RETENTION_DAYS", "90")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig returned error: %v", err)
	}
	if cfg.purgeHeartbeat {
		t.Fatal("purgeHeartbeat = true, want false")
	}
	if cfg.heartbeatRetentionDays != 90 {
		t.Fatalf("heartbeatRetentionDays = %d, want 90", cfg.heartbeatRetentionDays)
	}
}

func TestLoadConfigRejectsInvalidHeartbeatPurgeSettings(t *testing.T) {
	tests := []struct {
		name  string
		key   string
		value string
		want  string
	}{
		{name: "invalid toggle", key: "PURGE_HEARTBEAT", value: "sometimes", want: "PURGE_HEARTBEAT must be true or false"},
		{name: "zero retention", key: "HEARTBEAT_RETENTION_DAYS", value: "0", want: "HEARTBEAT_RETENTION_DAYS must be a positive integer"},
		{name: "fractional retention", key: "HEARTBEAT_RETENTION_DAYS", value: "1.5", want: "HEARTBEAT_RETENTION_DAYS must be a positive integer"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("BEARER_TOKEN", "real-bearer-token")
			t.Setenv("DATABASE_URL", "postgres://metrics_user:real_database_password@postgres:5432/metrics?sslmode=disable")
			t.Setenv("ALLOWED_NET", "")
			t.Setenv("PURGE_HEARTBEAT", "true")
			t.Setenv("HEARTBEAT_RETENTION_DAYS", "30")
			t.Setenv(tt.key, tt.value)

			_, err := loadConfig()
			if err == nil {
				t.Fatal("loadConfig returned nil error, want validation error")
			}
			if err.Error() != tt.want {
				t.Fatalf("loadConfig error = %q, want %q", err.Error(), tt.want)
			}
		})
	}
}

func TestPurgeHeartbeatRecordsUsesReceivedAtCutoff(t *testing.T) {
	db := &recordingExecer{}
	now := time.Date(2026, time.September, 22, 15, 30, 0, 0, time.FixedZone("PDT", -7*60*60))

	deleted, err := purgeHeartbeatRecords(context.Background(), db, now, 30)
	if err != nil {
		t.Fatalf("purgeHeartbeatRecords returned error: %v", err)
	}
	if deleted != 3 {
		t.Fatalf("deleted = %d, want 3", deleted)
	}
	if db.query != purgeHeartbeatSQL {
		t.Fatalf("query = %q, want purgeHeartbeatSQL", db.query)
	}
	if len(db.args) != 1 {
		t.Fatalf("argument count = %d, want 1", len(db.args))
	}

	cutoff, ok := db.args[0].(time.Time)
	if !ok {
		t.Fatalf("cutoff type = %T, want time.Time", db.args[0])
	}
	want := time.Date(2026, time.August, 23, 22, 30, 0, 0, time.UTC)
	if !cutoff.Equal(want) {
		t.Fatalf("cutoff = %s, want %s", cutoff, want)
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
