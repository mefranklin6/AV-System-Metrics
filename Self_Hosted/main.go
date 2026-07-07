package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
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
	"unicode/utf8"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	maxBodyBytes = int64(10_240)
	maxFieldLen  = 128
	maxMessages  = 25

	insertMetricSQL = `
INSERT INTO metric_events
    (clientname, sort_key, event_timestamp, metric, action, event_id, received_at, source_ip)
VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8)`
)

//go:embed schema.sql
var schemaSQL string

type config struct {
	addr        string
	bearerToken string
	databaseURL string
	allowedNet  *net.IPNet
}

type server struct {
	cfg config
	db  *sql.DB
}

type clientError struct {
	statusCode int
	message    string
}

func (e *clientError) Error() string { return e.message }

type validationError struct {
	Index int    `json:"index"`
	Error string `json:"error"`
}

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

	db, err := openDB(context.Background(), cfg.databaseURL)
	if err != nil {
		log.Fatalf("database error: %v", err)
	}
	defer db.Close()

	if err := applySchema(context.Background(), db); err != nil {
		log.Fatalf("schema error: %v", err)
	}

	srv := &server{cfg: cfg, db: db}

	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", srv.handleMetrics)
	mux.HandleFunc("/health", srv.handleHealth)

	httpServer := &http.Server{
		Addr:              cfg.addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("listening on %s", cfg.addr)
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
		bearerToken: os.Getenv("BEARER_TOKEN"),
		databaseURL: strings.TrimSpace(os.Getenv("DATABASE_URL")),
	}

	if cfg.bearerToken == "" {
		return cfg, errors.New("BEARER_TOKEN is required")
	}
	if cfg.databaseURL == "" {
		return cfg, errors.New("DATABASE_URL is required")
	}

	if cidr := os.Getenv("ALLOWED_NET"); cidr != "" {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return cfg, fmt.Errorf("ALLOWED_NET must be a valid CIDR: %w", err)
		}
		cfg.allowedNet = network
	}

	return cfg, nil
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
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %s from %s", resp.Status, endpoint)
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

func openDB(ctx context.Context, dsn string) (*sql.DB, error) {
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

	return db, nil
}

func applySchema(ctx context.Context, db *sql.DB) error {
	schemaCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	_, err := db.ExecContext(schemaCtx, schemaSQL)
	return err
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.db.PingContext(ctx); err != nil {
		log.Printf("health check failed: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	sourceIP, clientErr := s.sourceIP(r)
	if clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	if clientErr := s.validateSourceIP(sourceIP); clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}

	if clientErr := s.validateAuth(r); clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	body, clientErr := parseBody(w, r)
	if clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	messages, clientErr := normalizeMessages(body)
	if clientErr != nil {
		writeClientError(w, clientErr)
		return
	}

	if len(messages) > maxMessages {
		writeClientError(w, &clientError{
			statusCode: http.StatusBadRequest,
			message:    fmt.Sprintf("Too many messages. Maximum allowed is %d", maxMessages),
		})
		return
	}

	items := make([]metricItem, 0, len(messages))
	validationErrors := make([]validationError, 0)

	for i, message := range messages {
		item, validationMessage, err := buildItem(message, sourceIP.String())
		if err != nil {
			log.Printf("could not build metric item: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "Internal Server Error"})
			return
		}

		if validationMessage != "" {
			validationErrors = append(validationErrors, validationError{Index: i, Error: validationMessage})
			continue
		}

		items = append(items, item)
	}

	if len(validationErrors) > 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error":  "One or more messages failed validation",
			"errors": validationErrors,
		})
		return
	}

	if err := s.insertItems(r.Context(), items); err != nil {
		log.Printf("database insert failed: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "Internal Server Error"})
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"ok":    true,
		"count": len(items),
	})
}

func (s *server) sourceIP(r *http.Request) (net.IP, *clientError) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}

	ip := net.ParseIP(host)
	if ip == nil {
		log.Printf("invalid remote address: %q", r.RemoteAddr)
		return nil, &clientError{statusCode: http.StatusForbidden, message: "Forbidden"}
	}

	return ip, nil
}

func (s *server) validateSourceIP(sourceIP net.IP) *clientError {
	if s.cfg.allowedNet == nil {
		return nil
	}

	if !s.cfg.allowedNet.Contains(sourceIP) {
		log.Printf("unauthorized IP: %s", sourceIP.String())
		return &clientError{statusCode: http.StatusForbidden, message: "Forbidden"}
	}

	return nil
}

func (s *server) validateAuth(r *http.Request) *clientError {
	const prefix = "Bearer "

	authHeader := r.Header.Get("Authorization")
	if !strings.HasPrefix(authHeader, prefix) {
		return &clientError{statusCode: http.StatusUnauthorized, message: "Missing or invalid Authorization header"}
	}

	token := strings.TrimPrefix(authHeader, prefix)
	if subtle.ConstantTimeCompare([]byte(token), []byte(s.cfg.bearerToken)) != 1 {
		return &clientError{statusCode: http.StatusForbidden, message: "Invalid token"}
	}

	return nil
}

