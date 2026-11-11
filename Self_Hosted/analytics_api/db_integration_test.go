package main

// Database-backed tests. They run only when ANALYTICS_TEST_DATABASE_URL points
// at a disposable PostgreSQL database and an ADMIN (superuser) account, for
// example the throwaway container started by analytics_integration_test.sh:
//
//	ANALYTICS_TEST_DATABASE_URL=postgres://metrics_user:pw@127.0.0.1:5432/metrics?sslmode=disable go test ./...
//
// The ingest schema (../schema.sql, or ANALYTICS_TEST_SCHEMA_FILE) is applied
// first. The tests provision metrics_reader, then prove what it can and cannot do.

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func integrationAdminDB(t *testing.T) (*sql.DB, string) {
	t.Helper()
	dsn := os.Getenv("ANALYTICS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set ANALYTICS_TEST_DATABASE_URL (admin connection to a disposable database) to run database tests")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatalf("open admin database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("ping admin database: %v", err)
	}
	schemaPath := os.Getenv("ANALYTICS_TEST_SCHEMA_FILE")
	if schemaPath == "" {
		schemaPath = "../schema.sql"
	}
	schema, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("read ingest schema: %v", err)
	}
	if _, err := db.ExecContext(ctx, string(schema)); err != nil {
		t.Fatalf("apply ingest schema: %v", err)
	}
	return db, dsn
}

func randomSuffix(t *testing.T, n int) string {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b)
}

func readerDSN(t *testing.T, adminDSN, password string) string {
	t.Helper()
	u, err := url.Parse(adminDSN)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		t.Fatalf("ANALYTICS_TEST_DATABASE_URL must be a postgres:// URL")
	}
	u.User = url.UserPassword(readerRole, password)
	return u.String()
}

