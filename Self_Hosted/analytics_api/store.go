package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	maxSummaryRows = 50_000
	// maxHeartbeatBuckets bounds /api/v1/heartbeats (about 55 bytes of JSON
	// per bucket, roughly 11 MB at the limit) so one request cannot exhaust
	// the container's memory: 500 rooms x 92 days of hours is 1.1 million.
	maxHeartbeatBuckets = 200_000
	maxOpenConns        = 5
)

// apiTime marshals as RFC 3339 UTC with exactly six fractional digits,
// e.g. 2026-11-11T00:22:09.709041Z.
type apiTime struct{ time.Time }

const apiTimeLayout = "2006-01-02T15:04:05.000000Z"

func newAPITime(t time.Time) apiTime { return apiTime{t.UTC().Truncate(time.Microsecond)} }

func (t apiTime) MarshalJSON() ([]byte, error) {
	return []byte(`"` + t.UTC().Format(apiTimeLayout) + `"`), nil
}

func nullableTime(value sql.NullTime) *apiTime {
	if !value.Valid {
		return nil
	}
	t := newAPITime(value.Time)
	return &t
}

// ---- Domain / response types ----

type activityRange struct {
	FirstEvent *apiTime `json:"first_event"`
	LastEvent  *apiTime `json:"last_event"`
}

type heartbeatPurgeInfo struct {
	EnabledStatus *string  `json:"enabled_status"`
	RetentionDays *int64   `json:"retention_days"`
	Cutoff        *apiTime `json:"cutoff"`
	FinishedAt    *apiTime `json:"finished_at"`
}

type dbInfo struct {
	ActivityRange  activityRange
	HeartbeatPurge heartbeatPurgeInfo
}

type clientSummary struct {
	ClientName     string   `json:"clientname"`
	EventCount     int64    `json:"event_count"`
	HeartbeatCount int64    `json:"heartbeat_count"`
	FirstEvent     *apiTime `json:"first_event"`
	LastEvent      *apiTime `json:"last_event"`
	LastHeartbeat  *apiTime `json:"last_heartbeat"`
}

type event struct {
	ID             int64   `json:"id"`
	ClientName     string  `json:"clientname"`
	EventTimestamp apiTime `json:"event_timestamp"`
	Metric         string  `json:"metric"`
	Action         string  `json:"action"`
	EventID        string  `json:"event_id"`
	ReceivedAt     apiTime `json:"received_at"`
}

type summaryRow struct {
	ClientName string  `json:"clientname"`
	Metric     string  `json:"metric"`
	Action     string  `json:"action"`
	Count      int64   `json:"count"`
	FirstEvent apiTime `json:"first_event"`
	LastEvent  apiTime `json:"last_event"`
}

type heartbeatBucket struct {
	Start apiTime `json:"start"`
	Count int64   `json:"count"`
}

type heartbeatSeries struct {
	ClientName string            `json:"clientname"`
	Buckets    []heartbeatBucket `json:"buckets"`
}

// timeRange is a half-open [From, To) interval.
type timeRange struct {
	From time.Time
	To   time.Time
}

type eventQuery struct {
	Range             timeRange
	Clients           []string
	Metrics           []string
	Actions           []string
	IncludeHeartbeats bool
	Limit             int
	After             *pageCursor
}

type summaryQuery struct {
	Range             timeRange
	Clients           []string
	IncludeHeartbeats bool
}

type heartbeatQuery struct {
	Range   timeRange
	Clients []string
	Bucket  string // "hour" or "day"
}

// store is everything the HTTP layer needs from the database. Every method
// runs inside a read-only transaction.
type store interface {
	Ping(ctx context.Context) error
	Info(ctx context.Context) (dbInfo, error)
	Clients(ctx context.Context, r timeRange) ([]clientSummary, error)
	// Events returns up to q.Limit events plus whether more rows follow.
	Events(ctx context.Context, q eventQuery) ([]event, bool, error)
	// Summary returns up to maxSummaryRows rows plus whether it was truncated.
	Summary(ctx context.Context, q summaryQuery) ([]summaryRow, bool, error)
	// Heartbeats returns up to maxHeartbeatBuckets buckets plus whether it was truncated.
	Heartbeats(ctx context.Context, q heartbeatQuery) ([]heartbeatSeries, bool, error)
}

// ---- PostgreSQL implementation ----

type pgStore struct {
	db *sql.DB
}

func newPGStore(db *sql.DB) *pgStore { return &pgStore{db: db} }

// configurePool applies the API's conservative connection pool limits.
func configurePool(db *sql.DB) {
	db.SetMaxOpenConns(maxOpenConns)
	db.SetMaxIdleConns(maxOpenConns)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
}

func (s *pgStore) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

