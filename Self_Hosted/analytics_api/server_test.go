package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

var fixedNow = time.Date(2026, time.November, 11, 0, 22, 9, 709041123, time.UTC)

// fakeStore implements store and records the last query of each kind.
type fakeStore struct {
	mu            sync.Mutex
	pingErr       error
	err           error
	info          dbInfo
	clients       []clientSummary
	events        []event
	more          bool
	summary       []summaryRow
	truncated     bool
	series        []heartbeatSeries
	hbTruncated   bool
	block         chan struct{} // when set, store calls wait until it is closed
	lastRange     timeRange
	lastEvents    eventQuery
	lastSummary   summaryQuery
	lastHeartbeat heartbeatQuery
	calls         int
}

func (f *fakeStore) Ping(context.Context) error { return f.pingErr }

func (f *fakeStore) Info(context.Context) (dbInfo, error) {
	if f.block != nil {
		<-f.block
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.info, f.err
}

func (f *fakeStore) Clients(_ context.Context, r timeRange) ([]clientSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.lastRange = r
	return f.clients, f.err
}

func (f *fakeStore) Events(_ context.Context, q eventQuery) ([]event, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.lastEvents = q
	return f.events, f.more, f.err
}

func (f *fakeStore) Summary(_ context.Context, q summaryQuery) ([]summaryRow, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.lastSummary = q
	return f.summary, f.truncated, f.err
}

func (f *fakeStore) Heartbeats(_ context.Context, q heartbeatQuery) ([]heartbeatSeries, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.lastHeartbeat = q
	return f.series, f.hbTruncated, f.err
}

func testConfig() config {
	return config{
		addr:         ":8081",
		tokenDigests: [][sha256.Size]byte{sha256.Sum256([]byte(testToken)), sha256.Sum256([]byte(testToken2))},
		corsOrigins:  map[string]struct{}{},
	}
}

func newTestServer(cfg config, st store) *server {
	s := newServer(cfg, st)
	s.now = func() time.Time { return fixedNow }
	s.limiter.logf = func(string, ...any) {}
	s.denyLog.logf = func(string, ...any) {}
	return s
}

type reqOpt func(*http.Request)

func withToken(token string) reqOpt {
	return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }
}

func withHeader(k, v string) reqOpt { return func(r *http.Request) { r.Header.Set(k, v) } }

func withRemote(addr string) reqOpt { return func(r *http.Request) { r.RemoteAddr = addr } }

func do(t *testing.T, s *server, method, target string, opts ...reqOpt) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	req.RemoteAddr = "192.0.2.10:51000"
	for _, o := range opts {
		o(req)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	return rec
}

func decodeError(t *testing.T, rec *httptest.ResponseRecorder) errorDetail {
	t.Helper()
	var body map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body is not JSON: %v: %s", err, rec.Body.String())
	}
	if len(body) != 1 {
		t.Fatalf("error body has unexpected keys: %s", rec.Body.String())
	}
	var detail map[string]string
	if err := json.Unmarshal(body["error"], &detail); err != nil || len(detail) != 2 {
		t.Fatalf("error detail malformed: %s", rec.Body.String())
	}
	return errorDetail{Code: detail["code"], Message: detail["message"]}
}

func expectError(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) errorDetail {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("status = %d, want %d; body %s", rec.Code, status, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != jsonContentType {
		t.Fatalf("Content-Type = %q", ct)
	}
	detail := decodeError(t, rec)
	if detail.Code != code || detail.Message == "" {
		t.Fatalf("error = %+v, want code %q", detail, code)
	}
	return detail
}

// ---- Authentication ----

func TestAuthentication(t *testing.T) {
	tests := []struct {
		name     string
		header   string
		multiple bool
		status   int
		code     string
	}{
		{name: "missing", status: 401, code: codeUnauthorized},
		{name: "basic scheme", header: "Basic dXNlcjpwYXNz", status: 401, code: codeUnauthorized},
		{name: "bearer without token", header: "Bearer ", status: 401, code: codeUnauthorized},
		{name: "bearer only", header: "Bearer", status: 401, code: codeUnauthorized},
		{name: "token with space", header: "Bearer abc def", status: 401, code: codeUnauthorized},
		{name: "duplicate headers", header: "Bearer " + testToken, multiple: true, status: 401, code: codeUnauthorized},
		{name: "wrong token", header: "Bearer " + strings.Repeat("x", 40), status: 403, code: codeForbidden},
		{name: "token prefix", header: "Bearer " + testToken[:len(testToken)-1], status: 403, code: codeForbidden},
		{name: "token suffix added", header: "Bearer " + testToken + "x", status: 403, code: codeForbidden},
		{name: "valid token", header: "Bearer " + testToken, status: 200},
		{name: "rotated second token", header: "Bearer " + testToken2, status: 200},
		{name: "lowercase scheme", header: "bearer " + testToken, status: 200},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			st := &fakeStore{}
			s := newTestServer(testConfig(), st)
			rec := do(t, s, http.MethodGet, "/api/v1/info", func(r *http.Request) {
				if tt.header != "" {
					r.Header.Set("Authorization", tt.header)
				}
				if tt.multiple {
					r.Header.Add("Authorization", tt.header)
				}
			})
			if tt.status == 200 {
				if rec.Code != 200 {
					t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
				}
				return
			}
			expectError(t, rec, tt.status, tt.code)
			if tt.status == 401 && rec.Header().Get("WWW-Authenticate") != `Bearer realm="avsm-analytics"` {
				t.Fatalf("WWW-Authenticate = %q", rec.Header().Get("WWW-Authenticate"))
			}
			if tt.status == 403 && rec.Header().Get("WWW-Authenticate") != "" {
				t.Fatal("403 must not carry WWW-Authenticate")
			}
			if st.calls != 0 {
				t.Fatal("store must not be queried when authentication fails")
			}
		})
	}
}

