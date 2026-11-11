#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end test of the optional Analytics API against a throwaway
# PostgreSQL 18 on a private, --internal Docker network: no published ports,
# no host mounts, no persistent volumes, no internet access for the test
# containers. It
#   1. builds the production image (or uses ANALYTICS_IT_IMAGE),
#   2. applies ../schema.sql (the ingest schema) and seeds sample rows,
#   3. runs `analytics-api provision` twice (idempotency),
#   4. proves the server refuses to start with the superuser role,
#   5. starts the API as metrics_reader and probes it from another container,
#   6. runs the database-backed Go tests (db_integration_test.go) from another
#      container so scram-sha-256 password authentication is really exercised,
#   7. checks the ENABLE_ANALYTICS_API=false statement revokes the login.
# Requires Docker with BuildKit and Go (to cross-compile the test binary).

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCHEMA_FILE="$SOURCE_DIR/../schema.sql"
RUN_ID="$$-$RANDOM"
NETWORK="avsm-analytics-it-$RUN_ID"
PG="avsm-analytics-it-pg-$RUN_ID"
API="avsm-analytics-it-api-$RUN_ID"
RUNNER="avsm-analytics-it-runner-$RUN_ID"
IMAGE="${ANALYTICS_IT_IMAGE:-avsm-analytics-api:integration-$RUN_ID}"
WORK_DIR="$(mktemp -d)"

docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }
random_hex() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

ADMIN_PASSWORD="admin_$(random_hex)"
READER_PASSWORD="reader_$(random_hex)"
TOKEN="token_$(random_hex)$(random_hex)"
ADMIN_URL="postgres://metrics_user:${ADMIN_PASSWORD}@postgres:5432/metrics?sslmode=disable&connect_timeout=5"
READER_URL="postgres://metrics_reader:${READER_PASSWORD}@postgres:5432/metrics?sslmode=disable&connect_timeout=5"
HARDENING=(--cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --user 65532:65532)

