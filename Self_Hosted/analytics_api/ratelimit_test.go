package main

import (
	"net/netip"
	"testing"
	"time"
)

func quietLimiter() *limiter {
	l := newLimiter()
	l.logf = func(string, ...any) {}
	return l
}

func TestTokenBucketBurstAndRefill(t *testing.T) {
	l := quietLimiter()
	peer := peerKey(netip.MustParseAddr("192.0.2.1"))
	now := time.Unix(1_800_000_000, 0)
	for i := 0; i < int(rateLimitBurst); i++ {
		if ok, _ := l.allow(peer, now); !ok {
			t.Fatalf("request %d denied within burst", i)
		}
	}
	ok, wait := l.allow(peer, now)
	if ok || wait <= 0 || wait > 200*time.Millisecond {
		t.Fatalf("over burst: ok=%v wait=%s", ok, wait)
	}
	// 100 ms refills one token at 10 req/s.
	if ok, _ := l.allow(peer, now.Add(100*time.Millisecond)); !ok {
		t.Fatal("token not refilled after 100ms")
	}
	if ok, _ := l.allow(peer, now.Add(100*time.Millisecond)); ok {
		t.Fatal("only one token should have refilled")
	}
	// Refill never exceeds the burst.
	later := now.Add(time.Hour)
	for i := 0; i < int(rateLimitBurst); i++ {
		if ok, _ := l.allow(peer, later); !ok {
			t.Fatalf("request %d denied after full refill", i)
		}
	}
	if ok, _ := l.allow(peer, later); ok {
		t.Fatal("bucket exceeded burst capacity")
	}
}

func TestTokenAndPeerBucketsAreSeparate(t *testing.T) {
	l := quietLimiter()
	addr := netip.MustParseAddr("192.0.2.1")
	now := time.Unix(1_800_000_000, 0)
	for i := 0; i < int(rateLimitBurst); i++ {
		l.allow(peerKey(addr), now)
	}
	if ok, _ := l.allow(peerKey(addr), now); ok {
		t.Fatal("peer bucket not exhausted")
	}
	if ok, _ := l.allow(tokenKey(addr, 1), now); !ok {
		t.Fatal("an exhausted address bucket must not limit valid-token requests")
	}
	for i := 0; i < int(rateLimitBurst); i++ {
		l.allow(tokenKey(addr, 1), now)
	}
	if ok, _ := l.allow(tokenKey(addr, 2), now); !ok {
		t.Fatal("each token has its own bucket")
	}
}

func TestLockoutWindowIsSliding(t *testing.T) {
	l := quietLimiter()
	peer := netip.MustParseAddr("192.0.2.2")
	now := time.Unix(1_800_000_000, 0)

	// Failures spread wider than the window never lock out.
	for i := 0; i < 3*authFailureLimit; i++ {
		l.recordAuthFailure(peer, now.Add(time.Duration(i)*(authFailureWindow/time.Duration(authFailureLimit-1)+time.Second)))
	}
	if locked, _ := l.lockedOut(peer, now.Add(time.Hour)); locked {
		t.Fatal("spread-out failures must not lock out")
	}

	l2 := quietLimiter()
	start := now
	for i := 0; i < authFailureLimit-1; i++ {
		l2.recordAuthFailure(peer, start.Add(time.Duration(i)*time.Second))
	}
	if locked, _ := l2.lockedOut(peer, start.Add(time.Minute)); locked {
		t.Fatal("locked out before reaching the failure limit")
	}
	lockAt := start.Add(4 * time.Minute)
	l2.recordAuthFailure(peer, lockAt)
	locked, wait := l2.lockedOut(peer, lockAt.Add(time.Second))
	if !locked || wait != authLockoutDuration-time.Second {
		t.Fatalf("expected lockout: locked=%v wait=%s", locked, wait)
	}
	// The lockout never consumes or blocks the request buckets.
	if ok, _ := l2.allow(peerKey(peer), lockAt.Add(2*time.Second)); !ok {
		t.Fatal("bucket blocked by lockout")
	}
	if locked, _ := l2.lockedOut(peer, lockAt.Add(authLockoutDuration)); locked {
		t.Fatal("lockout did not expire")
	}
	if locked, _ := l2.lockedOut(netip.MustParseAddr("192.0.2.3"), lockAt.Add(time.Second)); locked {
		t.Fatal("lockout leaked to another address")
	}
}