func TestErrorMessagesNeverEchoTokens(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	presented := "Presented-Secret-Token-Value-1234567890"
	rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(presented))
	if strings.Contains(rec.Body.String(), presented) {
		t.Fatal("response echoes the presented token")
	}
}

func TestUnauthenticatedRoutes(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	rec := do(t, s, http.MethodGet, "/health")
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != `{"ok":true}` {
		t.Fatalf("health = %d %s", rec.Code, rec.Body.String())
	}

	down := newTestServer(testConfig(), &fakeStore{pingErr: errors.New("connection refused")})
	rec = do(t, down, http.MethodGet, "/health")
	if rec.Code != 503 || strings.TrimSpace(rec.Body.String()) != `{"ok":false}` {
		t.Fatalf("health down = %d %s", rec.Code, rec.Body.String())
	}

	rec = do(t, s, http.MethodGet, "/openapi.yaml")
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "application/yaml" || !strings.HasPrefix(rec.Body.String(), "openapi: 3.1") {
		t.Fatalf("openapi = %d %q", rec.Code, rec.Header().Get("Content-Type"))
	}
}

// ---- Allow-list, method, routing, ordering ----

func TestAllowList(t *testing.T) {
	cfg := testConfig()
	cfg.allowedNets = []netip.Prefix{netip.MustParsePrefix("10.20.0.0/16"), netip.MustParsePrefix("2001:db8::/32")}
	s := newTestServer(cfg, &fakeStore{})

	for _, remote := range []string{"10.20.3.4:5000", "[::ffff:10.20.3.4]:5000", "[2001:db8::1]:443"} {
		if rec := do(t, s, http.MethodGet, "/api/v1/info", withRemote(remote), withToken(testToken)); rec.Code != 200 {
			t.Fatalf("%s: status %d", remote, rec.Code)
		}
	}
	for _, remote := range []string{"10.21.0.1:5000", "[2001:db9::1]:443", "garbage"} {
		rec := do(t, s, http.MethodGet, "/api/v1/info", withRemote(remote), withToken(testToken))
		expectError(t, rec, 403, codeForbidden)
	}
	// Denied before authentication: no WWW-Authenticate even without a token.
	rec := do(t, s, http.MethodGet, "/api/v1/info", withRemote("198.51.100.7:1"))
	expectError(t, rec, 403, codeForbidden)
	if rec.Header().Get("WWW-Authenticate") != "" {
		t.Fatal("allow-list must be checked before authentication")
	}
	// /health is exempt so container probes keep working.
	if rec := do(t, s, http.MethodGet, "/health", withRemote("127.0.0.1:1")); rec.Code != 200 {
		t.Fatalf("health from loopback = %d", rec.Code)
	}
	expectError(t, do(t, s, http.MethodGet, "/openapi.yaml", withRemote("198.51.100.7:1")), 403, codeForbidden)
}

func TestMethodsAndRouting(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, "TRACE"} {
		rec := do(t, s, method, "/api/v1/events", withToken(testToken))
		expectError(t, rec, 405, codeMethodNotAllowed)
		if rec.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
			t.Fatalf("Allow = %q", rec.Header().Get("Allow"))
		}
	}
	// Method is checked before auth.
	expectError(t, do(t, s, http.MethodPost, "/api/v1/events"), 405, codeMethodNotAllowed)

	if rec := do(t, s, http.MethodHead, "/api/v1/info", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("HEAD status %d", rec.Code)
	}
	expectError(t, do(t, s, http.MethodGet, "/nope"), 404, codeNotFound)
	// Unknown /api routes require authentication first so routes cannot be probed.
	expectError(t, do(t, s, http.MethodGet, "/api/v1/secret"), 401, codeUnauthorized)
	expectError(t, do(t, s, http.MethodGet, "/api/v1/secret", withToken(testToken)), 404, codeNotFound)
	expectError(t, do(t, s, http.MethodGet, "/api/v1/info/", withToken(testToken)), 404, codeNotFound)
}

func TestSecurityHeadersOnEveryResponse(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	targets := []struct{ method, path string }{
		{"GET", "/health"}, {"GET", "/openapi.yaml"}, {"GET", "/api/v1/info"}, {"GET", "/nope"}, {"POST", "/api/v1/info"},
	}
	for _, target := range targets {
		rec := do(t, s, target.method, target.path)
		h := rec.Header()
		want := map[string]string{
			"Cache-Control":                "no-store",
			"X-Content-Type-Options":       "nosniff",
			"Referrer-Policy":              "no-referrer",
			"Content-Security-Policy":      "default-src 'none'; frame-ancestors 'none'",
			"X-Frame-Options":              "DENY",
			"Cross-Origin-Resource-Policy": "same-origin",
		}
		for k, v := range want {
			if h.Get(k) != v {
				t.Fatalf("%s %s: %s = %q, want %q", target.method, target.path, k, h.Get(k), v)
			}
		}
		if h.Get("Strict-Transport-Security") != "" {
			t.Fatal("HSTS must only be sent when TLS is enabled")
		}
		if h.Get("Access-Control-Allow-Origin") != "" {
			t.Fatal("no CORS headers by default")
		}
	}

	cfg := testConfig()
	cfg.tlsCertFile, cfg.tlsKeyFile = "c", "k"
	rec := do(t, newTestServer(cfg, &fakeStore{}), http.MethodGet, "/health")
	if rec.Header().Get("Strict-Transport-Security") == "" {
		t.Fatal("HSTS missing with TLS enabled")
	}
}

