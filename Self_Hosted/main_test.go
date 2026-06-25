package main

import (
	"strings"
	"testing"
	"time"
)

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
