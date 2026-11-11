package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	requestTimeout   = 20 * time.Second
	healthTimeout    = 2 * time.Second
	corsMaxAgeSecs   = "600"
	allowedMethods   = "GET, HEAD, OPTIONS"
	wwwAuthenticate  = `Bearer realm="avsm-analytics"`
	apiPathPrefix    = "/api/"
	jsonContentType  = "application/json; charset=utf-8"
	yamlContentType  = "application/yaml"
	maxHeaderBytes   = 16 << 10
	logThrottleEvery = 10 * time.Second
)

// Error codes returned in {"error":{"code":...,"message":...}}.
const (
	codeBadRequest       = "bad_request"
	codeUnauthorized     = "unauthorized"
	codeForbidden        = "forbidden"
	codeNotFound         = "not_found"
	codeMethodNotAllowed = "method_not_allowed"
	codeTooManyRequests  = "too_many_requests"
	codeInternal         = "internal"
	codeUnavailable      = "unavailable"
)

type routeHandler func(w http.ResponseWriter, r *http.Request)

type server struct {
	cfg     config
	store   store
	limiter *limiter
	now     func() time.Time
	routes  map[string]routeHandler
	denyLog *throttledLogger
}

func newServer(cfg config, st store) *server {
	s := &server{
		cfg:     cfg,
		store:   st,
		limiter: newLimiter(),
		now:     time.Now,
		denyLog: &throttledLogger{every: logThrottleEvery, logf: log.Printf},
	}
	s.routes = map[string]routeHandler{
		"/health":            s.handleHealth,
		"/openapi.yaml":      s.handleOpenAPI,
		"/api/v1/info":       s.handleInfo,
		"/api/v1/clients":    s.handleClients,
		"/api/v1/events":     s.handleEvents,
		"/api/v1/summary":    s.handleSummary,
		"/api/v1/heartbeats": s.handleHeartbeats,
	}
	return s
}

// ServeHTTP enforces, in order: peer IP allow-list, method, authentication
// with its rate limits, then the route handler (parameters, query).
//
// Authentication runs before the failed-sign-in lockout so that a valid token
// is never refused because someone else behind the same address (for example
// a shared reverse proxy) sent wrong tokens. Requests without a valid token
// are charged to the client address and are subject to the lockout; requests
// with a valid token are charged to that token plus the client address.
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	header := w.Header()
	setSecurityHeaders(header, s.cfg.tlsEnabled())
	origin := r.Header.Get("Origin")
	corsAllowed := s.applyCORS(header, origin)

	path := r.URL.Path
	handler, known := s.routes[path]
	isAPI := strings.HasPrefix(path, apiPathPrefix)

	peer, ok := peerAddr(r.RemoteAddr)
	if !ok {
		writeError(w, http.StatusForbidden, codeForbidden, "Forbidden.")
		return
	}
	// /health stays reachable for container and load-balancer probes; it only
	// reports whether the database is reachable.
	if path != "/health" && !s.peerAllowed(peer) {
		s.denyLog.printf("analytics api: rejected request from address outside ANALYTICS_ALLOWED_NET: %s", peer)
		writeError(w, http.StatusForbidden, codeForbidden, "Your network address is not allowed to use this API.")
		return
	}

	authenticated := isAPI && (r.Method == http.MethodGet || r.Method == http.MethodHead)
	if !authenticated {
		// Unauthenticated routes, preflights, unknown paths, and unsupported
		// methods only cost the client address.
		if !s.allowRequest(w, peerKey(peer)) {
			return
		}
		switch {
		case !known && !isAPI:
			writeError(w, http.StatusNotFound, codeNotFound, "Not found.")
		case r.Method == http.MethodOptions:
			s.handleOptions(w, r, origin, corsAllowed)
		case r.Method != http.MethodGet && r.Method != http.MethodHead:
			header.Set("Allow", allowedMethods)
			writeError(w, http.StatusMethodNotAllowed, codeMethodNotAllowed, "Only GET, HEAD, and OPTIONS are supported.")
		default:
			handler(w, r)
		}
		return
	}

	tokenIndex, status, code, message := s.authenticate(r)
	if status != 0 {
		now := s.now()
		if locked, wait := s.limiter.lockedOut(peer, now); locked {
			s.writeTooManyRequests(w, wait)
			return
		}
		if !s.allowRequest(w, peerKey(peer)) {
			return
		}
		s.limiter.recordAuthFailure(peer, now)
		if status == http.StatusUnauthorized {
			header.Set("WWW-Authenticate", wwwAuthenticate)
		}
		writeError(w, status, code, message)
		return
	}

	key := tokenKey(peer, tokenIndex)
	if !s.allowRequest(w, key) {
		return
	}
	if !known {
		writeError(w, http.StatusNotFound, codeNotFound, "Not found.")
		return
	}
	if !s.limiter.acquire(key, s.now()) {
		s.writeTooManyRequests(w, time.Second)
		return
	}
	defer s.limiter.release(key)
	handler(w, r)
}