// ---- CORS ----

func TestCORS(t *testing.T) {
	cfg := testConfig()
	cfg.corsOrigins = map[string]struct{}{"https://viz.example.edu": {}}
	s := newTestServer(cfg, &fakeStore{})

	preflight := do(t, s, http.MethodOptions, "/api/v1/events",
		withHeader("Origin", "https://viz.example.edu"),
		withHeader("Access-Control-Request-Method", "GET"),
		withHeader("Access-Control-Request-Headers", "authorization"))
	if preflight.Code != http.StatusNoContent {
		t.Fatalf("preflight status %d", preflight.Code)
	}
	h := preflight.Header()
	checks := map[string]string{
		"Access-Control-Allow-Origin":  "https://viz.example.edu",
		"Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type",
		"Access-Control-Max-Age":       "600",
		"Vary":                         "Origin",
	}
	for k, v := range checks {
		if h.Get(k) != v {
			t.Fatalf("preflight %s = %q, want %q", k, h.Get(k), v)
		}
	}
	if h.Get("Cross-Origin-Resource-Policy") != "" {
		t.Fatal("CORP same-origin must be omitted for an allowed CORS origin")
	}

	denied := do(t, s, http.MethodOptions, "/api/v1/events",
		withHeader("Origin", "https://evil.example.com"),
		withHeader("Access-Control-Request-Method", "GET"))
	expectError(t, denied, 403, codeForbidden)
	if denied.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("denied origin must not receive CORS headers")
	}

	// Origins are compared exactly (no suffix, scheme, or port tricks).
	for _, origin := range []string{"http://viz.example.edu", "https://viz.example.edu:8443", "https://viz.example.edu.evil.com", "null"} {
		rec := do(t, s, http.MethodGet, "/api/v1/info", withHeader("Origin", origin), withToken(testToken))
		if rec.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Fatalf("origin %q must not be allowed", origin)
		}
	}

	actual := do(t, s, http.MethodGet, "/api/v1/info", withHeader("Origin", "https://viz.example.edu"), withToken(testToken))
	if actual.Code != 200 || actual.Header().Get("Access-Control-Allow-Origin") != "https://viz.example.edu" ||
		actual.Header().Get("Access-Control-Allow-Credentials") != "" {
		t.Fatalf("actual request CORS headers wrong: %v", actual.Header())
	}
	// Error responses for allowed origins are readable by the browser app.
	unauth := do(t, s, http.MethodGet, "/api/v1/info", withHeader("Origin", "https://viz.example.edu"))
	if unauth.Code != 401 || unauth.Header().Get("Access-Control-Allow-Origin") == "" ||
		!strings.Contains(unauth.Header().Get("Access-Control-Expose-Headers"), "WWW-Authenticate") {
		t.Fatalf("401 for allowed origin lacks CORS headers: %v", unauth.Header())
	}

	// OPTIONS without Origin is a plain capability query.
	plain := do(t, s, http.MethodOptions, "/api/v1/info")
	if plain.Code != http.StatusNoContent || plain.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
		t.Fatalf("plain OPTIONS = %d", plain.Code)
	}
}

func TestCORSDisabledByDefault(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	rec := do(t, s, http.MethodOptions, "/api/v1/info",
		withHeader("Origin", "https://viz.example.edu"), withHeader("Access-Control-Request-Method", "GET"))
	expectError(t, rec, 403, codeForbidden)
	if rec.Header().Get("Vary") != "" {
		t.Fatal("Vary: Origin is only needed when CORS is configured")
	}
}

// ---- Rate limiting and lockout through the handler ----

func TestRateLimitThroughServer(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	for i := 0; i < int(rateLimitBurst); i++ {
		if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken)); rec.Code != 200 {
			t.Fatalf("request %d: status %d", i, rec.Code)
		}
	}
	rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken))
	expectError(t, rec, 429, codeTooManyRequests)
	if rec.Header().Get("Retry-After") != "1" {
		t.Fatalf("Retry-After = %q", rec.Header().Get("Retry-After"))
	}
	// Another address is unaffected.
	if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken), withRemote("192.0.2.99:1")); rec.Code != 200 {
		t.Fatalf("other peer status %d", rec.Code)
	}
	// Another token from the same address (for example behind a shared
	// reverse proxy) has its own bucket.
	if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken2)); rec.Code != 200 {
		t.Fatalf("other token status %d", rec.Code)
	}
}

// Behind a shared reverse proxy every user has the same address. Tokenless or
// wrong-token floods must not exhaust the budget of users with a valid token.
func TestUnauthenticatedFloodDoesNotAffectValidTokens(t *testing.T) {
	s := newTestServer(testConfig(), &fakeStore{})
	for i := 0; i < 3*int(rateLimitBurst); i++ {
		do(t, s, http.MethodGet, "/api/v1/info")
		do(t, s, http.MethodGet, "/health")
	}
	expectError(t, do(t, s, http.MethodGet, "/health"), 429, codeTooManyRequests)
	expectError(t, do(t, s, http.MethodGet, "/api/v1/info"), 429, codeTooManyRequests)
	if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("valid token after flood: status %d", rec.Code)
	}
}