// readOnly runs fn inside a READ ONLY transaction that is always rolled back.
func (s *pgStore) readOnly(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	return fn(tx)
}

const (
	infoActivitySQL = `SELECT min(event_timestamp), max(event_timestamp)
FROM metric_events
WHERE action <> 'Heartbeat'`
	infoPurgeSQL = `SELECT status, retention_days, cutoff, finished_at
FROM heartbeat_purge_status
WHERE id = 1`
	clientsSQL = `SELECT clientname,
    count(*) FILTER (WHERE action <> 'Heartbeat'),
    count(*) FILTER (WHERE action = 'Heartbeat'),
    min(event_timestamp) FILTER (WHERE action <> 'Heartbeat'),
    max(event_timestamp) FILTER (WHERE action <> 'Heartbeat'),
    max(event_timestamp) FILTER (WHERE action = 'Heartbeat')
FROM metric_events
WHERE event_timestamp >= $1 AND event_timestamp < $2
GROUP BY clientname
ORDER BY clientname COLLATE "C"`
)

func (s *pgStore) Info(ctx context.Context) (dbInfo, error) {
	var info dbInfo
	err := s.readOnly(ctx, func(tx *sql.Tx) error {
		var first, last sql.NullTime
		if err := tx.QueryRowContext(ctx, infoActivitySQL).Scan(&first, &last); err != nil {
			return err
		}
		info.ActivityRange = activityRange{FirstEvent: nullableTime(first), LastEvent: nullableTime(last)}

		var status sql.NullString
		var retention sql.NullInt64
		var cutoff, finished sql.NullTime
		err := tx.QueryRowContext(ctx, infoPurgeSQL).Scan(&status, &retention, &cutoff, &finished)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if status.Valid {
			value := status.String
			info.HeartbeatPurge.EnabledStatus = &value
		}
		if retention.Valid {
			value := retention.Int64
			info.HeartbeatPurge.RetentionDays = &value
		}
		info.HeartbeatPurge.Cutoff = nullableTime(cutoff)
		info.HeartbeatPurge.FinishedAt = nullableTime(finished)
		return nil
	})
	return info, err
}

func (s *pgStore) Clients(ctx context.Context, r timeRange) ([]clientSummary, error) {
	clients := make([]clientSummary, 0)
	err := s.readOnly(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, clientsSQL, r.From, r.To)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var c clientSummary
			var first, last, heartbeat sql.NullTime
			if err := rows.Scan(&c.ClientName, &c.EventCount, &c.HeartbeatCount, &first, &last, &heartbeat); err != nil {
				return err
			}
			c.FirstEvent, c.LastEvent, c.LastHeartbeat = nullableTime(first), nullableTime(last), nullableTime(heartbeat)
			clients = append(clients, c)
		}
		return rows.Err()
	})
	return clients, err
}

// sqlBuilder assembles WHERE clauses whose values are always bind parameters.
// Only fixed SQL fragments written in this file are ever concatenated.
type sqlBuilder struct {
	conditions []string
	args       []any
}

func (b *sqlBuilder) param(value any) string {
	b.args = append(b.args, value)
	return "$" + strconv.Itoa(len(b.args))
}

func (b *sqlBuilder) where(condition string) { b.conditions = append(b.conditions, condition) }

func (b *sqlBuilder) timeRange(r timeRange) {
	b.where("event_timestamp >= " + b.param(r.From))
	b.where("event_timestamp < " + b.param(r.To))
}

func (b *sqlBuilder) anyOf(column string, values []string) {
	if len(values) == 0 {
		return
	}
	b.where(column + " = ANY(" + b.param(values) + "::text[])")
}

func (b *sqlBuilder) whereSQL() string {
	return "WHERE " + strings.Join(b.conditions, "\n  AND ")
}

func buildEventsQuery(q eventQuery) (string, []any) {
	var b sqlBuilder
	b.timeRange(q.Range)
	if !q.IncludeHeartbeats {
		// Literal predicate so the partial index idx_metric_events_activity_ts applies.
		b.where("action <> 'Heartbeat'")
	}
	b.anyOf("clientname", q.Clients)
	b.anyOf("metric", q.Metrics)
	b.anyOf("action", q.Actions)
	if q.After != nil {
		b.where("(event_timestamp, event_id) > (" + b.param(q.After.Timestamp) + ", " + b.param(formatUUID(q.After.EventID)) + "::uuid)")
	}
	// event_id is selected under another name so ORDER BY event_id below
	// refers to the uuid column (matching the cursor comparison and the
	// index), not to a text output column.
	query := `SELECT id, clientname, event_timestamp, metric, action, event_id::text AS event_id_text, received_at
FROM metric_events
` + b.whereSQL() + `
ORDER BY event_timestamp, event_id
LIMIT ` + b.param(q.Limit+1)
	return query, b.args
}