// allowRequest charges one request to key's bucket, writing a 429 response
// when the bucket is empty.
func (s *server) allowRequest(w http.ResponseWriter, key limitKey) bool {
	if ok, wait := s.limiter.allow(key, s.now()); !ok {
		s.writeTooManyRequests(w, wait)
		return false
	}
	return true
}

func (s *server) writeTooManyRequests(w http.ResponseWriter, wait time.Duration) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfterSeconds(wait)))
	writeError(w, http.StatusTooManyRequests, codeTooManyRequests, "Too many requests. Wait for the number of seconds in the Retry-After header, then try again.")
}

func setSecurityHeaders(h http.Header, tlsEnabled bool) {
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	h.Set("X-Frame-Options", "DENY")
	if tlsEnabled {
		h.Set("Strict-Transport-Security", "max-age=31536000")
	}
}

// applyCORS adds CORS response headers for exactly-allowed origins and
// reports whether the origin is allowed.
func (s *server) applyCORS(h http.Header, origin string) bool {
	if len(s.cfg.corsOrigins) > 0 {
		h.Add("Vary", "Origin")
	}
	allowed := false
	if origin != "" {
		_, allowed = s.cfg.corsOrigins[origin]
	}
	if !allowed {
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		return false
	}
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Access-Control-Expose-Headers", "Retry-After, WWW-Authenticate")
	return true
}

func (s *server) handleOptions(w http.ResponseWriter, r *http.Request, origin string, corsAllowed bool) {
	h := w.Header()
	h.Set("Allow", allowedMethods)
	if origin == "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if !corsAllowed {
		writeError(w, http.StatusForbidden, codeForbidden, "This origin is not allowed. Add it to ANALYTICS_CORS_ORIGINS on the server.")
		return
	}
	if r.Header.Get("Access-Control-Request-Method") != "" {
		h.Set("Access-Control-Allow-Methods", allowedMethods)
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		h.Set("Access-Control-Max-Age", corsMaxAgeSecs)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) peerAllowed(peer netip.Addr) bool {
	if len(s.cfg.allowedNets) == 0 {
		return true
	}
	for _, prefix := range s.cfg.allowedNets {
		if prefix.Contains(peer) {
			return true
		}
	}
	return false
}

func peerAddr(remoteAddr string) (netip.Addr, bool) {
	if addrPort, err := netip.ParseAddrPort(remoteAddr); err == nil {
		return addrPort.Addr().Unmap().WithZone(""), true
	}
	if addr, err := netip.ParseAddr(remoteAddr); err == nil {
		return addr.Unmap().WithZone(""), true
	}
	return netip.Addr{}, false
}