func TestFailedAuthLockout(t *testing.T) {
	now := fixedNow
	s := newTestServer(testConfig(), &fakeStore{})
	s.now = func() time.Time { return now }
	var logs []string
	s.limiter.logf = func(format string, args ...any) { logs = append(logs, fmt.Sprintf(format, args...)) }

	for i := 0; i < authFailureLimit; i++ {
		now = now.Add(time.Second)
		rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(strings.Repeat("w", 40)))
		expectError(t, rec, 403, codeForbidden)
	}
	now = now.Add(time.Second)
	for _, opts := range [][]reqOpt{{withToken(strings.Repeat("w", 40))}, {}, {withHeader("Authorization", "Basic abc")}} {
		rec := do(t, s, http.MethodGet, "/api/v1/info", opts...)
		expectError(t, rec, 429, codeTooManyRequests)
		// Locked at the 10th failure; one second has passed since.
		if rec.Header().Get("Retry-After") != "899" {
			t.Fatalf("Retry-After = %q, want 899", rec.Header().Get("Retry-After"))
		}
	}
	if len(logs) != 1 || !strings.Contains(logs[0], "locked out") || strings.Contains(logs[0], testToken) {
		t.Fatalf("lockout logs = %v", logs)
	}
	// A valid token is never refused because of the lockout: behind a shared
	// reverse proxy the locked address belongs to every user.
	if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("valid token during lockout = %d", rec.Code)
	}
	// Non-API routes are still reachable while locked out.
	if rec := do(t, s, http.MethodGet, "/health"); rec.Code != 200 {
		t.Fatalf("health during lockout = %d", rec.Code)
	}
	now = now.Add(authLockoutDuration)
	rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(strings.Repeat("w", 40)))
	expectError(t, rec, 403, codeForbidden)
}

func TestInFlightCapPerToken(t *testing.T) {
	st := &fakeStore{block: make(chan struct{})}
	s := newTestServer(testConfig(), st)
	var wg sync.WaitGroup
	codes := make(chan int, maxInFlightPerKey)
	for i := 0; i < maxInFlightPerKey; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes <- do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken)).Code
		}()
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		s.limiter.mu.Lock()
		state := s.limiter.peers[tokenKey(netip.MustParseAddr("192.0.2.10"), 1)]
		busy := state != nil && state.inFlight == maxInFlightPerKey
		s.limiter.mu.Unlock()
		if busy {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("requests never became in flight")
		}
		time.Sleep(time.Millisecond)
	}
	rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken))
	expectError(t, rec, 429, codeTooManyRequests)
	if rec.Header().Get("Retry-After") != "1" {
		t.Fatalf("Retry-After = %q", rec.Header().Get("Retry-After"))
	}
	close(st.block)
	if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken2)); rec.Code != 200 {
		t.Fatalf("other token status %d", rec.Code)
	}
	wg.Wait()
	close(codes)
	for code := range codes {
		if code != 200 {
			t.Fatalf("in-flight request status %d", code)
		}
	}
	if rec := do(t, s, http.MethodGet, "/api/v1/info", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("slot not released: status %d", rec.Code)
	}
}

// ---- Parameter validation ----

func TestTimeRangeDefaultsAndValidation(t *testing.T) {
	st := &fakeStore{}
	s := newTestServer(testConfig(), st)

	rec := do(t, s, http.MethodGet, "/api/v1/clients", withToken(testToken))
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	wantTo := fixedNow.Truncate(time.Microsecond)
	if !st.lastRange.To.Equal(wantTo) || !st.lastRange.From.Equal(wantTo.AddDate(0, 0, -30)) {
		t.Fatalf("default range = %+v", st.lastRange)
	}
	var body clientsResponseJSON
	mustJSON(t, rec, &body)
	if body.To != "2026-11-11T00:22:09.709041Z" || body.From != "2026-10-12T00:22:09.709041Z" {
		t.Fatalf("echoed range = %s .. %s", body.From, body.To)
	}

	// Only from: to defaults to now. Only to: from defaults to to - 30 days.
	do(t, s, http.MethodGet, "/api/v1/clients?from=2026-11-01T00:00:00Z", withToken(testToken))
	if !st.lastRange.From.Equal(time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)) || !st.lastRange.To.Equal(wantTo) {
		t.Fatalf("from-only range = %+v", st.lastRange)
	}
	do(t, s, http.MethodGet, "/api/v1/clients?to=2026-03-31T00:00:00-07:00", withToken(testToken))
	if !st.lastRange.To.Equal(time.Date(2026, 3, 31, 7, 0, 0, 0, time.UTC)) || !st.lastRange.From.Equal(time.Date(2026, 3, 1, 7, 0, 0, 0, time.UTC)) {
		t.Fatalf("to-only range = %+v", st.lastRange)
	}
	// An unencoded '+' offset arrives as a space and is accepted.
	if rec := do(t, s, http.MethodGet, "/api/v1/clients?from=2026-11-01T00:00:00+00:00", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("unencoded plus offset rejected: %s", rec.Body.String())
	}
	if rec := do(t, s, http.MethodGet, "/api/v1/clients?from=2026-11-01T00:00:00%2B01:00", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("encoded plus offset rejected: %s", rec.Body.String())
	}

	bad := []string{
		"from=2026-11-01",          // no time
		"from=2026-11-01T00:00:00", // no offset
		"from=yesterday",           // garbage
		"from=",                    // empty
		"from=2026-11-01T00:00:00Z&from=2026-11-02T00:00:00Z", // repeated
		"from=2026-11-05T00:00:00Z&to=2026-11-05T00:00:00Z",   // from == to
		"from=2026-11-06T00:00:00Z&to=2026-11-05T00:00:00Z",   // from > to
		"from=2025-01-01T00:00:00Z&to=2026-02-05T00:00:01Z",   // > 400 days
		"from=2030-01-01T00:00:00Z",                           // from after default to
		"bogus=1",                                             // unknown parameter
		"client=BSS_245",                                      // not accepted by /clients
		"from=%zz",                                            // bad escape
	}
	for _, q := range bad {
		rec := do(t, s, http.MethodGet, "/api/v1/clients?"+q, withToken(testToken))
		detail := expectError(t, rec, 400, codeBadRequest)
		if strings.Contains(detail.Message, "yesterday") || strings.Contains(detail.Message, "bogus") {
			t.Fatalf("%s: message echoes input: %q", q, detail.Message)
		}
	}
	// Exactly 400 days is allowed.
	if rec := do(t, s, http.MethodGet, "/api/v1/clients?from=2025-01-01T00:00:00Z&to=2026-02-05T00:00:00Z", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("400-day span rejected: %s", rec.Body.String())
	}
}

