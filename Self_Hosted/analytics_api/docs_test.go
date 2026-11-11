package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// These tests keep README.md and openapi.yaml in step with the limits that
// third-party developers depend on, and prove the documented behaviour of
// oversized requests.

func readmeText(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile("README.md")
	if err != nil {
		t.Fatalf("read README.md: %v", err)
	}
	return string(data)
}

// openAPIPathSection returns the text of one path item in openapi.yaml.
func openAPIPathSection(t *testing.T, spec, path string) string {
	t.Helper()
	start := strings.Index(spec, "\n  "+path+":\n")
	if start < 0 {
		t.Fatalf("openapi.yaml does not document %s", path)
	}
	rest := spec[start+1:]
	end := len(rest)
	for _, marker := range []string{"\n  /", "\ncomponents:"} {
		if i := strings.Index(rest, marker); i >= 0 && i < end {
			end = i
		}
	}
	return rest[:end]
}

func groupThousands(n int) string {
	s := fmt.Sprint(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

func TestOpenAPIDocumentsLongQueryResponses(t *testing.T) {
	spec := string(openAPISpec)
	for _, path := range []string{"/api/v1/events", "/api/v1/summary", "/api/v1/heartbeats"} {
		section := openAPIPathSection(t, spec, path)
		for _, needle := range []string{
			`$ref: "#/components/parameters/Client"`,
			`"414": { $ref: "#/components/responses/URITooLong" }`,
			`"431": { $ref: "#/components/responses/RequestHeaderFieldsTooLarge" }`,
			`"429": { $ref: "#/components/responses/TooManyRequests" }`,
		} {
			if !strings.Contains(section, needle) {
				t.Errorf("openapi.yaml %s lacks %s", path, needle)
			}
		}
	}
	for _, needle := range []string{"\n    URITooLong:\n", "\n    RequestHeaderFieldsTooLarge:\n", "text/plain:", "## Long query strings (414, 431)", "## Truncated results"} {
		if !strings.Contains(spec, needle) {
			t.Errorf("openapi.yaml lacks %q", needle)
		}
	}
}

func TestDocsStateCurrentLimits(t *testing.T) {
	readme := readmeText(t)
	spec := string(openAPISpec)
	lockout := fmt.Sprintf("`%d`", int(authLockoutDuration/time.Second))
	rangeDays := int(maxRangeSpan / (24 * time.Hour))
	hourlyDays := int(maxHourlyBucketSpan / (24 * time.Hour))
	readmeNeedles := []string{
		fmt.Sprintf("about %d per second with bursts up to %d", int(rateLimitPerSecond), int(rateLimitBurst)),
		fmt.Sprintf("At most %d requests at once", maxInFlightPerKey),
		fmt.Sprintf("%d failed sign-ins (`401` or `403` for the token) within %d minutes", authFailureLimit, int(authFailureWindow/time.Minute)),
		fmt.Sprintf("for %d minutes", int(authLockoutDuration/time.Minute)),
		"Up to " + lockout,
		fmt.Sprintf("about %d KiB", maxHeaderBytes>>10),
		"about 6 KiB",
		groupThousands(maxHeartbeatBuckets),
		groupThousands(maxSummaryRows),
		fmt.Sprintf("repeated up to %d times", maxClientFilters),
		fmt.Sprintf("up to %d separated by commas", maxTokens),
		fmt.Sprintf("1 to %d characters", maxFilterValueLen),
		fmt.Sprintf("(1 to %d, default %d)", maxEventLimit, defaultEventLimit),
		fmt.Sprintf("`from` = %d days before `to`", defaultRangeDays),
		fmt.Sprintf("The range may span at most %d days", rangeDays),
		fmt.Sprintf("With `bucket=hour` the range may span at most %d days", hourlyDays),
		fmt.Sprintf("at most %d days, or %d days for hourly heartbeats", rangeDays, hourlyDays),
		"| 414 |", "| 431 |",
	}
	for _, needle := range readmeNeedles {
		if !strings.Contains(readme, needle) {
			t.Errorf("README.md lacks %q", needle)
		}
	}
	specNeedles := []string{
		fmt.Sprintf("about %d requests per second with bursts of up to %d", int(rateLimitPerSecond), int(rateLimitBurst)),
		fmt.Sprintf("At most %d requests per token and client IP address", maxInFlightPerKey),
		"up to " + lockout,
		fmt.Sprintf("about %d KiB", maxHeaderBytes>>10),
		"about 6 KiB",
		groupThousands(maxHeartbeatBuckets),
		groupThousands(maxSummaryRows),
		fmt.Sprintf("maxItems: %d", maxClientFilters),
		fmt.Sprintf("`from` to %d days before `to`", defaultRangeDays),
		fmt.Sprintf("With `bucket=hour` the range may span at most %d days", hourlyDays),
	}
	// Wrapped descriptions: compare with line breaks and indentation collapsed.
	flatSpec := strings.Join(strings.Fields(spec), " ")
	for _, needle := range []string{
		fmt.Sprintf("Defaults to %d days before `to`", defaultRangeDays),
		fmt.Sprintf("the range may span at most %d days", rangeDays),
	} {
		if !strings.Contains(flatSpec, needle) {
			t.Errorf("openapi.yaml lacks %q", needle)
		}
	}
	for _, needle := range specNeedles {
		if !strings.Contains(spec, needle) {
			t.Errorf("openapi.yaml lacks %q", needle)
		}
	}
	// openapi.yaml spells these out in words.
	if authFailureLimit != 10 || authFailureWindow != 5*time.Minute || authLockoutDuration != 15*time.Minute {
		t.Error("the failed-authentication lockout changed; update the wording in openapi.yaml and README.md")
	}
}

// startRealServer serves s through the production http.Server settings.
func startRealServer(t *testing.T, cfg config, s *server) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	httpServer := newHTTPServer(cfg, s)
	httpServer.ErrorLog = nil
	go func() { _ = httpServer.Serve(ln) }()
	t.Cleanup(func() { _ = httpServer.Close() })
	return ln.Addr().String()
}

func clientQuery(count, nameLength int) string {
	values := url.Values{}
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("ROOM_%04d_", i)
		values.Add("client", name+strings.Repeat("x", nameLength-len(name)))
	}
	return values.Encode()
}

