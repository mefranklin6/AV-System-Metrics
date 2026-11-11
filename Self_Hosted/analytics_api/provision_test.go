package main

import (
	"context"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
	"time"
)

const testReaderPassword = "Reader-password_123.456~xyz"

func TestValidateReaderPassword(t *testing.T) {
	good := []string{testReaderPassword, strings.Repeat("a", 16), strings.Repeat("Z9._~-", 21)[:126]}
	for _, pw := range good {
		if err := validateReaderPassword(pw, "admin_password_value"); err != nil {
			t.Fatalf("validateReaderPassword(%q) = %v", pw, err)
		}
	}
	bad := map[string]string{
		"":                                 "is required",
		exampleAnalyticsDBPassword:         "must be changed from the .env.example value",
		strings.Repeat("a", 15):            "at least 16",
		strings.Repeat("a", 129):           "at most 128",
		"has space in the password":        "may only contain",
		"quote'injection--xxxxxxx":         "may only contain",
		"percent%encoded_password":         "may only contain",
		"semicolon;drop_role_xxxx":         "may only contain",
		"unicode_ü_password_xxxxx":         "may only contain",
		"slash/and@at_password_xx":         "may only contain",
		"same_as_admin_password_123456789": "must be different from POSTGRES_PASSWORD",
	}
	for pw, want := range bad {
		err := validateReaderPassword(pw, "same_as_admin_password_123456789")
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("validateReaderPassword(%q) = %v, want %q", pw, err, want)
		}
		if pw != "" && strings.Contains(err.Error(), pw) {
			t.Fatalf("error leaks the password: %v", err)
		}
	}
}

func TestLoadProvisionConfig(t *testing.T) {
	set := func(dbURL, pw, timeout string) {
		t.Setenv("PROVISION_DATABASE_URL", dbURL)
		t.Setenv("ANALYTICS_DB_PASSWORD", pw)
		t.Setenv("ANALYTICS_PROVISION_TIMEOUT", timeout)
	}
	admin := "postgres://metrics_user:admin_password_value_1@postgres:5432/metrics?sslmode=disable"

	set(admin, testReaderPassword, "")
	cfg, err := loadProvisionConfig()
	if err != nil || cfg.timeout != 15*time.Minute || cfg.readerPassword != testReaderPassword {
		t.Fatalf("defaults: %+v %v", cfg.timeout, err)
	}
	set(admin, testReaderPassword, "1h")
	if cfg, err = loadProvisionConfig(); err != nil || cfg.timeout != time.Hour {
		t.Fatalf("timeout: %v %v", cfg.timeout, err)
	}

	cases := []struct{ url, pw, timeout, want string }{
		{"", testReaderPassword, "", "PROVISION_DATABASE_URL is required"},
		{"postgres://u:p@h:bad/db", testReaderPassword, "", "valid PostgreSQL connection string"},
		{"postgres://metrics_user:" + examplePostgresPassword + "@postgres/metrics", testReaderPassword, "", "POSTGRES_PASSWORD must be changed"},
		{admin, "", "", "ANALYTICS_DB_PASSWORD is required"},
		{admin, exampleAnalyticsDBPassword, "", "must be changed"},
		{admin, "admin_password_value_1", "", "must be different"},
		{admin, testReaderPassword, "0s", "positive duration"},
		{admin, testReaderPassword, "15", "positive duration"},
	}
	for _, tc := range cases {
		set(tc.url, tc.pw, tc.timeout)
		_, err := loadProvisionConfig()
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Fatalf("loadProvisionConfig(%q, %q, %q) = %v, want %q", tc.url, tc.pw, tc.timeout, err, tc.want)
		}
	}
}