func TestEventsParameterValidation(t *testing.T) {
	st := &fakeStore{}
	s := newTestServer(testConfig(), st)

	ok := do(t, s, http.MethodGet, "/api/v1/events?client=BSS_245&client=HOLT_155&client=BSS_245&metric=hdmi&action=Started&action=Stopped&include_heartbeats=true&limit=5000", withToken(testToken))
	if ok.Code != 200 {
		t.Fatalf("status %d: %s", ok.Code, ok.Body.String())
	}
	q := st.lastEvents
	if strings.Join(q.Clients, ",") != "BSS_245,HOLT_155" || strings.Join(q.Metrics, ",") != "hdmi" ||
		strings.Join(q.Actions, ",") != "Started,Stopped" || !q.IncludeHeartbeats || q.Limit != 5000 || q.After != nil {
		t.Fatalf("parsed query = %+v", q)
	}

	do(t, s, http.MethodGet, "/api/v1/events", withToken(testToken))
	if st.lastEvents.Limit != 1000 || st.lastEvents.IncludeHeartbeats || st.lastEvents.Clients != nil {
		t.Fatalf("defaults = %+v", st.lastEvents)
	}

	manyClients := url.Values{}
	for i := 0; i < 201; i++ {
		manyClients.Add("client", fmt.Sprintf("R%d", i))
	}
	manyMetrics := url.Values{}
	for i := 0; i < 51; i++ {
		manyMetrics.Add("metric", fmt.Sprintf("m%d", i))
	}
	bad := []string{
		"limit=0", "limit=5001", "limit=-1", "limit=1.5", "limit=abc", "limit=", "limit=+5", "limit=10&limit=20", "limit=00001000000",
		"include_heartbeats=yes", "include_heartbeats=1", "include_heartbeats=TRUE", "include_heartbeats=",
		"client=", "client=" + strings.Repeat("a", 129), "client=%00abc", "client=%ff", "metric=", "action=" + strings.Repeat("b", 129),
		manyClients.Encode(), manyMetrics.Encode(),
		"cursor=", "cursor=abc", "cursor=" + strings.Repeat("A", 34), "cursor=" + strings.Repeat("A", 100),
		"cursor=" + encodeCursor(pageCursor{Timestamp: fixedNow}) + "&cursor=" + encodeCursor(pageCursor{Timestamp: fixedNow}),
		"bucket=hour",
	}
	for _, query := range bad {
		rec := do(t, s, http.MethodGet, "/api/v1/events?"+query, withToken(testToken))
		expectError(t, rec, 400, codeBadRequest)
	}

	// 200 clients of 128 characters each are accepted at the parser level.
	maxClients := make([]string, 0, 200)
	for i := 0; i < 200; i++ {
		maxClients = append(maxClients, fmt.Sprintf("%03d", i)+strings.Repeat("é", 125))
	}
	values := url.Values{"client": maxClients}
	q2, perr := parseEventQuery(values, fixedNow)
	if perr != nil || len(q2.Clients) != 200 {
		t.Fatalf("max clients rejected: %v", perr)
	}

	cursor := pageCursor{Timestamp: time.Date(2026, 11, 10, 23, 47, 27, 225600000, time.UTC)}
	cursor.EventID, _ = parseUUID("f5ba6c9f-571c-472c-8d6a-6002f03d8209")
	if rec := do(t, s, http.MethodGet, "/api/v1/events?cursor="+encodeCursor(cursor), withToken(testToken)); rec.Code != 200 {
		t.Fatalf("valid cursor rejected: %s", rec.Body.String())
	}
	if st.lastEvents.After == nil || !st.lastEvents.After.Timestamp.Equal(cursor.Timestamp) || st.lastEvents.After.EventID != cursor.EventID {
		t.Fatalf("cursor not passed to store: %+v", st.lastEvents.After)
	}
}

