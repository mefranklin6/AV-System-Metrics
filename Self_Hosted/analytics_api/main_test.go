package main

import (
	"bytes"
	"flag"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestMain keeps expected error logs out of non-verbose test output.
func TestMain(m *testing.M) {
	flag.Parse()
	if !testing.Verbose() {
		log.SetOutput(io.Discard)
	}
	os.Exit(m.Run())
}

func TestCgroupMemoryLimit(t *testing.T) {
	dir := t.TempDir()
	write := func(name, value string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	v2 := write("memory.max", "268435456\n")
	unlimited := write("unlimited", "max\n")
	v1Default := write("v1", "9223372036854771712\n")
	missing := filepath.Join(dir, "missing")
	if limit, ok := cgroupMemoryLimit([]string{missing, v2}); !ok || limit != 256<<20 {
		t.Fatalf("v2 limit = %d, %v", limit, ok)
	}
	for _, path := range []string{unlimited, v1Default, missing} {
		if limit, ok := cgroupMemoryLimit([]string{path}); ok {
			t.Fatalf("%s: unlimited reported as %d", path, limit)
		}
	}
}

func TestHealthcheckURLFromAddr(t *testing.T) {
	cases := []struct {
		addr string
		tls  bool
		want string
	}{
		{":8081", false, "http://127.0.0.1:8081/health"},
		{"0.0.0.0:9000", false, "http://127.0.0.1:9000/health"},
		{"[::]:9000", false, "http://127.0.0.1:9000/health"},
		{"10.0.0.5:8081", false, "http://10.0.0.5:8081/health"},
		{"[::1]:8081", false, "http://[::1]:8081/health"},
		{":8443", true, "https://127.0.0.1:8443/health"},
		{"garbage", false, "http://127.0.0.1:8081/health"},
		{"", true, "https://127.0.0.1:8081/health"},
	}
	for _, tc := range cases {
		if got := healthcheckURLFromAddr(tc.addr, tc.tls); got != tc.want {
			t.Fatalf("healthcheckURLFromAddr(%q, %v) = %q, want %q", tc.addr, tc.tls, got, tc.want)
		}
	}
}

func TestIsLoopbackURL(t *testing.T) {
	yes := []string{"https://127.0.0.1:8081/health", "https://localhost:8081/health", "https://[::1]:8081/health", "http://127.0.0.2/health"}
	no := []string{"https://example.edu/health", "https://10.0.0.1:8081/health", "https://127.0.0.1.evil.com/health"}
	for _, u := range yes {
		if !isLoopbackURL(u) {
			t.Fatalf("%s should be loopback", u)
		}
	}
	for _, u := range no {
		if isLoopbackURL(u) {
			t.Fatalf("%s must not be loopback", u)
		}
	}
	if tr := healthcheckTransport("https://example.edu/health").(*http.Transport); tr.TLSClientConfig != nil && tr.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("certificate verification must stay on for non-loopback targets")
	}
	if tr := healthcheckTransport("https://127.0.0.1:8081/health").(*http.Transport); tr.TLSClientConfig == nil || !tr.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("loopback HTTPS probe should skip hostname verification")
	}
}

func TestRunHealthcheck(t *testing.T) {
	healthy := httptest.NewServer(newTestServer(testConfig(), &fakeStore{}))
	defer healthy.Close()
	t.Setenv("ANALYTICS_TLS_CERT_FILE", "")
	t.Setenv("ANALYTICS_TLS_KEY_FILE", "")
	t.Setenv("HEALTHCHECK_URL", healthy.URL+"/health")
	if err := runHealthcheck(); err != nil {
		t.Fatalf("healthy: %v", err)
	}

	down := httptest.NewServer(newTestServer(testConfig(), &fakeStore{pingErr: errTest}))
	defer down.Close()
	t.Setenv("HEALTHCHECK_URL", down.URL+"/health")
	if err := runHealthcheck(); err == nil || !strings.Contains(err.Error(), "503") {
		t.Fatalf("unhealthy: %v", err)
	}

	tlsServer := httptest.NewTLSServer(newTestServer(testConfig(), &fakeStore{}))
	defer tlsServer.Close()
	t.Setenv("HEALTHCHECK_URL", tlsServer.URL+"/health")
	if err := runHealthcheck(); err != nil {
		t.Fatalf("loopback TLS: %v", err)
	}
}

func TestHandshakeNoiseFilter(t *testing.T) {
	var buf bytes.Buffer
	f := handshakeNoiseFilter{w: &buf}
	_, _ = f.Write([]byte("http: TLS handshake error from 1.2.3.4:5: EOF\n"))
	_, _ = f.Write([]byte("http: panic serving 1.2.3.4:5: boom\n"))
	if strings.Contains(buf.String(), "handshake") || !strings.Contains(buf.String(), "panic serving") {
		t.Fatalf("filtered log = %q", buf.String())
	}
}

type testError string

func (e testError) Error() string { return string(e) }

const errTest = testError("database down")