func parseBody(w http.ResponseWriter, r *http.Request) (any, *clientError) {
	defer r.Body.Close()

	limitedBody := http.MaxBytesReader(w, r.Body, maxBodyBytes)
	rawBody, err := io.ReadAll(limitedBody)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			return nil, &clientError{statusCode: http.StatusRequestEntityTooLarge, message: "Request body too large"}
		}
		return nil, &clientError{statusCode: http.StatusBadRequest, message: "Could not read request body"}
	}

	if len(bytes.TrimSpace(rawBody)) == 0 {
		rawBody = []byte("{}")
	}

	decoder := json.NewDecoder(bytes.NewReader(rawBody))
	decoder.UseNumber()

	var body any
	if err := decoder.Decode(&body); err != nil {
		return nil, &clientError{statusCode: http.StatusBadRequest, message: "Invalid JSON body"}
	}

	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, &clientError{statusCode: http.StatusBadRequest, message: "Invalid JSON body"}
	}

	return body, nil
}

func normalizeMessages(body any) ([]map[string]any, *clientError) {
	switch value := body.(type) {
	case []any:
		return normalizeMessageList(value)
	case map[string]any:
		if messages, ok := value["messages"].([]any); ok {
			return normalizeMessageList(messages)
		}
		return []map[string]any{value}, nil
	default:
		return nil, &clientError{statusCode: http.StatusBadRequest, message: "Request body must be an object or list of objects"}
	}
}

func normalizeMessageList(values []any) ([]map[string]any, *clientError) {
	if len(values) == 0 {
		return nil, &clientError{statusCode: http.StatusBadRequest, message: "Request body must contain at least one message"}
	}

	messages := make([]map[string]any, 0, len(values))
	for _, value := range values {
		message, ok := value.(map[string]any)
		if !ok {
			return nil, &clientError{statusCode: http.StatusBadRequest, message: "Each message must be an object"}
		}
		messages = append(messages, message)
	}

	return messages, nil
}

func buildItem(message map[string]any, sourceIP string) (metricItem, string, error) {
	clientNameValue, hasClientName := message["clientname"]
	metricValue, hasMetric := message["metric"]
	actionValue, hasAction := message["action"]
	timestampValue, hasTimestamp := message["timestamp"]

	if isMissing(clientNameValue, hasClientName) || isMissing(metricValue, hasMetric) || isMissing(actionValue, hasAction) || isMissing(timestampValue, hasTimestamp) {
		return metricItem{}, "Missing required fields: clientname, metric, action, timestamp", nil
	}

	clientName, ok := clientNameValue.(string)
	if !ok || utf8.RuneCountInString(clientName) > maxFieldLen {
		return metricItem{}, fieldLengthError("clientname"), nil
	}

	metric, ok := metricValue.(string)
	if !ok || utf8.RuneCountInString(metric) > maxFieldLen {
		return metricItem{}, fieldLengthError("metric"), nil
	}

	action, ok := actionValue.(string)
	if !ok || utf8.RuneCountInString(action) > maxFieldLen {
		return metricItem{}, fieldLengthError("action"), nil
	}

	timestamp, ok := timestampValue.(string)
	if !ok {
		return metricItem{}, "Field 'timestamp' must be a string in ISO 8601 format", nil
	}

	eventTimestamp, ok := parseTimestamp(timestamp)
	if !ok {
		log.Printf("invalid timestamp format: %s", timestamp)
		return metricItem{}, "Invalid timestamp format, expected ISO 8601", nil
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

func isMissing(value any, exists bool) bool {
	if !exists || value == nil {
		return true
	}
	stringValue, ok := value.(string)
	return ok && stringValue == ""
}

func fieldLengthError(fieldName string) string {
	return fmt.Sprintf("Field '%s' must be a string of at most %d characters", fieldName, maxFieldLen)
}

func parseTimestamp(value string) (time.Time, bool) {
	layouts := []string{
		time.RFC3339Nano,
		"2006-01-02T15:04:05",
		"2006-01-02T15:04:05.999999999",
		"2006-01-02 15:04:05",
		"2006-01-02 15:04:05.999999999",
	}

	for i, layout := range layouts {
		var (
			t   time.Time
			err error
		)
		if i == 0 {
			t, err = time.Parse(layout, value)
		} else {
			t, err = time.ParseInLocation(layout, value, time.UTC)
		}
		if err == nil {
			return t.UTC(), true
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

func (s *server) insertItems(ctx context.Context, items []metricItem) error {
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
		_, err := stmt.ExecContext(
			ctx,
			item.ClientName,
			item.SortKey,
			item.EventTimestamp,
			item.Metric,
			item.Action,
			item.EventID,
			item.ReceivedAt,
			item.SourceIP,
		)
		if err != nil {
			_ = tx.Rollback()
			return err
		}
	}

	return tx.Commit()
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