func TestProvisionStatementText(t *testing.T) {
	grants := strings.Join(privilegeSQL(), "\n")
	column := ""
	for _, stmt := range privilegeSQL() {
		if strings.HasPrefix(stmt, "GRANT SELECT (") {
			column = stmt
		}
	}
	if column != "GRANT SELECT (id, clientname, event_timestamp, metric, action, event_id, received_at) ON public.metric_events TO metrics_reader" {
		t.Fatalf("column grant = %q", column)
	}
	for _, forbidden := range []string{"source_ip", "sort_key", "INSERT", "UPDATE", "DELETE", "ALL PRIVILEGES", "GRANT ALL"} {
		if strings.Contains(grants, forbidden) {
			t.Fatalf("privilege statements contain %q:\n%s", forbidden, grants)
		}
	}
	if !strings.Contains(grants, "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM metrics_reader") ||
		!strings.Contains(grants, "REVOKE CREATE ON SCHEMA public FROM PUBLIC") ||
		!strings.Contains(grants, "GRANT SELECT ON public.heartbeat_purge_status TO metrics_reader") ||
		!strings.Contains(grants, "pg_catalog.lo_from_bytea(oid, bytea), pg_catalog.lo_put(oid, bigint, bytea) FROM PUBLIC, metrics_reader") {
		t.Fatalf("missing privilege resets:\n%s", grants)
	}
	if !strings.HasPrefix(grants, "REVOKE") {
		t.Fatal("privileges must be revoked before granting")
	}

	for _, attr := range []string{"NOSUPERUSER", "NOCREATEDB", "NOCREATEROLE", "NOINHERIT", "NOREPLICATION", "NOBYPASSRLS"} {
		if !strings.Contains(createRoleSQL, attr) || !strings.Contains(alterRoleFormatSQL, attr) {
			t.Fatalf("role statements missing %s", attr)
		}
	}
	if !strings.Contains(alterRoleFormatSQL, "PASSWORD %L") || !strings.Contains(alterRoleFormatSQL, "CONNECTION LIMIT 10") ||
		!strings.Contains(alterRoleFormatSQL, "$2::text") || !strings.Contains(alterRoleFormatSQL, "ALTER ROLE %I") {
		t.Fatalf("password statement must be built server-side with format(): %s", alterRoleFormatSQL)
	}
	wantSettings := []string{"default_transaction_read_only = on", "statement_timeout = '30s'", "idle_in_transaction_session_timeout = '60s'", "lock_timeout = '5s'"}
	for i, want := range wantSettings {
		if !strings.HasSuffix(roleSettingsSQL[i], want) {
			t.Fatalf("role setting %d = %q, want suffix %q", i, roleSettingsSQL[i], want)
		}
	}
	for _, idx := range provisionIndexes {
		if !strings.HasPrefix(idx.createSQL, "CREATE INDEX CONCURRENTLY IF NOT EXISTS "+idx.name+" ON public.metric_events") {
			t.Fatalf("index statement = %q", idx.createSQL)
		}
	}
	if !strings.Contains(provisionIndexes[0].createSQL, "(event_timestamp, event_id) WHERE action <> 'Heartbeat'") ||
		!strings.Contains(provisionIndexes[1].createSQL, "(clientname, event_timestamp) WHERE action = 'Heartbeat'") {
		t.Fatal("index definitions do not match the spec")
	}
}

// provisionResponder simulates PostgreSQL catalogs for the provisioning flow.
type provisionResponder struct {
	roleExists  bool
	memberships []string
	indexStates map[string][]driver.Value // successive indisvalid answers per index (nil value = missing)
	failOn      string
}