func (s *pgStore) Events(ctx context.Context, q eventQuery) ([]event, bool, error) {
	query, args := buildEventsQuery(q)
	events := make([]event, 0, min(q.Limit, 1024))
	more := false
	err := s.readOnly(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, query, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			if len(events) == q.Limit {
				more = true
				break
			}
			var e event
			var ts, received time.Time
			if err := rows.Scan(&e.ID, &e.ClientName, &ts, &e.Metric, &e.Action, &e.EventID, &received); err != nil {
				return err
			}
			e.EventTimestamp, e.ReceivedAt = newAPITime(ts), newAPITime(received)
			events = append(events, e)
		}
		return rows.Err()
	})
	return events, more, err
}

func buildSummaryQuery(q summaryQuery) (string, []any) {
	var b sqlBuilder
	b.timeRange(q.Range)
	if !q.IncludeHeartbeats {
		b.where("action <> 'Heartbeat'")
	}
	b.anyOf("clientname", q.Clients)
	query := `SELECT clientname, metric, action, count(*), min(event_timestamp), max(event_timestamp)
FROM metric_events
` + b.whereSQL() + `
GROUP BY clientname, metric, action
ORDER BY clientname COLLATE "C", metric COLLATE "C", action COLLATE "C"
LIMIT ` + b.param(maxSummaryRows+1)
	return query, b.args
}

func (s *pgStore) Summary(ctx context.Context, q summaryQuery) ([]summaryRow, bool, error) {
	query, args := buildSummaryQuery(q)
	result := make([]summaryRow, 0)
	truncated := false
	err := s.readOnly(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, query, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			if len(result) == maxSummaryRows {
				truncated = true
				break
			}
			var row summaryRow
			var first, last time.Time
			if err := rows.Scan(&row.ClientName, &row.Metric, &row.Action, &row.Count, &first, &last); err != nil {
				return err
			}
			row.FirstEvent, row.LastEvent = newAPITime(first), newAPITime(last)
			result = append(result, row)
		}
		return rows.Err()
	})
	return result, truncated, err
}

func buildHeartbeatsQuery(q heartbeatQuery) (string, []any, error) {
	if q.Bucket != "hour" && q.Bucket != "day" {
		return "", nil, fmt.Errorf("unsupported bucket")
	}
	var b sqlBuilder
	bucket := b.param(q.Bucket)
	b.where("action = 'Heartbeat'")
	b.timeRange(q.Range)
	b.anyOf("clientname", q.Clients)
	query := `SELECT clientname, date_trunc(` + bucket + `::text, event_timestamp AT TIME ZONE 'UTC') AS bucket_start, count(*)
FROM metric_events
` + b.whereSQL() + `
GROUP BY clientname, bucket_start
ORDER BY clientname COLLATE "C", bucket_start
LIMIT ` + b.param(maxHeartbeatBuckets+1)
	return query, b.args, nil
}

func (s *pgStore) Heartbeats(ctx context.Context, q heartbeatQuery) ([]heartbeatSeries, bool, error) {
	query, args, err := buildHeartbeatsQuery(q)
	if err != nil {
		return nil, false, err
	}
	series := make([]heartbeatSeries, 0)
	buckets := 0
	truncated := false
	err = s.readOnly(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, query, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			if buckets == maxHeartbeatBuckets {
				truncated = true
				break
			}
			buckets++
			var client string
			var start time.Time
			var count int64
			if err := rows.Scan(&client, &start, &count); err != nil {
				return err
			}
			// bucket_start is a UTC wall-clock timestamp without time zone.
			start = time.Date(start.Year(), start.Month(), start.Day(), start.Hour(), start.Minute(), start.Second(), start.Nanosecond(), time.UTC)
			if len(series) == 0 || series[len(series)-1].ClientName != client {
				series = append(series, heartbeatSeries{ClientName: client, Buckets: make([]heartbeatBucket, 0)})
			}
			last := &series[len(series)-1]
			last.Buckets = append(last.Buckets, heartbeatBucket{Start: newAPITime(start), Count: count})
		}
		return rows.Err()
	})
	return series, truncated, err
}

// ---- Startup privilege self-check ----