func TestHeartbeatParameterValidation(t *testing.T) {
	st := &fakeStore{}
	s := newTestServer(testConfig(), st)
	if rec := do(t, s, http.MethodGet, "/api/v1/heartbeats", withToken(testToken)); rec.Code != 200 || st.lastHeartbeat.Bucket != "hour" {
		t.Fatalf("default bucket: %d %+v", rec.Code, st.lastHeartbeat)
	}
	if rec := do(t, s, http.MethodGet, "/api/v1/heartbeats?bucket=day&from=2025-11-01T00:00:00Z&to=2026-11-01T00:00:00Z", withToken(testToken)); rec.Code != 200 || st.lastHeartbeat.Bucket != "day" {
		t.Fatalf("day bucket: %d %s", rec.Code, rec.Body.String())
	}
	// 92 days hourly is fine; 92 days + 1 s is not.
	if rec := do(t, s, http.MethodGet, "/api/v1/heartbeats?from=2026-01-01T00:00:00Z&to=2026-04-03T00:00:00Z", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("92-day hourly rejected: %s", rec.Body.String())
	}
	for _, query := range []string{
		"from=2026-01-01T00:00:00Z&to=2026-04-03T00:00:01Z",
		"bucket=week", "bucket=", "bucket=hour&bucket=day", "bucket=HOUR", "limit=5",
		"bucket=day&from=2025-01-01T00:00:00Z&to=2026-02-06T00:00:00Z",
	} {
		expectError(t, do(t, s, http.MethodGet, "/api/v1/heartbeats?"+query, withToken(testToken)), 400, codeBadRequest)
	}
}

func TestSummaryAndInfoParameterValidation(t *testing.T) {
	st := &fakeStore{}
	s := newTestServer(testConfig(), st)
	if rec := do(t, s, http.MethodGet, "/api/v1/summary?client=ARTS_107&include_heartbeats=true", withToken(testToken)); rec.Code != 200 {
		t.Fatalf("summary: %s", rec.Body.String())
	}
	if !st.lastSummary.IncludeHeartbeats || len(st.lastSummary.Clients) != 1 {
		t.Fatalf("summary query = %+v", st.lastSummary)
	}
	for _, query := range []string{"limit=5", "metric=x", "include_heartbeats=maybe", "client="} {
		expectError(t, do(t, s, http.MethodGet, "/api/v1/summary?"+query, withToken(testToken)), 400, codeBadRequest)
	}
	expectError(t, do(t, s, http.MethodGet, "/api/v1/info?from=2026-01-01T00:00:00Z", withToken(testToken)), 400, codeBadRequest)
}

func TestParametersValidatedBeforeQuery(t *testing.T) {
	st := &fakeStore{}
	s := newTestServer(testConfig(), st)
	expectError(t, do(t, s, http.MethodGet, "/api/v1/events?limit=0", withToken(testToken)), 400, codeBadRequest)
	if st.calls != 0 {
		t.Fatal("store queried despite invalid parameters")
	}
}

// ---- Response shapes ----

type clientsResponseJSON struct {
	From    string                       `json:"from"`
	To      string                       `json:"to"`
	Clients []map[string]json.RawMessage `json:"clients"`
}

func mustJSON(t *testing.T, rec *httptest.ResponseRecorder, v any) {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != jsonContentType {
		t.Fatalf("Content-Type = %q", ct)
	}
	if err := json.Unmarshal(rec.Body.Bytes(), v); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, rec.Body.String())
	}
}

var timestampPattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$`)

func ts(s string) apiTime {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		panic(err)
	}
	return newAPITime(t)
}

func tsPtr(s string) *apiTime { v := ts(s); return &v }

func TestInfoResponseShape(t *testing.T) {
	status := "succeeded"
	days := int64(30)
	st := &fakeStore{info: dbInfo{
		ActivityRange:  activityRange{FirstEvent: tsPtr("2026-02-03T14:00:01Z"), LastEvent: tsPtr("2026-11-11T00:20:55.103221+00:00")},
		HeartbeatPurge: heartbeatPurgeInfo{EnabledStatus: &status, RetentionDays: &days, Cutoff: tsPtr("2026-10-11T03:00:00Z"), FinishedAt: tsPtr("2026-11-10T03:00:12.512Z")},
	}}
	rec := do(t, newTestServer(testConfig(), st), http.MethodGet, "/api/v1/info", withToken(testToken))
	want := `{"api_version":"1","server_time":"2026-11-11T00:22:09.709041Z","activity_range":{"first_event":"2026-02-03T14:00:01.000000Z","last_event":"2026-11-11T00:20:55.103221Z"},"heartbeat_purge":{"enabled_status":"succeeded","retention_days":30,"cutoff":"2026-10-11T03:00:00.000000Z","finished_at":"2026-11-10T03:00:12.512000Z"}}`
	if strings.TrimSpace(rec.Body.String()) != want {
		t.Fatalf("info body\n got %s\nwant %s", rec.Body.String(), want)
	}

	empty := do(t, newTestServer(testConfig(), &fakeStore{}), http.MethodGet, "/api/v1/info", withToken(testToken))
	wantEmpty := `{"api_version":"1","server_time":"2026-11-11T00:22:09.709041Z","activity_range":{"first_event":null,"last_event":null},"heartbeat_purge":{"enabled_status":null,"retention_days":null,"cutoff":null,"finished_at":null}}`
	if strings.TrimSpace(empty.Body.String()) != wantEmpty {
		t.Fatalf("empty info body\n got %s\nwant %s", empty.Body.String(), wantEmpty)
	}
}

func TestClientsResponseShape(t *testing.T) {
	st := &fakeStore{clients: []clientSummary{
		{ClientName: "BSS_245", EventCount: 3, HeartbeatCount: 10, FirstEvent: tsPtr("2026-11-01T10:00:00Z"), LastEvent: tsPtr("2026-11-02T10:00:00Z"), LastHeartbeat: tsPtr("2026-11-02T11:00:00Z")},
		{ClientName: "HOLT_155", HeartbeatCount: 5, LastHeartbeat: tsPtr("2026-11-02T11:00:00Z")},
	}}
	rec := do(t, newTestServer(testConfig(), st), http.MethodGet, "/api/v1/clients", withToken(testToken))
	var body clientsResponseJSON
	mustJSON(t, rec, &body)
	if len(body.Clients) != 2 {
		t.Fatalf("clients = %s", rec.Body.String())
	}
	keys := []string{"clientname", "event_count", "heartbeat_count", "first_event", "last_event", "last_heartbeat"}
	for _, c := range body.Clients {
		if len(c) != len(keys) {
			t.Fatalf("client keys = %v", c)
		}
		for _, k := range keys {
			if _, ok := c[k]; !ok {
				t.Fatalf("missing key %s", k)
			}
		}
	}
	if string(body.Clients[1]["first_event"]) != "null" || string(body.Clients[1]["event_count"]) != "0" {
		t.Fatalf("heartbeat-only client = %v", body.Clients[1])
	}

	// An empty result is an empty array, never null.
	rec = do(t, newTestServer(testConfig(), &fakeStore{clients: []clientSummary{}}), http.MethodGet, "/api/v1/clients", withToken(testToken))
	if !strings.Contains(rec.Body.String(), `"clients":[]`) {
		t.Fatalf("empty clients = %s", rec.Body.String())
	}
}

func TestEventsResponseAndNextCursor(t *testing.T) {
	events := []event{
		{ID: 1, ClientName: "Holt_171", EventTimestamp: ts("2026-11-10T23:47:27.2256Z"), Metric: "System - User", Action: "Stopped", EventID: "f5ba6c9f-571c-472c-8d6a-6002f03d8209", ReceivedAt: ts("2026-11-10T23:47:37.295791Z")},
		{ID: 2, ClientName: "Holt_171", EventTimestamp: ts("2026-11-10T23:47:28.145687Z"), Metric: "Projector_2", Action: "Stopped", EventID: "c114bf2c-19c0-4559-adc3-47ac07ea7e53", ReceivedAt: ts("2026-11-10T23:47:37.295795Z")},
	}
	st := &fakeStore{events: events, more: true}
	s := newTestServer(testConfig(), st)
	rec := do(t, s, http.MethodGet, "/api/v1/events?limit=2", withToken(testToken))
	var body struct {
		From       string                       `json:"from"`
		To         string                       `json:"to"`
		Events     []map[string]json.RawMessage `json:"events"`
		NextCursor *string                      `json:"next_cursor"`
	}
	mustJSON(t, rec, &body)
	if len(body.Events) != 2 || body.NextCursor == nil {
		t.Fatalf("events body = %s", rec.Body.String())
	}
	first := body.Events[0]
	if len(first) != 7 || string(first["event_timestamp"]) != `"2026-11-10T23:47:27.225600Z"` || string(first["id"]) != "1" ||
		string(first["event_id"]) != `"f5ba6c9f-571c-472c-8d6a-6002f03d8209"` {
		t.Fatalf("event = %v", first)
	}
	for _, e := range body.Events {
		for _, key := range []string{"event_timestamp", "received_at"} {
			var v string
			_ = json.Unmarshal(e[key], &v)
			if !timestampPattern.MatchString(v) {
				t.Fatalf("%s = %q not in API timestamp format", key, v)
			}
		}
		if _, leaked := e["source_ip"]; leaked {
			t.Fatal("source_ip must never be returned")
		}
	}
	c, err := decodeCursor(*body.NextCursor)
	if err != nil || !c.Timestamp.Equal(events[1].EventTimestamp.Time) || formatUUID(c.EventID) != events[1].EventID {
		t.Fatalf("next cursor = %+v, %v", c, err)
	}

	st.more = false
	rec = do(t, s, http.MethodGet, "/api/v1/events", withToken(testToken))
	if !strings.Contains(rec.Body.String(), `"next_cursor":null`) {
		t.Fatalf("last page must have null next_cursor: %s", rec.Body.String())
	}

	rec = do(t, newTestServer(testConfig(), &fakeStore{events: []event{}}), http.MethodGet, "/api/v1/events", withToken(testToken))
	if !strings.Contains(rec.Body.String(), `"events":[]`) || !strings.Contains(rec.Body.String(), `"next_cursor":null`) {
		t.Fatalf("empty events = %s", rec.Body.String())
	}
}

func TestSummaryAndHeartbeatsResponseShape(t *testing.T) {
	st := &fakeStore{
		summary:   []summaryRow{{ClientName: "BSS_245", Metric: "hdmi", Action: "Started", Count: 41, FirstEvent: ts("2026-10-13T15:02:11Z"), LastEvent: ts("2026-11-10T19:44:03.12Z")}},
		truncated: true,
		series: []heartbeatSeries{{ClientName: "BSS_245", Buckets: []heartbeatBucket{
			{Start: ts("2026-11-09T00:00:00Z"), Count: 12}, {Start: ts("2026-11-09T01:00:00Z"), Count: 11},
		}}},
	}
	s := newTestServer(testConfig(), st)
	rec := do(t, s, http.MethodGet, "/api/v1/summary?from=2026-10-12T00:00:00Z&to=2026-11-11T00:00:00Z", withToken(testToken))
	want := `{"from":"2026-10-12T00:00:00.000000Z","to":"2026-11-11T00:00:00.000000Z","truncated":true,"rows":[{"clientname":"BSS_245","metric":"hdmi","action":"Started","count":41,"first_event":"2026-10-13T15:02:11.000000Z","last_event":"2026-11-10T19:44:03.120000Z"}]}`
	if strings.TrimSpace(rec.Body.String()) != want {
		t.Fatalf("summary\n got %s\nwant %s", rec.Body.String(), want)
	}
	rec = do(t, s, http.MethodGet, "/api/v1/heartbeats?from=2026-11-09T00:00:00Z&to=2026-11-11T00:00:00Z", withToken(testToken))
	want = `{"from":"2026-11-09T00:00:00.000000Z","to":"2026-11-11T00:00:00.000000Z","bucket":"hour","truncated":false,"series":[{"clientname":"BSS_245","buckets":[{"start":"2026-11-09T00:00:00.000000Z","count":12},{"start":"2026-11-09T01:00:00.000000Z","count":11}]}]}`
	if strings.TrimSpace(rec.Body.String()) != want {
		t.Fatalf("heartbeats\n got %s\nwant %s", rec.Body.String(), want)
	}
	st.hbTruncated = true
	rec = do(t, s, http.MethodGet, "/api/v1/heartbeats?from=2026-11-09T00:00:00Z&to=2026-11-11T00:00:00Z", withToken(testToken))
	if !strings.Contains(rec.Body.String(), `"bucket":"hour","truncated":true,"series"`) {
		t.Fatalf("truncated heartbeats = %s", rec.Body.String())
	}
}

func TestAPITimeFormat(t *testing.T) {
	loc := time.FixedZone("PDT", -7*3600)
	cases := map[time.Time]string{
		time.Date(2026, 11, 10, 17, 22, 9, 709041999, loc): `"2026-11-11T00:22:09.709041Z"`,
		time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC):        `"2026-01-02T03:04:05.000000Z"`,
	}
	for in, want := range cases {
		got, _ := newAPITime(in).MarshalJSON()
		if string(got) != want {
			t.Fatalf("apiTime(%v) = %s, want %s", in, got, want)
		}
	}
}

// ---- Store error mapping ----

func TestStoreErrorsAreGeneric(t *testing.T) {
	cases := []struct {
		err    error
		status int
		code   string
	}{
		{errors.New(`relation "secret_table" does not exist`), 500, codeInternal},
		{&pgconn.PgError{Code: "42501", Message: "permission denied for table metric_events"}, 500, codeInternal},
		{&pgconn.PgError{Code: "57014", Message: "canceling statement due to statement timeout"}, 503, codeUnavailable},
		{fmt.Errorf("wrapped: %w", context.DeadlineExceeded), 503, codeUnavailable},
		{&pgconn.PgError{Code: "08006", Message: "connection failure"}, 503, codeUnavailable},
		{&pgconn.PgError{Code: "53300", Message: "too many connections"}, 503, codeUnavailable},
	}
	for _, tc := range cases {
		s := newTestServer(testConfig(), &fakeStore{err: tc.err})
		for _, path := range []string{"/api/v1/info", "/api/v1/clients", "/api/v1/events", "/api/v1/summary", "/api/v1/heartbeats"} {
			rec := do(t, s, http.MethodGet, path, withToken(testToken))
			detail := expectError(t, rec, tc.status, tc.code)
			if strings.Contains(detail.Message, "secret_table") || strings.Contains(detail.Message, "permission") || strings.Contains(detail.Message, "metric_events") {
				t.Fatalf("%s leaks database error: %q", path, detail.Message)
			}
		}
	}
}

func TestHTTPServerLimits(t *testing.T) {
	srv := newHTTPServer(testConfig(), http.NotFoundHandler())
	if srv.MaxHeaderBytes != 16<<10 || srv.ReadHeaderTimeout == 0 || srv.WriteTimeout <= requestTimeout || srv.TLSConfig.MinVersion < 0x0303 {
		t.Fatalf("server limits = %+v", srv)
	}
}

func TestThrottledLogger(t *testing.T) {
	var lines []string
	l := &throttledLogger{every: time.Hour, logf: func(f string, a ...any) { lines = append(lines, fmt.Sprintf(f, a...)) }}
	for i := 0; i < 5; i++ {
		l.printf("denied %d", i)
	}
	if len(lines) != 1 || lines[0] != "denied 0" {
		t.Fatalf("lines = %v", lines)
	}
	l.last = time.Now().Add(-2 * time.Hour)
	l.printf("denied again")
	if len(lines) != 2 || !strings.Contains(lines[1], "4 similar messages suppressed") {
		t.Fatalf("lines = %v", lines)
	}
}

func TestOpenAPIDocumentsEveryRoute(t *testing.T) {
	spec := string(openAPISpec)
	s := newTestServer(testConfig(), &fakeStore{})
	for path := range s.routes {
		if !strings.Contains(spec, "\n  "+path+":\n") {
			t.Fatalf("openapi.yaml does not document %s", path)
		}
	}
	for _, needle := range []string{"openapi: 3.1.0", "bearerAuth:", "scheme: bearer", "enabled_status", "next_cursor", "too_many_requests", "Retry-After"} {
		if !strings.Contains(spec, needle) {
			t.Fatalf("openapi.yaml lacks %q", needle)
		}
	}
	if strings.Contains(spec, "\t") {
		t.Fatal("openapi.yaml must not contain tabs (invalid YAML indentation)")
	}
	// Example cursor in the spec must be a real, valid cursor.
	m := regexp.MustCompile(`next_cursor: (\S+)`).FindStringSubmatch(spec)
	if m == nil {
		t.Fatal("no next_cursor example")
	}
	if _, err := decodeCursor(m[1]); err != nil {
		t.Fatalf("example cursor %q invalid: %v", m[1], err)
	}
}