func (p *provisionResponder) respond(c fakeCall) fakeResult {
	if p.failOn != "" && strings.Contains(c.query, p.failOn) {
		return fakeResult{err: errors.New("simulated failure")}
	}
	switch {
	case strings.HasPrefix(c.query, provisionReadySQL[:20]):
		return one(true)
	case c.query == roleExistsSQL:
		return one(p.roleExists)
	case c.query == alterRoleFormatSQL:
		pw := c.args[1].(string)
		return one("ALTER ROLE metrics_reader WITH LOGIN PASSWORD '" + pw + "'")
	case c.query == memberOfFormatSQL:
		res := noRows(1)
		for _, m := range p.memberships {
			res.rows = append(res.rows, []driver.Value{m})
		}
		return res
	case c.query == remainingMembershipsSQL:
		return one(int64(0))
	case c.query == grantConnectFormatSQL:
		return one("GRANT CONNECT ON DATABASE metrics TO metrics_reader")
	case c.query == databaseRevokeFormatSQL:
		return one("REVOKE ALL ON DATABASE metrics FROM metrics_reader", "REVOKE TEMPORARY ON DATABASE metrics FROM PUBLIC")
	case c.query == indexValiditySQL:
		name := c.args[0].(string)
		states := p.indexStates[name]
		if len(states) == 0 {
			return one(true)
		}
		next := states[0]
		p.indexStates[name] = states[1:]
		if next == nil {
			return noRows(1)
		}
		return one(next)
	}
	return fakeResult{}
}

func TestProvisionFlowCreatesRoleGrantsAndIndexes(t *testing.T) {
	resp := &provisionResponder{
		memberships: []string{"REVOKE pg_read_all_data FROM metrics_reader GRANTED BY metrics_user"},
		indexStates: map[string][]driver.Value{
			"idx_metric_events_activity_ts":         {nil, true},   // missing -> created
			"idx_metric_events_heartbeat_client_ts": {false, true}, // invalid -> rebuilt
		},
	}
	db, fake := newFakeDB(t, resp.respond)
	summary, err := provision(context.Background(), db, testReaderPassword)
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	if !summary.roleCreated || summary.membershipsRevoked != 1 ||
		strings.Join(summary.indexes, ";") != "idx_metric_events_activity_ts created;idx_metric_events_heartbeat_client_ts rebuilt" {
		t.Fatalf("summary = %+v", summary)
	}
	if strings.Contains(summary.String(), testReaderPassword) {
		t.Fatal("summary leaks the password")
	}

	calls := fake.recorded()
	order := []string{
		"pg_advisory_lock",
		"BEGIN",
		"SET LOCAL log_statement = 'none'",
		"SET LOCAL log_min_error_statement = 'panic'",
		roleExistsSQL,
		createRoleSQL,
		alterRoleFormatSQL,
		"ALTER ROLE metrics_reader WITH LOGIN PASSWORD",
		roleSettingsSQL[0],
		memberOfFormatSQL,
		"REVOKE pg_read_all_data FROM metrics_reader",
		"REVOKE ALL ON DATABASE metrics FROM metrics_reader",
		"REVOKE TEMPORARY ON DATABASE metrics FROM PUBLIC",
		"REVOKE ALL ON ALL TABLES IN SCHEMA public FROM metrics_reader",
		"REVOKE EXECUTE ON FUNCTION pg_catalog.lo_create(oid)",
		"GRANT SELECT (id, clientname",
		"GRANT CONNECT ON DATABASE metrics TO metrics_reader",
		"COMMIT",
		"SET statement_timeout = 0",
		provisionIndexes[0].createSQL,
		"DROP INDEX CONCURRENTLY IF EXISTS public.idx_metric_events_heartbeat_client_ts",
		provisionIndexes[1].createSQL,
		"pg_advisory_unlock",
	}
	pos := 0
	for _, c := range calls {
		if pos < len(order) && strings.Contains(c.query, order[pos]) {
			pos++
		}
	}
	if pos != len(order) {
		var got []string
		for _, c := range calls {
			got = append(got, c.query)
		}
		t.Fatalf("statement %q missing or out of order; got:\n%s", order[pos], strings.Join(got, "\n"))
	}

	for _, c := range calls {
		// The password must only ever travel as a bind argument to format().
		if c.query != "ALTER ROLE metrics_reader WITH LOGIN PASSWORD '"+testReaderPassword+"'" && strings.Contains(c.query, testReaderPassword) {
			t.Fatalf("password concatenated into SQL text: %q", c.query)
		}
		if c.query == alterRoleFormatSQL && (len(c.args) != 3 || c.args[0] != readerRole || c.args[1] != testReaderPassword || c.args[2] != "infinity") {
			t.Fatalf("format args = %v", c.args)
		}
		if strings.Contains(c.query, "CONCURRENTLY") && c.inTx {
			t.Fatalf("concurrent index statement ran inside a transaction: %q", c.query)
		}
		if strings.HasPrefix(c.query, "SET LOCAL") && !c.inTx {
			t.Fatalf("SET LOCAL outside the role transaction: %q", c.query)
		}
		if strings.Contains(c.query, "PASSWORD") && !strings.Contains(c.query, "format(") && !c.inTx {
			t.Fatal("password statement must run inside the logging-protected transaction")
		}
	}
}

