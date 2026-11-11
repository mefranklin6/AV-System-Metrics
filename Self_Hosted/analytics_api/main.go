// Command analytics-api is the optional, read-only Analytics API for
// AV-System-Metrics. It serves aggregated and raw (non-sensitive) event data
// to the Metrics Visualizer and to custom reporting apps.
//
// Subcommands:
//
//	analytics-api              run the HTTP API (default)
//	analytics-api healthcheck  GET the local /health endpoint; exit 0 when healthy
//	analytics-api provision    create/repair the metrics_reader role, grants, and indexes
package main

import (
	"context"
	"crypto/tls"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// Startup connection retry window for the API server.
var (
	startupDBTimeout  = 60 * time.Second
	startupDBInterval = 2 * time.Second
)

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	command := ""
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	switch command {
	case "":
		if err := runServer(); err != nil {
			log.Fatalf("analytics api: %v", err)
		}
	case "healthcheck":
		if err := runHealthcheck(); err != nil {
			log.Printf("healthcheck failed: %v", err)
			os.Exit(1)
		}
	case "provision":
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		if err := runProvision(ctx); err != nil {
			stop()
			log.Fatalf("analytics provisioning failed: %v", err)
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: analytics-api [healthcheck|provision]")
		os.Exit(2)
	}
}

func runServer() error {
	applyContainerMemoryLimit()
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("configuration error: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, err := openReaderDB(ctx, cfg.databaseURL)
	if err != nil {
		return fmt.Errorf("database error: %w", err)
	}
	defer db.Close()

	checkCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	result, err := runSelfCheck(checkCtx, db)
	cancel()
	if err != nil {
		return fmt.Errorf("refusing to start: %w", err)
	}
	log.Printf("analytics api: database role %q passed the read-only self-check", result.User)

	srv := newServer(cfg, newPGStore(db))
	httpServer := newHTTPServer(cfg, srv)

	errCh := make(chan error, 1)
	go func() {
		if cfg.tlsEnabled() {
			log.Printf("analytics api: listening on %s (HTTPS)", cfg.addr)
			errCh <- httpServer.ListenAndServeTLS(cfg.tlsCertFile, cfg.tlsKeyFile)
			return
		}
		log.Printf("analytics api: listening on %s (HTTP; use a TLS reverse proxy or ANALYTICS_TLS_* outside trusted networks)", cfg.addr)
		errCh <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("server error: %w", err)
		}
	case <-ctx.Done():
		log.Printf("analytics api: shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown error: %w", err)
		}
	}
	return nil
}

// cgroupMemoryFiles are the container memory limit files for cgroup v2 and v1.
var cgroupMemoryFiles = []string{"/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"}

// applyContainerMemoryLimit sets a soft Go heap limit (80% of the container's
// memory limit) unless GOMEMLIMIT is set, so the garbage collector works
// harder before the kernel would kill the container for exceeding its limit.
func applyContainerMemoryLimit() {
	if strings.TrimSpace(os.Getenv("GOMEMLIMIT")) != "" {
		return
	}
	limit, ok := cgroupMemoryLimit(cgroupMemoryFiles)
	if !ok {
		return
	}
	soft := limit / 10 * 8
	debug.SetMemoryLimit(soft)
	log.Printf("analytics api: Go memory limit set to %d MiB (80%% of the container limit)", soft>>20)
}

// cgroupMemoryLimit returns the first finite limit found in paths.
func cgroupMemoryLimit(paths []string) (int64, bool) {
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		value := strings.TrimSpace(string(data))
		limit, err := strconv.ParseInt(value, 10, 64)
		// "max" (v2) and the huge v1 default both mean unlimited.
		if err != nil || limit <= 0 || limit >= 1<<50 {
			return 0, false
		}
		return limit, true
	}
	return 0, false
}

func newHTTPServer(cfg config, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              cfg.addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		// Longer than the 20 s per-request query timeout plus encoding time.
		WriteTimeout:   35 * time.Second,
		IdleTimeout:    60 * time.Second,
		MaxHeaderBytes: maxHeaderBytes,
		TLSConfig:      &tls.Config{MinVersion: tls.VersionTLS12},
		ErrorLog:       log.New(handshakeNoiseFilter{w: os.Stderr}, "analytics api: ", log.LstdFlags|log.LUTC),
	}
}

// handshakeNoiseFilter drops the TLS handshake errors that internet scanners
// trigger constantly, while keeping every other server error (such as
// recovered handler panics) in the log.
type handshakeNoiseFilter struct{ w io.Writer }

func (f handshakeNoiseFilter) Write(p []byte) (int, error) {
	if strings.Contains(string(p), "TLS handshake error") {
		return len(p), nil
	}
	return f.w.Write(p)
}

// openReaderDB opens the pool and waits (bounded) for the database.
func openReaderDB(ctx context.Context, dsn string) (*sql.DB, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, errors.New("could not configure the database connection")
	}
	configurePool(db)
	deadline := time.Now().Add(startupDBTimeout)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err = db.PingContext(pingCtx)
		cancel()
		if err == nil {
			return db, nil
		}
		if ctx.Err() != nil || time.Now().Add(startupDBInterval).After(deadline) {
			db.Close()
			return nil, err
		}
		log.Printf("analytics api: waiting for database: %v", err)
		timer := time.NewTimer(startupDBInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			db.Close()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

func runHealthcheck() error {
	tlsEnabled := strings.TrimSpace(os.Getenv("ANALYTICS_TLS_CERT_FILE")) != "" && strings.TrimSpace(os.Getenv("ANALYTICS_TLS_KEY_FILE")) != ""
	endpoint := strings.TrimSpace(os.Getenv("HEALTHCHECK_URL"))
	if endpoint == "" {
		endpoint = healthcheckURLFromAddr(getenvDefault("ADDR", defaultAddr), tlsEnabled)
	}
	client := &http.Client{Timeout: 2 * time.Second, Transport: healthcheckTransport(endpoint)}
	resp, err := client.Get(endpoint)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %s from %s", resp.Status, endpoint)
	}
	return nil
}

// healthcheckTransport skips certificate verification only for loopback
// HTTPS targets: the certificate names the public host, not 127.0.0.1, and
// the probe never sends credentials.
func healthcheckTransport(endpoint string) http.RoundTripper {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	if strings.HasPrefix(endpoint, "https://") && isLoopbackURL(endpoint) {
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true} //nolint:gosec // loopback probe only
	}
	return transport
}

func isLoopbackURL(endpoint string) bool {
	rest := strings.TrimPrefix(strings.TrimPrefix(endpoint, "https://"), "http://")
	hostport, _, _ := strings.Cut(rest, "/")
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		host = hostport
	}
	host = strings.Trim(host, "[]")
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func healthcheckURLFromAddr(addr string, tlsEnabled bool) string {
	scheme := "http"
	if tlsEnabled {
		scheme = "https"
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return scheme + "://127.0.0.1:8081/health"
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return scheme + "://" + net.JoinHostPort(host, port) + "/health"
}