cleanup() {
  local status=$?
  if (( status != 0 )); then
    printf -- '--- analytics-api container log (tail) ---\n' >&2
    docker logs "$API" 2>&1 | tail -n 40 >&2 || true
  fi
  docker rm --force "$API" "$RUNNER" "$PG" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  if [[ -z "${ANALYTICS_IT_IMAGE:-}" ]]; then docker image rm "$IMAGE" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT

[[ -f "$SCHEMA_FILE" ]] || fail "ingest schema not found at $SCHEMA_FILE"

if [[ -z "${ANALYTICS_IT_IMAGE:-}" ]]; then
  step "Building analytics-api image"
  docker build --quiet --tag "$IMAGE" "$SOURCE_DIR" >/dev/null
fi

step "Cross-compiling the Go test binary"
ARCH="$(docker version --format '{{.Server.Arch}}')"
(cd "$SOURCE_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" go test -c -o "$WORK_DIR/analytics.test" .)

step "Starting PostgreSQL on an internal network"
docker network create --internal "$NETWORK" >/dev/null
docker run --detach --name "$PG" --network "$NETWORK" --network-alias postgres \
  -e POSTGRES_USER=metrics_user -e POSTGRES_PASSWORD="$ADMIN_PASSWORD" -e POSTGRES_DB=metrics \
  postgres:18-alpine >/dev/null
# TCP readiness only succeeds once the final server (not the init server) runs.
for attempt in {1..60}; do
  if docker exec "$PG" pg_isready -h 127.0.0.1 -U metrics_user -d metrics >/dev/null 2>&1; then break; fi
  [[ "$attempt" != 60 ]] || fail "PostgreSQL did not start"
  sleep 1
done

psql_admin() { docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U metrics_user -d metrics "$@"; }

step "Applying ingest schema and seeding sample rows"
tr -d '\r' < "$SCHEMA_FILE" | psql_admin >/dev/null
psql_admin >/dev/null <<'SQL'
INSERT INTO metric_events (clientname, sort_key, event_timestamp, metric, action, event_id, received_at, source_ip)
SELECT c, 'seed', now() - interval '1 hour' + (n * interval '1 minute'), m, a, gen_random_uuid(), now(), '192.0.2.10'
FROM (VALUES
  ('BSS_245', 1, 'System - User', 'Started'),
  ('BSS_245', 2, 'hdmi', 'Started'),
  ('BSS_245', 3, 'Projector_1', 'Started'),
  ('BSS_245', 4, 'Ok', 'Heartbeat'),
  ('BSS_245', 5, 'Btn_Volume_Up Pressed', 'Trace'),
  ('BSS_245', 6, 'System - Inactivity', 'Stopped'),
  ('HOLT_155', 7, 'Ok', 'Heartbeat'),
  ('AVSM-System', 8, 'Update Started', 'Trace')
) AS v(c, n, m, a);
INSERT INTO heartbeat_purge_status VALUES (1, 'succeeded', now() - interval '2 hours', now() - interval '119 minutes', now() - interval '30 days', 30, 0);
SQL

provision() {
  docker run --rm --network "$NETWORK" "${HARDENING[@]}" \
    -e PROVISION_DATABASE_URL="$ADMIN_URL" -e ANALYTICS_DB_PASSWORD="$READER_PASSWORD" \
    "$IMAGE" provision 2>&1
}

step "Provisioning metrics_reader (twice, must be idempotent)"
first="$(provision)" || { printf '%s\n' "$first" >&2; fail "first provisioning run failed"; }
[[ "$first" == *"role metrics_reader created"* && "$first" == *"idx_metric_events_activity_ts created"* ]] \
  || { printf '%s\n' "$first" >&2; fail "unexpected first provisioning summary"; }
second="$(provision)" || { printf '%s\n' "$second" >&2; fail "second provisioning run failed"; }
[[ "$second" == *"role metrics_reader updated"* && "$second" == *"idx_metric_events_heartbeat_client_ts present"* ]] \
  || { printf '%s\n' "$second" >&2; fail "unexpected second provisioning summary"; }
for output in "$first" "$second"; do
  [[ "$output" != *"$READER_PASSWORD"* && "$output" != *"$ADMIN_PASSWORD"* ]] || fail "provisioning output leaked a password"
done
[[ "$(psql_admin -Atc "SELECT has_column_privilege('metrics_reader','metric_events','source_ip','SELECT')")" == f ]] \
  || fail "metrics_reader can read source_ip"
[[ "$(psql_admin -Atc "SELECT rolconfig::text FROM pg_roles WHERE rolname='metrics_reader'")" == *"default_transaction_read_only=on"* ]] \
  || fail "metrics_reader is not read-only by default"
[[ "$(psql_admin -Atc "SELECT has_database_privilege('metrics_reader', current_database(), 'CREATE, TEMPORARY') OR has_function_privilege('metrics_reader', 'lo_from_bytea(oid, bytea)', 'EXECUTE')")" == f ]] \
  || fail "metrics_reader can create temporary tables, schemas, or large objects"

step "Server must refuse to start with the superuser role"
if unsafe="$(docker run --rm --network "$NETWORK" "${HARDENING[@]}" \
    -e ANALYTICS_API_TOKEN="$TOKEN" -e ANALYTICS_DATABASE_URL="$ADMIN_URL" "$IMAGE" 2>&1)"; then
  fail "server started with a superuser database role"
fi
[[ "$unsafe" == *"refusing to start"* && "$unsafe" == *"superuser"* ]] || { printf '%s\n' "$unsafe" >&2; fail "missing unsafe-role message"; }
[[ "$unsafe" != *"$TOKEN"* && "$unsafe" != *"$ADMIN_PASSWORD"* ]] || fail "startup error leaked a secret"

step "Starting the API as metrics_reader"
docker run --detach --name "$API" --network "$NETWORK" --network-alias analytics-api "${HARDENING[@]}" \
  -e ADDR=:8081 -e ANALYTICS_API_TOKEN="$TOKEN" -e ANALYTICS_DATABASE_URL="$READER_URL" \
  "$IMAGE" >/dev/null
for attempt in {1..30}; do
  if docker exec "$API" /app/analytics-api healthcheck >/dev/null 2>&1; then break; fi
  [[ "$attempt" != 30 ]] || fail "analytics-api did not become healthy"
  sleep 1
done

step "Starting the test runner container"
docker run --detach --name "$RUNNER" --network "$NETWORK" --user 65532:65532 \
  --cap-drop ALL --security-opt no-new-privileges:true --entrypoint sleep postgres:18-alpine 900 >/dev/null
docker exec -i "$RUNNER" sh -c 'cat > /tmp/analytics.test && chmod 0755 /tmp/analytics.test' < "$WORK_DIR/analytics.test"
tr -d '\r' < "$SCHEMA_FILE" | docker exec -i "$RUNNER" sh -c 'cat > /tmp/schema.sql'

# http_get PATH [TOKEN] -> prints "<status line>\n<body>"
http_get() {
  docker exec -e TOKEN="${2:-}" -e TARGET="http://analytics-api:8081$1" "$RUNNER" sh -c '
    if [ -n "$TOKEN" ]; then set -- --header "Authorization: Bearer $TOKEN"; fi
    out=$(wget -S -O /tmp/body "$@" "$TARGET" 2>&1); status=$(printf "%s\n" "$out" | grep -m1 "HTTP/1.1" | sed "s/^ *//")
    printf "%s\n" "$status"; cat /tmp/body 2>/dev/null; rm -f /tmp/body'
}
expect() { # expect PATH TOKEN STATUS BODY_FRAGMENT
  local response
  response="$(http_get "$1" "$2")"
  [[ "$response" == *"HTTP/1.1 $3"* ]] || { printf '%s\n' "$response" >&2; fail "GET $1: expected HTTP $3"; }
  [[ -z "$4" || "$response" == *"$4"* ]] || { printf '%s\n' "$response" >&2; fail "GET $1: body lacks $4"; }
  printf '%s' "$response"
}

step "Probing the running API"
expect /health "" 200 '{"ok":true}' >/dev/null
expect /openapi.yaml "" 200 'openapi: 3.1.0' >/dev/null
# busybox wget does not save error bodies; error shapes are covered by Go tests.
expect /api/v1/info "" 401 "" >/dev/null
expect /api/v1/info "wrong-token-wrong-token-wrong-token-1234" 403 "" >/dev/null
expect /api/v1/info "$TOKEN" 200 '"enabled_status":"succeeded"' >/dev/null
expect /api/v1/clients "$TOKEN" 200 '"clientname":"HOLT_155"' >/dev/null
events="$(expect '/api/v1/events?client=BSS_245&limit=2' "$TOKEN" 200 '"next_cursor":"')"
[[ "$events" != *Heartbeat* && "$events" != *192.0.2.10* ]] || fail "events leaked heartbeats or source_ip"
expect '/api/v1/events?client=BSS_245&include_heartbeats=true' "$TOKEN" 200 '"action":"Heartbeat"' >/dev/null
expect '/api/v1/summary?client=BSS_245' "$TOKEN" 200 '"metric":"hdmi"' >/dev/null
expect '/api/v1/heartbeats?bucket=day' "$TOKEN" 200 '"bucket":"day"' >/dev/null
expect '/api/v1/events?limit=0' "$TOKEN" 400 "" >/dev/null
expect /api/v1/nope "$TOKEN" 404 "" >/dev/null
api_logs="$(docker logs "$API" 2>&1)"
[[ "$api_logs" != *"$TOKEN"* && "$api_logs" != *"$READER_PASSWORD"* ]] || fail "API logs leaked a secret"

step "Running database-backed Go tests"
docker exec -e ANALYTICS_TEST_DATABASE_URL="${ADMIN_URL}" -e ANALYTICS_TEST_SCHEMA_FILE=/tmp/schema.sql \
  -e TMPDIR=/tmp -w /tmp "$RUNNER" /tmp/analytics.test -test.run 'TestDatabaseIntegration' -test.v -test.count=1

step "Disabling the feature revokes the database login"
# Same statement as docker-compose.analytics-false.yml.
psql_admin -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='metrics_reader') THEN ALTER ROLE metrics_reader NOLOGIN; PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='metrics_reader'; END IF; END \$\$;" >/dev/null
[[ "$(psql_admin -Atc "SELECT rolcanlogin FROM pg_roles WHERE rolname='metrics_reader'")" == f ]] || fail "metrics_reader can still log in"
for attempt in {1..10}; do
  if [[ "$(http_get /health)" == *"HTTP/1.1 503"* ]]; then break; fi
  [[ "$attempt" != 10 ]] || fail "API still healthy after the login was revoked"
  sleep 1
done
step "Re-provisioning restores the login"
provision >/dev/null || fail "re-provisioning failed"
[[ "$(psql_admin -Atc "SELECT rolcanlogin FROM pg_roles WHERE rolname='metrics_reader'")" == t ]] || fail "login not restored"

echo 'Analytics API PostgreSQL integration tests passed'