func sqlState(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

type seededEvent struct {
	client, metric, action string
	at                     time.Time
}

func TestDatabaseIntegration(t *testing.T) {
	admin, adminDSN := integrationAdminDB(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	prefix := "IT" + randomSuffix(t, 4) + "_"
	roomA, roomB, roomC := prefix+"BSS_245", prefix+"HOLT_155", prefix+"ARTS_107"
	base := time.Now().UTC().Truncate(time.Hour).Add(-48 * time.Hour)
	tie := base.Add(30 * time.Minute)
	seed := []seededEvent{
		{roomA, "Ok", "Heartbeat", base},
		{roomA, "Ok", "Heartbeat", base.Add(5 * time.Minute)},
		{roomA, "Ok", "Heartbeat", base.Add(65 * time.Minute)},
		{roomA, "System - User", "Started", base.Add(10 * time.Minute)},
		{roomA, "hdmi", "Started", base.Add(11 * time.Minute)},
		{roomA, "Projector_1", "Started", base.Add(12 * time.Minute)},
		{roomA, "pc", "Started", base.Add(20 * time.Minute)},
		{roomA, "Btn_Volume_Up Pressed", "Trace", tie},
		{roomA, "Btn_Volume_Up Tapped", "Trace", tie}, // same timestamp: ordered by event_id
		{roomA, "Projector_1", "Stopped", base.Add(50 * time.Minute)},
		{roomA, "System - Inactivity", "Stopped", base.Add(55 * time.Minute)},
		{roomB, "Ok", "Heartbeat", base.Add(2 * time.Hour)},
		{roomB, "Ok", "Heartbeat", base.Add(2*time.Hour + 5*time.Minute)},
		{roomB, "Ok", "Heartbeat", base.Add(2*time.Hour + 10*time.Minute)},
		{roomC, "Projector_1", "Disconnected", base.Add(3 * time.Hour)},
		{roomC, "Projector_1", "Connected", base.Add(3*time.Hour + time.Minute)},
	}
	for i, e := range seed {
		_, err := admin.ExecContext(ctx, `INSERT INTO metric_events
    (clientname, sort_key, event_timestamp, metric, action, event_id, received_at, source_ip)
VALUES ($1, $2, $3, $4, $5, gen_random_uuid(), $6, '192.0.2.44')`,
			e.client, fmt.Sprintf("%s#%03d", e.at.Format(time.RFC3339Nano), i), e.at, e.metric, e.action, e.at.Add(10*time.Second))
		if err != nil {
			t.Fatalf("seed row %d: %v", i, err)
		}
	}
	t.Cleanup(func() {
		_, _ = admin.ExecContext(context.Background(), `DELETE FROM metric_events WHERE clientname LIKE $1`, prefix+"%")
	})

	password := "It-" + randomSuffix(t, 16)

	t.Run("provision is idempotent and repairs invalid indexes", func(t *testing.T) {
		first, err := provision(ctx, admin, password)
		if err != nil {
			t.Fatalf("first provision: %v", err)
		}
		second, err := provision(ctx, admin, password)
		if err != nil {
			t.Fatalf("second provision: %v", err)
		}
		if second.roleCreated || strings.Join(second.indexes, ",") != "idx_metric_events_activity_ts present,idx_metric_events_heartbeat_client_ts present" {
			t.Fatalf("second run summary = %s (first %s)", second, first)
		}
		// Simulate an interrupted CREATE INDEX CONCURRENTLY.
		if _, err := admin.ExecContext(ctx, `UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'public.idx_metric_events_activity_ts'::regclass`); err != nil {
			t.Fatalf("mark index invalid: %v", err)
		}
		third, err := provision(ctx, admin, password)
		if err != nil {
			t.Fatalf("repair provision: %v", err)
		}
		if !strings.Contains(strings.Join(third.indexes, ","), "idx_metric_events_activity_ts rebuilt") {
			t.Fatalf("invalid index not rebuilt: %s", third)
		}
		var valid bool
		if err := admin.QueryRowContext(ctx, indexValiditySQL, "idx_metric_events_activity_ts").Scan(&valid); err != nil || !valid {
			t.Fatalf("index valid=%v err=%v", valid, err)
		}
		// A stale membership granted by an administrator is removed.
		if _, err := admin.ExecContext(ctx, `GRANT pg_read_all_data TO metrics_reader`); err != nil {
			t.Fatalf("grant membership: %v", err)
		}
		fourth, err := provision(ctx, admin, password)
		if err != nil || fourth.membershipsRevoked != 1 {
			t.Fatalf("membership not revoked: %s %v", fourth, err)
		}
	})

	reader, err := sql.Open("pgx", readerDSN(t, adminDSN, password))
	if err != nil {
		t.Fatal(err)
	}
	configurePool(reader)
	t.Cleanup(func() { _ = reader.Close() })

	t.Run("self-check accepts metrics_reader and rejects the admin role", func(t *testing.T) {
		res, err := runSelfCheck(ctx, reader)
		if err != nil {
			t.Fatalf("metrics_reader rejected: %v", err)
		}
		if res.User != readerRole || res.CanReadSourceAddress || res.CanReadSortKey || res.CanCreateInDatabase || res.CanCreateLargeObjects {
			t.Fatalf("self-check result = %+v", res)
		}
		if _, err := runSelfCheck(ctx, admin); err == nil || !strings.Contains(err.Error(), "superuser") {
			t.Fatalf("admin role accepted: %v", err)
		}
	})

	t.Run("metrics_reader cannot write or read sensitive columns", func(t *testing.T) {
		conn, err := reader.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() {
			// Return the pooled session to its role defaults.
			_, _ = conn.ExecContext(context.Background(), `RESET default_transaction_read_only`)
			_ = conn.Close()
		}()

		var timeout string
		if err := conn.QueryRowContext(ctx, `SHOW statement_timeout`).Scan(&timeout); err != nil || timeout != "30s" {
			t.Fatalf("statement_timeout = %q, %v", timeout, err)
		}
		// Layer 1: sessions are read-only by default.
		_, err = conn.ExecContext(ctx, `DELETE FROM metric_events WHERE clientname = $1`, roomA)
		if code := sqlState(err); code != "25006" {
			t.Fatalf("DELETE in default session: SQLSTATE %q (%v), want 25006 read_only_sql_transaction", code, err)
		}
		// Layer 2: even after opting out of read-only mode, privileges deny writes.
		if _, err := conn.ExecContext(ctx, `SET default_transaction_read_only = off`); err != nil {
			t.Fatalf("set read-write: %v", err)
		}
		denied := []string{
			`INSERT INTO metric_events (clientname, sort_key, event_timestamp, metric, action, event_id, received_at, source_ip)
VALUES ('x', 'x', now(), 'x', 'x', gen_random_uuid(), now(), '127.0.0.1')`,
			`UPDATE metric_events SET metric = 'x' WHERE clientname = '` + roomA + `'`,
			`DELETE FROM metric_events WHERE clientname = '` + roomA + `'`,
			`TRUNCATE metric_events`,
			`UPDATE heartbeat_purge_status SET status = 'failed'`,
			`DELETE FROM heartbeat_purge_status`,
			`SELECT source_ip FROM metric_events LIMIT 1`,
			`SELECT sort_key FROM metric_events LIMIT 1`,
			`SELECT * FROM metric_events LIMIT 1`,
			`CREATE TABLE public.analytics_should_not_exist (id int)`,
			`CREATE TEMP TABLE analytics_should_not_exist (id int)`,
			`CREATE SCHEMA analytics_should_not_exist`,
			`SELECT lo_from_bytea(0, '\x00'::bytea)`,
			`SELECT lo_create(0)`,
			`SET ROLE metrics_user`,
		}
		for _, stmt := range denied {
			_, err := conn.ExecContext(ctx, stmt)
			if code := sqlState(err); code != "42501" {
				t.Fatalf("%s\n=> SQLSTATE %q (%v), want 42501 insufficient_privilege", stmt, code, err)
			}
		}
		var count int
		if err := conn.QueryRowContext(ctx, `SELECT count(*) FROM metric_events WHERE clientname = $1`, roomA).Scan(&count); err != nil || count != 11 {
			t.Fatalf("permitted read failed: count=%d err=%v", count, err)
		}

		wrong, err := sql.Open("pgx", readerDSN(t, adminDSN, "wrong-"+password))
		if err != nil {
			t.Fatal(err)
		}
		defer wrong.Close()
		if err := wrong.PingContext(ctx); err == nil {
			t.Fatal("metrics_reader logged in with a wrong password")
		}
	})

	t.Run("store queries return seeded data", func(t *testing.T) {
		st := newPGStore(reader)
		rng := timeRange{From: base.Add(-time.Hour), To: base.Add(4 * time.Hour)}

		info, err := st.Info(ctx)
		if err != nil || info.ActivityRange.FirstEvent == nil || info.ActivityRange.LastEvent == nil {
			t.Fatalf("Info = %+v, %v", info, err)
		}

		clients, err := st.Clients(ctx, rng)
		if err != nil {
			t.Fatal(err)
		}
		byName := map[string]clientSummary{}
		for _, c := range clients {
			byName[c.ClientName] = c
		}
		a, b, c := byName[roomA], byName[roomB], byName[roomC]
		if a.EventCount != 8 || a.HeartbeatCount != 3 || a.FirstEvent == nil || a.LastHeartbeat == nil ||
			!a.FirstEvent.Equal(base.Add(10*time.Minute)) || !a.LastHeartbeat.Equal(base.Add(65*time.Minute)) {
			t.Fatalf("room A = %+v", a)
		}
		if b.EventCount != 0 || b.HeartbeatCount != 3 || b.FirstEvent != nil || b.LastEvent != nil {
			t.Fatalf("heartbeat-only room B = %+v", b)
		}
		if c.EventCount != 2 || c.HeartbeatCount != 0 || c.LastHeartbeat != nil {
			t.Fatalf("room C = %+v", c)
		}

		rows, truncated, err := st.Summary(ctx, summaryQuery{Range: rng, Clients: []string{roomA}})
		if err != nil || truncated || len(rows) != 8 {
			t.Fatalf("summary rows=%d truncated=%v err=%v", len(rows), truncated, err)
		}
		withHB, _, err := st.Summary(ctx, summaryQuery{Range: rng, Clients: []string{roomA}, IncludeHeartbeats: true})
		if err != nil || len(withHB) != 9 {
			t.Fatalf("summary with heartbeats = %d, %v", len(withHB), err)
		}

		series, truncated, err := st.Heartbeats(ctx, heartbeatQuery{Range: rng, Bucket: "hour", Clients: []string{roomA, roomB}})
		if err != nil || truncated || len(series) != 2 {
			t.Fatalf("heartbeat series = %+v, %v", series, err)
		}
		for _, s := range series {
			if s.ClientName == roomA {
				if len(s.Buckets) != 2 || s.Buckets[0].Count != 2 || !s.Buckets[0].Start.Equal(base) || s.Buckets[1].Count != 1 {
					t.Fatalf("room A buckets = %+v", s.Buckets)
				}
			}
		}
		daily, _, err := st.Heartbeats(ctx, heartbeatQuery{Range: rng, Bucket: "day", Clients: []string{roomB}})
		if err != nil || len(daily) != 1 || len(daily[0].Buckets) != 1 || daily[0].Buckets[0].Count != 3 ||
			!daily[0].Buckets[0].Start.Equal(base.Add(2*time.Hour).Truncate(24*time.Hour)) {
			t.Fatalf("daily buckets = %+v, %v", daily, err)
		}
	})

	t.Run("HTTP pagination walks every event exactly once", func(t *testing.T) {
		cfg := testConfig()
		srv := httptest.NewServer(newServer(cfg, newPGStore(reader)))
		defer srv.Close()

		var want []string
		rows, err := admin.QueryContext(ctx, `SELECT event_id::text FROM metric_events
WHERE clientname = ANY($1::text[]) AND action <> 'Heartbeat' ORDER BY event_timestamp, event_id`, []string{roomA, roomC})
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				t.Fatal(err)
			}
			want = append(want, id)
		}
		rows.Close()

		params := url.Values{}
		params.Set("from", base.Add(-time.Hour).Format(time.RFC3339))
		params.Set("to", base.Add(4*time.Hour).Format(time.RFC3339))
		params.Add("client", roomA)
		params.Add("client", roomC)
		params.Set("limit", "1")
		var got []string
		cursor := ""
		for page := 0; page < 50; page++ {
			q := url.Values{}
			for k, v := range params {
				q[k] = v
			}
			if cursor != "" {
				q.Set("cursor", cursor)
			}
			req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/v1/events?"+q.Encode(), nil)
			req.Header.Set("Authorization", "Bearer "+testToken)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			var body struct {
				Events []struct {
					EventID string `json:"event_id"`
					Action  string `json:"action"`
				} `json:"events"`
				NextCursor *string `json:"next_cursor"`
			}
			err = json.NewDecoder(resp.Body).Decode(&body)
			resp.Body.Close()
			if err != nil || resp.StatusCode != http.StatusOK {
				t.Fatalf("page %d: status %d err %v", page, resp.StatusCode, err)
			}
			for _, e := range body.Events {
				got = append(got, e.EventID)
				if e.Action == "Heartbeat" {
					t.Fatal("heartbeat returned without include_heartbeats")
				}
			}
			if body.NextCursor == nil {
				break
			}
			cursor = *body.NextCursor
		}
		if strings.Join(got, ",") != strings.Join(want, ",") || len(want) != 10 {
			t.Fatalf("paged event ids\n got %v\nwant %v", got, want)
		}

		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/v1/info", nil)
		req.Header.Set("Authorization", "Bearer "+testToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("info status %d", resp.StatusCode)
		}
	})
}
