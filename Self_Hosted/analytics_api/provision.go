package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	// readerRole is the only role the provisioner manages. It is a constant,
	// never taken from input.
	readerRole = "metrics_reader"

	minReaderPasswordLen = 16
	maxReaderPasswordLen = 128

	// provisionLockKey serializes concurrent provisioning runs (pg_advisory_lock).
	provisionLockKey int64 = 0x4156534d_414e4c59 // "AVSMANLY"

	readerRoleAttributes = "NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS"
)

// Readiness polling for the provisioner; variables so tests can shorten them.
var (
	provisionReadyTimeout  = 60 * time.Second
	provisionReadyInterval = 2 * time.Second
)

// readerColumns are the only metric_events columns metrics_reader may read.
// source_ip and sort_key are deliberately excluded.
var readerColumns = []string{"id", "clientname", "event_timestamp", "metric", "action", "event_id", "received_at"}

type indexSpec struct {
	name      string
	createSQL string
}

// provisionIndexes are built CONCURRENTLY (never inside a transaction) so
// ingestion keeps running while they build.
var provisionIndexes = []indexSpec{
	{
		name:      "idx_metric_events_activity_ts",
		createSQL: `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_metric_events_activity_ts ON public.metric_events (event_timestamp, event_id) WHERE action <> 'Heartbeat'`,
	},
	{
		name:      "idx_metric_events_heartbeat_client_ts",
		createSQL: `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_metric_events_heartbeat_client_ts ON public.metric_events (clientname, event_timestamp) WHERE action = 'Heartbeat'`,
	},
}

const (
	provisionReadySQL = `SELECT to_regclass('public.metric_events') IS NOT NULL
    AND to_regclass('public.heartbeat_purge_status') IS NOT NULL`
	roleExistsSQL = `SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)`
	createRoleSQL = `CREATE ROLE ` + readerRole + ` WITH NOLOGIN ` + readerRoleAttributes
	// Utility statements cannot take bind parameters, so PostgreSQL itself
	// quotes the identifier (%I) and password literal (%L) from bind values.
	// The password is never concatenated into SQL text in Go.
	alterRoleFormatSQL = `SELECT format('ALTER ROLE %I WITH ` + readerRoleAttributes +
		` LOGIN PASSWORD %L CONNECTION LIMIT 10 VALID UNTIL %L', $1::text, $2::text, $3::text)`
	grantConnectFormatSQL = `SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), $1::text)`
	// PostgreSQL grants TEMPORARY on every database to PUBLIC by default, so
	// revoking it only from metrics_reader would have no effect. The database
	// owner (metrics_user, a superuser) is unaffected.
	databaseRevokeFormatSQL = `SELECT format('REVOKE ALL ON DATABASE %I FROM %I', current_database(), $1::text),
    format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database())`
	memberOfFormatSQL = `SELECT format('REVOKE %I FROM %I GRANTED BY %I', g.rolname, u.rolname, gr.rolname)
FROM pg_auth_members m
JOIN pg_roles g ON g.oid = m.roleid
JOIN pg_roles u ON u.oid = m.member
JOIN pg_roles gr ON gr.oid = m.grantor
WHERE u.rolname = $1
ORDER BY g.rolname, gr.rolname`
	remainingMembershipsSQL = `SELECT count(*) FROM pg_auth_members m JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = $1`
	indexValiditySQL        = `SELECT i.indisvalid
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = $1`
)

// protectSessionLogging keeps the password-bearing ALTER ROLE statement out
// of server logs and statement statistics for this transaction only.
var protectSessionLogging = []string{
	`SET LOCAL log_statement = 'none'`,
	`SET LOCAL log_min_error_statement = 'panic'`,
	`SET LOCAL log_min_duration_statement = -1`,
	`SET LOCAL log_min_duration_sample = -1`,
	`SET LOCAL pg_stat_statements.track_utility = off`,
	`SET LOCAL password_encryption = 'scram-sha-256'`,
}

