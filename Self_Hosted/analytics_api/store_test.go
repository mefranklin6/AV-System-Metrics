package main

import (
	"context"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"
)

var (
	rangeFrom = time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	rangeTo   = time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC)
)

func TestBuildEventsQueryIsParameterized(t *testing.T) {
	id, _ := parseUUID("f5ba6c9f-571c-472c-8d6a-6002f03d8209")
	q := eventQuery{
		Range:   timeRange{From: rangeFrom, To: rangeTo},
		Clients: []string{"BSS_245", "x'; DROP TABLE metric_events; --"},
		Metrics: []string{"hdmi"},
		Actions: []string{"Started"},
		Limit:   250,
		After:   &pageCursor{Timestamp: rangeFrom.Add(time.Hour), EventID: id},
	}
	query, args := buildEventsQuery(q)
	for _, want := range []string{
		"event_timestamp >= $1", "event_timestamp < $2", "action <> 'Heartbeat'",
		"clientname = ANY($3::text[])", "metric = ANY($4::text[])", "action = ANY($5::text[])",
		"(event_timestamp, event_id) > ($6, $7::uuid)", "ORDER BY event_timestamp, event_id", "LIMIT $8",
	} {
		if !strings.Contains(query, want) {
			t.Fatalf("query lacks %q:\n%s", want, query)
		}
	}
	if strings.Contains(query, "DROP TABLE") || strings.Contains(query, "BSS_245") || strings.Contains(query, "source_ip") || strings.Contains(query, "sort_key") {
		t.Fatalf("query contains values or forbidden columns:\n%s", query)
	}
	if len(args) != 8 || args[6] != "f5ba6c9f-571c-472c-8d6a-6002f03d8209" || args[7] != 251 {
		t.Fatalf("args = %#v", args)
	}

	minimal, args := buildEventsQuery(eventQuery{Range: timeRange{From: rangeFrom, To: rangeTo}, IncludeHeartbeats: true, Limit: 10})
	if strings.Contains(minimal, "Heartbeat") || strings.Contains(minimal, "ANY(") || len(args) != 3 {
		t.Fatalf("minimal query:\n%s\nargs %v", minimal, args)
	}
}