// authenticate returns a zero status and the 1-based position of the
// matching token in ANALYTICS_API_TOKEN when the bearer token is valid.
// The presented token is hashed and compared against every configured digest
// in constant time without an early exit, so timing reveals neither which
// token matched nor token lengths.
func (s *server) authenticate(r *http.Request) (int, int, string, string) {
	values := r.Header.Values("Authorization")
	if len(values) == 0 {
		return 0, http.StatusUnauthorized, codeUnauthorized, "Missing Authorization header. Send: Authorization: Bearer <token>."
	}
	if len(values) > 1 {
		return 0, http.StatusUnauthorized, codeUnauthorized, "Send exactly one Authorization header."
	}
	scheme, token, found := strings.Cut(values[0], " ")
	if !found || !strings.EqualFold(scheme, "Bearer") || token == "" || len(token) > maxTokenLength || !isTokenCharset(token) {
		return 0, http.StatusUnauthorized, codeUnauthorized, "Malformed Authorization header. Send: Authorization: Bearer <token>."
	}
	presented := sha256.Sum256([]byte(token))
	match := 0
	for i := range s.cfg.tokenDigests {
		equal := subtle.ConstantTimeCompare(presented[:], s.cfg.tokenDigests[i][:])
		match = subtle.ConstantTimeSelect(equal, i+1, match)
	}
	if match == 0 {
		return 0, http.StatusForbidden, codeForbidden, "The API token is not valid."
	}
	return match, 0, "", ""
}

// ---- Responses ----

type errorBody struct {
	Error errorDetail `json:"error"`
}

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorBody{Error: errorDetail{Code: code, Message: message}})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(body); err != nil {
		log.Printf("analytics api: could not encode response: %v", err)
		buf.Reset()
		status = http.StatusInternalServerError
		_ = json.NewEncoder(&buf).Encode(errorBody{Error: errorDetail{Code: codeInternal, Message: "Internal server error."}})
	}
	h := w.Header()
	h.Set("Content-Type", jsonContentType)
	h.Set("Content-Length", strconv.Itoa(buf.Len()))
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

// writeStoreError maps database failures to generic API errors. Details are
// logged server-side only; responses never echo database errors.
func (s *server) writeStoreError(w http.ResponseWriter, r *http.Request, route string, err error) {
	if r.Context().Err() != nil {
		// The client went away; nobody is listening for the response.
		return
	}
	var pgErr *pgconn.PgError
	isPG := errors.As(err, &pgErr)
	code := ""
	if isPG {
		code = pgErr.Code
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded), code == "57014", code == "55P03":
		// 57014 query_canceled (statement_timeout), 55P03 lock_not_available (lock_timeout).
		log.Printf("analytics api: %s query timed out: %v", route, err)
		writeError(w, http.StatusServiceUnavailable, codeUnavailable, "The query took too long. Narrow the date range or filter by fewer rooms and try again.")
	case strings.HasPrefix(code, "08"), code == "53300", code == "57P01", code == "57P03",
		!isPG && isConnectionError(err):
		log.Printf("analytics api: %s database unavailable: %v", route, err)
		writeError(w, http.StatusServiceUnavailable, codeUnavailable, "The database is temporarily unavailable. Try again shortly.")
	default:
		log.Printf("analytics api: %s query failed: %v", route, err)
		writeError(w, http.StatusInternalServerError, codeInternal, "Internal server error.")
	}
}

func isConnectionError(err error) bool {
	var connectErr *pgconn.ConnectError
	return errors.As(err, &connectErr) || pgconn.SafeToRetry(err)
}

// throttledLogger prints at most one line per interval and reports how many
// lines were suppressed, so floods of denied requests cannot flood the logs.
type throttledLogger struct {
	mu         sync.Mutex
	every      time.Duration
	last       time.Time
	suppressed int
	logf       func(format string, args ...any)
}

func (t *throttledLogger) printf(format string, args ...any) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	if !t.last.IsZero() && now.Sub(t.last) < t.every {
		t.suppressed++
		return
	}
	if t.suppressed > 0 {
		format += " (%d similar messages suppressed)"
		args = append(args, t.suppressed)
	}
	t.last = now
	t.suppressed = 0
	t.logf(format, args...)
}
