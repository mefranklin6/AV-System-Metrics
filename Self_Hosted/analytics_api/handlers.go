package main

import (
	"context"
	_ "embed"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

//go:embed openapi.yaml
var openAPISpec []byte

const (
	apiVersion          = "1"
	defaultRangeDays    = 30
	maxRangeSpan        = 400 * 24 * time.Hour
	maxHourlyBucketSpan = 92 * 24 * time.Hour
	maxClientFilters    = 200
	maxValueFilters     = 50
	maxFilterValueLen   = 128
	defaultEventLimit   = 1000
	maxEventLimit       = 5000
	maxCursorParamLen   = 64
)

// paramError is a 400 response. Messages name parameters but never echo values.
type paramError struct{ message string }

func (e *paramError) Error() string { return e.message }

func badParam(format string, args ...any) *paramError {
	return &paramError{message: fmt.Sprintf(format, args...)}
}

// ---- Unauthenticated routes ----

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	// Query strings on probes are ignored.
	ctx, cancel := context.WithTimeout(r.Context(), healthTimeout)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		s.denyLog.printf("analytics api: health check failed: %v", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]bool{"ok": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *server) handleOpenAPI(w http.ResponseWriter, _ *http.Request) {
	h := w.Header()
	h.Set("Content-Type", yamlContentType)
	h.Set("Content-Length", strconv.Itoa(len(openAPISpec)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(openAPISpec)
}

// ---- /api/v1 routes ----

type infoResponse struct {
	APIVersion     string             `json:"api_version"`
	ServerTime     apiTime            `json:"server_time"`
	ActivityRange  activityRange      `json:"activity_range"`
	HeartbeatPurge heartbeatPurgeInfo `json:"heartbeat_purge"`
}

func (s *server) handleInfo(w http.ResponseWriter, r *http.Request) {
	if _, perr := parseQuery(r, nil); perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	info, err := s.store.Info(ctx)
	if err != nil {
		s.writeStoreError(w, r, "info", err)
		return
	}
	writeJSON(w, http.StatusOK, infoResponse{
		APIVersion:     apiVersion,
		ServerTime:     newAPITime(s.now()),
		ActivityRange:  info.ActivityRange,
		HeartbeatPurge: info.HeartbeatPurge,
	})
}

type clientsResponse struct {
	From    apiTime         `json:"from"`
	To      apiTime         `json:"to"`
	Clients []clientSummary `json:"clients"`
}

func (s *server) handleClients(w http.ResponseWriter, r *http.Request) {
	values, perr := parseQuery(r, []string{"from", "to"})
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	rng, perr := parseTimeRange(values, s.now(), maxRangeSpan)
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	clients, err := s.store.Clients(ctx, rng)
	if err != nil {
		s.writeStoreError(w, r, "clients", err)
		return
	}
	if clients == nil {
		clients = []clientSummary{}
	}
	writeJSON(w, http.StatusOK, clientsResponse{From: newAPITime(rng.From), To: newAPITime(rng.To), Clients: clients})
}

type eventsResponse struct {
	From       apiTime `json:"from"`
	To         apiTime `json:"to"`
	Events     []event `json:"events"`
	NextCursor *string `json:"next_cursor"`
}

func parseEventQuery(values url.Values, now time.Time) (eventQuery, *paramError) {
	var q eventQuery
	var perr *paramError
	if q.Range, perr = parseTimeRange(values, now, maxRangeSpan); perr != nil {
		return q, perr
	}
	if q.Clients, perr = parseStringList(values, "client", maxClientFilters); perr != nil {
		return q, perr
	}
	if q.Metrics, perr = parseStringList(values, "metric", maxValueFilters); perr != nil {
		return q, perr
	}
	if q.Actions, perr = parseStringList(values, "action", maxValueFilters); perr != nil {
		return q, perr
	}
	if q.IncludeHeartbeats, perr = parseBoolParam(values, "include_heartbeats", false); perr != nil {
		return q, perr
	}
	if q.Limit, perr = parseLimit(values); perr != nil {
		return q, perr
	}
	raw, perr := singleValue(values, "cursor")
	if perr != nil {
		return q, perr
	}
	if values.Has("cursor") {
		if len(raw) > maxCursorParamLen {
			return q, badParam("Parameter 'cursor' is not valid. Use the next_cursor value from a previous response unchanged.")
		}
		c, err := decodeCursor(raw)
		if err != nil {
			return q, badParam("Parameter 'cursor' is not valid. Use the next_cursor value from a previous response unchanged.")
		}
		q.After = &c
	}
	return q, nil
}

func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	values, perr := parseQuery(r, []string{"from", "to", "client", "metric", "action", "include_heartbeats", "limit", "cursor"})
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	q, perr := parseEventQuery(values, s.now())
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	events, more, err := s.store.Events(ctx, q)
	if err != nil {
		s.writeStoreError(w, r, "events", err)
		return
	}
	if events == nil {
		events = []event{}
	}
	resp := eventsResponse{From: newAPITime(q.Range.From), To: newAPITime(q.Range.To), Events: events}
	if more && len(events) > 0 {
		last := events[len(events)-1]
		id, err := parseUUID(last.EventID)
		if err != nil {
			s.writeStoreError(w, r, "events", fmt.Errorf("unexpected event_id format: %w", err))
			return
		}
		next := encodeCursor(pageCursor{Timestamp: last.EventTimestamp.Time, EventID: id})
		resp.NextCursor = &next
	}
	writeJSON(w, http.StatusOK, resp)
}

type summaryResponse struct {
	From      apiTime      `json:"from"`
	To        apiTime      `json:"to"`
	Truncated bool         `json:"truncated"`
	Rows      []summaryRow `json:"rows"`
}

func (s *server) handleSummary(w http.ResponseWriter, r *http.Request) {
	values, perr := parseQuery(r, []string{"from", "to", "client", "include_heartbeats"})
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	var q summaryQuery
	if q.Range, perr = parseTimeRange(values, s.now(), maxRangeSpan); perr == nil {
		if q.Clients, perr = parseStringList(values, "client", maxClientFilters); perr == nil {
			q.IncludeHeartbeats, perr = parseBoolParam(values, "include_heartbeats", false)
		}
	}
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	rows, truncated, err := s.store.Summary(ctx, q)
	if err != nil {
		s.writeStoreError(w, r, "summary", err)
		return
	}
	if rows == nil {
		rows = []summaryRow{}
	}
	writeJSON(w, http.StatusOK, summaryResponse{From: newAPITime(q.Range.From), To: newAPITime(q.Range.To), Truncated: truncated, Rows: rows})
}

type heartbeatsResponse struct {
	From      apiTime           `json:"from"`
	To        apiTime           `json:"to"`
	Bucket    string            `json:"bucket"`
	Truncated bool              `json:"truncated"`
	Series    []heartbeatSeries `json:"series"`
}

func parseHeartbeatQuery(values url.Values, now time.Time) (heartbeatQuery, *paramError) {
	var q heartbeatQuery
	bucket, perr := singleValue(values, "bucket")
	if perr != nil {
		return q, perr
	}
	if bucket == "" && values.Has("bucket") {
		return q, badParam("Parameter 'bucket' must be 'hour' or 'day'.")
	}
	switch bucket {
	case "", "hour":
		q.Bucket = "hour"
	case "day":
		q.Bucket = "day"
	default:
		return q, badParam("Parameter 'bucket' must be 'hour' or 'day'.")
	}
	if q.Range, perr = parseTimeRange(values, now, maxRangeSpan); perr != nil {
		return q, perr
	}
	if q.Bucket == "hour" && q.Range.To.Sub(q.Range.From) > maxHourlyBucketSpan {
		return q, badParam("With bucket=hour the range from 'from' to 'to' may be at most 92 days. Use bucket=day or split the range.")
	}
	if q.Clients, perr = parseStringList(values, "client", maxClientFilters); perr != nil {
		return q, perr
	}
	return q, nil
}

func (s *server) handleHeartbeats(w http.ResponseWriter, r *http.Request) {
	values, perr := parseQuery(r, []string{"from", "to", "client", "bucket"})
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	q, perr := parseHeartbeatQuery(values, s.now())
	if perr != nil {
		writeError(w, http.StatusBadRequest, codeBadRequest, perr.message)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
	defer cancel()
	series, truncated, err := s.store.Heartbeats(ctx, q)
	if err != nil {
		s.writeStoreError(w, r, "heartbeats", err)
		return
	}
	if series == nil {
		series = []heartbeatSeries{}
	}
	writeJSON(w, http.StatusOK, heartbeatsResponse{From: newAPITime(q.Range.From), To: newAPITime(q.Range.To), Bucket: q.Bucket, Truncated: truncated, Series: series})
}

// ---- Parameter parsing ----

// parseQuery parses the raw query string and rejects parameters the route
// does not accept. Single-value parameters are checked by their parsers.
func parseQuery(r *http.Request, allowed []string) (url.Values, *paramError) {
	values, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return nil, badParam("The query string is not valid URL encoding.")
	}
	for name := range values {
		ok := false
		for _, a := range allowed {
			if name == a {
				ok = true
				break
			}
		}
		if !ok {
			if len(allowed) == 0 {
				return nil, badParam("This endpoint does not accept query parameters.")
			}
			return nil, badParam("Unknown query parameter. Allowed parameters: %s.", strings.Join(allowed, ", "))
		}
	}
	return values, nil
}

// singleValue returns the parameter value, or "" when absent, rejecting repeats.
func singleValue(values url.Values, name string) (string, *paramError) {
	list := values[name]
	switch len(list) {
	case 0:
		return "", nil
	case 1:
		return list[0], nil
	default:
		return "", badParam("Parameter '%s' may only be given once.", name)
	}
}

// parseTimestampParam parses RFC 3339 with a required offset. A literal '+'
// in an unencoded query string arrives as a space, so spaces are restored.
func parseTimestampParam(values url.Values, name string) (time.Time, bool, *paramError) {
	raw, perr := singleValue(values, name)
	if perr != nil {
		return time.Time{}, false, perr
	}
	if raw == "" {
		if values.Has(name) {
			return time.Time{}, false, badParam("Parameter '%s' is empty. Use an RFC 3339 timestamp such as 2026-09-01T00:00:00Z.", name)
		}
		return time.Time{}, false, nil
	}
	if len(raw) > 64 {
		return time.Time{}, false, badParam("Parameter '%s' must be an RFC 3339 timestamp with a time zone offset, such as 2026-09-01T00:00:00Z.", name)
	}
	t, err := time.Parse(time.RFC3339Nano, strings.ReplaceAll(raw, " ", "+"))
	if err != nil {
		return time.Time{}, false, badParam("Parameter '%s' must be an RFC 3339 timestamp with a time zone offset, such as 2026-09-01T00:00:00Z.", name)
	}
	return t.UTC().Truncate(time.Microsecond), true, nil
}

// parseTimeRange applies the defaults (to = now, from = to - 30 days) and limits.
func parseTimeRange(values url.Values, now time.Time, maxSpan time.Duration) (timeRange, *paramError) {
	from, hasFrom, perr := parseTimestampParam(values, "from")
	if perr != nil {
		return timeRange{}, perr
	}
	to, hasTo, perr := parseTimestampParam(values, "to")
	if perr != nil {
		return timeRange{}, perr
	}
	if !hasTo {
		to = now.UTC().Truncate(time.Microsecond)
	}
	if !hasFrom {
		from = to.AddDate(0, 0, -defaultRangeDays)
	}
	if !from.Before(to) {
		return timeRange{}, badParam("Parameter 'from' must be earlier than 'to' (the range is [from, to)).")
	}
	if to.Sub(from) > maxSpan {
		return timeRange{}, badParam("The range from 'from' to 'to' may be at most %d days. Split the request into smaller ranges.", int(maxSpan/(24*time.Hour)))
	}
	return timeRange{From: from, To: to}, nil
}

// parseStringList validates a repeatable exact-match filter.
func parseStringList(values url.Values, name string, maxCount int) ([]string, *paramError) {
	list := values[name]
	if len(list) == 0 {
		return nil, nil
	}
	if len(list) > maxCount {
		return nil, badParam("Parameter '%s' may be repeated at most %d times.", name, maxCount)
	}
	seen := make(map[string]struct{}, len(list))
	out := make([]string, 0, len(list))
	for _, value := range list {
		if value == "" || !utf8.ValidString(value) || utf8.RuneCountInString(value) > maxFilterValueLen || strings.ContainsRune(value, 0) {
			return nil, badParam("Each '%s' value must be 1 to %d characters of valid UTF-8 text.", name, maxFilterValueLen)
		}
		if _, dup := seen[value]; dup {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out, nil
}

func parseBoolParam(values url.Values, name string, fallback bool) (bool, *paramError) {
	raw, perr := singleValue(values, name)
	if perr != nil {
		return false, perr
	}
	switch raw {
	case "":
		if values.Has(name) {
			return false, badParam("Parameter '%s' must be true or false.", name)
		}
		return fallback, nil
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, badParam("Parameter '%s' must be true or false.", name)
	}
}

func parseLimit(values url.Values) (int, *paramError) {
	raw, perr := singleValue(values, "limit")
	if perr != nil {
		return 0, perr
	}
	if raw == "" && !values.Has("limit") {
		return defaultEventLimit, nil
	}
	if raw == "" || len(raw) > 4 {
		return 0, badParam("Parameter 'limit' must be a whole number from 1 to %d.", maxEventLimit)
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return 0, badParam("Parameter 'limit' must be a whole number from 1 to %d.", maxEventLimit)
		}
	}
	limit, err := strconv.Atoi(raw)
	if err != nil || limit < 1 || limit > maxEventLimit {
		return 0, badParam("Parameter 'limit' must be a whole number from 1 to %d.", maxEventLimit)
	}
	return limit, nil
}