// TestOversizedQueryGets431PlainTextWithoutCORS proves what README.md and
// openapi.yaml promise: a request line beyond the header limit is refused by
// the HTTP server with a plain-text 431 that carries no CORS headers.
func TestOversizedQueryGets431PlainTextWithoutCORS(t *testing.T) {
	cfg := testConfig()
	cfg.corsOrigins = map[string]struct{}{"https://viz.example.edu": {}}
	addr := startRealServer(t, cfg, newTestServer(cfg, &fakeStore{}))

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	// 200 names of 128 characters: about 27 KiB of query string.
	request := "GET /api/v1/events?" + clientQuery(maxClientFilters, maxFilterValueLen) + " HTTP/1.1\r\n" +
		"Host: " + addr + "\r\nOrigin: https://viz.example.edu\r\nAuthorization: Bearer " + testToken + "\r\n\r\n"
	// The server may stop reading early; the response is what matters.
	_, _ = io.WriteString(conn, request)
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusRequestHeaderFieldsTooLarge {
		t.Fatalf("status = %d, want 431", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("Content-Type = %q, want text/plain", ct)
	}
	if acao := resp.Header.Get("Access-Control-Allow-Origin"); acao != "" {
		t.Errorf("431 carried Access-Control-Allow-Origin %q", acao)
	}
}

// TestVisualizerQueryBudgetFitsServerLimit proves that a query within the
// documented client budget (about 6 KiB, at most 200 names) is accepted.
func TestVisualizerQueryBudgetFitsServerLimit(t *testing.T) {
	cfg := testConfig()
	addr := startRealServer(t, cfg, newTestServer(cfg, &fakeStore{}))
	query := clientQuery(128, 40)
	if len(query) > 6*1024 {
		t.Fatalf("test query is %d bytes, over the 6 KiB budget", len(query))
	}
	req, err := http.NewRequest(http.MethodGet, "http://"+addr+"/api/v1/events?"+query, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
}