var roleSettingsSQL = []string{
	`ALTER ROLE ` + readerRole + ` SET default_transaction_read_only = on`,
	`ALTER ROLE ` + readerRole + ` SET statement_timeout = '30s'`,
	`ALTER ROLE ` + readerRole + ` SET idle_in_transaction_session_timeout = '60s'`,
	`ALTER ROLE ` + readerRole + ` SET lock_timeout = '5s'`,
}

// privilegeSQL resets metrics_reader's privileges to exactly what the API needs.
// REVOKE at table level also revokes earlier column-level grants.
func privilegeSQL() []string {
	return []string{
		`REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ` + readerRole,
		`REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM ` + readerRole,
		`REVOKE CREATE ON SCHEMA public FROM PUBLIC`,
		// Large objects are stored in pg_largeobject, outside any table grant;
		// PUBLIC may create them by default. Server-side lo_import/lo_export
		// are already restricted to superusers.
		`REVOKE EXECUTE ON FUNCTION pg_catalog.lo_create(oid), pg_catalog.lo_creat(integer), ` +
			`pg_catalog.lo_from_bytea(oid, bytea), pg_catalog.lo_put(oid, bigint, bytea) FROM PUBLIC, ` + readerRole,
		`GRANT USAGE ON SCHEMA public TO ` + readerRole,
		`GRANT SELECT (` + strings.Join(readerColumns, ", ") + `) ON public.metric_events TO ` + readerRole,
		`GRANT SELECT ON public.heartbeat_purge_status TO ` + readerRole,
	}
}

type provisionConfig struct {
	databaseURL    string
	readerPassword string
	timeout        time.Duration
}

func loadProvisionConfig() (provisionConfig, error) {
	cfg := provisionConfig{databaseURL: strings.TrimSpace(os.Getenv("PROVISION_DATABASE_URL"))}
	if cfg.databaseURL == "" {
		return cfg, errors.New("PROVISION_DATABASE_URL is required")
	}
	adminConfig, err := pgconn.ParseConfig(cfg.databaseURL)
	if err != nil {
		return cfg, errors.New("PROVISION_DATABASE_URL must be a valid PostgreSQL connection string")
	}
	if adminConfig.Password == examplePostgresPassword {
		return cfg, errors.New("POSTGRES_PASSWORD must be changed from the .env.example value")
	}
	cfg.readerPassword = os.Getenv("ANALYTICS_DB_PASSWORD")
	if err := validateReaderPassword(cfg.readerPassword, adminConfig.Password); err != nil {
		return cfg, err
	}
	cfg.timeout = defaultProvision
	if raw := strings.TrimSpace(os.Getenv("ANALYTICS_PROVISION_TIMEOUT")); raw != "" {
		d, err := time.ParseDuration(raw)
		if err != nil || d <= 0 {
			return cfg, errors.New("ANALYTICS_PROVISION_TIMEOUT must be a positive duration (for example 15m or 1h)")
		}
		cfg.timeout = d
	}
	return cfg, nil
}

// validateReaderPassword enforces the metrics_reader password policy. Error
// messages never include the password.
func validateReaderPassword(password, adminPassword string) error {
	switch {
	case password == "":
		return errors.New("ANALYTICS_DB_PASSWORD is required")
	case password == exampleAnalyticsDBPassword:
		return errors.New("ANALYTICS_DB_PASSWORD must be changed from the .env.example value")
	case len(password) < minReaderPasswordLen:
		return fmt.Errorf("ANALYTICS_DB_PASSWORD must be at least %d characters", minReaderPasswordLen)
	case len(password) > maxReaderPasswordLen:
		return fmt.Errorf("ANALYTICS_DB_PASSWORD must be at most %d characters", maxReaderPasswordLen)
	}
	for i := 0; i < len(password); i++ {
		if !isURLSafePasswordChar(password[i]) {
			return errors.New("ANALYTICS_DB_PASSWORD may only contain letters, digits, '.', '_', '~', and '-' (it is embedded in a database URL)")
		}
	}
	if adminPassword != "" && password == adminPassword {
		return errors.New("ANALYTICS_DB_PASSWORD must be different from POSTGRES_PASSWORD")
	}
	return nil
}

func isURLSafePasswordChar(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
		c == '.' || c == '_' || c == '~' || c == '-'
}