// selfCheckSQL uses has_any_column_privilege for INSERT and UPDATE so that
// column-level grants are caught as well as table-level ones.
const selfCheckSQL = `SELECT
    current_user,
    current_setting('transaction_read_only'),
    current_setting('default_transaction_read_only'),
    r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolbypassrls, r.rolreplication,
    EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = r.oid),
    has_any_column_privilege(current_user, 'public.metric_events', 'INSERT'),
    has_any_column_privilege(current_user, 'public.metric_events', 'UPDATE'),
    has_table_privilege(current_user, 'public.metric_events', 'DELETE'),
    has_table_privilege(current_user, 'public.metric_events', 'TRUNCATE'),
    has_any_column_privilege(current_user, 'public.heartbeat_purge_status', 'INSERT, UPDATE')
        OR has_table_privilege(current_user, 'public.heartbeat_purge_status', 'DELETE, TRUNCATE'),
    has_schema_privilege(current_user, 'public', 'CREATE'),
    has_database_privilege(current_user, current_database(), 'CREATE, TEMPORARY'),
    has_function_privilege(current_user, 'pg_catalog.lo_create(oid)', 'EXECUTE')
        OR has_function_privilege(current_user, 'pg_catalog.lo_creat(integer)', 'EXECUTE')
        OR has_function_privilege(current_user, 'pg_catalog.lo_from_bytea(oid, bytea)', 'EXECUTE')
        OR has_function_privilege(current_user, 'pg_catalog.lo_put(oid, bigint, bytea)', 'EXECUTE'),
    has_column_privilege(current_user, 'public.metric_events', 'source_ip', 'SELECT'),
    has_column_privilege(current_user, 'public.metric_events', 'sort_key', 'SELECT')
FROM pg_roles r
WHERE r.rolname = current_user`

type selfCheckResult struct {
	User                  string
	TransactionReadOnly   string
	DefaultReadOnly       string
	Superuser             bool
	CreateRole            bool
	CreateDB              bool
	BypassRLS             bool
	Replication           bool
	MemberOfRoles         bool
	CanInsert             bool
	CanUpdate             bool
	CanDelete             bool
	CanTruncate           bool
	CanWritePurgeStatus   bool
	CanCreateInPublic     bool
	CanCreateInDatabase   bool
	CanCreateLargeObjects bool
	CanReadSourceAddress  bool
	CanReadSortKey        bool
}

// problems lists every reason the session is not safe for a read-only API.
func (r selfCheckResult) problems() []string {
	var problems []string
	add := func(bad bool, msg string) {
		if bad {
			problems = append(problems, msg)
		}
	}
	add(r.TransactionReadOnly != "on" || r.DefaultReadOnly != "on", "sessions are not read-only by default (default_transaction_read_only is not on)")
	add(r.Superuser, "role is a superuser")
	add(r.CreateRole, "role can create roles")
	add(r.CreateDB, "role can create databases")
	add(r.BypassRLS, "role bypasses row-level security")
	add(r.Replication, "role has the replication attribute")
	add(r.MemberOfRoles, "role is a member of other roles (it could SET ROLE to gain privileges)")
	add(r.CanInsert, "role can INSERT into metric_events")
	add(r.CanUpdate, "role can UPDATE metric_events")
	add(r.CanDelete, "role can DELETE from metric_events")
	add(r.CanTruncate, "role can TRUNCATE metric_events")
	add(r.CanWritePurgeStatus, "role can modify heartbeat_purge_status")
	add(r.CanCreateInPublic, "role can CREATE objects in schema public")
	add(r.CanCreateInDatabase, "role can create schemas or temporary tables in the database (CREATE or TEMPORARY)")
	add(r.CanCreateLargeObjects, "role can create large objects (EXECUTE on lo_create, lo_creat, lo_from_bytea, or lo_put)")
	add(r.CanReadSourceAddress, "role can read metric_events.source_ip")
	add(r.CanReadSortKey, "role can read metric_events.sort_key")
	return problems
}

// runSelfCheck refuses to let the server start with a database role that
// could modify data. It deliberately runs outside a read-only transaction so
// it observes the session defaults that every pooled connection inherits.
func runSelfCheck(ctx context.Context, db *sql.DB) (selfCheckResult, error) {
	var r selfCheckResult
	err := db.QueryRowContext(ctx, selfCheckSQL).Scan(
		&r.User, &r.TransactionReadOnly, &r.DefaultReadOnly,
		&r.Superuser, &r.CreateRole, &r.CreateDB, &r.BypassRLS, &r.Replication,
		&r.MemberOfRoles,
		&r.CanInsert, &r.CanUpdate, &r.CanDelete, &r.CanTruncate,
		&r.CanWritePurgeStatus, &r.CanCreateInPublic, &r.CanCreateInDatabase,
		&r.CanCreateLargeObjects, &r.CanReadSourceAddress, &r.CanReadSortKey,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return r, errors.New("could not find the current role in pg_roles")
	}
	if err != nil {
		return r, err
	}
	if problems := r.problems(); len(problems) > 0 {
		return r, fmt.Errorf("database role %q is not safe for the read-only analytics API: %s; run the provision command and use the metrics_reader role",
			r.User, strings.Join(problems, "; "))
	}
	return r, nil
}
