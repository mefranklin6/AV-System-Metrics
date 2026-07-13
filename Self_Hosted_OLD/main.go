package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	maxBodyBytes = int64(10_240)
	maxFieldLen  = 128

	examplePostgresPassword = "change_me_url_safe_database_password"

	insertMetricSQL = `
INSERT INTO metric_events
    (clientname, sort_key, event_timestamp, metric, action, event_id, received_at, source_ip)
VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8)`
)

//go:embed schema.sql
var schemaSQL string

type config struct {
	addr           string
	databaseURL    string
	allowedNet     *net.IPNet
	legacyLocation *time.Location
}

type metricStore interface {
	Ping(context.Context) error
	Insert(context.Context, []metricItem) error
	Close() error
}

type postgresStore struct {
	db *sql.DB
}

type server struct {
	cfg   config
	store metricStore
}

type clientError struct {
	statusCode int
	message    string
}

func (e *clientError) Error() string { return e.message }

type metricItem struct {
	ClientName     string
	SortKey        string
	EventTimestamp time.Time
	Metric         string
	Action         string
	EventID        string
	ReceivedAt     time.Time
	SourceIP       string
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		if err := runHealthcheck(); err != nil {
			log.Printf("healthcheck failed: %v", err)
			os.Exit(1)
		}
		return
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	store, err := openPostgresStore(context.Background(), cfg.databaseURL)
	if err != nil {
		log.Fatalf("database error: %v", err)
	}
	defer store.Close()

	srv := &server{cfg: cfg, store: store}
	httpServer := &http.Server{
		Addr:              cfg.addr,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("legacy metrics adapter listening on %s", cfg.addr)
		errCh <- httpServer.ListenAndServe()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server error: %v", err)
		}
	case sig := <-sigCh:
		log.Printf("received %s, shutting down", sig)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(ctx); err != nil {
			log.Fatalf("shutdown error: %v", err)
		}
	}
}

func loadConfig() (config, error) {
	cfg := config{
		addr:        getenvDefault("ADDR", ":8080"),
		databaseURL: strings.TrimSpace(os.Getenv("DATABASE_URL")),
	}

	if cfg.databaseURL == "" {
		return cfg, errors.New("DATABASE_URL is required")
	}
	if err := validateDatabaseURL(cfg.databaseURL); err != nil {
		return cfg, err
	}

	if cidr := strings.TrimSpace(os.Getenv("ALLOWED_NET")); cidr != "" {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return cfg, fmt.Errorf("ALLOWED_NET must be a valid CIDR: %w", err)
		}
		cfg.allowedNet = network
	}

	locationName := getenvDefault("LEGACY_TIMEZONE", "UTC")
	location, err := time.LoadLocation(locationName)
	if err != nil {
		return cfg, fmt.Errorf("LEGACY_TIMEZONE must be a valid IANA time zone: %w", err)
	}
	cfg.legacyLocation = location

	return cfg, nil
}

func validateDatabaseURL(databaseURL string) error {
	pgConfig, err := pgconn.ParseConfig(databaseURL)
	if err != nil {
		return fmt.Errorf("DATABASE_URL must be a valid PostgreSQL connection string: %w", err)
	}
	if pgConfig.Password == examplePostgresPassword {
		return errors.New("POSTGRES_PASSWORD must be changed from the .env.example value")
	}
	return nil
}

func getenvDefault(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

func runHealthcheck() error {
	endpoint := os.Getenv("HEALTHCHECK_URL")
	if endpoint == "" {
		endpoint = healthcheckURLFromAddr(getenvDefault("ADDR", ":8080"))
	}

	client := &http.Client{Timeout: 2 * time.Second}
	request, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}

	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	_, _ = io.Copy(io.Discard, response.Body)
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %s from %s", response.Status, endpoint)
	}
	return nil
}

func healthcheckURLFromAddr(addr string) string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return "http://127.0.0.1:8080/health"
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/health"
}

func openPostgresStore(ctx context.Context, dsn string) (*postgresStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}

	db.SetConnMaxLifetime(3 * time.Minute)
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(10)

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		db.Close()
		return nil, err
	}

	schemaCtx, schemaCancel := context.WithTimeout(ctx, 10*time.Second)
	defer schemaCancel()
	if _, err := db.ExecContext(schemaCtx, schemaSQL); err != nil {
		db.Close()
		return nil, err
	}

	return &postgresStore{db: db}, nil
}

func (s *postgresStore) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s *postgresStore) Insert(ctx context.Context, items []metricItem) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}

	stmt, err := tx.PrepareContext(ctx, insertMetricSQL)
	if err != nil {
		_ = tx.Rollback()
		return err
	}
	defer stmt.Close()

	for _, item := range items {
		if _, err := stmt.ExecContext(
			ctx,
			item.ClientName,
			item.SortKey,
			item.EventTimestamp,
			item.Metric,
			item.Action,
			item.EventID,
			item.ReceivedAt,
			item.SourceIP,
		); err != nil {
			_ = tx.Rollback()
			return err
		}
	}

	return tx.Commit()
}

func (s *postgresStore) Close() error {
	return s.db.Close()
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/data/global/enable", s.handleGlobalEnable)
	mux.HandleFunc("/global/enable", s.handleGlobalEnable)
	mux.HandleFunc("/data", s.handleLegacyMetrics)
	mux.HandleFunc("/check", s.handleCheck)
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/", s.handleRoot)
	return mux
}

func (s *server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "Not Found"})
		return
	}

	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, "You have reached the legacy metrics proxy server")
	case http.MethodPost:
		s.handleLegacyMetrics(w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
	}
}