type provisionSummary struct {
	roleCreated        bool
	membershipsRevoked int
	indexes            []string // "<name> created|present|rebuilt"
}

func (s provisionSummary) String() string {
	role := "updated"
	if s.roleCreated {
		role = "created"
	}
	return fmt.Sprintf("role %s %s (read-only defaults, column-level SELECT); %d stale role memberships revoked; indexes: %s",
		readerRole, role, s.membershipsRevoked, strings.Join(s.indexes, ", "))
}

// runProvision is the entry point of the "provision" subcommand.
func runProvision(ctx context.Context) error {
	cfg, err := loadProvisionConfig()
	if err != nil {
		return err
	}
	db, err := sql.Open("pgx", cfg.databaseURL)
	if err != nil {
		return errors.New("could not configure the database connection")
	}
	defer db.Close()
	db.SetMaxOpenConns(2)

	if err := waitForSchema(ctx, db, provisionReadyTimeout, provisionReadyInterval); err != nil {
		return err
	}
	runCtx, cancel := context.WithTimeout(ctx, cfg.timeout)
	defer cancel()
	summary, err := provision(runCtx, db, cfg.readerPassword)
	if err != nil {
		return err
	}
	log.Printf("analytics provisioning complete: %s", summary)
	return nil
}

// waitForSchema retries until the database accepts connections and the
// ingest service has created its tables.
func waitForSchema(ctx context.Context, db *sql.DB, timeout, interval time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		attemptCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		var ready bool
		err := db.QueryRowContext(attemptCtx, provisionReadySQL).Scan(&ready)
		cancel()
		switch {
		case err == nil && ready:
			return nil
		case err == nil:
			lastErr = errors.New("table metric_events does not exist yet (the ingest service creates it on startup)")
		default:
			lastErr = err
		}
		if time.Now().Add(interval).After(deadline) {
			return fmt.Errorf("database not ready after %s: %w", timeout, lastErr)
		}
		log.Printf("analytics provisioning: waiting for database: %v", lastErr)
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

// provision creates or repairs metrics_reader and the read-path indexes.
// Every step is idempotent.
func provision(ctx context.Context, db *sql.DB, password string) (provisionSummary, error) {
	var summary provisionSummary
	if err := validateReaderPassword(password, ""); err != nil {
		return summary, err
	}
	conn, err := db.Conn(ctx)
	if err != nil {
		return summary, fmt.Errorf("connect: %w", err)
	}
	defer conn.Close()

	if _, err := conn.ExecContext(ctx, `SELECT pg_advisory_lock($1)`, provisionLockKey); err != nil {
		return summary, fmt.Errorf("acquire provisioning lock: %w", err)
	}
	defer func() {
		unlockCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = conn.ExecContext(unlockCtx, `SELECT pg_advisory_unlock($1)`, provisionLockKey)
	}()

	if err := provisionRole(ctx, conn, password, &summary); err != nil {
		return summary, err
	}
	if err := provisionIndexesConcurrently(ctx, conn, &summary); err != nil {
		return summary, err
	}
	return summary, nil
}

func provisionRole(ctx context.Context, conn *sql.Conn, password string, summary *provisionSummary) error {
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin role transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	for _, stmt := range protectSessionLogging {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("prepare session: %w", err)
		}
	}

	var exists bool
	if err := tx.QueryRowContext(ctx, roleExistsSQL, readerRole).Scan(&exists); err != nil {
		return fmt.Errorf("check role: %w", err)
	}
	if !exists {
		if _, err := tx.ExecContext(ctx, createRoleSQL); err != nil {
			return fmt.Errorf("create role %s: %w", readerRole, err)
		}
		summary.roleCreated = true
	}

	var alterRole string
	if err := tx.QueryRowContext(ctx, alterRoleFormatSQL, readerRole, password, "infinity").Scan(&alterRole); err != nil {
		return fmt.Errorf("build role password statement: %w", err)
	}
	if _, err := tx.ExecContext(ctx, alterRole); err != nil {
		// Never include the statement: it contains the password.
		return fmt.Errorf("set %s login and password: %w", readerRole, err)
	}

	for _, stmt := range roleSettingsSQL {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("set %s defaults: %w", readerRole, err)
		}
	}

	revokes, err := queryStrings(ctx, tx, memberOfFormatSQL, readerRole)
	if err != nil {
		return fmt.Errorf("list role memberships: %w", err)
	}
	for _, stmt := range revokes {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("revoke role membership: %w", err)
		}
	}
	summary.membershipsRevoked = len(revokes)
	var remaining int
	if err := tx.QueryRowContext(ctx, remainingMembershipsSQL, readerRole).Scan(&remaining); err != nil {
		return fmt.Errorf("verify role memberships: %w", err)
	}
	if remaining != 0 {
		return fmt.Errorf("%s is still a member of %d roles; remove those memberships manually", readerRole, remaining)
	}

	var grantConnect string
	if err := tx.QueryRowContext(ctx, grantConnectFormatSQL, readerRole).Scan(&grantConnect); err != nil {
		return fmt.Errorf("build connect grant: %w", err)
	}
	var revokeDatabase, revokeTemporary string
	if err := tx.QueryRowContext(ctx, databaseRevokeFormatSQL, readerRole).Scan(&revokeDatabase, &revokeTemporary); err != nil {
		return fmt.Errorf("build database privilege statements: %w", err)
	}
	statements := append([]string{revokeDatabase, revokeTemporary}, privilegeSQL()...)
	for _, stmt := range append(statements, grantConnect) {
		if _, err := tx.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("set %s privileges: %w", readerRole, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit role changes: %w", err)
	}
	return nil
}

type queryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func queryStrings(ctx context.Context, q queryer, query string, args ...any) ([]string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		out = append(out, value)
	}
	return out, rows.Err()
}

// provisionIndexesConcurrently builds each index outside any transaction.
// An index left invalid by an interrupted concurrent build is dropped
// concurrently and rebuilt.
func provisionIndexesConcurrently(ctx context.Context, conn *sql.Conn, summary *provisionSummary) error {
	// Index builds may legitimately run long; the context deadline bounds them.
	for _, stmt := range []string{`SET statement_timeout = 0`, `SET lock_timeout = 0`} {
		if _, err := conn.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("prepare index session: %w", err)
		}
	}
	for _, idx := range provisionIndexes {
		state, err := indexState(ctx, conn, idx.name)
		if err != nil {
			return err
		}
		outcome := "present"
		switch state {
		case indexValid:
		case indexInvalid:
			log.Printf("analytics provisioning: index %s is invalid (an earlier build was interrupted); rebuilding", idx.name)
			if _, err := conn.ExecContext(ctx, `DROP INDEX CONCURRENTLY IF EXISTS public.`+idx.name); err != nil {
				return fmt.Errorf("drop invalid index %s: %w", idx.name, err)
			}
			outcome = "rebuilt"
			fallthrough
		case indexMissing:
			if outcome == "present" {
				outcome = "created"
			}
			log.Printf("analytics provisioning: building index %s concurrently (this can take a while on large tables)", idx.name)
			if _, err := conn.ExecContext(ctx, idx.createSQL); err != nil {
				return fmt.Errorf("create index %s: %w (re-run provisioning to repair)", idx.name, err)
			}
			after, err := indexState(ctx, conn, idx.name)
			if err != nil {
				return err
			}
			if after != indexValid {
				return fmt.Errorf("index %s is not valid after building; a non-index relation may use that name", idx.name)
			}
		}
		summary.indexes = append(summary.indexes, idx.name+" "+outcome)
	}
	return nil
}

type indexStatus int

const (
	indexMissing indexStatus = iota
	indexValid
	indexInvalid
)

func indexState(ctx context.Context, conn *sql.Conn, name string) (indexStatus, error) {
	var valid bool
	err := conn.QueryRowContext(ctx, indexValiditySQL, name).Scan(&valid)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return indexMissing, nil
	case err != nil:
		return indexMissing, fmt.Errorf("check index %s: %w", name, err)
	case valid:
		return indexValid, nil
	default:
		return indexInvalid, nil
	}
}