func TestLockoutLoggedOnce(t *testing.T) {
	l := newLimiter()
	count := 0
	l.logf = func(string, ...any) { count++ }
	peer := netip.MustParseAddr("192.0.2.3")
	now := time.Unix(1_800_000_000, 0)
	for i := 0; i < 3*authFailureLimit; i++ {
		l.recordAuthFailure(peer, now.Add(time.Duration(i)*time.Second))
	}
	if count != 1 {
		t.Fatalf("lockout logged %d times, want 1", count)
	}
}

func TestIPv6PeersGroupedBySlash64(t *testing.T) {
	l := quietLimiter()
	now := time.Unix(1_800_000_000, 0)
	a := netip.MustParseAddr("2001:db8:1:2::1")
	b := netip.MustParseAddr("2001:db8:1:2:ffff::9")
	c := netip.MustParseAddr("2001:db8:1:3::1")
	for i := 0; i < int(rateLimitBurst); i++ {
		l.allow(peerKey(a), now)
	}
	if ok, _ := l.allow(peerKey(b), now); ok {
		t.Fatal("same /64 must share a bucket")
	}
	if ok, _ := l.allow(peerKey(c), now); !ok {
		t.Fatal("different /64 must have its own bucket")
	}
	if limiterKey(netip.MustParseAddr("::ffff:192.0.2.1")) != netip.MustParseAddr("192.0.2.1") {
		t.Fatal("IPv4-mapped addresses must be unmapped")
	}
}

func TestInFlightAcquireRelease(t *testing.T) {
	l := quietLimiter()
	key := tokenKey(netip.MustParseAddr("192.0.2.4"), 1)
	now := time.Unix(1_800_000_000, 0)
	for i := 0; i < maxInFlightPerKey; i++ {
		if !l.acquire(key, now) {
			t.Fatalf("slot %d refused", i)
		}
	}
	if l.acquire(key, now) {
		t.Fatal("in-flight cap exceeded")
	}
	if !l.acquire(tokenKey(netip.MustParseAddr("192.0.2.4"), 2), now) {
		t.Fatal("another token shares the cap")
	}
	l.release(key)
	if !l.acquire(key, now) {
		t.Fatal("released slot not reusable")
	}
	// Releasing an unknown key or more than acquired is harmless.
	l.release(peerKey(netip.MustParseAddr("198.51.100.200")))
	for i := 0; i < 2*maxInFlightPerKey; i++ {
		l.release(key)
	}
	if !l.acquire(key, now) {
		t.Fatal("over-release broke the counter")
	}
}

func TestLimiterMemoryIsBounded(t *testing.T) {
	l := quietLimiter()
	l.maxPeers = 100
	now := time.Unix(1_800_000_000, 0)
	locked := netip.MustParseAddr("198.51.100.1")
	for i := 0; i < authFailureLimit; i++ {
		l.recordAuthFailure(locked, now)
	}
	busy := tokenKey(netip.MustParseAddr("198.51.100.2"), 1)
	l.acquire(busy, now)
	for i := 0; i < 5000; i++ {
		addr := netip.AddrFrom4([4]byte{10, byte(i >> 16), byte(i >> 8), byte(i)})
		l.allow(peerKey(addr), now.Add(time.Duration(i)*time.Millisecond))
		if l.size() > l.maxPeers {
			t.Fatalf("limiter grew to %d entries", l.size())
		}
	}
	if isLocked, _ := l.lockedOut(locked, now.Add(10*time.Second)); !isLocked {
		t.Fatal("address flood evicted an active lockout")
	}
	l.mu.Lock()
	state := l.peers[busy]
	l.mu.Unlock()
	if state == nil || state.inFlight != 1 {
		t.Fatal("address flood evicted an entry with requests in flight")
	}

	// Idle entries are swept once the map is full and the sweep interval passed.
	later := now.Add(time.Hour)
	l.allow(peerKey(netip.MustParseAddr("203.0.113.5")), later)
	if l.size() > 4 {
		t.Fatalf("idle peers not swept: %d entries", l.size())
	}
}

func TestRetryAfterSeconds(t *testing.T) {
	cases := map[time.Duration]int{0: 1, time.Millisecond: 1, time.Second: 1, 1500 * time.Millisecond: 2, authLockoutDuration: 900}
	for in, want := range cases {
		if got := retryAfterSeconds(in); got != want {
			t.Fatalf("retryAfterSeconds(%s) = %d, want %d", in, got, want)
		}
	}
}