func (s *server) handleLegacyMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}

	sourceIP, clientErr := s.requestSourceIP(r)
	if clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	body, clientErr := parseJSONBody(w, r)
	if clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	message, ok := body.(map[string]any)
	if !ok {
		writeClientError(w, &clientError{http.StatusBadRequest, "Request body must be an object"})
		return
	}

	item, validationMessage, err := buildLegacyItem(message, sourceIP.String(), s.cfg.legacyLocation)
	if err != nil {
		log.Printf("could not build legacy metric: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "Internal Server Error"})
		return
	}
	if validationMessage != "" {
		writeClientError(w, &clientError{http.StatusBadRequest, validationMessage})
		return
	}

	if err := s.store.Insert(r.Context(), []metricItem{item}); err != nil {
		log.Printf("database insert failed: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "Internal Server Error"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"message": "200"})
}

func (s *server) handleGlobalEnable(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	if _, clientErr := s.requestSourceIP(r); clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		log.Printf("legacy global enable check failed: %v", err)
		writeJSON(w, http.StatusOK, "False")
		return
	}
	writeJSON(w, http.StatusOK, "True")
}

func (s *server) handleCheck(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		log.Printf("database compatibility check failed: %v", err)
		writeJSON(w, http.StatusOK, "Could not connect to the Database.")
		return
	}
	writeJSON(w, http.StatusOK, "DB Connection is good")
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		log.Printf("health check failed: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) requestSourceIP(r *http.Request) (net.IP, *clientError) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}

	ip := net.ParseIP(host)
	if ip == nil {
		log.Printf("invalid remote address: %q", r.RemoteAddr)
		return nil, &clientError{http.StatusForbidden, "Forbidden"}
	}
	if s.cfg.allowedNet != nil && !s.cfg.allowedNet.Contains(ip) {
		log.Printf("unauthorized IP: %s", ip.String())
		return nil, &clientError{http.StatusForbidden, "Forbidden"}
	}
	return ip, nil
}

func parseJSONBody(w http.ResponseWriter, r *http.Request) (any, *clientError) {
	defer r.Body.Close()

	limitedBody := http.MaxBytesReader(w, r.Body, maxBodyBytes)
	rawBody, err := io.ReadAll(limitedBody)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			return nil, &clientError{http.StatusRequestEntityTooLarge, "Request body too large"}
		}
		return nil, &clientError{http.StatusBadRequest, "Could not read request body"}
	}
	if len(bytes.TrimSpace(rawBody)) == 0 {
		return nil, &clientError{http.StatusBadRequest, "Invalid JSON body"}
	}

	decoder := json.NewDecoder(bytes.NewReader(rawBody))
	decoder.UseNumber()
	var body any
	if err := decoder.Decode(&body); err != nil {
		return nil, &clientError{http.StatusBadRequest, "Invalid JSON body"}
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, &clientError{http.StatusBadRequest, "Invalid JSON body"}
	}
	return body, nil
}

func buildLegacyItem(message map[string]any, sourceIP string, location *time.Location) (metricItem, string, error) {
	clientName, validationMessage := legacyString(message, "room", "processor")
	if validationMessage != "" {
		return metricItem{}, validationMessage, nil
	}
	timestamp, validationMessage := legacyString(message, "time", "timestamp")
	if validationMessage != "" {
		return metricItem{}, validationMessage, nil
	}
	metric, validationMessage := legacyString(message, "metric")
	if validationMessage != "" {
		return metricItem{}, validationMessage, nil
	}
	action, validationMessage := legacyString(message, "action")
	if validationMessage != "" {
		return metricItem{}, validationMessage, nil
	}

	eventTimestamp, ok := parseTimestamp(timestamp, location)
	if !ok {
		return metricItem{}, "Invalid time format, expected ISO 8601", nil
	}

	eventID, err := newUUIDv4()
	if err != nil {
		return metricItem{}, "", err
	}
	eventTimestamp = eventTimestamp.UTC()

	return metricItem{
		ClientName:     clientName,
		SortKey:        formatSortTimestamp(eventTimestamp) + "#" + eventID,
		EventTimestamp: eventTimestamp,
		Metric:         metric,
		Action:         action,
		EventID:        eventID,
		ReceivedAt:     time.Now().UTC(),
		SourceIP:       sourceIP,
	}, "", nil
}

func legacyString(message map[string]any, names ...string) (string, string) {
	for _, name := range names {
		value, exists := message[name]
		if !exists {
			continue
		}
		text, ok := value.(string)
		if !ok || text == "" {
			return "", fmt.Sprintf("Field '%s' must be a non-empty string", name)
		}
		if utf8.RuneCountInString(text) > maxFieldLen {
			return "", fmt.Sprintf("Field '%s' must be at most %d characters", name, maxFieldLen)
		}
		return text, ""
	}
	return "", fmt.Sprintf("Missing required field: %s", strings.Join(names, " or "))
}

func parseTimestamp(value string, location *time.Location) (time.Time, bool) {
	if parsed, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return parsed.UTC(), true
	}

	for _, layout := range []string{
		"2006-01-02T15:04:05",
		"2006-01-02T15:04:05.999999999",
		"2006-01-02 15:04:05",
		"2006-01-02 15:04:05.999999999",
	} {
		if parsed, err := time.ParseInLocation(layout, value, location); err == nil {
			return parsed.UTC(), true
		}
	}
	return time.Time{}, false
}

func formatSortTimestamp(value time.Time) string {
	return value.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

func newUUIDv4() (string, error) {
	var b [16]byte
	if _, err := io.ReadFull(rand.Reader, b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

func writeClientError(w http.ResponseWriter, err *clientError) {
	log.Printf("client error: %s", err.message)
	writeJSON(w, err.statusCode, map[string]any{"error": err.message})
}

func writeJSON(w http.ResponseWriter, statusCode int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("could not write response: %v", err)
	}
}