func TestBuildSummaryAndHeartbeatQueries(t *testing.T) {
	query, args := buildSummaryQuery(summaryQuery{Range: timeRange{From: rangeFrom, To: rangeTo}, Clients: []string{"A"}})
	if !strings.Contains(query, "GROUP BY clientname, metric, action") || !strings.Contains(query, "action <> 'Heartbeat'") ||
		!strings.Contains(query, `ORDER BY clientname COLLATE "C", metric COLLATE "C", action COLLATE "C"`) || args[len(args)-1] != maxSummaryRows+1 {
		t.Fatalf("summary query:\n%s\nargs %v", query, args)
	}

	query, args, err := buildHeartbeatsQuery(heartbeatQuery{Range: timeRange{From: rangeFrom, To: rangeTo}, Bucket: "day", Clients: []string{"A"}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(query, "date_trunc($1::text, event_timestamp AT TIME ZONE 'UTC')") || !strings.Contains(query, "action = 'Heartbeat'") ||
		args[0] != "day" || len(args) != 5 || args[4] != maxHeartbeatBuckets+1 || !strings.HasSuffix(query, "LIMIT $5") {
		t.Fatalf("heartbeat query:\n%s\nargs %v", query, args)
	}
	if _, _, err := buildHeartbeatsQuery(heartbeatQuery{Bucket: "minute"}); err == nil {
		t.Fatal("unsupported bucket accepted")
	}
}

func TestPGStoreUsesReadOnlyTransactions(t *testing.T) {
	ts1 := time.Date(2026, 11, 10, 23, 47, 27, 225600000, time.UTC)
	ts2 := ts1.Add(time.Second)
	db, fake := newFakeDB(t, func(c fakeCall) fakeResult {
		switch {
		case c.query == infoActivitySQL:
			return one(ts1, ts2)
		case c.query == infoPurgeSQL:
			return noRows(4)
		case c.query == clientsSQL:
			return fakeResult{cols: []string{"a", "b", "c", "d", "e", "f"}, rows: [][]driver.Value{
				{"BSS_245", int64(3), int64(10), ts1, ts2, ts2},
				{"HOLT_155", int64(0), int64(5), nil, nil, ts2},
			}}
		case strings.Contains(c.query, "FROM metric_events") && strings.Contains(c.query, "ORDER BY event_timestamp, event_id"):
			return fakeResult{cols: make([]string, 7), rows: [][]driver.Value{
				{int64(1), "Holt_171", ts1, "System - User", "Stopped", "f5ba6c9f-571c-472c-8d6a-6002f03d8209", ts2},
				{int64(2), "Holt_171", ts2, "Projector_2", "Stopped", "c114bf2c-19c0-4559-adc3-47ac07ea7e53", ts2},
				{int64(3), "Holt_171", ts2, "Projector_1", "Stopped", "d114bf2c-19c0-4559-adc3-47ac07ea7e53", ts2},
			}}
		case strings.Contains(c.query, "GROUP BY clientname, metric, action"):
			return fakeResult{cols: make([]string, 6), rows: [][]driver.Value{{"A", "hdmi", "Started", int64(4), ts1, ts2}}}
		case strings.Contains(c.query, "date_trunc"):
			bucket := time.Date(2026, 11, 9, 1, 0, 0, 0, time.UTC)
			return fakeResult{cols: make([]string, 3), rows: [][]driver.Value{
				{"A", bucket, int64(12)}, {"A", bucket.Add(time.Hour), int64(11)}, {"B", bucket, int64(3)},
			}}
		}
		return fakeResult{}
	})
	s := newPGStore(db)
	ctx := context.Background()
	rng := timeRange{From: rangeFrom, To: rangeTo}

	info, err := s.Info(ctx)
	if err != nil || info.ActivityRange.FirstEvent == nil || !info.ActivityRange.FirstEvent.Equal(ts1) || info.HeartbeatPurge.EnabledStatus != nil {
		t.Fatalf("Info = %+v, %v", info, err)
	}
	clients, err := s.Clients(ctx, rng)
	if err != nil || len(clients) != 2 || clients[1].FirstEvent != nil || clients[1].LastHeartbeat == nil || clients[0].EventCount != 3 {
		t.Fatalf("Clients = %+v, %v", clients, err)
	}
	events, more, err := s.Events(ctx, eventQuery{Range: rng, Limit: 2})
	if err != nil || len(events) != 2 || !more || events[0].EventID != "f5ba6c9f-571c-472c-8d6a-6002f03d8209" {
		t.Fatalf("Events = %+v more=%v %v", events, more, err)
	}
	events, more, err = s.Events(ctx, eventQuery{Range: rng, Limit: 3})
	if err != nil || len(events) != 3 || more {
		t.Fatalf("Events exact page = %d more=%v %v", len(events), more, err)
	}
	rows, truncated, err := s.Summary(ctx, summaryQuery{Range: rng})
	if err != nil || len(rows) != 1 || truncated || rows[0].Count != 4 {
		t.Fatalf("Summary = %+v %v %v", rows, truncated, err)
	}
	series, hbTruncated, err := s.Heartbeats(ctx, heartbeatQuery{Range: rng, Bucket: "hour"})
	if err != nil || hbTruncated || len(series) != 2 || len(series[0].Buckets) != 2 || series[1].ClientName != "B" || series[0].Buckets[1].Count != 11 {
		t.Fatalf("Heartbeats = %+v %v %v", series, hbTruncated, err)
	}

	for _, c := range fake.recorded() {
		if c.query == "BEGIN" || c.query == "COMMIT" || c.query == "ROLLBACK" {
			continue
		}
		if !c.inTx || !c.txReadOnly {
			t.Fatalf("query ran outside a read-only transaction: %q", c.query)
		}
	}
	if containsQuery(fake.recorded(), "COMMIT") {
		t.Fatal("read-only transactions should be rolled back, not committed")
	}
	for _, opts := range fake.txOptions {
		if !opts.ReadOnly {
			t.Fatal("transaction opened without ReadOnly")
		}
	}
}

func TestPGStoreSummaryTruncation(t *testing.T) {
	ts := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	db, _ := newFakeDB(t, func(c fakeCall) fakeResult {
		res := fakeResult{cols: make([]string, 6)}
		for i := 0; i < maxSummaryRows+1; i++ {
			res.rows = append(res.rows, []driver.Value{"A", "m", "a", int64(1), ts, ts})
		}
		return res
	})
	rows, truncated, err := newPGStore(db).Summary(context.Background(), summaryQuery{Range: timeRange{From: rangeFrom, To: rangeTo}})
	if err != nil || len(rows) != maxSummaryRows || !truncated {
		t.Fatalf("rows=%d truncated=%v err=%v", len(rows), truncated, err)
	}
}

func TestPGStoreHeartbeatTruncation(t *testing.T) {
	start := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	db, _ := newFakeDB(t, func(c fakeCall) fakeResult {
		res := fakeResult{cols: make([]string, 3)}
		for i := 0; i < maxHeartbeatBuckets+1; i++ {
			client := "A"
			if i >= maxHeartbeatBuckets/2 {
				client = "B"
			}
			res.rows = append(res.rows, []driver.Value{client, start.Add(time.Duration(i) * time.Hour), int64(12)})
		}
		return res
	})
	series, truncated, err := newPGStore(db).Heartbeats(context.Background(), heartbeatQuery{Range: timeRange{From: rangeFrom, To: rangeTo}, Bucket: "hour"})
	if err != nil || !truncated || len(series) != 2 || len(series[0].Buckets)+len(series[1].Buckets) != maxHeartbeatBuckets {
		t.Fatalf("series=%d truncated=%v err=%v", len(series), truncated, err)
	}
}

func TestPGStorePropagatesErrors(t *testing.T) {
	db, fake := newFakeDB(t, func(fakeCall) fakeResult { return fakeResult{err: errors.New("boom")} })
	_ = fake
	s := newPGStore(db)
	if _, err := s.Clients(context.Background(), timeRange{From: rangeFrom, To: rangeTo}); err == nil {
		t.Fatal("error swallowed")
	}
	fake.beginErr = errors.New("cannot begin")
	if _, err := s.Info(context.Background()); err == nil {
		t.Fatal("begin error swallowed")
	}
}

func safeSelfCheckRow() []driver.Value {
	return []driver.Value{"metrics_reader", "on", "on", false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false}
}

func TestSelfCheck(t *testing.T) {
	db, fake := newFakeDB(t, func(c fakeCall) fakeResult { return one(safeSelfCheckRow()...) })
	res, err := runSelfCheck(context.Background(), db)
	if err != nil || res.User != "metrics_reader" {
		t.Fatalf("safe role rejected: %v", err)
	}
	for _, c := range fake.recorded() {
		if c.inTx {
			t.Fatal("self-check must observe session defaults outside a transaction")
		}
	}

	unsafe := map[int]string{
		1:  "not read-only by default",
		2:  "not read-only by default",
		3:  "superuser",
		4:  "create roles",
		5:  "create databases",
		6:  "row-level security",
		7:  "replication",
		8:  "member of other roles",
		9:  "INSERT",
		10: "UPDATE",
		11: "DELETE",
		12: "TRUNCATE",
		13: "heartbeat_purge_status",
		14: "CREATE objects",
		15: "TEMPORARY",
		16: "large objects",
		17: "source_ip",
		18: "sort_key",
	}
	for col, want := range unsafe {
		row := safeSelfCheckRow()
		if col <= 2 {
			row[col] = "off"
		} else {
			row[col] = true
		}
		db, _ := newFakeDB(t, func(fakeCall) fakeResult { return one(row...) })
		_, err := runSelfCheck(context.Background(), db)
		if err == nil || !strings.Contains(err.Error(), want) || !strings.Contains(err.Error(), "metrics_reader") {
			t.Fatalf("column %d: err = %v, want %q", col, err, want)
		}
	}

	// Column-level INSERT/UPDATE grants are caught, not only table-level ones.
	for _, want := range []string{"has_any_column_privilege(current_user, 'public.metric_events', 'INSERT')",
		"has_any_column_privilege(current_user, 'public.metric_events', 'UPDATE')",
		"has_any_column_privilege(current_user, 'public.heartbeat_purge_status', 'INSERT, UPDATE')",
		"'CREATE, TEMPORARY'", "lo_from_bytea(oid, bytea)", "'sort_key', 'SELECT'"} {
		if !strings.Contains(selfCheckSQL, want) {
			t.Fatalf("self-check SQL is missing %s", want)
		}
	}

	missing, _ := newFakeDB(t, func(fakeCall) fakeResult { return noRows(19) })
	if _, err := runSelfCheck(context.Background(), missing); err == nil {
		t.Fatal("missing role row accepted")
	}
}