func TestProvisionExistingRoleAndValidIndexes(t *testing.T) {
	resp := &provisionResponder{roleExists: true}
	db, fake := newFakeDB(t, resp.respond)
	summary, err := provision(context.Background(), db, testReaderPassword)
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	if summary.roleCreated || summary.membershipsRevoked != 0 ||
		strings.Join(summary.indexes, ";") != "idx_metric_events_activity_ts present;idx_metric_events_heartbeat_client_ts present" {
		t.Fatalf("summary = %+v", summary)
	}
	calls := fake.recorded()
	if containsQuery(calls, "CREATE ROLE") || containsQuery(calls, "CREATE INDEX") || containsQuery(calls, "DROP INDEX") {
		t.Fatal("idempotent run must not recreate the role or valid indexes")
	}
	if !containsQuery(calls, "ALTER ROLE metrics_reader WITH LOGIN PASSWORD") {
		t.Fatal("password and attributes must be re-applied on every run")
	}
}

func TestProvisionErrorsRollBackAndNeverLeakPassword(t *testing.T) {
	for _, failOn := range []string{"ALTER ROLE metrics_reader WITH LOGIN", "GRANT SELECT (", provisionIndexes[0].createSQL} {
		resp := &provisionResponder{failOn: failOn, indexStates: map[string][]driver.Value{"idx_metric_events_activity_ts": {nil}}}
		db, fake := newFakeDB(t, resp.respond)
		_, err := provision(context.Background(), db, testReaderPassword)
		if err == nil {
			t.Fatalf("failure on %q not reported", failOn)
		}
		if strings.Contains(err.Error(), testReaderPassword) {
			t.Fatalf("error leaks password: %v", err)
		}
		calls := fake.recorded()
		if failOn != provisionIndexes[0].createSQL {
			if containsQuery(calls, "COMMIT") || !containsQuery(calls, "ROLLBACK") {
				t.Fatalf("role transaction not rolled back after failure on %q", failOn)
			}
		}
		if !containsQuery(calls, "pg_advisory_unlock") {
			t.Fatal("advisory lock not released after failure")
		}
	}
}

func TestProvisionRejectsBadPasswordBeforeConnecting(t *testing.T) {
	db, fake := newFakeDB(t, nil)
	if _, err := provision(context.Background(), db, "short"); err == nil {
		t.Fatal("short password accepted")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("no SQL may run with an invalid password")
	}
}

func TestWaitForSchemaRetriesUntilReady(t *testing.T) {
	attempts := 0
	db, _ := newFakeDB(t, func(c fakeCall) fakeResult {
		attempts++
		switch attempts {
		case 1:
			return fakeResult{err: errors.New("connection refused")}
		case 2:
			return one(false)
		default:
			return one(true)
		}
	})
	if err := waitForSchema(context.Background(), db, 5*time.Second, time.Millisecond); err != nil {
		t.Fatalf("waitForSchema: %v", err)
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}

	never, _ := newFakeDB(t, func(fakeCall) fakeResult { return one(false) })
	err := waitForSchema(context.Background(), never, 20*time.Millisecond, 5*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "metric_events does not exist") {
		t.Fatalf("err = %v", err)
	}
}
