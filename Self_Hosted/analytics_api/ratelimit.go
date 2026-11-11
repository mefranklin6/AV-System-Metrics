package main

import (
	"log"
	"math"
	"net/netip"
	"sync"
	"time"
)

const (
	rateLimitPerSecond  = 10.0
	rateLimitBurst      = 40.0
	authFailureLimit    = 10
	authFailureWindow   = 5 * time.Minute
	authLockoutDuration = 15 * time.Minute
	// maxInFlightPerKey caps concurrent /api requests per (token, client
	// address), so one token holder cannot occupy every database connection
	// (maxOpenConns). The Metrics Visualizer sends one request at a time.
	maxInFlightPerKey = 3
	maxTrackedPeers   = 10_000
	peerIdleExpiry    = 20 * time.Minute
	peerSweepInterval = time.Minute
)

// limitKey identifies one rate-limit bucket. Requests that are not
// authenticated with a valid token (health probes, preflights, failed
// sign-ins) are keyed on the client address alone (token 0). Requests with a
// valid token are keyed on the token (its 1-based position in
// ANALYTICS_API_TOKEN) plus the client address, so failed or tokenless
// requests from the same address, such as a shared reverse proxy, can never
// use up the budget of authenticated users.
type limitKey struct {
	addr  netip.Addr
	token int
}

func peerKey(addr netip.Addr) limitKey { return limitKey{addr: limiterKey(addr)} }

func tokenKey(addr netip.Addr, token int) limitKey {
	return limitKey{addr: limiterKey(addr), token: token}
}

// peerState is the per-key bookkeeping kept by the limiter.
type peerState struct {
	tokens      float64
	lastRefill  time.Time
	lastSeen    time.Time
	failures    [authFailureLimit]time.Time // ring buffer of recent auth failures
	failureNext int
	lockedUntil time.Time
	inFlight    int
}

// busy reports whether the entry must be kept: it is locked out or has
// requests in flight.
func (p *peerState) busy(now time.Time) bool { return now.Before(p.lockedUntil) || p.inFlight > 0 }

// limiter is an in-memory, bounded token bucket per key, a failed
// authentication lockout per client address, and an in-flight request cap per
// key. IPv6 peers are grouped by /64 so a single host cannot trivially rotate
// through addresses in its own subnet.
type limiter struct {
	mu          sync.Mutex
	peers       map[limitKey]*peerState
	maxPeers    int
	maxInFlight int
	lastSweep   time.Time
	rate        float64
	burst       float64
	logf        func(format string, args ...any)
}

func newLimiter() *limiter {
	return &limiter{
		peers:       make(map[limitKey]*peerState),
		maxPeers:    maxTrackedPeers,
		maxInFlight: maxInFlightPerKey,
		rate:        rateLimitPerSecond,
		burst:       rateLimitBurst,
		logf:        log.Printf,
	}
}

// limiterKey groups IPv6 addresses by their /64 network.
func limiterKey(addr netip.Addr) netip.Addr {
	addr = addr.Unmap()
	if addr.Is6() {
		if prefix, err := addr.Prefix(64); err == nil {
			return prefix.Addr()
		}
	}
	return addr
}

// allow takes one token from key's bucket. When the bucket is empty it
// reports how long the client should wait.
func (l *limiter) allow(key limitKey, now time.Time) (ok bool, retryAfter time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	state := l.peerLocked(key, now)
	state.lastSeen = now

	elapsed := now.Sub(state.lastRefill).Seconds()
	if elapsed > 0 {
		state.tokens = math.Min(l.burst, state.tokens+elapsed*l.rate)
		state.lastRefill = now
	}
	if state.tokens < 1 {
		wait := time.Duration((1 - state.tokens) / l.rate * float64(time.Second))
		return false, wait
	}
	state.tokens--
	return true, 0
}

// lockedOut reports whether addr is locked out after repeated failed sign-ins.
// The lockout only applies to requests that fail authentication: a request
// with a valid token is never refused because of it.
func (l *limiter) lockedOut(addr netip.Addr, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	state, ok := l.peers[peerKey(addr)]
	if !ok || !now.Before(state.lockedUntil) {
		return false, 0
	}
	state.lastSeen = now
	return true, state.lockedUntil.Sub(now)
}

// recordAuthFailure notes a failed authentication attempt and locks the peer
// out once authFailureLimit failures happened within authFailureWindow.
func (l *limiter) recordAuthFailure(addr netip.Addr, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()

	key := peerKey(addr)
	state := l.peerLocked(key, now)
	state.lastSeen = now
	state.failures[state.failureNext] = now
	state.failureNext = (state.failureNext + 1) % authFailureLimit
	// After the write, failureNext points at the oldest of the last N failures.
	oldest := state.failures[state.failureNext]
	if oldest.IsZero() || now.Sub(oldest) > authFailureWindow || now.Before(state.lockedUntil) {
		return
	}
	state.lockedUntil = now.Add(authLockoutDuration)
	state.failures = [authFailureLimit]time.Time{}
	state.failureNext = 0
	l.logf("analytics api: %s locked out of failing sign-ins for %s after %d failed authentication attempts within %s",
		key.addr, authLockoutDuration, authFailureLimit, authFailureWindow)
}

// acquire reserves one in-flight request slot for key. Callers that get true
// must call release(key) when the request finishes.
func (l *limiter) acquire(key limitKey, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	state := l.peerLocked(key, now)
	state.lastSeen = now
	if state.inFlight >= l.maxInFlight {
		return false
	}
	state.inFlight++
	return true
}

func (l *limiter) release(key limitKey) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if state, ok := l.peers[key]; ok && state.inFlight > 0 {
		state.inFlight--
	}
}

// peerLocked returns the state for key, creating it if needed while keeping
// the map bounded. Callers must hold l.mu.
func (l *limiter) peerLocked(key limitKey, now time.Time) *peerState {
	if state, ok := l.peers[key]; ok {
		return state
	}
	if len(l.peers) >= l.maxPeers {
		l.sweepLocked(now, true)
	}
	if len(l.peers) >= l.maxPeers {
		l.evictOneLocked(now)
	}
	state := &peerState{tokens: l.burst, lastRefill: now, lastSeen: now}
	l.peers[key] = state
	return state
}

// sweepLocked drops idle entries that are not busy. It runs at most once per
// peerSweepInterval unless forced by a full map with an expired interval.
func (l *limiter) sweepLocked(now time.Time, full bool) {
	if !full || now.Sub(l.lastSweep) < peerSweepInterval {
		return
	}
	l.lastSweep = now
	for key, state := range l.peers {
		if now.Sub(state.lastSeen) > peerIdleExpiry && !state.busy(now) {
			delete(l.peers, key)
		}
	}
}

// evictOneLocked removes one entry, preferring entries that are not busy so
// an address flood cannot easily erase existing lockouts.
func (l *limiter) evictOneLocked(now time.Time) {
	var fallback limitKey
	found := false
	checked := 0
	for key, state := range l.peers {
		if !found {
			fallback, found = key, true
		}
		if !state.busy(now) {
			delete(l.peers, key)
			return
		}
		checked++
		if checked >= 64 {
			break
		}
	}
	if found {
		delete(l.peers, fallback)
	}
}

// size returns the number of tracked keys (for tests and diagnostics).
func (l *limiter) size() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.peers)
}

// retryAfterSeconds rounds a wait up to whole seconds, minimum one.
func retryAfterSeconds(wait time.Duration) int {
	seconds := int(math.Ceil(wait.Seconds()))
	if seconds < 1 {
		return 1
	}
	return seconds
}
